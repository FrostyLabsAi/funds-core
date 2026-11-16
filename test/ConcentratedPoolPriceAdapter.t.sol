// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {IValueInterpreter} from '../src/interfaces/IValueInterpreter.sol';
import {IPoolPriceAdapter} from '../src/interfaces/IPoolPriceAdapter.sol';
import {IPoolWatch} from '../src/interfaces/IPoolWatch.sol';
import {ConcentratedPoolPriceAdapter} from '../src/pricing/ConcentratedPoolPriceAdapter.sol';
import {PoolPriceAdapterBase} from '../src/pricing/PoolPriceAdapterBase.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';
import {ScriptedCLPool} from './utils/PoolPriceMocks.sol';

/// @notice ConcentratedPoolPriceAdapter: a token's 30-minute price from a Uniswap v3 or Slipstream pool. The ≈ $0 rule reads
///         the window's liquidity only, so emptying the pool's quote balance for one call (a flash) doesn't zero the price
///         (red-team PRICING-POOL-01, 2026-10-27); the buy floor (`liquidityUsd`) still counts the balance now. The window
///         is read as five 6-minute slices and their median, so an LP's own pull must last over 12 minutes, not one block.
contract ConcentratedPoolPriceAdapterTest is Test {
	ValueInterpreter internal vi;
	address internal impl;
	MockERC20 internal usdc;
	MockERC20 internal weth;
	MockAggregator internal wethFeed;
	address internal admin = makeAddr('admin');

	function setUp() public {
		vm.warp(30 days);
		vi = new ValueInterpreter(admin);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		weth = new MockERC20('Wrapped Ether', 'WETH', 18);
		wethFeed = new MockAggregator(8, 2000e8);
		vm.startPrank(admin);
		vi.addPrimitive(address(usdc), address(new MockAggregator(8, 1e8)), 25 hours);
		vi.addPrimitive(address(weth), address(wethFeed), 1 hours);
		vm.stopPrank();
		impl = address(new ConcentratedPoolPriceAdapter());
	}


	// ─── helpers ─────────────────────────────────────────────────────────────────

	/// @dev A pool of `asset` against `quote` with 2 days of history and plenty of liquidity.
	function _pool(MockERC20 asset, MockERC20 quote) internal returns (ScriptedCLPool pool) {
		pool = new ScriptedCLPool(address(asset), address(quote), address(this), 3000, 60);
		pool.setHistory(2 days);
	}

	function _adapter(ScriptedCLPool pool, MockERC20 asset) internal returns (IPoolPriceAdapter) {
		bool assetIsToken0 = pool.token0() == address(asset);
		address quote = assetIsToken0 ? pool.token1() : pool.token0();
		bytes memory args = abi.encode(
			IPoolPriceAdapter.Config({
				valueInterpreter: IValueInterpreter(address(vi)),
				pool: address(pool),
				asset: address(asset),
				quoteAsset: quote,
				assetIsToken0: assetIsToken0,
				assetDecimals: asset.decimals(),
				quoteDecimals: MockERC20(quote).decimals()
			})
		);
		return IPoolPriceAdapter(Clones.cloneWithImmutableArgs(address(impl), args));
	}

	/// @dev The tick at which one raw asset unit trades for `ratioTick`'s raw quote, from the
	///      asset's side: token1/token0 = 1.0001^tick, so an asset that is token1 flips the sign.
	function _tickFor(ScriptedCLPool pool, MockERC20 asset, int24 assetIsToken0Tick) internal view returns (int24) {
		return pool.token0() == address(asset) ? assetIsToken0Tick : -assetIsToken0Tick;
	}

	function _answer(IPoolPriceAdapter adapter) internal view returns (int256 answer) {
		(, answer,,,) = adapter.latestRoundData();
	}

	/// @dev USDC (6 decimals) liquidity L at tick 0 is L raw USDC as a full-range reserve.
	uint128 internal constant PLENTY = 1_000_000e6;

	// ─── price ───────────────────────────────────────────────────────────────────

	function test_pricesTheAssetAtTheWindowMeanTick() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 18);
		ScriptedCLPool pool = _pool(tkn, usdc);
		usdc.mint(address(pool), 1_000_000e6);
		// 1.0001^-269392 raw USDC per raw TKN = $2.00004161… per whole TKN (hand-computed);
		// L = √(500k TKN · 1M USDC) in raw units = √(5e23 · 1e12) ≈ 7.07e17 — a $1M-a-side pool
		pool.setOracle(_tickFor(pool, tkn, -269392), 707_106_781_186_547_524);

		assertApproxEqRel(_answer(_adapter(pool, tkn)), 2_000041611588882731, 1e9);
	}

	function test_pricesInUsdThroughTheQuoteTokensValueInterpreterPrice() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 18);
		ScriptedCLPool pool = _pool(tkn, weth);
		weth.mint(address(pool), 1_000e18);
		pool.setOracle(0, 1_000e18); // 1 WETH per TKN
		IPoolPriceAdapter adapter = _adapter(pool, tkn);

		assertEq(_answer(adapter), 2000e18);
		wethFeed.setAnswer(3000e8);
		assertEq(_answer(adapter), 3000e18);
	}

	function test_doesNotRevertWhenSpotIsFarFromTheWindowPrice() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 6);
		ScriptedCLPool pool = _pool(tkn, usdc);
		usdc.mint(address(pool), 1_000_000e6);
		pool.setOracle(0, PLENTY);
		pool.setSpotTick(5_000); // spot ≈ 65% away from the 30-minute price

		assertEq(_answer(_adapter(pool, tkn)), 1e18);
	}

	function test_usesThirtyMinutesWhenThePoolRemembersMore() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 6);
		ScriptedCLPool pool = _pool(tkn, usdc); // 2 days of history
		usdc.mint(address(pool), 1_000_000e6);
		pool.setOracle(0, PLENTY); // $1 over the last 30 minutes…
		pool.setOlderTick(_tickFor(pool, tkn, 23028), 30 minutes); // …$10 before that

		assertEq(_answer(_adapter(pool, tkn)), 1e18);
	}

	function test_usesWhatHistoryThePoolHasWhenUnderThirtyMinutes() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 6);
		ScriptedCLPool pool = _pool(tkn, usdc);
		usdc.mint(address(pool), 1_000_000e6);
		pool.setOracle(0, PLENTY);
		pool.setHistory(10 minutes); // a 30-minute observe would revert 'OLD'

		assertEq(_answer(_adapter(pool, tkn)), 1e18);
	}

	function test_findsTheOldestObservationInSlotZeroWhileTheRingGrows() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 6);
		ScriptedCLPool pool = _pool(tkn, usdc);
		usdc.mint(address(pool), 1_000_000e6);
		pool.setOracle(0, PLENTY);
		// the slot after the newest is reserved but unwritten; slot 0 is 10 minutes old
		pool.setGrowingHistory(10 minutes);

		assertEq(_answer(_adapter(pool, tkn)), 1e18);
	}

	function test_revertsWhenThePoolHasNoHistoryBeforeThisBlock() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 6);
		ScriptedCLPool pool = _pool(tkn, usdc);
		usdc.mint(address(pool), 1_000_000e6);
		pool.setOracle(0, PLENTY);
		pool.setHistory(0);
		IPoolPriceAdapter adapter = _adapter(pool, tkn);

		vm.expectRevert(PoolPriceAdapterBase.NoPriceHistory.selector);
		adapter.latestRoundData();
	}

	function test_neverAnswersZero() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 0);
		ScriptedCLPool pool = _pool(tkn, usdc);
		usdc.mint(address(pool), 1_000_000e6);
		// 1.0001^-400000 ≈ 4.2e-18 raw USDC per whole TKN ≈ $4e-24: rounds to 0 at 18 decimals,
		// while L = 1e20 still holds ≈ $206k (L · 1.0001^-200000) — above the valuation minimum
		pool.setOracle(_tickFor(pool, tkn, -400000), 1e20);

		assertEq(_answer(_adapter(pool, tkn)), 1);
	}

	// ─── liquidity ───────────────────────────────────────────────────────────────

	function test_liquidityIsTheBalanceWhenTheWindowHadMore() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 6);
		ScriptedCLPool pool = _pool(tkn, usdc);
		usdc.mint(address(pool), 40_000e6);
		pool.setOracle(0, 100_000e6); // at tick 0, L = 100k USDC as a full-range reserve

		assertEq(_adapter(pool, tkn).liquidityUsd(), 40_000e18);
	}

	function test_liquidityIsTheWindowsWhenTheBalanceIsHigher() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 6);
		ScriptedCLPool pool = _pool(tkn, usdc);
		usdc.mint(address(pool), 100_000e6);
		pool.setOracle(0, 30_000e6);

		assertApproxEqRel(_adapter(pool, tkn).liquidityUsd(), 30_000e18, 1e9);
	}

	function test_liquidityReadsTheWindowedReserveOnTheQuoteSide() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 18);
		ScriptedCLPool pool = _pool(tkn, usdc);
		usdc.mint(address(pool), 10_000_000e6);
		// $2 TKN in a $1M-a-side pool (see test_pricesTheAssetAtTheWindowMeanTick): the window's
		// liquidity holds ≈ 1M USDC, under the 10M balance
		pool.setOracle(_tickFor(pool, tkn, -269392), 707_106_781_186_547_524);

		assertApproxEqRel(_adapter(pool, tkn).liquidityUsd(), 1_000_000e18, 1e14);
	}

	function test_liquidityIsCountedInUsdAtTheQuotePrice() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 18);
		ScriptedCLPool pool = _pool(tkn, weth);
		weth.mint(address(pool), 10e18); // 10 WETH at $2000
		pool.setOracle(0, 1_000e18);

		assertEq(_adapter(pool, tkn).liquidityUsd(), 20_000e18);
	}

	function test_pricesNearZeroWhenLiquidityLeftDuringTheWindow() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 6);
		ScriptedCLPool pool = _pool(tkn, usdc);
		// a rug that removed liquidity without collecting: the balance is still there
		usdc.mint(address(pool), 1_000_000e6);
		pool.setOracle(0, 1_000e6);

		assertEq(_answer(_adapter(pool, tkn)), 1);
	}

	function test_pricesNormallyAtExactlyTheValuationMinimum() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 6);
		ScriptedCLPool pool = _pool(tkn, usdc);
		usdc.mint(address(pool), 5_000e6);
		pool.setOracle(0, PLENTY);

		assertEq(_answer(_adapter(pool, tkn)), 1e18);
	}

	// ─── feed shape ──────────────────────────────────────────────────────────────

	function test_answersAreStampedNowWithEighteenDecimals() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 6);
		ScriptedCLPool pool = _pool(tkn, usdc);
		usdc.mint(address(pool), 1_000_000e6);
		pool.setOracle(0, PLENTY);
		IPoolPriceAdapter adapter = _adapter(pool, tkn);

		(,,, uint256 updatedAt,) = adapter.latestRoundData();
		assertEq(updatedAt, block.timestamp);
		assertEq(adapter.decimals(), 18);
	}

	function test_valueInterpreterPricesAHoldingThroughTheAdapter() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 18);
		ScriptedCLPool pool = _pool(tkn, weth);
		weth.mint(address(pool), 1_000e18);
		pool.setOracle(0, 1_000e18); // 1 WETH per TKN = $2000
		IPoolPriceAdapter adapter = _adapter(pool, tkn);
		vm.prank(admin);
		vi.addPrimitive(address(tkn), address(adapter), 1 hours);

		// 3 TKN = $6000 = 6000 USDC
		assertEq(vi.calcCanonicalAssetValue(address(tkn), 3e18, address(usdc)), 6000e6);
	}

	/// The pool's quote balance gone for this call, the window's liquidity unchanged: the price stays at the window.
	function test_aDrainedQuoteBalanceLeavesThePriceAtTheWindow() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 6);
		ScriptedCLPool pool = _pool(tkn, usdc);
		usdc.mint(address(pool), 1_000_000e6);
		pool.setOracle(0, PLENTY); // $1 per TKN, $1M of windowed liquidity
		IPoolPriceAdapter adapter = _adapter(pool, tkn);
		assertEq(_answer(adapter), 1e18);

		deal(address(usdc), address(pool), 0);
		assertEq(_answer(adapter), 1e18, 'still the window price');

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

	/// The pull-and-wait-a-block case: one 2-second pull doesn't read as a rug (one harmonic mean over the window would).
	function test_aOneBlockPullDoesNotZeroTheToken() public {
		(ScriptedCLPool pool, MockERC20 tkn) = _pulled(100, 102);
		assertEq(_answer(_adapter(pool, tkn)), 1e18, 'priced');
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

	/// The mean tick rounds toward negative infinity, in the slice that sets the median: tick -1 for the last 721 s, 0 before. The third slice's mean,
	/// -1/360, floors to -1, which is the median; rounded toward zero it would be 0, and so would the median.
	function test_meanTickRoundsTowardNegativeInfinity() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 6);
		ScriptedCLPool pool = _pool(tkn, usdc);
		usdc.mint(address(pool), 1_000_000e6);
		pool.setOracle(-1, PLENTY);
		pool.setOlderTick(0, 721);

		// tick -1 is 1/1.0001 quote per asset for token0, 1.0001 for token1 (hand-computed)
		uint256 expected = pool.token0() == address(tkn) ? 999900009999000099 : 1_000100000000000000;
		assertApproxEqRel(uint256(_answer(_adapter(pool, tkn))), expected, 1e9);
	}
}
