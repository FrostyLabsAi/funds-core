// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice The canonical pool lookup of Uniswap v3's factory (fee tier in pips).
/// @dev Moved here from TwapListingRegistry.sol (2026-10-04, TWAP cleanup) so CompounderFactory no longer
///      imports the retired TWAP registry; same declaration, so its bytecode is unchanged.
interface IUniswapV3PoolFactory {
	function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// @notice The canonical pool lookup of an Aerodrome Slipstream factory (keyed by tick spacing).
interface ISlipstreamPoolFactory {
	function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
}
