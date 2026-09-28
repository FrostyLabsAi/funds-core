// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title IExternalPositionTypeFactory
/// @notice Per-type deployer for external positions; types are registered on the FundFactory.
interface IExternalPositionTypeFactory {
	function deployPosition(address comptroller, bytes calldata initArgs) external returns (address position);
}
