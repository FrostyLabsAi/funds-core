// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title IExternalPosition
/// @notice A fund holding outside the Vault that reports its value as managed (+) and debt (-)
///         assets, aggregated into GAV.
/// @dev In-kind redemption forfeits external-position value.
interface IExternalPosition {
	/// @notice Assets this position manages (positive value).
	function getManagedAssets() external returns (address[] memory assets, uint256[] memory amounts);

	/// @notice Assets this position owes (negative value).
	function getDebtAssets() external returns (address[] memory assets, uint256[] memory amounts);

	/// @notice Entry point for position actions; only the owning Comptroller may call it (policy hooks).
	function receiveCallFromFund(bytes calldata actionData) external;

	/// @notice True only for an action that moves value solely back toward the fund (close,
	///         cancel, return to vault). Such actions run unpriced, so a stale oracle never
	///         blocks cutting risk. False for anything else.
	function isRiskReducing(bytes calldata actionData) external view returns (bool);
}
