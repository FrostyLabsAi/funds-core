// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title IFee
/// @notice Fee plugin that settles in shares (mint to recipient / dilute holders).
/// @dev Performance fee accrues continuously against the HWM (settled on every supply change):
///      W = max(g - hwm, 0) * TS;  F = W * rate;  feeShares = F * TS / (GAV - F)
interface IFee {
	enum FeeHook {
		PreBuyShares,
		PostBuyShares,
		PreRedeemShares,
		Continuous
	}

	/// @notice Settle the fee for the calling fund; returns shares to mint to the fee recipient.
	function settle(FeeHook hook, bytes calldata settlementData) external returns (uint256 sharesDue);

	function implementedHooks() external view returns (FeeHook[] memory);
}
