// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IPolicy} from '../interfaces/IPolicy.sol';

/// @title MinMaxDepositPolicy
/// @notice Bounds the size of a single deposit. maxDeposit = 0 disables new deposits entirely
///         (a fund-closing switch), per v4 MinMaxInvestmentPolicy (spec/topics/policies.md).
/// @dev Immutable bounds — deploy a new instance to change them.
contract MinMaxDepositPolicy is IPolicy {
	uint256 public immutable minDeposit;
	uint256 public immutable maxDeposit;

	error DepositOutOfBounds(uint256 assets);

	constructor(uint256 minDeposit_, uint256 maxDeposit_) {
		minDeposit = minDeposit_;
		maxDeposit = maxDeposit_;
	}

	/// @inheritdoc IPolicy
	function validate(PolicyHook, bytes calldata validationData) external view {
		// PostDepositRequest: (depositor, assets) — assets is the second word.
		(, uint256 assets) = abi.decode(validationData, (address, uint256));
		if (assets < minDeposit || maxDeposit == 0 || assets > maxDeposit) revert DepositOutOfBounds(assets);
	}

	/// @inheritdoc IPolicy
	function implementedHooks() external pure returns (PolicyHook[] memory hooks) {
		hooks = new PolicyHook[](1);
		hooks[0] = PolicyHook.PostDepositRequest;
	}
}
