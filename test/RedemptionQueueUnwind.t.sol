// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {Vm} from 'forge-std/Vm.sol';
import {ComptrollerV3} from '../src/core/ComptrollerV3.sol';
import {RedemptionQueue} from '../src/redemption/RedemptionQueue.sol';
import {MockUnwindPosition} from './utils/MockUnwindPosition.sol';
import {MockUnwinder} from './utils/MockUnwinder.sol';
import {RedemptionFixture} from './utils/RedemptionFixture.sol';

/// @notice The built-in, switched-off fallback (spec 2026-10-06 §6): once switched on, anyone may
///         close an overdue batch's share of the fund's perps; settlement then pays those
///         redeemers in kind plus the USDC raised, covering what wasn't raised from the vault's
///         tokens at full value. What even that can't cover is never forfeited: it stays queued.
contract RedemptionQueueUnwindTest is RedemptionFixture {
	MockUnwinder internal unwinder;

	function setUp() public override {
		super.setUp();
		unwinder = new MockUnwinder();
		queue.approveUnwinder(address(unwinder), true);
	}

	function _switchOn() internal {
		vm.prank(guardian);
		queue.setUnwinderOn(address(unwinder), true);
	}

	/// @dev vault 2,000 USDC + 8,000 locked; alice asks for half her shares; the deadline passes.
	function _overdueHalf(RedemptionQueue.Mode mode) internal returns (ComptrollerV3 fund, MockUnwindPosition position, uint256 shares) {
		(fund, position) = _fundWithPosition(8_000e6);
		shares = _sharesOf(fund, alice) / 2;
		_request(fund, alice, shares, mode);
		skip(4 days + 1);
		_refreshFeeds();
	}

	function test_unwind_refusedWhileSwitchedOff() public {
		(ComptrollerV3 fund,,) = _overdueHalf(RedemptionQueue.Mode.InKind);
		vm.expectRevert(RedemptionQueue.UnwinderOff.selector);
		queue.unwindOverdue(address(fund), 50);
	}

	function test_unwind_refusedBeforeTheDeadline() public {
		_switchOn();
		(ComptrollerV3 fund,) = _fundWithPosition(8_000e6);
		_request(fund, alice, 1_000e18, RedemptionQueue.Mode.InKind);
		skip(4 days);
		vm.expectRevert(RedemptionQueue.NotOverdue.selector);
		queue.unwindOverdue(address(fund), 50);
	}

	function test_unwind_closesTheOverdueFractionOnly() public {
		_switchOn();
		(ComptrollerV3 fund, MockUnwindPosition position) = _fundWithPosition(8_000e6);
		_deposit(fund, bob, 1_000e6); // supply 11,000
		uint256 aliceShares = _sharesOf(fund, alice) / 2;
		_request(fund, alice, aliceShares, RedemptionQueue.Mode.InKind);
		skip(3 days);
		_request(fund, bob, 100e18, RedemptionQueue.Mode.InKind);
		skip(1 days + 1);
		_refreshFeeds();

		uint256 fraction = Math.mulDiv(aliceShares, 1e18, fund.shares().totalSupply());
		queue.unwindOverdue(address(fund), 50); // anyone
		assertEq(position.locked(), 8_000e6 - Math.mulDiv(8_000e6, fraction, 1e18), "alice's share of the position closed");
		assertTrue(queue.requestAt(address(fund), 0).unwound);
		assertFalse(queue.requestAt(address(fund), 1).unwound, "bob's request isn't overdue");

		vm.prank(alice);
		vm.expectRevert(RedemptionQueue.Unwound.selector);
		queue.cancel(address(fund));
		vm.prank(bob);
		queue.cancel(address(fund)); // bob still can
	}

	/// A batch is at most `maxRequests` overdue requests, oldest first, so many small overdue
	/// requests can't push one unwind past a block (final review 2026-10-06, C1).
	function test_unwind_batchesAtMostMaxRequests() public {
		_switchOn();
		(ComptrollerV3 fund, MockUnwindPosition position) = _fundWithPosition(8_000e6);
		_deposit(fund, bob, 1_000e6);
		uint256 aliceShares = _sharesOf(fund, alice) / 2;
		_request(fund, alice, aliceShares, RedemptionQueue.Mode.InKind);
		_request(fund, bob, 100e18, RedemptionQueue.Mode.InKind);
		skip(4 days + 1);
		_refreshFeeds();

		uint256 fraction = Math.mulDiv(aliceShares, 1e18, fund.shares().totalSupply());
		queue.unwindOverdue(address(fund), 1);
		assertTrue(queue.requestAt(address(fund), 0).unwound);
		assertFalse(queue.requestAt(address(fund), 1).unwound, "bob waits for the next batch");
		assertEq(position.locked(), 8_000e6 - Math.mulDiv(8_000e6, fraction, 1e18), "only alice's share closed");
	}

	function test_unwind_onlyOncePerBatch() public {
		_switchOn();
		(ComptrollerV3 fund,,) = _overdueHalf(RedemptionQueue.Mode.InKind);
		queue.unwindOverdue(address(fund), 50);
		vm.expectRevert(RedemptionQueue.UnwindPending.selector);
		queue.unwindOverdue(address(fund), 50);
	}

	function test_settleUnwound_waitsForTheFillsOrTheTimeout() public {
		_switchOn();
		(ComptrollerV3 fund,,) = _overdueHalf(RedemptionQueue.Mode.InKind);
		queue.unwindOverdue(address(fund), 50);
		unwinder.setPending(true);
		vm.expectRevert(RedemptionQueue.UnwindPending.selector);
		queue.settle(address(fund), 10);
		skip(1 hours);
		_refreshFeeds();
		assertEq(queue.settle(address(fund), 10), 1, 'after the timeout it settles');
	}

	function test_settleUnwound_collectsThenPaysFullValue_evenForACashRequest() public {
		_switchOn();
		(ComptrollerV3 fund, MockUnwindPosition position, uint256 shares) = _overdueHalf(RedemptionQueue.Mode.Cash);
		uint256 owed = Math.mulDiv(10_000e6, shares, fund.shares().totalSupply()); // 4,999.5
		queue.unwindOverdue(address(fund), 50);
		queue.settle(address(fund), 10);
		assertEq(usdc.balanceOf(alice), owed, 'full value in USDC');
		assertEq(position.idle(), 0, 'the closed USDC was collected');
		assertApproxEqAbs(fund.calcGrossShareValue(), 1e6, 1, 'the remaining holders lost nothing');
	}

	function test_settleUnwound_aCloseThatFailedIsCoveredFromTheVaultsTokens() public {
		_switchOn();
		ComptrollerV3 fund = _fund();
		_swap(fund, usdc, weth, 4_000e6, 2e18); // vault 6,000 USDC + 2 WETH ($4,000)
		MockUnwindPosition position = _openPosition(fund, 4_000e6); // vault 2,000 USDC + 2 WETH; position 4,000
		uint256 shares = _sharesOf(fund, alice) / 2;
		uint256 supply = fund.shares().totalSupply();
		_request(fund, alice, shares, RedemptionQueue.Mode.InKind);
		skip(4 days + 1);
		_refreshFeeds();

		position.setRejectCloses(true);
		vm.recordLogs();
		queue.unwindOverdue(address(fund), 50);
		assertTrue(_emitted(vm.getRecordedLogs(), RedemptionQueue.UnwindCloseFailed.selector), 'the failure is reported');
		assertEq(position.locked(), 4_000e6, 'nothing closed');

		queue.settle(address(fund), 10);
		uint256 value = usdc.balanceOf(alice) + Math.mulDiv(weth.balanceOf(alice), 2_000e6, 1e18);
		assertApproxEqAbs(value, Math.mulDiv(10_000e6, shares, supply), 2, 'full value: USDC plus WETH');
		assertEq(usdc.balanceOf(alice), 2_000e6, 'all the vault USDC');
		assertGt(weth.balanceOf(alice), Math.mulDiv(2e18, shares, supply), 'more WETH than pro rata covers the gap');
		assertApproxEqAbs(fund.calcGrossShareValue(), 1e6, 1, 'the remaining holders lost nothing');
	}

	/// Never forfeited (final review 2026-10-06, C2): the vault pays what it can cover at full value
	/// and burns only those shares; the rest of the request stays queued, still overdue (fees stay
	/// stopped), for the manager or another unwind.
	function test_settleUnwound_whatTheVaultCantCoverStaysQueued_neverForfeited() public {
		_switchOn();
		ComptrollerV3 fund = _fund();
		_swap(fund, usdc, weth, 2_000e6, 1e18); // vault 8,000 USDC + 1 WETH
		MockUnwindPosition perp = _openPosition(fund, 1_000e6);
		MockUnwindPosition lp = _openPosition(fund, 6_000e6); // vault 1,000 USDC + 1 WETH
		unwinder.setUnsupported(address(lp), true);
		uint256 shares = _sharesOf(fund, alice); // all of alice's 9,999 of 10,000
		uint256 supply = fund.shares().totalSupply();
		_request(fund, alice, shares, RedemptionQueue.Mode.InKind);
		skip(4 days + 1);
		_refreshFeeds();

		queue.unwindOverdue(address(fund), 50);
		assertEq(lp.locked(), 6_000e6, 'the LP stand-in is never unwound');
		assertLt(perp.locked(), 1_000e6);
		queue.settle(address(fund), 10);

		(bool exists,, RedemptionQueue.Request memory rest) = queue.requestOf(address(fund), alice);
		assertTrue(exists, 'the rest is still queued');
		assertGt(rest.shares, 0);
		assertFalse(rest.unwound, 'an ordinary request again');
		assertEq(_sharesOf(fund, address(queue)), rest.shares, 'only the paid shares were burned');
		uint256 paid = usdc.balanceOf(alice) + Math.mulDiv(weth.balanceOf(alice), 2_000e6, 1e18);
		assertApproxEqAbs(paid, Math.mulDiv(10_000e6, shares - rest.shares, supply), 2, 'full value for the shares burned');
		assertEq(weth.balanceOf(address(fund.vault())), 0, 'every coverable token was used');
		assertApproxEqAbs(fund.calcGrossShareValue(), 1e6, 1, 'the remaining holders lost nothing');
		assertTrue(queue.isOverdue(address(fund)), "the manager's fees stay stopped");
		queue.unwindOverdue(address(fund), 50); // and the rest can be unwound again
	}

	/// When the vault runs out on the first request of a batch, every later request of the batch
	/// becomes an ordinary one again too: cancellable, and the fund is free to unwind again.
	function test_settleUnwound_theVaultRunsOut_theRestOfTheBatchIsReleased() public {
		_switchOn();
		ComptrollerV3 fund = _fund();
		_deposit(fund, bob, 1_000e6);
		MockUnwindPosition lp = _openPosition(fund, 10_000e6); // vault 1,000 USDC; the rest in an LP stand-in
		unwinder.setUnsupported(address(lp), true);
		_request(fund, alice, _sharesOf(fund, alice) / 2, RedemptionQueue.Mode.InKind);
		_request(fund, bob, 100e18, RedemptionQueue.Mode.InKind);
		skip(4 days + 1);
		_refreshFeeds();
		queue.unwindOverdue(address(fund), 50);
		assertTrue(queue.requestAt(address(fund), 1).unwound);

		queue.settle(address(fund), 10); // the 1,000 USDC covers part of alice's request only
		assertTrue(queue.requestAt(address(fund), 0).open, "the rest of alice's request waits");
		assertFalse(queue.requestAt(address(fund), 0).unwound);
		assertFalse(queue.requestAt(address(fund), 1).unwound, "bob's request is ordinary again");
		vm.prank(bob);
		queue.cancel(address(fund));
		queue.unwindOverdue(address(fund), 50); // a new batch can start
	}

	/// A stale price makes the unwinder's closeActions revert: the whole unwind reverts, nothing is
	/// marked, and the request stays cancellable (final review 2026-10-06, C2: catching it let
	/// anyone mark a batch unwound with nothing closed, and settlement forfeited the perp share).
	function test_unwind_aStalePriceRevertsTheWholeUnwind_theRequestStaysCancellable() public {
		_switchOn();
		(ComptrollerV3 fund, MockUnwindPosition position,) = _overdueHalf(RedemptionQueue.Mode.InKind);
		unwinder.setStale(true);
		vm.expectRevert(abi.encodeWithSelector(MockUnwinder.StalePrice.selector, 0));
		queue.unwindOverdue(address(fund), 50);
		assertFalse(queue.requestAt(address(fund), 0).unwound);
		assertEq(position.locked(), 8_000e6);
		vm.prank(alice);
		queue.cancel(address(fund));
	}

	function test_unwind_neverMovesValueOutsideTheFund() public {
		_switchOn();
		(ComptrollerV3 fund, MockUnwindPosition position,) = _overdueHalf(RedemptionQueue.Mode.InKind);
		unwinder.setMalicious(true); // asks for a non-risk-reducing action
		uint256 gav = fund.calcGav();
		vm.recordLogs();
		queue.unwindOverdue(address(fund), 50);
		assertTrue(_emitted(vm.getRecordedLogs(), RedemptionQueue.UnwindCloseFailed.selector), 'refused by the comptroller');
		assertEq(position.locked(), 8_000e6);
		assertEq(fund.calcGav(), gav);
	}

	/// Governance switched the unwinder off after the unwind started: nothing can be collected, so
	/// rather than forfeit the perp share the requests become ordinary ones again (cancel works,
	/// they wait for the manager); nothing is forfeited.
	function test_settleUnwound_switchedOffMeanwhile_requestsBecomeOrdinaryAgain() public {
		_switchOn();
		(ComptrollerV3 fund, MockUnwindPosition position, uint256 shares) = _overdueHalf(RedemptionQueue.Mode.InKind);
		queue.unwindOverdue(address(fund), 50);
		queue.setUnwinderOn(address(unwinder), false); // governance
		vm.expectRevert(RedemptionQueue.NothingSettled.selector); // vault 2,000 can't pay 4,999.5
		queue.settle(address(fund), 10);

		queue.releaseUnwound(address(fund));
		assertFalse(queue.requestAt(address(fund), 0).unwound, 'an ordinary request again');
		uint256 owed = Math.mulDiv(10_000e6, shares, fund.shares().totalSupply());
		_managerReturns(fund, position, position.idle()); // the manager returns the closed USDC
		queue.settle(address(fund), 10);
		assertEq(usdc.balanceOf(alice), owed, 'paid in full, nothing forfeited');
	}

	/// An unwound request paid by an ordinary settle while every unwinder was off leaves no batch
	/// behind: once an unwinder is on again, a new overdue request unwinds and settles (final
	/// review 2026-10-06, I1: a stale marker made settle, unwind and release all revert).
	function test_unwind_afterAnUnwinderWasSwitchedOffAndOnAgain_nothingDeadlocks() public {
		_switchOn();
		(ComptrollerV3 fund, MockUnwindPosition position,) = _overdueHalf(RedemptionQueue.Mode.InKind);
		queue.unwindOverdue(address(fund), 50);
		queue.setUnwinderOn(address(unwinder), false); // governance
		_managerReturns(fund, position, position.idle());
		queue.settle(address(fund), 10); // the ordinary path pays the unwound request
		assertFalse(queue.requestAt(address(fund), 0).open);

		_deposit(fund, bob, 1_000e6);
		_request(fund, bob, 100e18, RedemptionQueue.Mode.InKind);
		_switchOn();
		skip(4 days + 1);
		_refreshFeeds();
		queue.unwindOverdue(address(fund), 50);
		assertTrue(queue.requestAt(address(fund), 1).unwound);
		queue.settle(address(fund), 10);
		assertFalse(queue.requestAt(address(fund), 1).open, 'bob was paid');
		assertFalse(queue.isOverdue(address(fund)));
	}

	/// Nobody can starve a close of gas to mark a batch unwound with nothing closed: a close that
	/// ran out of the gas the caller passed fails the whole unwind instead.
	function test_unwind_aCallerCantStarveACloseIntoAFailedClose() public {
		_switchOn();
		(ComptrollerV3 fund, MockUnwindPosition position,) = _overdueHalf(RedemptionQueue.Mode.InKind);
		position.setCloseGas(1_000_000); // an honest close, well under the queue's 2M close allowance

		uint256 state = vm.snapshotState();
		uint256 succeeded;
		for (uint256 g = 500_000; g < 4_000_000; g += 20_000) {
			(bool ok,) = address(queue).call{gas: g}(abi.encodeCall(RedemptionQueue.unwindOverdue, (address(fund), 50)));
			if (ok) assertLt(position.locked(), 8_000e6, 'marked unwound only with the close done');
			if (ok) ++succeeded;
			vm.revertToState(state);
		}
		assertGt(succeeded, 0, 'enough gas succeeds');
	}

	/// The fallback's settlement doesn't freeze on a stale feed either: the stale token is paid in
	/// kind and never used to cover (final review 2026-10-06, I4).
	function test_settleUnwound_aStaleFeedDoesntFreezeIt() public {
		_switchOn();
		ComptrollerV3 fund = _fund();
		_swap(fund, usdc, weth, 2_000e6, 1e18); // vault 8,000 USDC + 1 WETH
		MockUnwindPosition position = _openPosition(fund, 6_000e6); // vault 2,000 USDC + 1 WETH
		uint256 shares = _sharesOf(fund, alice) / 2;
		uint256 supply = fund.shares().totalSupply();
		_request(fund, alice, shares, RedemptionQueue.Mode.InKind);
		skip(4 days + 1);
		usdcFeed.setAnswer(1e8); // WETH's feed is stale
		queue.unwindOverdue(address(fund), 50);
		assertLt(position.locked(), 6_000e6);

		queue.settle(address(fund), 10);
		assertEq(weth.balanceOf(alice), Math.mulDiv(1e18, shares, supply), 'WETH: her slice, in kind');
		assertApproxEqAbs(usdc.balanceOf(alice), Math.mulDiv(8_000e6, shares, supply), 2, 'USDC: her share of vault + position');
		assertFalse(queue.requestAt(address(fund), 0).open);
	}

	function _emitted(Vm.Log[] memory logs, bytes32 topic) internal pure returns (bool) {
		for (uint256 i; i < logs.length; ++i) {
			if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) return true;
		}
		return false;
	}
}
