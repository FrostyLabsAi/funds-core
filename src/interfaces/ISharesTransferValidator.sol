// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice What Shares asks before every transfer between holders: the fund's comptroller, which runs its
///         transfer policies and reverts to block one.
interface ISharesTransferValidator {
	function validateSharesTransfer(address from, address to, uint256 amount) external;
}
