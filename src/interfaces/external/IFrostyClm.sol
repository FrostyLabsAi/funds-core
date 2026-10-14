// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice The FrostyFi CLM vault (funds-yield FrostyClmVault: Beefy's BeefyVaultConcLiq, solc 0.8.23) as funds-core
///         uses it. funds-yield can't be imported here: its compiler setup is pinned to Beefy's (2026-10-11).
interface IFrostyClmVault {
	function strategy() external view returns (address);
	function wants() external view returns (address token0, address token1);
	function totalSupply() external view returns (uint256);
	function balanceOf(address account) external view returns (uint256);
	function deposit(uint256 amount0, uint256 amount1, uint256 minShares) external;
	function withdraw(uint256 shares, uint256 minAmount0, uint256 minAmount1) external;
}

/// @notice The FrostyFi CLM strategy (funds-yield FrostyClmStrategy) as funds-core reads it.
interface IFrostyClmStrategy {
	function vault() external view returns (address);
	function factory() external view returns (address);
	function pool() external view returns (address);
	function nftManager() external view returns (address);
	function lpToken0() external view returns (address);
	function lpToken1() external view returns (address);
	function compoundToken() external view returns (address);
	function positionMain() external view returns (uint256 nftId, int24 tickLower, int24 tickUpper);
	function positionAlt() external view returns (uint256 nftId, int24 tickLower, int24 tickUpper);
	/// @dev Token balances held by the strategy (not spot-derived).
	function balancesOfThis() external view returns (uint256 token0Bal, uint256 token1Bal);
	function totalLocked0() external view returns (uint256);
	function totalLocked1() external view returns (uint256);
	function lastHarvest() external view returns (uint256);
}
