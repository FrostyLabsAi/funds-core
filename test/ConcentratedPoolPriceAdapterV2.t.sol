// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IPoolPriceAdapter} from '../src/interfaces/IPoolPriceAdapter.sol';
import {IPoolWatch} from '../src/interfaces/IPoolWatch.sol';
import {ConcentratedPoolPriceAdapter} from '../src/pricing/ConcentratedPoolPriceAdapter.sol';
import {ConcentratedPoolPriceAdapterV2} from '../src/pricing/ConcentratedPoolPriceAdapterV2.sol';
import {MockERC20} from './utils/Mocks.sol';
import {ScriptedCLPool} from './utils/PoolPriceMocks.sol';
import {ConcentratedPoolPriceAdapterTest} from './ConcentratedPoolPriceAdapter.t.sol';

/// @notice Every ConcentratedPoolPriceAdapter test, run on V2, plus V2's one change: the ≈ $0 rule reads the window's
///         liquidity only, so emptying the pool's quote balance for one call (a flash) no longer zeroes the price
///         (red-team PRICING-POOL-01, 2026-10-27). The buy floor (`liquidityUsd`) still counts the balance now. And the
///         cutoff reads the upper median of six 5-minute slices, so an LP's own pull must last over 10 minutes, not one block.
contract ConcentratedPoolPriceAdapterV2Test is ConcentratedPoolPriceAdapterTest {
	function _implementation() internal override returns (address) {
		return address(new ConcentratedPoolPriceAdapterV2());
	}

	function _v1(ScriptedCLPool pool, MockERC20 asset) internal returns (IPoolPriceAdapter adapter) {
		address v2 = impl;
		impl = address(new ConcentratedPoolPriceAdapter());
		adapter = _adapter(pool, asset);
		impl = v2;
	}

	/// The pool's quote balance gone for this call, the window's liquidity unchanged: V2 prices at the window, V1 at 1 wei.
	function test_aDrainedQuoteBalanceLeavesThePriceAtTheWindow() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 6);
		ScriptedCLPool pool = _pool(tkn, usdc);
		usdc.mint(address(pool), 1_000_000e6);
		pool.setOracle(0, PLENTY); // $1 per TKN, $1M of windowed liquidity
		IPoolPriceAdapter adapter = _adapter(pool, tkn);
		IPoolPriceAdapter v1 = _v1(pool, tkn);
		assertEq(_answer(adapter), 1e18);

		deal(address(usdc), address(pool), 0);
		assertEq(_answer(adapter), 1e18, 'V2: still the window price');
		assertEq(_answer(v1), 1, 'V1 (the control): 1 wei');

		vm.prank(admin);
		vi.addPrimitive(address(tkn), address(adapter), 1 hours);
		assertEq(vi.calcCanonicalAssetValue(address(tkn), 1_000e6, address(usdc)), 1_000e6, 'the VI values a holding fairly');
	}

	/// The buy floor still sees the balance now: no buy into a pool that holds nothing.
	function test_theBuyFloorStillCountsTheBalanceNow() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 6);
		ScriptedCLPool pool = _pool(tkn, usdc);
		usdc.mint(address(pool), 1_000_000e6);
		pool.setOracle(0, PLENTY);
		IPoolPriceAdapter adapter = _adapter(pool, tkn);

		deal(address(usdc), address(pool), 4_000e6);
		assertEq(adapter.liquidityUsd(), 4_000e18);
	}

	/// The cliff itself still works, on the window's liquidity, whatever the pool holds now.
	function test_theCliffReadsTheWindowedLiquidity() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 6);
		ScriptedCLPool above = _pool(tkn, usdc);
		usdc.mint(address(above), 1_000_000e6);
		above.setOracle(0, 5_001e6);
		assertEq(_answer(_adapter(above, tkn)), 1e18, 'just over $5,000 windowed: priced');

		ScriptedCLPool below = _pool(tkn, usdc);
		usdc.mint(address(below), 1_000_000e6);
		below.setOracle(0, 4_999e6);
		assertEq(_answer(_adapter(below, tkn)), 1, 'just under: 1 wei, however much the pool holds now');
	}

	/// @dev A pool at $1, $1M of in-range liquidity, its quote balance full; in-range liquidity pulled to 1 for
	///      [fromAgo, toAgo) seconds ago (an LP's own burn and re-mint).
	function _pulled(uint32 fromAgo, uint32 toAgo) internal returns (ScriptedCLPool pool, MockERC20 tkn) {
		tkn = new MockERC20('Token', 'TKN', 6);
		pool = _pool(tkn, usdc);
		usdc.mint(address(pool), 1_000_000e6);
		pool.setOracle(0, PLENTY);
		pool.setDip(1, fromAgo, toAgo);
	}

	/// The pull-and-wait-a-block case: one 2-second pull no longer reads as a rug (V1, one harmonic mean, did).
	function test_aOneBlockPullDoesNotZeroTheToken() public {
		(ScriptedCLPool pool, MockERC20 tkn) = _pulled(100, 102);
		assertEq(_answer(_adapter(pool, tkn)), 1e18, 'V2: priced');
		assertEq(_answer(_v1(pool, tkn)), 1, 'V1 (the control): 1 wei');
	}

	/// A pull that shows in two of the five slices still prices.
	function test_aPullInTwoSlicesStillPrices() public {
		(ScriptedCLPool pool, MockERC20 tkn) = _pulled(361, 1079);
		assertEq(_answer(_adapter(pool, tkn)), 1e18);
	}

	/// In three it is a rug: 1 wei.
	function test_aPullInThreeSlicesZeroesTheToken() public {
		(ScriptedCLPool pool, MockERC20 tkn) = _pulled(359, 721);
		assertEq(_answer(_adapter(pool, tkn)), 1);
	}

	/// A rug still going reads 1 wei once it reaches a third slice (12 minutes).
	function test_aRugStillGoingZeroesAfterTwelveMinutes() public {
		(ScriptedCLPool twelve, MockERC20 a) = _pulled(0, 719);
		assertEq(_answer(_adapter(twelve, a)), 1e18, '11m59s: priced');
		(ScriptedCLPool past, MockERC20 b) = _pulled(0, 721);
		assertEq(_answer(_adapter(past, b)), 1, '12m01s: 1 wei');
	}

	// ─── a pushed price (review 2026-11-01, High 1) ─────────────────────────

	/// @dev A pool at $1 with liquidity to spare, pushed to `tick` for the last `seconds_`.
	function _pushed(int24 tick, uint32 seconds_) internal returns (ScriptedCLPool pool, MockERC20 tkn) {
		tkn = new MockERC20('Token', 'TKN', 6);
		pool = _pool(tkn, usdc);
		usdc.mint(address(pool), 1_000_000e6);
		pool.setOracle(tick, PLENTY);
		pool.setOlderTick(0, seconds_);
	}

	/// The reviewer's case: a burn, a dust swap to the end of the range, a minute's wait. The mean tick moved ×48; the
	/// median of the slices didn't, whichever way the push went.
	function test_aPushOfAMinuteLeavesThePrice() public {
		(ScriptedCLPool up, MockERC20 a) = _pushed(887_272, 60);
		assertEq(_answer(_adapter(up, a)), 1e18);
		assertNotEq(_answer(_v1(up, a)), 1e18, 'V1 (the control): the mean moved');
		(ScriptedCLPool down, MockERC20 b) = _pushed(-887_272, 60);
		assertEq(_answer(_adapter(down, b)), 1e18);
	}

	/// Two slices pushed, the third untouched: still the price, both ways.
	function test_aPushUnderTwelveMinutesLeavesThePrice() public {
		(ScriptedCLPool up, MockERC20 a) = _pushed(887_272, 719);
		assertEq(_answer(_adapter(up, a)), 1e18);
		(ScriptedCLPool down, MockERC20 b) = _pushed(-887_272, 719);
		assertEq(_answer(_adapter(down, b)), 1e18);
	}

	/// A free push needs an empty pool, and an empty pool reads 1 wei the moment the push would count: it never reads high.
	function test_aFreePushOnAnEmptyPoolNeverReadsHigh() public {
		(ScriptedCLPool up, MockERC20 a) = _pushed(887_272, 721);
		up.setDip(1, 0, 721);
		assertEq(_answer(_adapter(up, a)), 1);
		(ScriptedCLPool down, MockERC20 b) = _pushed(-887_272, 721);
		down.setDip(1, 0, 721);
		assertEq(_answer(_adapter(down, b)), 1);
	}

	/// The limit of any pool price: liquidity kept in range at the pushed price for over 12 minutes does move it.
	function test_aPushHeldWithLiquidityMovesThePriceAfterTwelveMinutes() public {
		(ScriptedCLPool pool, MockERC20 tkn) = _pushed(887_272, 721);
		assertNotEq(_answer(_adapter(pool, tkn)), 1e18);
	}

	// ─── an unsettled pool (review 2026-11-01) ───────────────────────────

	function _unsettled(ScriptedCLPool pool, MockERC20 tkn) internal returns (bool) {
		return IPoolWatch(address(_adapter(pool, tkn))).poolUnsettled();
	}

	function test_aSteadyPoolIsSettled() public {
		(ScriptedCLPool pool, MockERC20 tkn) = _pushed(0, 1);
		assertFalse(_unsettled(pool, tkn));
	}

	/// A rug shows the block it happens, while the price and the ≈ $0 rule still read the window.
	function test_liquidityUnderHalfNowIsUnsettled_atThePriceOfTheWindow() public {
		(ScriptedCLPool pool, MockERC20 tkn) = _pushed(0, 1);
		pool.setSpotLiquidity(PLENTY / 2);
		assertFalse(_unsettled(pool, tkn), 'half is the line');
		pool.setSpotLiquidity(PLENTY / 2 - 1);
		assertTrue(_unsettled(pool, tkn));
		assertEq(_answer(_adapter(pool, tkn)), 1e18);
	}

	/// A manager's own contract re-adding for one call: full liquidity now, gone for the last 30 seconds.
	function test_liquidityAddedThisBlockDoesNotHideAPull() public {
		(ScriptedCLPool pool, MockERC20 tkn) = _pushed(0, 1);
		pool.setDip(1, 0, 30);
		pool.setSpotLiquidity(PLENTY);
		assertTrue(_unsettled(pool, tkn));
	}

	/// A flash moves balances, not liquidity, and at worst a wait is all it could cost.
	function test_aFlashOfTheQuoteIsNoSignal() public {
		(ScriptedCLPool pool, MockERC20 tkn) = _pushed(0, 1);
		deal(address(usdc), address(pool), 0);
		assertFalse(_unsettled(pool, tkn));
	}

	/// History short of the window: a new pool, or a ring churned by swaps.
	function test_aShortHistoryIsUnsettled() public {
		(ScriptedCLPool pool, MockERC20 tkn) = _pushed(0, 1);
		pool.setHistory(1799);
		assertTrue(_unsettled(pool, tkn));
		pool.setHistory(1800);
		assertFalse(_unsettled(pool, tkn));
	}

	/// The buy floor still sees a pull at once: no buys while the pool's balance is gone.
	function test_theBuyFloorSeesAPullAtOnce() public {
		(ScriptedCLPool pool, MockERC20 tkn) = _pulled(0, 2);
		deal(address(usdc), address(pool), 1_000e6);
		assertEq(_adapter(pool, tkn).liquidityUsd(), 1_000e18);
	}

	/// V1's rounding test, in the slice that sets the median: tick -1 for the last 721 s, 0 before. The third slice's mean,
	/// -1/360, floors to -1, which is the median; rounded toward zero it would be 0, and so would the median.
	function test_meanTickRoundsTowardNegativeInfinity() public override {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 6);
		ScriptedCLPool pool = _pool(tkn, usdc);
		usdc.mint(address(pool), 1_000_000e6);
		pool.setOracle(-1, PLENTY);
		pool.setOlderTick(0, 721);

		// tick -1 is 1/1.0001 quote per asset for token0, 1.0001 for token1 (hand-computed)
		uint256 expected = pool.token0() == address(tkn) ? 999900009999000099 : 1_000100000000000000;
		assertApproxEqRel(uint256(_answer(_adapter(pool, tkn))), expected, 1e9);
	}

	/// On a steady pool V2 answers what V1 does: the price exactly, the buy floor to rounding (five slices).
	function test_answersAsV1DoesWhenNothingIsDrained() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 18);
		ScriptedCLPool pool = _pool(tkn, usdc);
		usdc.mint(address(pool), 10_000_000e6);
		pool.setOracle(_tickFor(pool, tkn, -269392), 707_106_781_186_547_524);
		IPoolPriceAdapter adapter = _adapter(pool, tkn);
		IPoolPriceAdapter v1 = _v1(pool, tkn);

		assertEq(_answer(adapter), _answer(v1));
		assertApproxEqRel(adapter.liquidityUsd(), v1.liquidityUsd(), 1e9);
	}
}
