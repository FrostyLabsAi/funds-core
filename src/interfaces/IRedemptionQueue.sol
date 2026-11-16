// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice What a comptroller reads from its redemption queue (founder 2026-10-06).
interface IRedemptionQueue {
	/// @notice True while the fund's oldest open request is past its deadline (fees stop).
	function isOverdue(address comptroller) external view returns (bool);

	/// @notice The fund's open requests: the oldest unpaid index and the queue's length. A reconfiguration waits until
	///         none are open.
	function queueBounds(address comptroller) external view returns (uint256 head, uint256 length);
}
