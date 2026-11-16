// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IDexPool} from './IDexPool.sol';

/// @notice A concentrated-liquidity pool, Uniswap v3 or Aerodrome Slipstream: the views and the history call the price
///         adapter and the registrar use. The shapes match on both; slot0 differs after its fourth field, so the adapter
///         reads it raw.
interface IConcentratedPool is IDexPool {
	function observe(uint32[] calldata secondsAgos)
		external
		view
		returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

	function observations(uint256 index)
		external
		view
		returns (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized);

	/// @notice In-range liquidity now.
	function liquidity() external view returns (uint128);

	function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}

/// @notice A Uniswap v3 pool, keyed in its factory by fee tier (pips).
interface IUniswapV3Pool is IConcentratedPool {
	function fee() external view returns (uint24);
}

/// @notice An Aerodrome Slipstream pool, keyed in its factory by tick spacing.
interface ISlipstreamPool is IConcentratedPool {
	function tickSpacing() external view returns (int24);
}
