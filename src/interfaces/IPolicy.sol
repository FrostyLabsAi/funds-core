// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title IPolicy
/// @notice Pass/fail validation plugin invoked on policy hooks during fund actions.
/// @dev Successor to melon-v1 IPolicy (melon-v1/src/fund/policies/IPolicy.sol) using
///      Enzyme v4's hook taxonomy (spec/architecture/release.md#policymanager).
///      Mandatory marketplace defaults (see living doc): allowed-adapters list,
///      cumulative slippage tolerance, dust-only untracking, no-depeg redemptions.
interface IPolicy {
	enum PolicyHook {
		PostDepositRequest,
		PostBuyShares,
		PreTransferShares,
		RedeemSharesForSpecificAssets,
		PostCallOnIntegration,
		CreateExternalPosition,
		PostCallOnExternalPosition,
		RemoveExternalPosition
	}

	/// @notice Validate an action; MUST revert if the rule is violated. Policies never mutate fund state.
	function validate(PolicyHook hook, bytes calldata validationData) external;

	/// @notice Which hooks this policy implements.
	function implementedHooks() external view returns (PolicyHook[] memory);
}
