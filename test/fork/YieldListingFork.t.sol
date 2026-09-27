// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {ERC4626PriceFeed} from '../../src/pricing/ERC4626PriceFeed.sol';
import {MockERC20} from '../utils/Mocks.sol';
import {VerantaFundingFixture as Fx} from '../utils/VerantaFundingFixture.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {YieldListing} from '../../script/mainnet/YieldListing.sol';

/// @notice The yield listing batch on the genesis deployment against the REAL vaults on Base:
///         Aave V3 static aTokens and Morpho MetaMorpho vaults become VI derivatives, and a
///         fund deposits into / redeems from them through the generic ERC4626Adapter with NAV
///         intact. The IPOR stock carry vaults hold B20 stock tokens, which Foundry cannot
///         execute — so here they must be REFUSED while their stock is unpriced (the listing
///         script runs after list-coinbase-stocks.sh on mainnet).
///         Run: BASE_MAINNET_RPC=<url> forge test --match-path test/fork/YieldListingFork.t.sol
contract YieldListingForkTest is Test {
	address internal constant SAFE = 0xB0f37bE90a8BD82D991Bf694F960C67198778B8B;

	bool internal forked;
	address internal deployer = makeAddr('deployer');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');
	FundsMainnet.Deployed internal d;
	address internal feed;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, Fx.BLOCK);
		forked = true;
		MockERC20 frostStandIn = new MockERC20('FROST stand-in', 'FROST', 18);
		vm.startPrank(deployer);
		d = FundsMainnet.deploy(
			FundsMainnet.Config({deployer: deployer, safe: SAFE, frost: address(frostStandIn), autopilotKeeper: makeAddr('keeper'), protocolFeeBps: 25})
		);
		feed = address(new ERC4626PriceFeed());
		vm.stopPrank();
	}

	function _list() internal returns (uint256 listed) {
		vm.startPrank(deployer);
		listed = YieldListing.listAll(d.valueInterpreter, feed, YieldListing.nonStockVaults());
		vm.stopPrank();
	}

	function test_fork_everyNonStockVaultIsListed_andValuedAtItsUnderlying() public {
		vm.skip(!forked);
		assertEq(_list(), YieldListing.nonStockVaults().length);
		address[] memory vaults = YieldListing.nonStockVaults();
		for (uint256 i; i < vaults.length; ++i) {
			assertTrue(d.valueInterpreter.isSupportedAsset(vaults[i]));
		}
		// one whole Aave static-aUSDC share is worth at least one USDC (interest only accrues)
		uint256 oneShare = d.valueInterpreter.calcCanonicalAssetValue(YieldListing.AAVE_STATIC_USDC, 1e6, FundsMainnet.USDC);
		assertGe(oneShare, 1e6);
		assertLt(oneShare, 2e6);
	}

	function test_fork_aFundEarnsInAaveAndMorpho_navIntact() public {
		vm.skip(!forked);
		_list();
		Comptroller fund = _fundWithDeposit(10_000e6);
		uint256 gav0 = fund.calcGav();
		_erc4626(fund, 0, YieldListing.AAVE_STATIC_USDC, 3_000e6);
		_erc4626(fund, 0, YieldListing.MORPHO_GAUNTLET_USDC_PRIME, 3_000e6);
		assertApproxEqRel(fund.calcGav(), gav0, 0.0005e18, 'depositing moves value, not NAV');
		assertGt(IERC20(YieldListing.AAVE_STATIC_USDC).balanceOf(address(fund.vault())), 0);
		assertGt(IERC20(YieldListing.MORPHO_GAUNTLET_USDC_PRIME).balanceOf(address(fund.vault())), 0);

		uint256 shares = IERC20(YieldListing.MORPHO_GAUNTLET_USDC_PRIME).balanceOf(address(fund.vault()));
		_erc4626(fund, 1, YieldListing.MORPHO_GAUNTLET_USDC_PRIME, shares);
		assertEq(IERC20(YieldListing.MORPHO_GAUNTLET_USDC_PRIME).balanceOf(address(fund.vault())), 0, 'redeemed out');
		assertApproxEqRel(fund.calcGav(), gav0, 0.0005e18);
	}

	function test_fork_aStockVaultIsRefusedWhileItsStockIsUnpriced() public {
		vm.skip(!forked);
		address[] memory one = new address[](1);
		one[0] = YieldListing.IPOR_GOOGL_CARRY;
		vm.expectRevert(
			abi.encodeWithSelector(YieldListing.UnderlyingNotPriced.selector, YieldListing.IPOR_GOOGL_CARRY, YieldListing.GOOGLC)
		);
		this.listExternal(one);
	}

	function listExternal(address[] memory vaults) external {
		vm.startPrank(deployer);
		YieldListing.listAll(d.valueInterpreter, feed, vaults);
		vm.stopPrank();
	}

	function test_fork_listingTwiceIsANoOp() public {
		vm.skip(!forked);
		_list();
		assertEq(_list(), 0);
	}

	function _erc4626(Comptroller fund, uint8 action, address vault, uint256 amount) internal {
		vm.prank(manager);
		fund.callOnIntegration(d.erc4626Adapter, abi.encode(action, vault, amount, uint256(0)));
	}

	function _fundWithDeposit(uint256 amount) internal returns (Comptroller fund) {
		fund = Comptroller(
			d.factory.createFund(
				FundFactory.FundConfig({
					name: 'Yield Fund',
					symbol: 'frYLD',
					denominationAsset: IERC20(FundsMainnet.USDC),
					fundOwner: manager,
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: 0,
					sharesActionTimelock: 0,
					minRequestDuration: 1 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				})
			)
		);
		deal(FundsMainnet.USDC, alice, amount);
		vm.startPrank(alice);
		IERC20(FundsMainnet.USDC).approve(address(fund), amount);
		fund.requestDeposit(amount);
		vm.stopPrank();
		skip(1 minutes);
		fund.executeDepositRequest(alice);
	}
}
