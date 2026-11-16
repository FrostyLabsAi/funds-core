// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title ILiveRegistrar
/// @notice The views ReleaseListings reads off today's pool-price registrar (the head of the windowed chain,
///         0x1f77…C466, deployments/base-mainnet-windowed-pricing.json `registrar`) to copy its setup onto the release.
interface ILiveRegistrar {
	function poolPricedAdapter(address asset) external view returns (address);
	function isQuote(address token) external view returns (bool);
	function isPoolApproved(bytes32 poolId) external view returns (bool);
	function hookOf(address hook) external view returns (bool approved, bytes memory hookData);
	function v4KeyOf(address asset)
		external
		view
		returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks);
}
