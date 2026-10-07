// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice What a V3 comptroller reads from its redemption queue (founder 2026-10-06).
interface IRedemptionQueue {
	/// @notice True while the fund's oldest open request is past its deadline (fees stop).
	function isOverdue(address comptroller) external view returns (bool);
}
