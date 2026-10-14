// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {ComptrollerV6} from '../../src/core/ComptrollerV6.sol';
import {RedemptionQueueV2} from '../../src/redemption/RedemptionQueueV2.sol';
import {ComptrollerV6Lib} from '../../src/core/ComptrollerV6Lib.sol';
import {ViaWethSellAdapter} from '../../src/adapters/ViaWethSellAdapter.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {V4Pricing} from '../../script/mainnet/V4Pricing.sol';
import {RedemptionQueueV2ShortDeadline} from '../utils/RedemptionQueueV2ShortDeadline.sol';

/// @notice A ghosted v6 fund holding feed-priced tokens whose liquidity is against WETH (exit audit 2026-10-14): the
///         keeper sells cbETH (cbETH → WETH on Slipstream-1 ts1, WETH → USDC on Uniswap v3 0.05%) and WELL (WELL → WETH
///         on Aerodrome's volatile pool, WETH → USDC on Slipstream-1 ts100) through ViaWethSellAdapter, within the 3%
///         cap, and the leaver is paid in USDC. A plain sale into WETH is refused (NotASale). Live Base (block
///         52,607,800, as ERC4626ExitFork); a 1-second deadline queue as FundV6Fork's.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/ViaWethSellFork.t.sol -vv
contract ViaWethSellForkTest is Test {
	uint256 internal constant FORK_BLOCK = 52_607_800;
	address internal constant USDC = FundsMainnet.USDC;
	address internal constant WETH = FundsMainnet.WETH;
	address internal constant CBETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
	address internal constant WELL = 0xA88594D404727625A9437C3f886C7643872296AE;

	bool internal forked;
	address internal deployer;
	FundFactory internal factory;
	address internal uniAdapter;
	address internal slipstreamAdapter;
	address internal aerodromeBasicAdapter;
	RedemptionQueueV2 internal queue;
	ViaWethSellAdapter internal sellAdapter;
	address internal manager = makeAddr('manager');
	address internal investor = makeAddr('investor');
	address internal keeper = makeAddr('keeper');

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, FORK_BLOCK);
		forked = true;
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		string memory v4 = vm.readFile('deployments/base-mainnet-v4.json');
		deployer = vm.parseJsonAddress(genesis, '.deployer');
		factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		uniAdapter = vm.parseJsonAddress(v4, '.uniAdapter');
		slipstreamAdapter = vm.parseJsonAddress(v4, '.slipstreamAdapter');
		aerodromeBasicAdapter = vm.parseJsonAddress(v4, '.aerodromeBasicAdapter');
		address registrarV2 = vm.parseJsonAddress(v4, '.registrar');
		address perpConfig = vm.parseJsonAddress(genesis, '.verantaFactory');

		queue = new RedemptionQueueV2ShortDeadline(address(this));
		queue.setFactory(address(factory));
		queue.setKeeper(keeper, true);
		ComptrollerBlueprintDeployer shortDeployer =
			new ComptrollerBlueprintDeployer(type(ComptrollerV6).creationCode, abi.encode(registrarV2, queue, perpConfig));
		sellAdapter = new ViaWethSellAdapter(
			WETH,
			FundsMainnet.UNI_SWAP_ROUTER02,
			FundsMainnet.CL_SWAP_ROUTER,
			FundsMainnet.CL2_SWAP_ROUTER,
			FundsMainnet.CL3_SWAP_ROUTER,
			FundsMainnet.AERODROME_ROUTER,
			FundsMainnet.AERODROME_POOL_FACTORY,
			V4Pricing.TREASURY,
			V4Pricing.FEE_BPS,
			deployer
		);
		vm.startPrank(deployer);
		factory.setComptrollerDeployer(shortDeployer);
		factory.registerAdapter(address(sellAdapter));
		vm.stopPrank();
	}

	function test_fork_keeperSellsCbEthAndWellThroughWeth_andSettlesInUsdc() public {
		vm.skip(!forked);
		ComptrollerV6 fund = _fundHoldingWethPairTokens();
		address v = address(fund.vault());
		uint256 cbeth = IERC20(CBETH).balanceOf(v);
		uint256 well = IERC20(WELL).balanceOf(v);
		_overdueRedemption(fund);

		uint256 gavBefore = fund.calcGav();
		uint256 treasuryCbeth = IERC20(CBETH).balanceOf(V4Pricing.TREASURY);
		uint256 treasuryWell = IERC20(WELL).balanceOf(V4Pricing.TREASURY);
		vm.startPrank(keeper);
		queue.liquidate(
			address(fund),
			address(sellAdapter),
			_sale(CBETH, cbeth, _hop(ViaWethSellAdapter.Venue.Slipstream1, 1), _hop(ViaWethSellAdapter.Venue.UniswapV3, 500))
		);
		queue.liquidate(
			address(fund),
			address(sellAdapter),
			_sale(WELL, well, _hop(ViaWethSellAdapter.Venue.AerodromeBasic, 0), _hop(ViaWethSellAdapter.Venue.Slipstream1, 100))
		);
		vm.stopPrank();
		assertEq(IERC20(CBETH).balanceOf(v), 0, 'all cbETH sold');
		assertEq(IERC20(WELL).balanceOf(v), 0, 'all WELL sold');
		assertEq(IERC20(WETH).balanceOf(v), 0, 'no WETH came back');
		assertEq(IERC20(CBETH).balanceOf(address(sellAdapter)), 0);
		assertEq(IERC20(WELL).balanceOf(address(sellAdapter)), 0);
		assertEq(IERC20(WETH).balanceOf(address(sellAdapter)), 0);
		assertEq(IERC20(CBETH).balanceOf(V4Pricing.TREASURY) - treasuryCbeth, cbeth * 5 / 10_000, 'the protocol fee, 5 bps');
		assertEq(IERC20(WELL).balanceOf(V4Pricing.TREASURY) - treasuryWell, well * 5 / 10_000);
		uint256 gavAfter = fund.calcGav();
		emit log_named_int('sale cost vs oracle value (USDC, 6 decimals)', int256(gavBefore) - int256(gavAfter));
		assertGt(gavAfter, gavBefore * 9_970 / 10_000, 'within the 3% cap, and far under it');
		assertApproxEqAbs(IERC20(USDC).balanceOf(v), gavAfter, 1, 'the fund is all USDC');

		uint256 shares = fund.shares().balanceOf(address(queue));
		uint256 supply = fund.shares().totalSupply();
		vm.prank(keeper);
		assertEq(queue.settle(address(fund), 1), 1);
		assertApproxEqAbs(IERC20(USDC).balanceOf(investor), gavAfter * shares / supply, 2, 'paid in USDC');
	}

	/// The sale this adapter exists for: cbETH sold into WETH is not a sale (cbETH is feed-priced).
	function test_fork_aPlainSaleIntoWethIsNotASale() public {
		vm.skip(!forked);
		ComptrollerV6 fund = _fundHoldingWethPairTokens();
		uint256 cbeth = IERC20(CBETH).balanceOf(address(fund.vault()));
		_overdueRedemption(fund);
		vm.prank(keeper);
		vm.expectRevert(ComptrollerV6Lib.NotASale.selector);
		queue.liquidate(address(fund), slipstreamAdapter, abi.encode(CBETH, WETH, int24(1), cbeth, uint256(0)));
	}

	function _hop(ViaWethSellAdapter.Venue venue, int24 param) internal pure returns (ViaWethSellAdapter.Hop memory) {
		return ViaWethSellAdapter.Hop(venue, param);
	}

	function _sale(address token, uint256 amount, ViaWethSellAdapter.Hop memory toWeth, ViaWethSellAdapter.Hop memory fromWeth)
		internal
		pure
		returns (bytes memory)
	{
		return abi.encode(token, amount, uint256(0), USDC, toWeth, fromWeth);
	}

	/// @dev 20k USDC in; the manager buys ~16k of WETH, then cbETH with ~8k of it on Slipstream-1 and WELL with the
	///      rest on Aerodrome: what a fund holds after buying them where they trade.
	function _fundHoldingWethPairTokens() internal returns (ComptrollerV6 fund) {
		fund = ComptrollerV6(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'WETH pairs fund',
					symbol: 'frWP',
					denominationAsset: IERC20(USDC),
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
		deal(USDC, investor, 20_000e6);
		vm.startPrank(investor);
		IERC20(USDC).approve(address(fund), 20_000e6);
		fund.requestDeposit(20_000e6, type(uint256).max);
		vm.stopPrank();
		vm.warp(block.timestamp + 1 minutes);
		vm.roll(block.number + 30);
		fund.executeDepositRequest(investor);

		address v = address(fund.vault());
		vm.startPrank(manager);
		fund.callOnIntegration(uniAdapter, abi.encode(USDC, WETH, uint24(500), uint256(16_000e6), uint256(0)));
		uint256 weth = IERC20(WETH).balanceOf(v);
		fund.callOnIntegration(slipstreamAdapter, abi.encode(WETH, CBETH, int24(1), weth / 2, uint256(0)));
		fund.callOnIntegration(aerodromeBasicAdapter, abi.encode(WETH, WELL, IERC20(WETH).balanceOf(v), uint256(0)));
		vm.stopPrank();
		assertGt(IERC20(CBETH).balanceOf(v), 0);
		assertGt(IERC20(WELL).balanceOf(v), 0);
		assertEq(IERC20(WETH).balanceOf(v), 0);
	}

	/// @dev The investor asks for half; the 1-second deadline passes.
	function _overdueRedemption(ComptrollerV6 fund) internal {
		uint256 shares = fund.shares().balanceOf(investor) / 2;
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(address(queue), shares);
		queue.requestRedeem(address(fund), shares);
		vm.stopPrank();
		vm.warp(block.timestamp + 2);
		vm.roll(block.number + 1);
		assertTrue(queue.isOverdue(address(fund)));
	}
}
