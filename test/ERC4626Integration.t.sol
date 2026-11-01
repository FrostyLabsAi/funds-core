// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {V6Host} from './utils/V6Host.sol';
import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {ComptrollerV6 as Comptroller} from '../src/core/ComptrollerV6.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {ERC4626PriceFeed} from '../src/pricing/ERC4626PriceFeed.sol';
import {ERC4626Adapter} from '../src/adapters/ERC4626Adapter.sol';
import {MockERC20, MockAggregator, MockERC4626Vault} from './utils/Mocks.sol';

contract ERC4626IntegrationTest is Test {
	FundFactory internal factory;
	ValueInterpreter internal interpreter;
	Comptroller internal comptroller;
	MockERC20 internal usdc;
	MockERC4626Vault internal yieldVault;
	ERC4626PriceFeed internal feed4626;
	ERC4626Adapter internal adapter;

	address internal admin = makeAddr('admin');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');

	function setUp() public {
		vm.warp(30 days);
		interpreter = new ValueInterpreter(admin);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		MockAggregator usdcFeed = new MockAggregator(8, 1e8);
		yieldVault = new MockERC4626Vault(IERC20(address(usdc)));
		feed4626 = new ERC4626PriceFeed();

		vm.startPrank(admin);
		interpreter.addPrimitive(address(usdc), address(usdcFeed), 7 days);
		interpreter.addDerivative(address(yieldVault), address(feed4626));
		vm.stopPrank();

		factory = new FundFactory(interpreter, V6Host.deployer(), new SharesVaultDeployer());
		adapter = new ERC4626Adapter();
		factory.registerAdapter(address(adapter));

		comptroller = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Iceberg Yield',
					symbol: 'frICE',
					denominationAsset: IERC20(address(usdc)),
					fundOwner: manager,
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: 0,
					sharesActionTimelock: 0,
					minRequestDuration: 30 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				})
			)
		);

		usdc.mint(alice, 10_000e6);
		vm.startPrank(alice);
		usdc.approve(address(comptroller), 10_000e6);
		comptroller.requestDeposit(10_000e6, type(uint256).max);
		vm.stopPrank();
		skip(30 minutes);
		comptroller.executeDepositRequest(alice);
	}

	function _depositTo4626(uint256 assets, uint256 minShares) internal {
		vm.prank(manager);
		comptroller.callOnIntegration(
			address(adapter), abi.encode(uint8(0), address(yieldVault), assets, minShares)
		);
	}

	function test_derivativePricing_sharesValuedViaUnderlying() public {
		_depositTo4626(4000e6, 4000e6); // 1:1 on an empty vault

		// Vault: 6000 USDC + 4000e6-worth of yUSDC shares, auto-tracked → GAV unchanged
		assertEq(comptroller.getTrackedAssets().length, 2);
		assertEq(comptroller.calcGav(), 10_000e6);
		assertEq(yieldVault.balanceOf(address(comptroller.vault())), 4000e6);

		// Yield accrues: +400 USDC donated to the 4626 → share price ~1.1 → GAV ~10,400
		// (approx: OZ 4626's virtual-offset rounding shaves wei-level dust)
		usdc.mint(address(yieldVault), 400e6);
		assertApproxEqAbs(comptroller.calcGav(), 10_400e6, 2);
	}

	function test_redeemFrom4626_backToVault() public {
		_depositTo4626(4000e6, 4000e6);
		usdc.mint(address(yieldVault), 400e6); // +10% yield

		// Redeem all shares back to USDC (minOut enforced by balance delta)
		uint256 shares = yieldVault.balanceOf(address(comptroller.vault()));
		vm.prank(manager);
		comptroller.callOnIntegration(
			address(adapter), abi.encode(uint8(1), address(yieldVault), shares, uint256(4399e6))
		);

		assertEq(yieldVault.balanceOf(address(comptroller.vault())), 0);
		// 6000 + ~4400 back (rounding down by a wei-level amount is acceptable)
		assertApproxEqAbs(usdc.balanceOf(address(comptroller.vault())), 10_400e6, 2);
	}

	function test_unregistered4626_cannotBeAcquired() public {
		MockERC4626Vault rogueVault = new MockERC4626Vault(IERC20(address(usdc)));
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(Comptroller.AssetNotSupported.selector, address(rogueVault)));
		comptroller.callOnIntegration(
			address(adapter), abi.encode(uint8(0), address(rogueVault), 1000e6, uint256(0))
		);
	}

	function test_derivativeRegistry_rules() public {
		// Quote must be primitive
		vm.expectRevert(
			abi.encodeWithSelector(ValueInterpreter.QuoteAssetMustBePrimitive.selector, address(yieldVault))
		);
		interpreter.calcCanonicalAssetValue(address(usdc), 1e6, address(yieldVault));

		// Cannot double-register as both primitive and derivative
		MockAggregator feed = new MockAggregator(8, 1e8);
		vm.prank(admin);
		vm.expectRevert(abi.encodeWithSelector(ValueInterpreter.AlreadyRegistered.selector, address(yieldVault)));
		interpreter.addPrimitive(address(yieldVault), address(feed), 1 days);

		// Feed must actually support the asset (a plain ERC20 has no asset() function)
		MockERC20 plain = new MockERC20('Plain', 'PLN', 18);
		vm.prank(admin);
		vm.expectRevert(abi.encodeWithSelector(ValueInterpreter.FeedDoesNotSupportAsset.selector, address(plain)));
		interpreter.addDerivative(address(plain), address(feed4626));

		// calcUsdRate on the share: 1.0 → $1 per share-unit (18 dec share on 6 dec asset)
		uint256 rate = interpreter.calcUsdRate(address(yieldVault));
		assertApproxEqRel(rate, 1e18, 0.01e18);
	}
}
