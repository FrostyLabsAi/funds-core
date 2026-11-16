// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {ComptrollerLib} from '../../src/core/ComptrollerLib.sol';
import {IValueInterpreterAdmin} from '../../src/interfaces/IValueInterpreterAdmin.sol';
import {IVerantaMulticall, IVerantaTradingStorage} from '../../src/interfaces/external/IVeranta.sol';
import {VerantaPerpPosition} from '../../src/positions/VerantaPerpPosition.sol';
import {VerantaPriceAdapter} from '../../src/pricing/VerantaPriceAdapter.sol';
import {VerantaPriceStore} from '../../src/pricing/VerantaPriceStore.sol';
import {RedemptionQueue} from '../../src/redemption/RedemptionQueue.sol';
import {BaseMainnet} from '../../script/release/BaseMainnet.sol';
import {ReleaseFork} from './utils/ReleaseFork.sol';
import {IVerantaOperatorRouter} from './utils/IVerantaOperatorRouter.sol';

/// @notice A ghosted fund holding a real Veranta perp (founder 2026-10-11, USDC-only exit): the release at the block of a
///         real pair-129 Lazer packet and operator fill, on a 1-second-deadline queue, with pair 129's marker priced from
///         the release's store. The keeper settles what the vault covers, closes the rest of the request's need on
///         Veranta, collects the USDC once Veranta's operator fills the close, and settles the rest; the investor is paid
///         in USDC.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/FundPerpLiquidationFork.t.sol -vv
contract FundPerpLiquidationForkTest is ReleaseFork {
	address internal constant ROUTER = BaseMainnet.VERANTA_ROUTER;
	address internal constant MULTICALL = BaseMainnet.VERANTA_MULTICALL;
	address internal constant TRADING_STORAGE = BaseMainnet.VERANTA_STORAGE;
	uint256 internal constant PERP_TYPE = BaseMainnet.VERANTA_PERP_TYPE;
	address internal constant VERANTA_OPERATOR = 0xe8f6E3281AAa99404003ecA9fb0653d751D4BC92;
	uint256 internal constant PAIR = 129;
	bytes internal constant PACKET =
		hex'2a22999aaf1341602a82157b55c523c737d5e5c4d90e619723a8b66395d136e675b6fd7745d0405770a1894b06ce2afceddf0260e82a3ccc7335d277767ae78e208578ad00003293c7d37500065d21f1d4730003010000055d040000000000006f7b100500000000000007d004fffb0c0100065d21f1d47300';
	uint256 internal constant PACKET_TS = 1_791_250_232;
	uint256 internal constant PACKET_PRICE = 730_600_000_000; // $73.06 at 1e10

	RedemptionQueue internal queue;
	VerantaPriceStore internal store;

	/// @dev The packet's block.
	function _forkBlock() internal pure override returns (uint256) {
		return 52_230_324;
	}

	function setUp() public override {
		super.setUp();
		if (!forked) return;
		queue = _shortDeadlineQueue();
		store = r.verantaStore;
		address marker = _copyPairAsset(PAIR);
		VerantaPriceAdapter feed = new VerantaPriceAdapter(
			store, PAIR, BaseMainnet.VERANTA_MAX_PUSH_AGE, BaseMainnet.VERANTA_MAX_FEED_AGE, 'pair 129 / USD'
		);
		r.registrar.execute(abi.encodeCall(IValueInterpreterAdmin.addPrimitive, (marker, address(feed), 600)));
	}

	function test_fork_aGhostedPerpFund_isClosedOnVeranta_andTheLeaverPaidInUsdc() public {
		vm.skip(!forked);
		(Comptroller fund, address account) = _fundWithFilledTrade(1_000e6, 800e6); // vault 200, trade 800
		uint256 shares = fund.shares().balanceOf(investor) / 2;
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(address(queue), shares);
		uint256 id = queue.requestRedeem(address(fund), shares);
		vm.stopPrank();
		vm.warp(block.timestamp + 2); // overdue under the test queue's 1-second deadline
		_push();
		uint256 supply = fund.shares().totalSupply();
		uint256 gav = fund.calcGav();

		// what the vault covers now, in part
		vm.prank(keeper);
		queue.settle(address(fund), 1);
		uint256 firstPaid = IERC20(USDC).balanceOf(investor);
		assertApproxEqAbs(firstPaid, 200e6, 1, 'the vault had 200');
		assertTrue(queue.requestAt(address(fund), id).open, 'the rest waits');

		// a close of nothing is refused; half the trade closes on Veranta, the operator fills it
		vm.prank(keeper);
		vm.expectRevert(ComptrollerLib.CloseOfNothing.selector);
		queue.liquidatePosition(address(fund), account, new address[](0), _one(_closeTrade(0)));
		uint256 collateral = _collateral(account);
		vm.prank(keeper);
		queue.liquidatePosition(address(fund), account, new address[](0), _one(_closeTrade(collateral / 2)));
		_fillPending(account);
		assertApproxEqAbs(_collateral(account), collateral - collateral / 2, 1, 'half the trade closed');

		// the close's USDC back to the vault, then the rest of the request settles
		uint256 idle = IERC20(USDC).balanceOf(account);
		assertGt(idle, 0);
		address[] memory back = new address[](1);
		back[0] = USDC;
		vm.prank(keeper);
		queue.liquidatePosition(
			address(fund), account, back, _one(abi.encode(uint8(VerantaPerpPosition.Action.ReturnToVault), abi.encode(idle)))
		);
		_push();
		vm.prank(keeper);
		queue.settle(address(fund), 1);
		assertFalse(queue.requestAt(address(fund), id).open, 'paid');
		assertApproxEqRel(IERC20(USDC).balanceOf(investor), Math.mulDiv(gav, shares, supply), 0.005e18, 'its share, within the close costs');
	}

	/// A filled long reports its pair's marker, which the fund never tracked (the open ran trackHeld before Veranta's
	/// operator filled it). At a full tracked set (20) the keeper's close went into TrackedAssetsLimitReached, and the
	/// investor got only the vault's USDC (red-team POSITIONS-01, 2026-10-27). The marker is now tracked past the cap
	/// (MAX_TRACKED_ASSETS: 20 then, 30 since 2026-11-05).
	function test_fork_aLongOnAFullTrackedSet_isClosedByTheKeeper_andTheLeaverPaid() public {
		vm.skip(!forked);
		(Comptroller fund, address account) = _fundWithFilledTrade(1_000e6, 800e6); // vault 200, trade 800
		_fillTrackedSet(fund, account);
		uint256 max = fund.MAX_TRACKED_ASSETS();
		assertEq(fund.getTrackedAssets().length, max, 'tracked set full');
		uint256 shares = fund.shares().balanceOf(investor);
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(address(queue), shares);
		uint256 id = queue.requestRedeem(address(fund), shares);
		vm.stopPrank();
		vm.warp(block.timestamp + 2); // overdue under the test queue's 1-second deadline
		_push();
		uint256 gav = fund.calcGav();

		uint256 collateral = _collateral(account);
		vm.prank(keeper);
		queue.liquidatePosition(address(fund), account, new address[](0), _one(_closeTrade(collateral)));
		assertEq(fund.getTrackedAssets().length, max + 1, "the long's marker is tracked past the cap");
		_fillPending(account);
		assertEq(_collateral(account), 0, 'closed on Veranta');

		uint256 idle = IERC20(USDC).balanceOf(account);
		address[] memory back = new address[](1);
		back[0] = USDC;
		vm.prank(keeper);
		queue.liquidatePosition(
			address(fund), account, back, _one(abi.encode(uint8(VerantaPerpPosition.Action.ReturnToVault), abi.encode(idle)))
		);
		_push();
		vm.prank(keeper);
		queue.settle(address(fund), 1);
		assertFalse(queue.requestAt(address(fund), id).open, 'paid in full');
		assertApproxEqRel(IERC20(USDC).balanceOf(investor), gav, 0.005e18, 'the whole fund, within the close costs');
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	function _one(bytes memory action) internal pure returns (bytes[] memory actions) {
		actions = new bytes[](1);
		actions[0] = action;
	}

	function _closeTrade(uint256 amount) internal pure returns (bytes memory) {
		return abi.encode(uint8(VerantaPerpPosition.Action.CloseTrade), abi.encode(PAIR, uint256(0), amount, PACKET_PRICE));
	}

	function _fundWithFilledTrade(uint256 deposit, uint256 collateral) internal returns (Comptroller fund, address account) {
		fund = _fundWithDeposit(deposit);

		vm.prank(manager);
		account = fund.createExternalPosition(PERP_TYPE, '');
		vm.roll(block.number + (PACKET_TS - 20 - block.timestamp) / 2);
		vm.warp(PACKET_TS - 20);
		address[] memory assets = new address[](1);
		assets[0] = USDC;
		uint256[] memory amounts = new uint256[](1);
		amounts[0] = collateral;
		bytes memory open = abi.encode(
			uint8(VerantaPerpPosition.Action.OpenTrade),
			abi.encode(PAIR, collateral, uint256(5e10), true, PACKET_PRICE, uint256(1e10), uint8(0), uint256(0), uint256(0))
		);
		vm.prank(manager);
		fund.callOnExternalPosition(account, assets, amounts, new address[](0), open);
		vm.roll(block.number + 11);
		vm.warp(PACKET_TS + 2);
		_fillPending(account);
	}

	function _push() internal {
		vm.deal(address(this), 1 ether);
		store.submit{value: 1}(PAIR, PACKET);
	}

	function _fillPending(address account) internal {
		IVerantaMulticall.PendingOrder[] memory pending = IVerantaMulticall(MULTICALL).getPendingOrder(account);
		require(pending.length == 1, 'one pending order');
		bytes[] memory update = new bytes[](1);
		update[0] = PACKET;
		vm.deal(VERANTA_OPERATOR, 1 ether);
		vm.prank(VERANTA_OPERATOR);
		IVerantaOperatorRouter(ROUTER).executeMarketOrder{value: 1}(
			pending[0].orderId,
			update,
			1,
			IVerantaOperatorRouter.OffChainSpreadParams({
				spreadP: 1e8, bookDepth: 0, impactParam: 0, byPass: true, maxSpreadP: 0, slot1: false, slot3: 0
			})
		);
		assertEq(IVerantaMulticall(MULTICALL).getPendingOrder(account).length, 0, 'filled');
	}

	/// @dev Tracks pair markers (never the long's own) until the set is full, each listed on the release's VI with the
	///      feed the live VI prices it from at the fork block (red-team RT_POSITIONS_01b).
	function _fillTrackedSet(Comptroller fund, address account) internal {
		address own = LIVE_PERP_CONFIG.pairAsset(PAIR);
		uint256 pairs = VerantaPerpPosition(payable(account)).pairStorage().pairsCount();
		uint256 max = fund.MAX_TRACKED_ASSETS();
		for (uint256 p; p < pairs && fund.getTrackedAssets().length < max; ++p) {
			address a = LIVE_PERP_CONFIG.pairAsset(p);
			if (a == address(0) || a == own || !LIVE_VI.isSupportedAsset(a) || LIVE_VI.isZeroPricedAsset(a)) continue;
			if (!r.valueInterpreter.isSupportedAsset(a)) _copyFeed(a);
			vm.prank(manager);
			try fund.addTrackedAsset(a) {} catch {}
		}
	}

	function _collateral(address account) internal view returns (uint256) {
		return IVerantaTradingStorage(TRADING_STORAGE).openTrades(account, PAIR, 0).initialPosToken;
	}
}
