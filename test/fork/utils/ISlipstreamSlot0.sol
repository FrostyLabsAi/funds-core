// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice Slipstream's slot0 (its shape differs from Uniswap v3's after the fourth field).
interface ISlipstreamSlot0 {
	function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, bool);
}
