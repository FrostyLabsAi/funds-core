// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title IValueInterpreter
/// @notice Single aggregation point for asset pricing: primitives (Chainlink/Pyth-style feeds)
///         and derivatives (custom feeds quoted in underlyings).
/// @dev Pattern per Enzyme v4 ValueInterpreter (spec/architecture/release.md#valueinterpreter).
///      HARD RULES from post-mortems (see living doc):
///      - NEVER price from pool spot state / currentTick (Gamma exploit, Jan 2024).
///      - NEVER assume tokenized-stock wrappers are 1:1 with their underlying equity
///        (wrapper gets its own feed; depeg is a real state).
///      - Equity feeds must carry market-hours staleness logic (weekend prices are stale by design).
interface IValueInterpreter {
	/// @notice Value `amount` of `baseAsset` in terms of `quoteAsset`.
	function calcCanonicalAssetValue(address baseAsset, uint256 amount, address quoteAsset)
		external
		returns (uint256 value);

	/// @notice True if the asset has a registered, currently-valid price source.
	function isSupportedAsset(address asset) external view returns (bool);

	/// @notice The asset's validated USD rate, 1e18-scaled. Reverts on unregistered,
	///         non-positive, or stale feeds (same validation as calcCanonicalAssetValue).
	function calcUsdRate(address asset) external view returns (uint256 rate);

	/// @notice True for side-pocket assets: holdable but valued at ZERO until realized
	///         (sold into a priced asset). Only funds created with allowRiskyAssets may
	///         acquire them.
	function isZeroPricedAsset(address asset) external view returns (bool);
}
