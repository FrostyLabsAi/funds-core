// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice The Comptroller's view of the FundFactory's protocol-curated adapter list.
interface IAdapterRegistry {
	function isAdapterRegistered(address adapter) external view returns (bool);
}
