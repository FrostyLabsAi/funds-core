// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IPolicy} from '../interfaces/IPolicy.sol';

/// @title AllowedExternalPositionTypesPolicy
/// @notice Restricts which external position types a fund may create. The primary use is a
///         fund committing to investors that it uses NO external positions (empty list) or
///         only specific ones (e.g., only HyperliquidPerp), per v4's
///         AllowedExternalPositionTypesPolicy (spec/topics/policies.md).
/// @dev Immutable set, fixed at deployment — deploy a new instance to change it.
contract AllowedExternalPositionTypesPolicy is IPolicy {
	mapping(uint256 typeId => bool) public isAllowedType;

	error PositionTypeNotAllowed(uint256 typeId);

	constructor(uint256[] memory allowedTypeIds) {
		for (uint256 i; i < allowedTypeIds.length; ++i) {
			isAllowedType[allowedTypeIds[i]] = true;
		}
	}

	/// @inheritdoc IPolicy
	function validate(PolicyHook, bytes calldata validationData) external view {
		// CreateExternalPosition: (typeId, position)
		(uint256 typeId,) = abi.decode(validationData, (uint256, address));
		if (!isAllowedType[typeId]) revert PositionTypeNotAllowed(typeId);
	}

	/// @inheritdoc IPolicy
	function implementedHooks() external pure returns (PolicyHook[] memory hooks) {
		hooks = new PolicyHook[](1);
		hooks[0] = PolicyHook.CreateExternalPosition;
	}
}
