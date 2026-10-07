// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice A position-type helper the RedemptionQueue's fallback unwind uses (founder 2026-10-06).
///         Stateless and holds nothing: it only describes actions, which the queue forwards through
///         ComptrollerV3.forwardUnwind, where the position's own isRiskReducing decides.
interface IRedemptionUnwinder {
	/// @notice True for a position this unwinder knows how to unwind.
	function canUnwind(address position) external view returns (bool);

	/// @notice Actions that close `fractionWad` (1e18 = all) of the position, pro rata.
	function closeActions(address position, uint256 fractionWad) external view returns (bytes[] memory);

	/// @notice The action that returns the position's idle value to the fund's vault (empty = nothing to return).
	function collectAction(address position) external view returns (bytes memory);

	/// @notice True while a close sent to the venue still waits for its fill.
	function hasPending(address position) external view returns (bool);
}
