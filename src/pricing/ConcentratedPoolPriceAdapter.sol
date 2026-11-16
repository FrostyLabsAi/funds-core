// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {PoolPriceAdapterBase} from './PoolPriceAdapterBase.sol';
import {IConcentratedPool} from '../interfaces/external/IConcentratedPool.sol';
import {TickMath} from '../libraries/TickMath.sol';
import {PoolPriceMath} from '../libraries/PoolPriceMath.sol';

/// @title ConcentratedPoolPriceAdapter
/// @notice A token's 30-minute price from a Uniswap v3 or Slipstream pool (or an Aero CL pool). The ≈ $0 rule reads only the window's in-range liquidity, never the quote token
///         the pool holds now, which a flash() empties for one call (red-team PRICING-POOL-01, 2026-10-27).
/// @dev - Five 6-minute slices of the window, and the median of each reading, so a reading moves only once it shows in three
///        slices (over 12 minutes for anything held; three block-long pulls 6 minutes apart for the liquidity).
///      - Price: the median of the slices' mean ticks. One mean over the window moved ×48 in a minute when an LP burned
///        everything and swapped dust to the end of the range, free at no liquidity (review 2026-11-01, High 1).
///      - Windowed: in-range liquidity as a full-range quote reserve at that tick, read as the median of the slices' harmonic
///        means. A flash moves balances, not in-range liquidity, so it can't move this. One harmonic mean over the whole
///        window follows its lowest stretch, so an LP pulling its own liquidity for one block (~2 s) dropped it to the cliff.
///        A free push needs an empty pool, which reads 1 wei by the time the push counts, so it never reads high. Five
///        slices, not six: an even count's median would let one direction through a slice sooner than the other.
///      - Current: the quote token the pool holds now; it counts only in `liquidityUsd()` (the buy floor).
///      - The price at a tick is PoolPriceMath's. What the 1-wei answer means for a fund: FundValuation's `floored`.
contract ConcentratedPoolPriceAdapter is PoolPriceAdapterBase {
	uint256 private constant SLICES = 5;
	uint32 private constant RECENT = 1 minutes;

	error PoolReadFailed();

	function _read(Config memory c, uint256 quoteUsd18) internal view override returns (uint256, uint256, uint256) {
		(int24 meanTick, uint128 windowedLiquidity) = _consult(c.pool);
		uint256 sqrtP = TickMath.getSqrtRatioAtTick(meanTick);
		uint256 unit = 10 ** c.quoteDecimals;
		uint256 windowed = Math.mulDiv(PoolPriceMath.quoteReserve(windowedLiquidity, sqrtP, c.assetIsToken0), quoteUsd18, unit);
		uint256 current = Math.mulDiv(IERC20(c.quoteAsset).balanceOf(c.pool), quoteUsd18, unit);
		uint256 price = PoolPriceMath.usdPerAssetAtSqrtP(sqrtP, c.assetIsToken0, c.assetDecimals, c.quoteDecimals, quoteUsd18);
		return (windowed, current, price);
	}

	/// @dev The lower of the pool's in-range liquidity now and over the last minute, against the window's. Now shows a pull in
	///      this very block; the last minute can't be lifted by liquidity added in this block, which has had no time to count, so
	///      a manager's own contract can't re-add for one call. History shorter than the window (a new pool, or the observation
	///      ring churned by swaps: 450 slots last 15 minutes at one a block, and 900 can't be grown in one transaction under
	///      Base's 16.7M gas cap) would shorten the time a push must hold (review 2026-11-01).
	function _poolUnsettled(Config memory c) internal view override returns (bool) {
		if (_span(c.pool) < WINDOW) return true;
		(, uint128 windowed) = _consult(c.pool);
		uint32[] memory secondsAgos = new uint32[](2);
		secondsAgos[0] = RECENT;
		(, uint160[] memory secondsPerLiquidity) = IConcentratedPool(c.pool).observe(secondsAgos);
		uint256 recent = _harmonicMean(RECENT, secondsPerLiquidity[1] - secondsPerLiquidity[0]);
		return Math.min(recent, IConcentratedPool(c.pool).liquidity()) * 2 < windowed;
	}

	/// @dev The median of the slices' arithmetic-mean ticks (rounded toward −∞, as Uniswap OracleLibrary.consult) and of their
	///      harmonic-mean liquidities, over the span. A span under one second a slice is one slice.
	function _consult(address pool) internal view returns (int24 meanTick, uint128 liquidity) {
		uint32 span = _span(pool);
		uint256 slices = span < SLICES ? 1 : SLICES;
		uint32[] memory secondsAgos = new uint32[](slices + 1);
		for (uint256 i; i < slices; ++i) {
			secondsAgos[i] = uint32(span - (span * i) / slices);
		}
		(int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidity) = IConcentratedPool(pool).observe(secondsAgos);

		int256[] memory ticks = new int256[](slices);
		int256[] memory liquidities = new int256[](slices);
		for (uint256 i; i < slices; ++i) {
			uint32 seconds_ = secondsAgos[i] - secondsAgos[i + 1];
			ticks[i] = _meanTick(tickCumulatives[i + 1] - tickCumulatives[i], seconds_);
			liquidities[i] = int256(uint256(_harmonicMean(seconds_, secondsPerLiquidity[i + 1] - secondsPerLiquidity[i])));
		}
		meanTick = int24(_median(ticks));
		liquidity = uint128(uint256(_median(liquidities)));
	}

	function _meanTick(int56 tickDelta, uint32 seconds_) private pure returns (int256 mean) {
		int56 secondsSigned = int56(uint56(seconds_));
		mean = tickDelta / secondsSigned;
		if (tickDelta < 0 && tickDelta % secondsSigned != 0) mean--;
	}

	/// @dev In-range liquidity over `seconds_` from its secondsPerLiquidity delta (ConcentratedPoolPriceAdapter's formula).
	function _harmonicMean(uint32 seconds_, uint160 splDelta) private pure returns (uint128) {
		return uint128((uint256(seconds_) * type(uint160).max) / (uint256(splDelta) << 32));
	}

	/// @dev The middle entry, by insertion sort (at most SLICES entries, an odd count).
	function _median(int256[] memory a) private pure returns (int256) {
		for (uint256 i = 1; i < a.length; ++i) {
			int256 v = a[i];
			uint256 j = i;
			while (j > 0 && a[j - 1] > v) {
				a[j] = a[j - 1];
				--j;
			}
			a[j] = v;
		}
		return a[a.length / 2];
	}

	/// @dev min(WINDOW, age of the pool's oldest observation), found the way Uniswap's oracle does:
	///      the slot after the newest, or slot 0 while that slot is reserved but unwritten.
	function _span(address pool) internal view returns (uint32) {
		(bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature('slot0()'));
		if (!ok || data.length < 128) revert PoolReadFailed();
		(,, uint16 index, uint16 cardinality) = abi.decode(data, (uint160, int24, uint16, uint16));

		(uint32 oldest,,, bool initialized) = IConcentratedPool(pool).observations((uint256(index) + 1) % cardinality);
		if (!initialized) (oldest,,,) = IConcentratedPool(pool).observations(0);

		uint256 age = block.timestamp - oldest;
		if (age == 0) revert NoPriceHistory();
		return age < WINDOW ? uint32(age) : WINDOW;
	}
}
