// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {ComptrollerV3} from '../src/core/ComptrollerV3.sol';
import {RedemptionQueue} from '../src/redemption/RedemptionQueue.sol';
import {ComptrollerBlueprintDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {Shares} from '../src/fund/Shares.sol';
import {RedemptionFixture} from './utils/RedemptionFixture.sol';

/// @notice RedemptionQueue requests, cancels, the 4-day deadline and the unwinder switch
///         (spec 2026-10-06 §3.1, §5).
contract RedemptionQueueTest is RedemptionFixture {
	function test_request_escrowsShares_oldestFirst() public {
		(ComptrollerV3 fund,) = _fundWithPosition(4_000e6);
		_deposit(fund, bob, 5_000e6);
		uint256 aliceShares = _sharesOf(fund, alice) / 2;
		uint256 bobShares = _sharesOf(fund, bob);
		assertEq(_request(fund, alice, aliceShares, RedemptionQueue.Mode.InKind), 0);
		skip(1 hours);
		assertEq(_request(fund, bob, bobShares, RedemptionQueue.Mode.Cash), 1);

		assertEq(_sharesOf(fund, address(queue)), aliceShares + bobShares, 'both escrows held');
		(uint256 head, uint256 length) = queue.queueBounds(address(fund));
		assertEq(head, 0);
		assertEq(length, 2);
		RedemptionQueue.Request memory first = queue.requestAt(address(fund), 0);
		assertEq(first.investor, alice);
		assertEq(first.shares, aliceShares);
		assertEq(uint8(first.mode), uint8(RedemptionQueue.Mode.InKind));
		assertTrue(first.open);
		(bool exists, uint256 id,) = queue.requestOf(address(fund), bob);
		assertTrue(exists);
		assertEq(id, 1);
	}

	function test_request_refusedForAPureSpotFund() public {
		ComptrollerV3 fund = _fund();
		vm.startPrank(alice);
		fund.shares().approve(address(queue), 1e18);
		vm.expectRevert(abi.encodeWithSelector(RedemptionQueue.NoExternalPositions.selector, address(fund)));
		queue.requestRedeem(address(fund), 1e18, RedemptionQueue.Mode.Cash);
		vm.stopPrank();
	}

	function test_request_oneOpenPerInvestor() public {
		(ComptrollerV3 fund,) = _fundWithPosition(4_000e6);
		_request(fund, alice, 1e18, RedemptionQueue.Mode.Cash);
		vm.startPrank(alice);
		fund.shares().approve(address(queue), 1e18);
		vm.expectRevert(RedemptionQueue.RequestExists.selector);
		queue.requestRedeem(address(fund), 1e18, RedemptionQueue.Mode.Cash);
		vm.stopPrank();
	}

	function test_request_refusedForAFundBoundToAnotherQueue() public {
		RedemptionQueue other = new RedemptionQueue(address(this));
		FundFactory otherFactory = new FundFactory(
			vi, new ComptrollerBlueprintDeployer(type(ComptrollerV3).creationCode, abi.encode(registrar, other)), new SharesVaultDeployer()
		);
		other.setFactory(address(otherFactory));
		address foreign = otherFactory.createFund(_config(0, 0, 0));
		vm.expectRevert(abi.encodeWithSelector(RedemptionQueue.NotOurFund.selector, foreign));
		queue.requestRedeem(foreign, 1, RedemptionQueue.Mode.Cash);
		vm.expectRevert(abi.encodeWithSelector(RedemptionQueue.NotOurFund.selector, address(0xbeef)));
		queue.requestRedeem(address(0xbeef), 1, RedemptionQueue.Mode.Cash);
	}

	function test_request_zeroSharesRefused() public {
		(ComptrollerV3 fund,) = _fundWithPosition(4_000e6);
		vm.prank(alice);
		vm.expectRevert(RedemptionQueue.ZeroShares.selector);
		queue.requestRedeem(address(fund), 0, RedemptionQueue.Mode.Cash);
	}

	function test_request_keepsTheFundsSharesActionTimelock() public {
		ComptrollerV3 fund = ComptrollerV3(factory.createFund(_config(0, 0, 1 days)));
		_deposit(fund, alice, 10_000e6);
		vm.prank(manager);
		fund.createExternalPosition(UNWIND_TYPE, '');
		vm.startPrank(alice);
		fund.shares().approve(address(queue), 1e18);
		vm.expectRevert(abi.encodeWithSelector(ComptrollerV3.SharesActionTimelocked.selector, alice));
		queue.requestRedeem(address(fund), 1e18, RedemptionQueue.Mode.Cash);
		vm.stopPrank();
	}

	function test_cancel_returnsTheShares_andTheNextRequestBecomesTheHead() public {
		(ComptrollerV3 fund,) = _fundWithPosition(4_000e6);
		_deposit(fund, bob, 5_000e6);
		uint256 before = _sharesOf(fund, alice);
		_request(fund, alice, 1e18, RedemptionQueue.Mode.Cash);
		_request(fund, bob, 1e18, RedemptionQueue.Mode.Cash);
		vm.prank(alice);
		queue.cancel(address(fund));
		assertEq(_sharesOf(fund, alice), before);
		(uint256 head,) = queue.queueBounds(address(fund));
		assertEq(head, 1, 'bob is next');
		(bool exists,,) = queue.requestOf(address(fund), alice);
		assertFalse(exists);
		_request(fund, alice, 1e18, RedemptionQueue.Mode.InKind); // may request again, at the back
		(, uint256 length) = queue.queueBounds(address(fund));
		assertEq(length, 3);
	}

	function test_cancel_withoutARequestReverts() public {
		(ComptrollerV3 fund,) = _fundWithPosition(4_000e6);
		vm.prank(alice);
		vm.expectRevert(RedemptionQueue.NoRequest.selector);
		queue.cancel(address(fund));
	}

	function test_isOverdue_onlyPastFourDays() public {
		(ComptrollerV3 fund,) = _fundWithPosition(4_000e6);
		assertFalse(queue.isOverdue(address(fund)), 'empty queue');
		_request(fund, alice, 1e18, RedemptionQueue.Mode.Cash);
		skip(4 days);
		assertFalse(queue.isOverdue(address(fund)), 'exactly 4 days: not yet');
		skip(1);
		assertTrue(queue.isOverdue(address(fund)));
	}

	function test_isOverdue_followsTheOldestOpenRequest() public {
		(ComptrollerV3 fund,) = _fundWithPosition(4_000e6);
		_deposit(fund, bob, 5_000e6);
		_request(fund, alice, 1e18, RedemptionQueue.Mode.Cash);
		skip(2 days);
		_request(fund, bob, 1e18, RedemptionQueue.Mode.Cash);
		skip(2 days + 1);
		assertTrue(queue.isOverdue(address(fund)), "alice's request is overdue");
		vm.prank(alice);
		queue.cancel(address(fund));
		assertFalse(queue.isOverdue(address(fund)), "bob's is 2 days old");
	}

	/// Request/cancel spam behind the oldest request must cost that request nothing: its cancel,
	/// the settle and isOverdue (read by every fee settlement) walk open requests only (final
	/// review 2026-10-06, C1: 2,000 dead entries made a cancel cost 5.2M gas; 7,000 is past the 16.78M transaction cap).
	function test_spamBehindTheOldestRequest_costsItNothing() public {
		ComptrollerV3 fund = _spammedBehindAlice(7_000);
		uint256 g = gasleft();
		queue.isOverdue(address(fund));
		assertLt(g - gasleft(), 20_000, 'isOverdue');
		vm.prank(alice);
		g = gasleft();
		queue.cancel(address(fund));
		assertLt(g - gasleft(), 150_000, "alice's cancel");
	}

	function test_spamBehindTheOldestRequest_settleStillPaysIt() public {
		ComptrollerV3 fund = _spammedBehindAlice(7_000);
		uint256 g = gasleft();
		assertEq(queue.settle(address(fund), 10), 1);
		assertLt(g - gasleft(), 1_500_000, 'settle');
		(uint256 head, uint256 length) = queue.queueBounds(address(fund));
		assertEq(head, length, 'nothing open');
	}

	/// @dev vault 3,000 USDC + 8,000 in a position; alice asks for 1,000 shares in kind (payable);
	///      bob then requests and cancels 1 wei of shares `cycles` times.
	function _spammedBehindAlice(uint256 cycles) internal returns (ComptrollerV3 fund) {
		(fund,) = _fundWithPosition(8_000e6);
		_deposit(fund, bob, 1_000e6);
		_request(fund, alice, 1_000e18, RedemptionQueue.Mode.InKind);
		Shares fundShares = fund.shares();
		vm.startPrank(bob);
		fundShares.approve(address(queue), type(uint256).max);
		for (uint256 i; i < cycles; ++i) {
			queue.requestRedeem(address(fund), 1, RedemptionQueue.Mode.Cash);
			queue.cancel(address(fund));
		}
		vm.stopPrank();
		vm.cool(address(queue));
	}

	// ─── the unwinder switch (governance approves, the guardian may switch on) ──────

	function test_unwinder_guardianSwitchesOnOnlyAnApprovedOne() public {
		address unwinder = makeAddr('unwinder');
		vm.prank(guardian);
		vm.expectRevert(abi.encodeWithSelector(RedemptionQueue.UnwinderNotApproved.selector, unwinder));
		queue.setUnwinderOn(unwinder, true);

		queue.approveUnwinder(unwinder, true);
		assertFalse(queue.isUnwinderOn(unwinder), 'approval leaves it off');
		vm.prank(guardian);
		queue.setUnwinderOn(unwinder, true);
		assertTrue(queue.isUnwinderOn(unwinder));
		assertEq(queue.unwinders().length, 1);
	}

	function test_unwinder_onlyGovernanceSwitchesOff() public {
		address unwinder = makeAddr('unwinder');
		queue.approveUnwinder(unwinder, true);
		vm.prank(guardian);
		queue.setUnwinderOn(unwinder, true);
		vm.prank(guardian);
		vm.expectRevert(RedemptionQueue.OnlyOwnerSwitchesOff.selector);
		queue.setUnwinderOn(unwinder, false);
		queue.setUnwinderOn(unwinder, false);
		assertFalse(queue.isUnwinderOn(unwinder));
	}

	function test_unwinder_withdrawingApprovalSwitchesItOff() public {
		address unwinder = makeAddr('unwinder');
		queue.approveUnwinder(unwinder, true);
		queue.setUnwinderOn(unwinder, true);
		queue.approveUnwinder(unwinder, false);
		assertFalse(queue.isUnwinderOn(unwinder));
		vm.prank(guardian);
		vm.expectRevert(abi.encodeWithSelector(RedemptionQueue.UnwinderNotApproved.selector, unwinder));
		queue.setUnwinderOn(unwinder, true);
	}

	function test_unwinder_strangersCanDoNothing() public {
		address unwinder = makeAddr('unwinder');
		vm.startPrank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		queue.approveUnwinder(unwinder, true);
		vm.stopPrank();
		queue.approveUnwinder(unwinder, true);
		vm.prank(stranger);
		vm.expectRevert(RedemptionQueue.NotGovernanceOrGuardian.selector);
		queue.setUnwinderOn(unwinder, true);
	}

	function test_setFactory_once_byTheOwner() public {
		vm.expectRevert(RedemptionQueue.FactoryAlreadySet.selector);
		queue.setFactory(address(1));
		RedemptionQueue fresh = new RedemptionQueue(address(this));
		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		fresh.setFactory(address(1));
	}
}
