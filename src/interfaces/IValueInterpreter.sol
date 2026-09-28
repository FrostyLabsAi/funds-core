// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title IValueInterpreter
/// @notice Single pricing point: primitives (oracle feeds) and derivatives (feeds quoted in underlyings).
/// @dev Never price from pool spot state; a tokenized stock gets its own feed (it can depeg).
interface IValueInterpreter {
	/// @notice Value `amount` of `baseAsset` in terms of `quoteAsset`.
	function calcCanonicalAssetValue(address baseAsset, uint256 amount, address quoteAsset)
		external
		returns (uint256 value);

	/// @notice True if the asset has a registered, currently-valid price source.
	function isSupportedAsset(address asset) external view returns (bool);

	/// @notice The asset's validated USD rate, 1e18-scaled; reverts on unregistered, non-positive or stale feeds.
	function calcUsdRate(address asset) external view returns (uint256 rate);

	/// @notice Side-pocket asset: holdable but valued at zero until sold; only allowRiskyAssets funds may hold it.
	function isZeroPricedAsset(address asset) external view returns (bool);
}
