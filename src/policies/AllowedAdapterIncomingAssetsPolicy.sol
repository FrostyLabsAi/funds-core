// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IPolicy} from '../interfaces/IPolicy.sol';

/// @title AllowedAdapterIncomingAssetsPolicy
/// @notice Whitelist of assets a fund may ACQUIRE through adapter trades — the fund's
///         investable-universe commitment to depositors.
/// @dev Port of melon-v1 AssetWhitelist (melon-v1/src/fund/policies/risk-management/
///      AssetWhitelist.sol) as v4's AllowedAdapterIncomingAssetsPolicy
///      (spec/topics/policies.md). Immutable set — deploy a new instance to change it.
contract AllowedAdapterIncomingAssetsPolicy is IPolicy {
	mapping(address asset => bool) public isAllowedAsset;

	error IncomingAssetNotAllowed(address asset);

	constructor(address[] memory allowedAssets) {
		for (uint256 i; i < allowedAssets.length; ++i) {
			isAllowedAsset[allowedAssets[i]] = true;
		}
	}

	/// @inheritdoc IPolicy
	function validate(PolicyHook, bytes calldata validationData) external view {
		(,,, address[] memory incomingAssets,) =
			abi.decode(validationData, (address, address[], uint256[], address[], uint256[]));
		for (uint256 i; i < incomingAssets.length; ++i) {
			if (!isAllowedAsset[incomingAssets[i]]) revert IncomingAssetNotAllowed(incomingAssets[i]);
		}
	}

	/// @inheritdoc IPolicy
	function implementedHooks() external pure returns (PolicyHook[] memory hooks) {
		hooks = new PolicyHook[](1);
		hooks[0] = PolicyHook.PostCallOnIntegration;
	}
}
