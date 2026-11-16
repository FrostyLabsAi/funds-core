// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IPolicy} from '../interfaces/IPolicy.sol';
import {IComptroller} from '../interfaces/IComptroller.sol';

/// @title MaxConcentrationPolicy
/// @notice After any adapter trade, no single non-denomination asset may exceed a fixed share of GAV.
/// @dev Immutable bound — deploy a new instance to change it. msg.sender is the fund's Comptroller.
contract MaxConcentrationPolicy is IPolicy {
	uint256 public constant BPS = 10_000;

	uint256 public immutable maxConcentrationBps;

	error MaxConcentrationExceeded(address asset, uint256 concentrationBps);
	error InvalidConcentration();

	constructor(uint256 maxConcentrationBps_) {
		if (maxConcentrationBps_ == 0 || maxConcentrationBps_ > BPS) revert InvalidConcentration();
		maxConcentrationBps = maxConcentrationBps_;
	}

	/// @inheritdoc IPolicy
	function validate(PolicyHook, bytes calldata validationData) external {
		(,,, address[] memory incomingAssets,) =
			abi.decode(validationData, (address, address[], uint256[], address[], uint256[]));

		IComptroller comptroller = IComptroller(msg.sender);
		address denominationAsset = address(comptroller.denominationAsset());
		uint256 gav = comptroller.calcGav();
		if (gav == 0) return;

		address vault = address(comptroller.vault());
		for (uint256 i; i < incomingAssets.length; ++i) {
			address asset = incomingAssets[i];
			if (asset == denominationAsset) continue;

			uint256 assetValue = comptroller.valueInterpreter().calcCanonicalAssetValue(
				asset, IERC20(asset).balanceOf(vault), denominationAsset
			);
			uint256 concentrationBps = Math.mulDiv(assetValue, BPS, gav);
			if (concentrationBps > maxConcentrationBps) revert MaxConcentrationExceeded(asset, concentrationBps);
		}
	}

	/// @inheritdoc IPolicy
	function implementedHooks() external pure returns (PolicyHook[] memory hooks) {
		hooks = new PolicyHook[](1);
		hooks[0] = PolicyHook.PostCallOnIntegration;
	}
}
