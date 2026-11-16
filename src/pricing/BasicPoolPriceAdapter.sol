// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {PoolPriceAdapterBase} from './PoolPriceAdapterBase.sol';
import {IAerodromeBasicPool} from '../interfaces/external/IAerodromeBasicPool.sol';

/// @title BasicPoolPriceAdapter
/// @notice A token's price from an Aerodrome basic VOLATILE pool's time-averaged reserves. The ≈ $0 rule reads only the
///         window's average quote reserve, never the current one, which a large sale or an LP's own burn can empty inside one transaction (red-team PRICING-POOL-01,
///         second pass, 2026-10-27).
/// @dev - Windowed: the average quote reserve since the newest observation at least 30 minutes old. Only time moves the
///        cumulatives, so nothing in the reading block moves it.
///      - Current: `getReserves()`'s quote reserve (never `balanceOf`: `skim()` hands donations back to anyone); it counts
///        only in `liquidityUsd()` (the buy floor).
contract BasicPoolPriceAdapter is PoolPriceAdapterBase {
	function _read(Config memory c, uint256 quoteUsd18)
		internal
		view
		override
		returns (uint256 windowed, uint256 current, uint256 price)
	{
		(uint256 avgAsset, uint256 avgQuote) = _averageReserves(IAerodromeBasicPool(c.pool), c.assetIsToken0);
		uint256 unit = 10 ** c.quoteDecimals;
		windowed = Math.mulDiv(avgQuote, quoteUsd18, unit);
		current = Math.mulDiv(_reserveQuote(c), quoteUsd18, unit);
		// floor(avgQuote · 10^ad · quoteUsd18 / (avgAsset · 10^qd)), rounded once (mulDiv is 512-bit)
		price = avgAsset == 0 ? 0 : Math.mulDiv(avgQuote, 10 ** c.assetDecimals * quoteUsd18, avgAsset) / unit;
	}

	/// @dev The quote reserve now against the window's average (review 2026-11-01). This ends the lag of the ≈ $0 rule, which
	///      takes up to 9.7 h to show a rug in a quiet pool nobody calls `sync()` on. Added reserves do lift it within a block,
	///      so a manager's own contract with a flash loan can pass it for one call: real capital, unlike a concentrated pool.
	function _poolUnsettled(Config memory c) internal view override returns (bool) {
		(, uint256 avgQuote) = _averageReserves(IAerodromeBasicPool(c.pool), c.assetIsToken0);
		return _reserveQuote(c) * 2 < avgQuote;
	}

	function _reserveQuote(Config memory c) private view returns (uint256) {
		(uint256 r0, uint256 r1,) = IAerodromeBasicPool(c.pool).getReserves();
		return c.assetIsToken0 ? r1 : r0;
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
