// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IPolicy} from '../interfaces/IPolicy.sol';

/// @title DisallowedAdapterIncomingAssetsPolicy
/// @notice Blacklist of assets a fund may never acquire through adapter trades (e.g., the
///         protocol's riskier-price-feeds list, per spec/topics/position-pricing.md).
/// @dev Port of melon-v1 AssetBlacklist (melon-v1/src/fund/policies/risk-management/
///      AssetBlacklist.sol) as v4's DisallowedAdapterIncomingAssetsPolicy.
///      Immutable set — deploy a new instance to change it.
contract DisallowedAdapterIncomingAssetsPolicy is IPolicy {
	mapping(address asset => bool) public isDisallowedAsset;

	error IncomingAssetDisallowed(address asset);

	constructor(address[] memory disallowedAssets) {
		for (uint256 i; i < disallowedAssets.length; ++i) {
			isDisallowedAsset[disallowedAssets[i]] = true;
		}
	}

	/// @inheritdoc IPolicy
	function validate(PolicyHook, bytes calldata validationData) external view {
		(,,, address[] memory incomingAssets,) =
			abi.decode(validationData, (address, address[], uint256[], address[], uint256[]));
		for (uint256 i; i < incomingAssets.length; ++i) {
			if (isDisallowedAsset[incomingAssets[i]]) revert IncomingAssetDisallowed(incomingAssets[i]);
		}
	}

	/// @inheritdoc IPolicy
	function implementedHooks() external pure returns (PolicyHook[] memory hooks) {
		hooks = new PolicyHook[](1);
		hooks[0] = PolicyHook.PostCallOnIntegration;
	}
}
