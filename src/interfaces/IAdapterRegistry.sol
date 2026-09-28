// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice The Comptroller's view of the FundFactory's protocol-curated adapter list.
interface IAdapterRegistry {
	function isAdapterRegistered(address adapter) external view returns (bool);
}

/// @notice The Comptroller's view of the FundFactory's protocol AUM-fee config, read at every settlement.
interface IProtocolFeeConfig {
	function getProtocolFeeConfig() external view returns (uint256 feeBps, address recipient);
}
