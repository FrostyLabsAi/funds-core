// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title IPolicy
/// @notice Pass/fail validation plugin invoked on policy hooks during fund actions.
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
