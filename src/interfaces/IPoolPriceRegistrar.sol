// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title IPoolPriceRegistrar
/// @notice What funds, policies and adapters ask the pool-price registrar: whether a token is priced from its own pool,
///         the liquidity a pool needs, and which Uniswap v4 pools and hooks are approved.
interface IPoolPriceRegistrar {
	/// @notice Whole USD of pool liquidity a pool-priced token needs before a fund may buy it.
	function MIN_LIQUIDITY_USD() external view returns (uint256);

	/// @notice The token's pool-price adapter, or zero when its price comes from a feed (or it has none).
	function poolPricedAdapter(address asset) external view returns (address);

	/// @notice Whether a Uniswap v4 pool (by pool id) is one funds may swap in.
	function isPoolApproved(bytes32 poolId) external view returns (bool);

	/// @notice Whether a Uniswap v4 hook is allowed: none, or one the owner approved.
	function isHookAllowed(address hook) external view returns (bool);

	/// @notice A hook's approval and the bytes swaps through it pass.
	function hookOf(address hook) external view returns (bool approved, bytes memory hookData);

	/// @notice The fixed tax, in bps of what is sold, a swap through v4 pool `poolId` pays (its hook's); the keeper's
	///         liquidation cap allows it on top for a sale through that pool.
	function poolSaleTaxBps(bytes32 poolId) external view returns (uint16);
}
