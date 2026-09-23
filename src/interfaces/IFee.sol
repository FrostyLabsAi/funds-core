// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title IFee
/// @notice Fee plugin that settles in shares (mint to recipient / dilute holders).
/// @dev Successor to melon-v1 IFee (melon-v1/src/fund/fees/IFee.sol).
///      Performance fee uses Enzyme v4's continuous-accrual HWM formula
///      (spec/fee-formulas/performance-fee.md) — settle on every share-supply change,
///      no crystallization periods:
///        W = max(g - hwm, 0) * TS;  F = W * rate;  feeShares = F * TS / (GAV - F)
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
