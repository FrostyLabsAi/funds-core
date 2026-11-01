// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {V6Host} from './utils/V6Host.sol';
import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {ComptrollerV6 as Comptroller} from '../src/core/ComptrollerV6.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {CompounderPriceFeed} from '../src/pricing/CompounderPriceFeed.sol';
import {CompounderAdapter} from '../src/adapters/CompounderAdapter.sol';
import {FrostyCompounder} from '../src/yield/FrostyCompounder.sol';
import {IUniswapV3NonfungiblePositionManager} from '../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {MockERC20, MockAggregator, MockUniV3PositionManager} from './utils/Mocks.sol';

/// @notice FUND-PARITY coverage (founder call): funds must be able to hold the revenue
///         compounder. Shares price through the CompounderPriceFeed (oracle-fair
///         decomposition — never the pool's spot price) and flow through the
///         CompounderAdapter on normal callOnIntegration rails.
contract CompounderIntegrationTest is Test {
	FundFactory internal factory;
	ValueInterpreter internal interpreter;
	Comptroller internal comptroller;
	MockUniV3PositionManager internal npm;
	MockERC20 internal usdc; // token0 — redeploy loop below guarantees the ordering
	MockERC20 internal teth; // token1
	FrostyCompounder internal compounder;
	CompounderPriceFeed internal feed;
	CompounderAdapter internal adapter;

	address internal admin = makeAddr('admin');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');
	address internal treasury = makeAddr('treasury');

	function setUp() public {
		vm.warp(30 days);
		interpreter = new ValueInterpreter(admin);
		npm = new MockUniV3PositionManager();

		usdc = new MockERC20('USD Coin', 'USDC', 6);
		teth = new MockERC20('Test ETH', 'tETH', 18);
		// FrostyCompounder requires pool ordering (token0 < token1); nonce-bump until true
		while (address(usdc) >= address(teth)) {
			teth = new MockERC20('Test ETH', 'tETH', 18);
		}

		vm.startPrank(admin);
		interpreter.addPrimitive(address(usdc), address(new MockAggregator(8, 1e8)), 7 days);
		interpreter.addPrimitive(address(teth), address(new MockAggregator(8, 2_500e8)), 7 days);
		vm.stopPrank();

		compounder = new FrostyCompounder(
			'Frosty Compounding tETH-tUSDC', 'fcETH',
			IUniswapV3NonfungiblePositionManager(address(npm)),
			IERC20(address(usdc)), IERC20(address(teth)), 3000, 887220, 1500, treasury
		);
		feed = new CompounderPriceFeed(interpreter);
		vm.prank(admin);
		interpreter.addDerivative(address(compounder), address(feed));

		factory = new FundFactory(interpreter, V6Host.deployer(), new SharesVaultDeployer());
		adapter = new CompounderAdapter();
		factory.registerAdapter(address(adapter));

		comptroller = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Compounding Fund',
					symbol: 'frCOMP',
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

		// The fund also holds tETH for the two-sided deposit (tracked by the manager)
		vm.prank(manager);
		comptroller.addTrackedAsset(address(teth));
		teth.mint(address(comptroller.vault()), 2e18);
	}

	function _fundDeposit(uint256 amount0, uint256 amount1, uint128 liquidity) internal {
		npm.setNextLiquidity(liquidity);
		vm.prank(manager);
		comptroller.callOnIntegration(
			address(adapter), abi.encode(uint8(0), address(compounder), amount0, amount1, uint256(0))
		);
	}

	function test_fundDeposits_sharesTrackedAndGavConsistent() public {
		_fundDeposit(4_000e6, 1.6e18, 5_000e6);

		address vault = address(comptroller.vault());
		assertEq(compounder.balanceOf(vault), 4_999e6); // shares landed in the fund's vault (minus the 1e6 bootstrap seed)
		assertEq(usdc.balanceOf(address(adapter)), 0); // nothing stuck in the adapter
		assertEq(teth.balanceOf(address(adapter)), 0);

		// GAV must equal remaining holdings + the feed's valuation of the shares —
		// i.e. auto-tracking picked the derivative up and prices it via the feed
		// value the vault's ACTUAL holding (4,999e6 — the 1e6 bootstrap seed stays with the sink)
		(address[] memory unders, uint256[] memory amts) = feed.calcUnderlyingValues(address(compounder), 4_999e6);
		uint256 shareValue = interpreter.calcCanonicalAssetValue(unders[0], amts[0], address(usdc))
			+ interpreter.calcCanonicalAssetValue(unders[1], amts[1], address(usdc));
		uint256 holdings = interpreter.calcCanonicalAssetValue(address(usdc), usdc.balanceOf(vault), address(usdc))
			+ interpreter.calcCanonicalAssetValue(address(teth), teth.balanceOf(vault), address(usdc));
		assertEq(comptroller.calcGav(), holdings + shareValue);
		assertGt(shareValue, 0);
		// (value CONSERVATION needs the real NPM's liquidity math — the mock invents
		// liquidity numbers; that property is proven by script/probe/run-compounder-e2e.sh)
	}

	function test_pendingFees_raiseShareValueProRata() public {
		_fundDeposit(4_000e6, 1.6e18, 5_000e6);
		(, uint256[] memory before_) = feed.calcUnderlyingValues(address(compounder), 5_000e6);

		npm.addOwedFees(1, 0.1e18, 250e6); // owed0 is token0 (usdc) in the mock? — args are (fee0, fee1)
		(, uint256[] memory after_) = feed.calcUnderlyingValues(address(compounder), 5_000e6);
		assertEq(after_[0] - before_[0], 0.1e18 > 0 ? uint256(0.1e18) : 0); // full supply → full fees
		assertEq(after_[1] - before_[1], 250e6);
	}

	function test_feedLinearity_andSupportProbe() public {
		_fundDeposit(4_000e6, 1.6e18, 5_000e6);
		(, uint256[] memory whole) = feed.calcUnderlyingValues(address(compounder), 5_000e6);
		(, uint256[] memory half) = feed.calcUnderlyingValues(address(compounder), 2_500e6);
		assertApproxEqAbs(half[0] * 2, whole[0], 2);
		assertApproxEqAbs(half[1] * 2, whole[1], 2);

		assertTrue(feed.isSupportedAsset(address(compounder)));
		assertFalse(feed.isSupportedAsset(address(usdc)));
	}

	function test_fundWithdraws_tokensBackToVault() public {
		_fundDeposit(4_000e6, 1.6e18, 5_000e6);
		address vault = address(comptroller.vault());
		uint256 usdcBefore = usdc.balanceOf(vault);
		uint256 tethBefore = teth.balanceOf(vault);

		npm.setNextDecreaseAmounts(uint128(2_000e6), uint128(0.8e18));
		vm.prank(manager);
		comptroller.callOnIntegration(
			address(adapter), abi.encode(uint8(1), address(compounder), uint256(2_500e6), uint256(0), uint256(0))
		);

		assertEq(compounder.balanceOf(vault), 2_499e6); // 4,999e6 after the bootstrap seed − 2,500e6
		assertEq(usdc.balanceOf(vault) - usdcBefore, 2_000e6);
		assertEq(teth.balanceOf(vault) - tethBefore, 0.8e18);
		assertEq(usdc.balanceOf(address(adapter)), 0);
		assertEq(teth.balanceOf(address(adapter)), 0);
	}
}
