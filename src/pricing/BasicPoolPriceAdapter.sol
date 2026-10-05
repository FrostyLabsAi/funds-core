// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {PoolPriceAdapterBase} from './PoolPriceAdapterBase.sol';

/// @notice The Aerodrome basic (v2-style) pool views the adapter reads.
interface IAerodromeBasicPool {
	function observationLength() external view returns (uint256);

	function observations(uint256 index)
		external
		view
		returns (uint256 timestamp, uint256 reserve0Cumulative, uint256 reserve1Cumulative);

	function lastObservation()
		external
		view
		returns (uint256 timestamp, uint256 reserve0Cumulative, uint256 reserve1Cumulative);

	/// @notice Cumulative RESERVES (not prices, despite the name) at `block.timestamp`.
	function currentCumulativePrices()
		external
		view
		returns (uint256 reserve0Cumulative, uint256 reserve1Cumulative, uint256 blockTimestamp);

	function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);
}

/// @title BasicPoolPriceAdapter
/// @notice Prices one asset from its Aerodrome basic VOLATILE (x·y=k) pool: the pool's
///         time-averaged reserves since its newest observation at least 30 minutes old (the pool
///         records one at most every 30 minutes; a pool younger than that uses all it has), times
///         the ValueInterpreter's USD price of the pool's other token. One minimal clone per asset
///         (PoolPriceRegistrar); its Config is the clone's immutable args.
/// @dev Only time moves the cumulatives, so a swap in the reading block can't move the average.
///      Liquidity is the lower of the current quote reserve and its window average, both from
///      `getReserves()` — never `balanceOf`, since `skim()` hands donations back to anyone.
///      Ported from AerodromeBasicTwapAdapter without its spot-deviation revert.
contract BasicPoolPriceAdapter is PoolPriceAdapterBase {
	function _read(Config memory c, uint256 quoteUsd18) internal view override returns (uint256, uint256) {
		IAerodromeBasicPool pool = IAerodromeBasicPool(c.pool);
		(uint256 avgAsset, uint256 avgQuote) = _averageReserves(pool, c.assetIsToken0);
		(uint256 r0, uint256 r1,) = pool.getReserves();
		uint256 reserveQuote = c.assetIsToken0 ? r1 : r0;

		uint256 liquidity = Math.mulDiv(Math.min(reserveQuote, avgQuote), quoteUsd18, 10 ** c.quoteDecimals);
		// floor(avgQuote · 10^ad · quoteUsd18 / (avgAsset · 10^qd)), rounded once (mulDiv is 512-bit)
		uint256 price =
			avgAsset == 0 ? 0 : Math.mulDiv(avgQuote, 10 ** c.assetDecimals * quoteUsd18, avgAsset) / 10 ** c.quoteDecimals;
		return (liquidity, price);
	}

	/// @dev Average reserves (raw units) from the newest observation at least WINDOW old — the last,
	///      else the one before it (observations are ≥ 30 minutes apart) — or the only one there is.
	function _averageReserves(IAerodromeBasicPool pool, bool assetIsToken0)
		internal
		view
		returns (uint256 avgAsset, uint256 avgQuote)
	{
		(uint256 t, uint256 c0, uint256 c1) = pool.lastObservation();
		uint256 count = pool.observationLength();
		if (block.timestamp - t < WINDOW && count >= 2) (t, c0, c1) = pool.observations(count - 2);

		(uint256 n0, uint256 n1, uint256 now_) = pool.currentCumulativePrices();
		uint256 span = now_ - t;
		if (span == 0) revert NoPriceHistory();
		(uint256 avg0, uint256 avg1) = ((n0 - c0) / span, (n1 - c1) / span);
		(avgAsset, avgQuote) = assetIsToken0 ? (avg0, avg1) : (avg1, avg0);
	}
}
