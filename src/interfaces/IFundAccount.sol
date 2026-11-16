// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title IFundAccount
/// @notice A contract that trades for one fund (a perp account): it answers which fund's comptroller owns it.
interface IFundAccount {
	function comptroller() external view returns (address);
}
