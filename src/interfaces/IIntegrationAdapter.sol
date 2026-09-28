// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title IIntegrationAdapter
/// @notice Venue adapter for fund trading, invoked only via Comptroller.callOnIntegration.
/// @dev The Comptroller sends spend assets to the adapter, calls executeAction, then checks the
///      vault's balance deltas against minIncomingAmounts (the adapter is never trusted for accounting).
interface IIntegrationAdapter {
	/// @notice Describe the asset flows of an action before execution.
	function parseAssetsForAction(bytes calldata integrationData)
		external
		view
		returns (
			address[] memory spendAssets,
			uint256[] memory spendAmounts,
			address[] memory incomingAssets,
			uint256[] memory minIncomingAmounts
		);

	/// @notice Execute the action; all output MUST be sent to `vault`.
	function executeAction(address vault, bytes calldata integrationData) external;
}
