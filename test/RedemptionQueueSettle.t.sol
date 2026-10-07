// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {ComptrollerV3} from '../src/core/ComptrollerV3.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {RedemptionQueue} from '../src/redemption/RedemptionQueue.sol';
import {MockUnwindPosition} from './utils/MockUnwindPosition.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';
import {RedemptionFixture} from './utils/RedemptionFixture.sol';

/// @dev A token that refuses transfers to blocked addresses, as USDC's blacklist does.
contract BlocklistToken is MockERC20 {
	mapping(address => bool) public blocked;

	constructor() MockERC20('Blocklist', 'BLK', 18) {}

	function setBlocked(address who) external {
		blocked[who] = true;
	}

	function _update(address from, address to, uint256 value) internal override {
		require(!blocked[to], 'blocked');
		super._update(from, to, value);
	}
}

/// @dev A token whose transfers burn `burnGas`, so a payout costs enough to be starved.
contract GasHeavyToken is MockERC20 {
	uint256 public burnGas;

	constructor() MockERC20('Heavy', 'HVY', 18) {}

	function setBurnGas(uint256 gas_) external {
		burnGas = gas_;
	}

	function _update(address from, address to, uint256 value) internal override {
		uint256 start = gasleft();
		while (start - gasleft() < burnGas) {}
		super._update(from, to, value);
	}
}

