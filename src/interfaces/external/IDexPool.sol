// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice The pool views every supported venue shares (Uniswap v3, Slipstream, Aerodrome basic).
interface IDexPool {
	function factory() external view returns (address);
	function token0() external view returns (address);
	function token1() external view returns (address);
}
