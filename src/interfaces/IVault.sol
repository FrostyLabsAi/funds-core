// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title IVault
/// @notice A fund's custody: holds its tokens and releases them only at its comptroller's call.
interface IVault {
	function factory() external view returns (address);
	function comptroller() external view returns (address);

	/// @notice Reconfiguration: custody follows the fund's new comptroller. Factory only.
	function migrateComptroller(address newComptroller) external;

	/// @notice Sends `amount` of `asset` to `to`. Comptroller only.
	function withdraw(address asset, address to, uint256 amount) external;
}
