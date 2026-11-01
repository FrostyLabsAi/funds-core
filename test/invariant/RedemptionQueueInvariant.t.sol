// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {ComptrollerV6} from '../../src/core/ComptrollerV6.sol';
import {RedemptionQueueV2} from '../../src/redemption/RedemptionQueueV2.sol';
import {Shares} from '../../src/fund/Shares.sol';
import {MockERC20, MockAggregator} from '../utils/Mocks.sol';
import {MockUnwindPosition} from '../utils/MockUnwindPosition.sol';
import {RedemptionFixtureV6} from '../utils/RedemptionFixtureV6.sol';

/// @dev Drives one fund v6: investors request, cancel, the manager
///      raises cash, anyone settles, time passes. Records what every settlement paid against the
///      share of NAV it was owed.
contract RedemptionQueueHandler is Test {
	ComptrollerV6 internal fund;
	RedemptionQueueV2 internal queue;
	MockUnwindPosition internal position;
	MockERC20 internal usdc;
	MockAggregator internal usdcFeed;
	address internal manager;
	address[] internal investors;

	bool public overpaid; // a redeemer got more than shares × NAV / supply
	bool public outOfOrder; // a request settled while an older one was open
	bool public diluted; // the remaining holders' share price fell at a settlement
	uint256 public settlements;

	constructor(
		ComptrollerV6 fund_,
		RedemptionQueueV2 queue_,
		MockUnwindPosition position_,
		MockERC20 usdc_,
		MockAggregator usdcFeed_,
		address manager_,
		address[] memory investors_
	) {
		fund = fund_;
		queue = queue_;
		position = position_;
		usdc = usdc_;
		usdcFeed = usdcFeed_;
		manager = manager_;
		investors = investors_;
	}

	function request(uint256 who, uint256 fractionBps) external {
		address investor = investors[who % investors.length];
		(bool exists,,) = queue.requestOf(address(fund), investor);
		uint256 free = fund.shares().balanceOf(investor);
		if (exists || free == 0) return;
		// half the requests take everything: a big request the vault can't pay yet, ahead of small
		// ones it can, is the case where the oldest-first rule matters
		uint256 bps = fractionBps % 2 == 0 ? 10_000 : bound(fractionBps, 1, 10_000);
		uint256 shares = Math.mulDiv(free, bps, 10_000);
		if (shares == 0) return;
		Shares fundShares = fund.shares();
		vm.startPrank(investor);
		fundShares.approve(address(queue), shares);
		queue.requestRedeem(address(fund), shares);
		vm.stopPrank();
	}

	function cancel(uint256 who) external {
		address investor = investors[who % investors.length];
		(bool exists,,) = queue.requestOf(address(fund), investor);
		if (!exists) return;
		vm.prank(investor);
		queue.cancel(address(fund));
	}

	function managerReturns(uint256 amount) external {
		uint256 locked = position.locked();
		if (locked == 0) return;
		amount = bound(amount, 1, locked);
		vm.startPrank(manager);
		fund.callOnExternalPosition(address(position), new address[](0), new uint256[](0), new address[](0), abi.encode(uint8(1), abi.encode(amount)));
		address[] memory back = new address[](1);
		back[0] = address(usdc);
		fund.callOnExternalPosition(address(position), new address[](0), new uint256[](0), back, abi.encode(uint8(6), abi.encode(amount)));
		vm.stopPrank();
	}

	function warp(uint256 dt) external {
		skip(bound(dt, 1, 12 hours));
		usdcFeed.setAnswer(1e8);
	}

	function settle() external {
		(uint256 head, uint256 length) = queue.queueBounds(address(fund));
		uint256 supply = fund.shares().totalSupply();
		uint256 gav = fund.calcGav();
		uint256 priceBefore = Math.mulDiv(gav, 1e18, supply);
		uint256[] memory before = new uint256[](length);
		bool[] memory wasOpen = new bool[](length);
		for (uint256 id = head; id < length; ++id) {
			RedemptionQueueV2.Request memory r = queue.requestAt(address(fund), id);
			wasOpen[id] = r.open;
			before[id] = usdc.balanceOf(r.investor);
		}
		vm.prank(manager); // the manager or a keeper settles
		try queue.settle(address(fund), 10) returns (uint256 n) {
			settlements += n;
		} catch {
			return;
		}
		bool olderStillOpen;
		for (uint256 id = head; id < length; ++id) {
			RedemptionQueueV2.Request memory r = queue.requestAt(address(fund), id);
			if (!wasOpen[id]) continue;
			if (r.open) {
				olderStillOpen = true;
				continue;
			}
			if (olderStillOpen) outOfOrder = true;
			// only USDC lives in this fund, so the payout's value is the USDC received
			if (usdc.balanceOf(r.investor) - before[id] > Math.mulDiv(gav, r.shares, supply)) overpaid = true;
		}
		uint256 supplyAfter = fund.shares().totalSupply();
		if (supplyAfter > 0 && Math.mulDiv(fund.calcGav(), 1e18, supplyAfter) < priceBefore) diluted = true;
	}
}

/// @notice Settlement invariants (spec 2026-10-06 §10).
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 40
contract RedemptionQueueInvariantTest is RedemptionFixtureV6 {
	RedemptionQueueHandler internal handler;
	ComptrollerV6 internal fund;

	function setUp() public override {
		super.setUp();
		MockUnwindPosition position;
		(fund, position) = _fundWithPosition(6_000e6);
		_deposit(fund, bob, 3_000e6);
		_deposit(fund, carol, 2_000e6);
		address[] memory investors = new address[](3);
		(investors[0], investors[1], investors[2]) = (alice, bob, carol);
		handler = new RedemptionQueueHandler(fund, queue, position, usdc, usdcFeed, manager, investors);
		targetContract(address(handler));
	}

	function invariant_noRedeemerIsOverpaid() public view {
		assertFalse(handler.overpaid());
	}

	function invariant_settlementIsOldestFirst() public view {
		assertFalse(handler.outOfOrder());
	}

	function invariant_remainingHoldersAreNeverDiluted() public view {
		assertFalse(handler.diluted());
	}

	function invariant_escrowEqualsTheOpenRequests() public view {
		(uint256 head, uint256 length) = queue.queueBounds(address(fund));
		uint256 open;
		for (uint256 id = head; id < length; ++id) {
			RedemptionQueueV2.Request memory r = queue.requestAt(address(fund), id);
			if (r.open) open += r.shares;
		}
		assertEq(fund.shares().balanceOf(address(queue)), open);
	}
}
