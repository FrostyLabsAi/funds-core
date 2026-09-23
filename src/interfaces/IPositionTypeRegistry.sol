// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice The Comptroller's view of the FundFactory's external-position type registry.
interface IPositionTypeRegistry {
	function positionTypeFactories(uint256 typeId) external view returns (address);
}
