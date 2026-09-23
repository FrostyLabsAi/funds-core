// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IPolicy} from '../interfaces/IPolicy.sol';

/// @title UnrestrictedMandatePolicy
/// @notice The explicit "this fund may hold anything the protocol supports" declaration.
///         Every fund MUST carry an investment mandate on-chain (factory-enforced);
///         choosing no restriction is a choice a manager makes in public, not a default
///         they fall into. One instance serves the whole protocol (stateless no-op).
contract UnrestrictedMandatePolicy is IPolicy {
	/// @inheritdoc IPolicy
	function validate(PolicyHook, bytes calldata) external pure {}

	/// @inheritdoc IPolicy
	function implementedHooks() external pure returns (PolicyHook[] memory hooks) {
		hooks = new PolicyHook[](1);
		hooks[0] = PolicyHook.PostCallOnIntegration;
	}
}
