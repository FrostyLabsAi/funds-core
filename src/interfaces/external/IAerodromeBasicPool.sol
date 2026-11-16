// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IDexPool} from './IDexPool.sol';

/// @notice An Aerodrome basic (v2-style) pool: the views the price adapter reads.
interface IAerodromeBasicPool is IDexPool {
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
