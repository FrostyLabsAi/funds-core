// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IPolicy} from '../interfaces/IPolicy.sol';
import {IComptroller} from '../interfaces/IComptroller.sol';

/// @title MaxPositionsPolicy
/// @notice After any adapter trade, the fund may hold at most N distinct non-denomination assets.
/// @dev Immutable bound — deploy a new instance to change it. Each external position counts as one.
contract MaxPositionsPolicy is IPolicy {
	uint256 public immutable maxPositions;

	error MaxPositionsExceeded(uint256 positions, uint256 maxAllowed);
	error InvalidMaxPositions();

	constructor(uint256 maxPositions_) {
		if (maxPositions_ == 0) revert InvalidMaxPositions();
		maxPositions = maxPositions_;
	}

	/// @inheritdoc IPolicy
	function validate(PolicyHook, bytes calldata) external view {
		IComptroller comptroller = IComptroller(msg.sender);
		address denominationAsset = address(comptroller.denominationAsset());

		(address[] memory assets, uint256[] memory balances) = comptroller.getFundHoldings();
		uint256 positions = comptroller.getExternalPositions().length;
		for (uint256 i; i < assets.length; ++i) {
			if (assets[i] != denominationAsset && balances[i] > 0) ++positions;
		}
		if (positions > maxPositions) revert MaxPositionsExceeded(positions, maxPositions);
	}

	/// @inheritdoc IPolicy
	function implementedHooks() external pure returns (PolicyHook[] memory hooks) {
		hooks = new PolicyHook[](2);
		hooks[0] = PolicyHook.PostCallOnIntegration;
		hooks[1] = PolicyHook.CreateExternalPosition;
	}
}
