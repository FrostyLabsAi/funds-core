// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title IDerivativePriceFeed
/// @notice Prices a derivative asset (vault share, LP token, receipt token) by resolving it
///         into underlying-asset amounts, which the ValueInterpreter then prices via its
///         primitive feeds. Pattern per Enzyme v4's derivative feeds
///         (spec/architecture/release.md#valueinterpreter).
/// @dev Underlyings MUST resolve to primitives — the ValueInterpreter rejects
///      derivative-of-derivative chains to make pricing cycles impossible.
interface IDerivativePriceFeed {
	/// @notice Resolve `amount` of `derivative` into underlying assets and amounts.
	function calcUnderlyingValues(address derivative, uint256 amount)
		external
		view
		returns (address[] memory underlyings, uint256[] memory underlyingAmounts);

	/// @notice True if this feed knows how to resolve the asset.
	function isSupportedAsset(address asset) external view returns (bool);
}