/// @notice Settlement (spec 2026-10-06 §5): anyone settles once the vault can pay, oldest first,
///         at the NAV of that moment, cash or in kind as each investor chose.
contract RedemptionQueueSettleTest is RedemptionFixture {
	/// @dev 2%/yr management fee as a 1e27-scaled per-second rate
	uint128 internal constant TWO_PCT_MGMT = 1_000_000_000_627_507_379_616_874_496;

	function test_settle_waitsUntilTheVaultCanPay_thenPaysAtSettlementNav() public {
		(ComptrollerV3 fund, MockUnwindPosition position) = _fundWithPosition(8_000e6); // vault 2,000 + position 8,000
		uint256 half = _sharesOf(fund, alice) / 2; // 4,999.5 of 10,000 shares
		_request(fund, alice, half, RedemptionQueue.Mode.InKind);
		uint256 owed = Math.mulDiv(10_000e6, half, fund.shares().totalSupply()); // 4,999.5 USDC

		vm.expectRevert(RedemptionQueue.NothingSettled.selector);
		queue.settle(address(fund), 10);

		_managerReturns(fund, position, 3_000e6); // vault 5,000, position 5,000
		assertEq(queue.settle(address(fund), 10), 1);
		assertEq(usdc.balanceOf(alice), owed);
		assertEq(_sharesOf(fund, address(queue)), 0, 'escrow burned');
		assertFalse(queue.requestAt(address(fund), 0).open);
		assertEq(fund.calcGrossShareValue(), 1e6, 'the remaining holders still hold 1 USDC per share');
	}

	function test_settle_oldestFirst_stopsAtTheFirstUnpayable() public {
		(ComptrollerV3 fund,) = _fundWithPosition(8_000e6);
		_deposit(fund, bob, 1_000e6); // vault 3,000, supply 11,000
		_request(fund, alice, _sharesOf(fund, alice), RedemptionQueue.Mode.Cash); // needs 9,999
		_request(fund, bob, _sharesOf(fund, bob), RedemptionQueue.Mode.InKind); // needs 1,000

		vm.expectRevert(RedemptionQueue.NothingSettled.selector);
		queue.settle(address(fund), 10);
		assertEq(usdc.balanceOf(bob), 0, 'bob does not jump ahead of alice');
		assertTrue(queue.requestAt(address(fund), 1).open);
	}

	function test_settle_twoRequestsInOneBatch_bothPaidFromTheSameSnapshot() public {
		(ComptrollerV3 fund,) = _fundWithPosition(0);
		_deposit(fund, bob, 5_000e6); // vault 15,000 USDC, supply 15,000
		_swap(fund, usdc, weth, 5_000e6, 2.5e18); // vault 10,000 USDC + 2.5 WETH ($5,000)
		_request(fund, alice, 3_000e18, RedemptionQueue.Mode.Cash);
		_request(fund, bob, 2_000e18, RedemptionQueue.Mode.InKind);

		assertEq(queue.settle(address(fund), 10), 2);
		assertEq(usdc.balanceOf(alice), 3_000e6, 'alice: 20% of $15,000 in cash');
		assertEq(weth.balanceOf(bob), Math.mulDiv(2.5e18, 2_000e18, 15_000e18), "bob: 2/15 of the batch's WETH");
		assertEq(usdc.balanceOf(bob), Math.mulDiv(10_000e6, 2_000e18, 15_000e18), '...and of its USDC');
		assertEq(fund.calcGrossShareValue(), 1e6, 'the remaining holders lost nothing');
	}

	function test_settle_cashPaysAPumpedPoolPricedTokenInKind() public {
		(ComptrollerV3 fund,) = _fundWithPosition(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6); // vault 8,000 USDC + 2,000 TKN
		uint256 tenth = 1_000e18; // 10% of 10,000 shares
		_request(fund, alice, tenth, RedemptionQueue.Mode.Cash);
		pool.setOracle(23028, PLENTY); // TKN pumped ×10
		skip(31 minutes);
		pool.setOracle(23028, PLENTY);
		_refreshFeeds();

		queue.settle(address(fund), 10);
		assertEq(usdc.balanceOf(alice), 800e6, '10% of the 8,000 USDC only');
		assertEq(tkn.balanceOf(alice), 200e6, '10% of the TKN, in kind');
	}

	function test_settle_feesSettleFirst_andTheEscrowBearsThem() public {
		ComptrollerV3 fund = ComptrollerV3(factory.createFund(_config(TWO_PCT_MGMT, 0, 0)));
		_deposit(fund, alice, 10_000e6);
		_openPosition(fund, 0);
		uint256 half = _sharesOf(fund, alice) / 2;
		_request(fund, alice, half, RedemptionQueue.Mode.InKind);
		skip(3 days); // inside the deadline: fees still run
		_refreshFeeds();

		uint256 supplyBefore = fund.shares().totalSupply();
		queue.settle(address(fund), 10);
		uint256 supplyWithFees = fund.shares().totalSupply() + half; // the escrow was burned at payout
		assertGt(supplyWithFees, supplyBefore, 'the management fee minted first');
		assertEq(usdc.balanceOf(alice), Math.mulDiv(10_000e6, half, supplyWithFees), 'paid on the diluted supply');
	}

	/// A payout that reverts (a token the fund holds refuses the redeemer) returns that redeemer's
	/// shares and the queue moves on (final review 2026-10-06, I2: it blocked every request behind
	/// it and left the fund overdue for good).
	function test_settle_aPayoutThatRevertsReturnsTheShares_andTheQueueMovesOn() public {
		(ComptrollerV3 fund, BlocklistToken blk) = _fundHoldingBlk();
		uint256 aliceShares = _sharesOf(fund, alice);
		_request(fund, alice, 1_000e18, RedemptionQueue.Mode.InKind);
		_request(fund, bob, 100e18, RedemptionQueue.Mode.InKind);
		blk.setBlocked(alice);

		assertEq(queue.settle(address(fund), 10), 2, 'both handled');
		assertEq(_sharesOf(fund, alice), aliceShares, "alice's shares came back");
		assertFalse(queue.requestAt(address(fund), 0).open);
		assertFalse(queue.requestAt(address(fund), 1).open, 'bob was paid');
		assertGt(blk.balanceOf(bob), 0);
		assertEq(_sharesOf(fund, address(queue)), 0);
		assertFalse(queue.isOverdue(address(fund)));
	}

	/// Nobody can starve a payout of gas to make it bounce: a payout that ran out of the gas the
	/// caller passed fails the whole settle instead (EIP-150 keeps 1/64 with the queue).
	function test_settle_aCallerCantStarveAPayoutIntoABounce() public {
		GasHeavyToken heavy = new GasHeavyToken();
		MockAggregator feed = new MockAggregator(8, 1e8);
		registrar.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (address(heavy), address(feed), 25 hours)));
		(ComptrollerV3 fund,) = _fundWithPosition(0);
		_swap(fund, usdc, MockERC20(address(heavy)), 1_000e6, 1_000e18);
		heavy.setBurnGas(2_000_000); // an honest payout, well under the queue's 3M payout allowance
		_request(fund, alice, 1_000e18, RedemptionQueue.Mode.InKind);
		uint256 aliceShares = _sharesOf(fund, alice);

		uint256 state = vm.snapshotState();
		uint256 succeeded;
		for (uint256 g = 2_000_000; g < 6_000_000; g += 20_000) {
			(bool ok,) = address(queue).call{gas: g}(abi.encodeCall(RedemptionQueue.settle, (address(fund), 10)));
			assertEq(_sharesOf(fund, alice), aliceShares, 'never bounced');
			if (ok) assertGt(heavy.balanceOf(alice), 0, 'paid');
			if (ok) ++succeeded;
			vm.revertToState(state);
		}
		assertGt(succeeded, 0, 'enough gas succeeds');
	}

	/// The payout allowance is never required up front: a payout that succeeds costs what it costs,
	/// so settlement still fits a block next to the fund's valuation (~2.8M gas per perp account).
	function test_settle_aCheapPayoutNeedsNoGasHeadroom() public {
		(ComptrollerV3 fund,) = _fundWithPosition(4_000e6);
		_request(fund, alice, 1_000e18, RedemptionQueue.Mode.InKind);
		(bool ok,) = address(queue).call{gas: 1_500_000}(abi.encodeCall(RedemptionQueue.settle, (address(fund), 10)));
		assertTrue(ok);
		assertGt(usdc.balanceOf(alice), 0);
	}

	/// Settle values the fund once (fees and the payout from the same pass), so a fund that can be
	/// valued in one transaction can settle in one (2026-10-07: valuing twice, 5 real perp accounts
	/// took 19M gas against Base's 16.78M cap).
	function test_settle_valuesTheFundOnce() public {
		(ComptrollerV3 fund, MockUnwindPosition position) = _fundWithPosition(4_000e6);
		position.setValuationGas(2_000_000);
		_request(fund, alice, 1_000e18, RedemptionQueue.Mode.InKind);
		uint256 g = gasleft();
		fund.calcGav();
		uint256 valuation = g - gasleft();
		g = gasleft();
		queue.settle(address(fund), 10);
		assertLt(g - gasleft(), valuation + 1_000_000, 'one valuation plus the payout');
		assertGt(usdc.balanceOf(alice), 0);
	}

	/// @dev vault 2,000 USDC + 1,000 BLK ($1 each); a position stand-in holding nothing.
	function _fundHoldingBlk() internal returns (ComptrollerV3 fund, BlocklistToken blk) {
		blk = new BlocklistToken();
		MockAggregator feed = new MockAggregator(8, 1e8);
		registrar.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (address(blk), address(feed), 25 hours)));
		(fund,) = _fundWithPosition(0);
		_deposit(fund, bob, 1_000e6);
		_swap(fund, usdc, MockERC20(address(blk)), 1_000e6, 1_000e18);
	}

	/// Giving up on an overdue request doesn't hand the manager the overdue period's fees: the
	/// cancel settles fees while the fund is still overdue (final review 2026-10-06, I3: the next
	/// settlement charged all 60 days).
	function test_cancel_whileOverdue_theOverduePeriodStaysFeeFree() public {
		ComptrollerV3 fund = ComptrollerV3(factory.createFund(_config(TWO_PCT_MGMT, 0, 0)));
		_deposit(fund, alice, 10_000e6);
		_openPosition(fund, 8_000e6);
		_request(fund, alice, 4_000e18, RedemptionQueue.Mode.InKind);
		skip(60 days);
		_refreshFeeds();
		assertTrue(queue.isOverdue(address(fund)));

		vm.prank(alice);
		queue.cancel(address(fund));
		uint256 supply = fund.shares().totalSupply();
		fund.settleFees();
		assertEq(fund.shares().totalSupply(), supply, 'no fee for the overdue period');
	}

	/// A held token's feed going stale doesn't freeze settlement: fees settle if they can, and
	/// that token is paid in kind (final review 2026-10-06, I4; README rule 6: oracles never gate
	/// an exit).
	function test_settle_aStaleFeedDoesntFreezeIt_thatTokenIsPaidInKind() public {
		(ComptrollerV3 fund,) = _fundWithPosition(0);
		_swap(fund, usdc, weth, 2_000e6, 1e18); // vault 8,000 USDC + 1 WETH
		_request(fund, alice, 1_000e18, RedemptionQueue.Mode.Cash);
		skip(26 hours);
		usdcFeed.setAnswer(1e8); // only USDC refreshed: WETH (25 h heartbeat) is stale
		uint256 supply = fund.shares().totalSupply();

		queue.settle(address(fund), 10);
		assertEq(usdc.balanceOf(alice), Math.mulDiv(8_000e6, 1_000e18, supply), 'the readable part in cash');
		assertEq(weth.balanceOf(alice), Math.mulDiv(1e18, 1_000e18, supply), 'WETH in kind');
	}

	/// A cancel's fee settlement can't be starved by the gas its sender passes: wallets estimate the
	/// least gas that succeeds, and with the settlement merely tried that was the gas at which it ran
	/// out — handing the manager the overdue period after all. Either the fees settle, or the cancel
	/// reverts (final review 2026-10-07).
	function test_cancel_whileOverdue_cantBeStarvedOutOfSettlingFees() public {
		ComptrollerV3 fund = ComptrollerV3(factory.createFund(_config(TWO_PCT_MGMT, 0, 0)));
		_deposit(fund, alice, 10_000e6);
		MockUnwindPosition position = _openPosition(fund, 8_000e6);
		position.setValuationGas(1_000_000); // settleFees values the fund: let that cost something
		_request(fund, alice, 4_000e18, RedemptionQueue.Mode.InKind);
		skip(60 days);
		_refreshFeeds();
		assertTrue(queue.isOverdue(address(fund)));

		uint256 state = vm.snapshotState();
		uint256 succeeded;
		for (uint256 g = 300_000; g < 3_000_000; g += 20_000) {
			vm.prank(alice);
			(bool ok,) = address(queue).call{gas: g}(abi.encodeCall(RedemptionQueue.cancel, (address(fund))));
			if (ok) {
				++succeeded;
				assertEq(fund.lastMgmtFeeSettled(), block.timestamp, 'the overdue period was settled, fee-free');
			}
			vm.revertToState(state);
		}
		assertGt(succeeded, 0, 'enough gas cancels');
	}

	function test_cancel_whileOverdue_aStaleFeedDoesntBlockIt() public {
		(ComptrollerV3 fund,) = _fundWithPosition(0);
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		uint256 before = _sharesOf(fund, alice);
		_request(fund, alice, 1_000e18, RedemptionQueue.Mode.Cash);
		skip(5 days); // overdue, and every feed is stale
		vm.prank(alice);
		queue.cancel(address(fund));
		assertEq(_sharesOf(fund, alice), before);
	}

	function test_settle_isPermissionless() public {
		(ComptrollerV3 fund,) = _fundWithPosition(0);
		_request(fund, alice, 1_000e18, RedemptionQueue.Mode.Cash);
		vm.prank(stranger);
		queue.settle(address(fund), 10);
		assertEq(usdc.balanceOf(alice), 1_000e6);
		assertEq(usdc.balanceOf(stranger), 0);
	}

	function test_settle_maxRequestsLimitsTheBatch() public {
		(ComptrollerV3 fund,) = _fundWithPosition(0);
		_deposit(fund, bob, 5_000e6);
		_request(fund, alice, 1_000e18, RedemptionQueue.Mode.Cash);
		_request(fund, bob, 1_000e18, RedemptionQueue.Mode.Cash);
		assertEq(queue.settle(address(fund), 1), 1);
		assertEq(usdc.balanceOf(alice), 1_000e6);
		assertEq(usdc.balanceOf(bob), 0);
		(uint256 head,) = queue.queueBounds(address(fund));
		assertEq(head, 1, 'bob is next');
	}

	function test_settle_withNothingQueuedReverts() public {
		(ComptrollerV3 fund,) = _fundWithPosition(0);
		vm.expectRevert(RedemptionQueue.NothingSettled.selector);
		queue.settle(address(fund), 10);
	}

	function test_settle_clearsOverdue_andFeesResumeAfter() public {
		ComptrollerV3 fund = ComptrollerV3(factory.createFund(_config(TWO_PCT_MGMT, 0, 0)));
		_deposit(fund, alice, 10_000e6);
		MockUnwindPosition position = _openPosition(fund, 8_000e6);
		_request(fund, alice, 4_000e18, RedemptionQueue.Mode.InKind); // needs ~4,000 of a 2,000 vault
		skip(5 days);
		_refreshFeeds();
		assertTrue(queue.isOverdue(address(fund)));

		uint256 supplyBefore = fund.shares().totalSupply();
		_managerReturns(fund, position, 3_000e6); // settles fees while overdue: nothing minted
		queue.settle(address(fund), 10);
		assertFalse(queue.isOverdue(address(fund)));
		assertEq(fund.shares().totalSupply(), supplyBefore - 4_000e18, 'no fee for the overdue days');

		skip(1 days);
		_refreshFeeds();
		uint256 supply = fund.shares().totalSupply();
		fund.settleFees();
		assertApproxEqRel(fund.shares().totalSupply() - supply, supply * 2 / 100 / 365, 0.02e18, 'fees resume after the clear');
	}
}
