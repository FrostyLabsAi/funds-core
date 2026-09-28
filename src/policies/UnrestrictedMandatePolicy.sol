// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IPolicy} from '../interfaces/IPolicy.sol';

/// @title UnrestrictedMandatePolicy
/// @notice Explicit "may hold anything the protocol supports" mandate: every fund must carry one
///         on-chain, so no restriction is a public choice. Stateless no-op, shared protocol-wide.
contract UnrestrictedMandatePolicy is IPolicy {
	/// @inheritdoc IPolicy
	function validate(PolicyHook, bytes calldata) external pure {}

	/// @inheritdoc IPolicy
	function implementedHooks() external pure returns (PolicyHook[] memory hooks) {
		hooks = new PolicyHook[](1);
		hooks[0] = PolicyHook.PostCallOnIntegration;
	}
}
