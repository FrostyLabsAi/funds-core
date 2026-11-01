// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title IPoolWatch
/// @notice Whether a pool-priced token's pool can be trusted for deposits and settlement right now. It only ever makes them
///         wait, it never changes a price, so a flash that trips it costs nobody anything (review 2026-11-01).
interface IPoolWatch {
	/// @return True while the pool's liquidity now is under half the window's, or its history doesn't cover the window.
	function poolUnsettled() external view returns (bool);
}
