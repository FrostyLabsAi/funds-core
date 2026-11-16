// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice The canonical pool lookup of Uniswap v3's factory (fee tier in pips).
interface IUniswapV3PoolFactory {
	function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// @notice The canonical pool lookup of an Aerodrome Slipstream factory (keyed by tick spacing).
interface ISlipstreamPoolFactory {
	function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
}

/// @notice The canonical pool lookup of Aerodrome's basic (v2-style) pool factory.
interface IAerodromeBasicFactory {
	function getPool(address tokenA, address tokenB, bool stable) external view returns (address);
}
