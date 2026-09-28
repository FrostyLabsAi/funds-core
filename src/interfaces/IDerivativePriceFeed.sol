// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title IDerivativePriceFeed
/// @notice Prices a derivative (vault share, LP token) by resolving it into underlying amounts,
///         which the ValueInterpreter prices via its primitive feeds.
/// @dev Underlyings must be primitives: derivative-of-derivative chains are rejected (no pricing cycles).
interface IDerivativePriceFeed {
	/// @notice Resolve `amount` of `derivative` into underlying assets and amounts.
	function calcUnderlyingValues(address derivative, uint256 amount)
		external
		view
		returns (address[] memory underlyings, uint256[] memory underlyingAmounts);

	/// @notice True if this feed knows how to resolve the asset.
	function isSupportedAsset(address asset) external view returns (bool);
}
