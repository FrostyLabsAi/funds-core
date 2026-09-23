// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title IExternalPositionTypeFactory
/// @notice Per-type deployer for external positions (Enzyme v4's lib/parser registry reduced
///         to a factory per type; the beacon-proxy upgrade path arrives with the proxy PR).
///         Types are registered on the FundFactory by protocol governance.
interface IExternalPositionTypeFactory {
	function deployPosition(address comptroller, bytes calldata initArgs) external returns (address position);
}
