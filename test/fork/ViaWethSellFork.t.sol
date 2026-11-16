// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {ComptrollerLib} from '../../src/core/ComptrollerLib.sol';
import {RedemptionQueue} from '../../src/redemption/RedemptionQueue.sol';
import {ViaWethSellAdapter} from '../../src/adapters/ViaWethSellAdapter.sol';
import {BaseMainnet} from '../../script/release/BaseMainnet.sol';
import {ReleaseFork} from './utils/ReleaseFork.sol';

/// @notice A ghosted fund holding feed-priced tokens whose liquidity is against WETH (exit audit 2026-10-14): the
///         keeper sells cbETH (cbETH → WETH on Slipstream-1 ts1, WETH → USDC on Uniswap v3 0.05%) and WELL (WELL → WETH
///         on Aerodrome's volatile pool, WETH → USDC on Slipstream-1 ts100) through ViaWethSellAdapter, within the 3%
///         cap, and the leaver is paid in USDC. A plain sale into WETH is refused (NotASale). The release on Base at
///         block 52,607,800, cbETH and WELL listed with the feeds the live VI used there; a 1-second deadline queue.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/ViaWethSellFork.t.sol -vv
contract ViaWethSellForkTest is ReleaseFork {
	address internal constant CBETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
	address internal constant WELL = 0xA88594D404727625A9437C3f886C7643872296AE;
	address internal constant TREASURY = BaseMainnet.TREASURY;

	RedemptionQueue internal queue;
	ViaWethSellAdapter internal sellAdapter;

	function _forkBlock() internal pure override returns (uint256) {
		return 52_607_800;
	}

	function setUp() public override {
		super.setUp();
		if (!forked) return;
		_copyFeed(CBETH);
		_copyFeed(WELL);
		queue = _shortDeadlineQueue();
		sellAdapter = r.adapters.viaWeth;
	}

	function test_fork_keeperSellsCbEthAndWellThroughWeth_andSettlesInUsdc() public {
		vm.skip(!forked);
		Comptroller fund = _fundHoldingWethPairTokens();
		address v = address(fund.vault());
		uint256 cbeth = IERC20(CBETH).balanceOf(v);
		uint256 well = IERC20(WELL).balanceOf(v);
		_overdueRedemption(fund, queue);

		uint256 gavBefore = fund.calcGav();
		uint256 treasuryCbeth = IERC20(CBETH).balanceOf(TREASURY);
		uint256 treasuryWell = IERC20(WELL).balanceOf(TREASURY);
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
		assertEq(IERC20(CBETH).balanceOf(TREASURY) - treasuryCbeth, cbeth * 5 / 10_000, 'the protocol fee, 5 bps');
		assertEq(IERC20(WELL).balanceOf(TREASURY) - treasuryWell, well * 5 / 10_000);
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
		Comptroller fund = _fundHoldingWethPairTokens();
		uint256 cbeth = IERC20(CBETH).balanceOf(address(fund.vault()));
		_overdueRedemption(fund, queue);
		vm.prank(keeper);
		vm.expectRevert(ComptrollerLib.NotASale.selector);
		queue.liquidate(address(fund), address(r.adapters.slipstream1), abi.encode(CBETH, WETH, int24(1), cbeth, uint256(0), uint256(0)));
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
	function _fundHoldingWethPairTokens() internal returns (Comptroller fund) {
		fund = _fundWithDeposit(20_000e6);
		address v = address(fund.vault());
		vm.startPrank(manager);
		fund.callOnIntegration(address(r.adapters.uniswapV3), abi.encode(USDC, WETH, uint24(500), uint256(16_000e6), uint256(0)));
		uint256 weth = IERC20(WETH).balanceOf(v);
		fund.callOnIntegration(
			address(r.adapters.slipstream1), abi.encode(WETH, CBETH, int24(1), weth / 2, uint256(0), uint256(0))
		);
		fund.callOnIntegration(
			address(r.adapters.aerodromeBasic), abi.encode(WETH, WELL, IERC20(WETH).balanceOf(v), uint256(0))
		);
		vm.stopPrank();
		assertGt(IERC20(CBETH).balanceOf(v), 0);
		assertGt(IERC20(WELL).balanceOf(v), 0);
		assertEq(IERC20(WETH).balanceOf(v), 0);
	}
}
