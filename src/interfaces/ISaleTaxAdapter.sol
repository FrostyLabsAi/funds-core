// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title ISaleTaxAdapter
/// @notice An adapter whose pools can charge a fixed tax on a swap (a Uniswap v4 hook's) reports the one the sale in
///         `integrationData` pays, so the keeper's liquidation cap allows it on top (ComptrollerLib.liquidateTrade). An
///         adapter without it, or a route without a recorded tax, keeps the plain cap.
interface ISaleTaxAdapter {
	/// @notice The tax, in bps of what is sold, recorded for the pool this sale goes through (0 if none).
	function saleTaxBps(bytes calldata integrationData) external view returns (uint256);
}
