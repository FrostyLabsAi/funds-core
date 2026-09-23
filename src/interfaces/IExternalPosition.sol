// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title IExternalPosition
/// @notice A non-ERC20 fund holding that lives outside the Vault and reports its value
///         as virtual managed (+) and debt (-) asset positions, aggregated into GAV by
///         the ValueInterpreter.
/// @dev Pattern per Enzyme v4 external positions (spec/topics/external-positions.md).
///      First planned implementation: HyperliquidPerpPosition (the delta-neutral hedge leg).
///      Funds holding external positions must use specific-assets redemption as the canonical
///      exit — in-kind redemption forfeits external-position value (spec/topics/fund-holdings.md).
interface IExternalPosition {
	/// @notice Assets this position manages (positive value).
	function getManagedAssets() external returns (address[] memory assets, uint256[] memory amounts);

	/// @notice Assets this position owes (negative value).
	function getDebtAssets() external returns (address[] memory assets, uint256[] memory amounts);

	/// @notice Entry point for position actions. MUST only be callable via the owning fund's
	///         Comptroller so every interaction passes policy hooks.
	function receiveCallFromFund(bytes calldata actionData) external;
}
