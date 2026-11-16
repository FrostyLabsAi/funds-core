// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice STFY's DividendVault (verified source, 0x4Ee3…4f98).
interface IDividendVault {
	function owner() external view returns (address);
	function setKeeper(address account, bool allowed) external;
	function startCycle() external;
	function distributeBatch(uint256 count) external;
	function nextDistribution() external view returns (uint256);
	function eligibleSupply() external view returns (uint256);
	function cycleActive() external view returns (bool);
	function unpaidTotal(address stock) external view returns (uint256);
}

/// @notice StockifyToken's on-chain registry of holders at or over `minShareBalance` (verified source).
interface IStockifyToken {
	function holderCount() external view returns (uint256);
	function holderAt(uint256 index) external view returns (address);
	function minShareBalance() external view returns (uint256);
}
