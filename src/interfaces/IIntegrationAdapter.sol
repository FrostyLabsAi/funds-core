// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title IIntegrationAdapter
/// @notice Venue adapter for fund trading, invoked only via Comptroller.callOnIntegration.
/// @dev Successor to melon-v1 ExchangeAdapter (melon-v1/src/exchanges/ExchangeAdapter.sol),
///      shaped by Enzyme v4's IntegrationManager adapter model
///      (spec/architecture/release.md#integrationmanager).
///      Flow: the Comptroller transfers spend assets to the adapter, calls executeAction,
///      and verifies the vault received at least minIncomingAmounts of each incoming asset
///      (measured by balance delta — the adapter's own claims are never trusted for
///      accounting). Adapters are protocol-curated via the FundFactory registry.
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
