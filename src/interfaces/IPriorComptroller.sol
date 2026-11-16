// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title IPriorComptroller
/// @notice What a reconfiguration reads from the comptroller it replaces. Any earlier build answers it, so a fund can
///         move onto a new comptroller with its high-water mark and tracked assets intact.
interface IPriorComptroller {
	function highWaterMark() external view returns (uint256);
	function getTrackedAssets() external view returns (address[] memory);
}
