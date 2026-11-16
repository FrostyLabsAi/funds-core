// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title IVerantaPriceStore
/// @notice Veranta's Pyth-signed prices, relayed on demand: the latest confirmed price per Veranta pair and when the
///         market last traded.
interface IVerantaPriceStore {
	/// @notice Verifies a signed Pyth Lazer packet for `pairIndex` and keeps it if newer. Anyone may relay.
	function submit(uint256 pairIndex, bytes calldata update) external payable returns (bool stored);

	/// @notice The pair's last confirmed price and when Pyth signed it as current (microseconds).
	function latest(uint256 pairIndex) external view returns (int64 price, int16 exponent, uint64 timestampUs);

	/// @notice When the pair's market last traded (the feed's own update time, microseconds).
	function feedUpdatedUs(uint256 pairIndex) external view returns (uint64);
}
