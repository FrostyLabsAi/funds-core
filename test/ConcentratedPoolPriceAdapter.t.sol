// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {IValueInterpreter} from '../src/interfaces/IValueInterpreter.sol';
import {IPoolPriceAdapter} from '../src/interfaces/IPoolPriceAdapter.sol';
import {ConcentratedPoolPriceAdapter} from '../src/pricing/ConcentratedPoolPriceAdapter.sol';
import {PoolPriceAdapterBase} from '../src/pricing/PoolPriceAdapterBase.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';
import {ScriptedCLPool} from './utils/PoolPriceMocks.sol';

contract ConcentratedPoolPriceAdapterTest is Test {
	ValueInterpreter internal vi;
	ConcentratedPoolPriceAdapter internal impl;
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
		impl = new ConcentratedPoolPriceAdapter();
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

	function test_meanTickRoundsTowardNegativeInfinity() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 6);
		ScriptedCLPool pool = _pool(tkn, usdc);
		usdc.mint(address(pool), 1_000_000e6);
		// tick -1 for the last second, 0 before: the mean, -1/1800, floors to -1
		pool.setOracle(-1, PLENTY);
		pool.setOlderTick(0, 1);

		// tick -1 is 1/1.0001 quote per asset for token0, 1.0001 for token1 (hand-computed)
		uint256 expected = pool.token0() == address(tkn) ? 999900009999000099 : 1_000100000000000000;
		assertApproxEqRel(uint256(_answer(_adapter(pool, tkn))), expected, 1e9);
	}

	function test_liquidityIsCountedInUsdAtTheQuotePrice() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 18);
		ScriptedCLPool pool = _pool(tkn, weth);
		weth.mint(address(pool), 10e18); // 10 WETH at $2000
		pool.setOracle(0, 1_000e18);

		assertEq(_adapter(pool, tkn).liquidityUsd(), 20_000e18);
	}

	function test_pricesNearZeroWhenThePoolWasDrained() public {
		MockERC20 tkn = new MockERC20('Token', 'TKN', 6);
		ScriptedCLPool pool = _pool(tkn, usdc);
		usdc.mint(address(pool), 4_999e6); // under the $5,000 valuation minimum
		pool.setOracle(0, PLENTY);

		assertEq(_answer(_adapter(pool, tkn)), 1);
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
}
