// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice Uniswap v2 Router02 (fee-on-transfer-supporting exactIn swap only).
/// @dev Verified against the Basescan source of 0x4752…aD24 (factory 0x8909…8eC6): pulls `amountIn`
///      from the caller into the first pair, swaps what the pair actually received, and requires the
///      recipient's balance of the last token to rise by ≥ `amountOutMin`. Returns nothing.
interface IUniswapV2Router02 {
	function swapExactTokensForTokensSupportingFeeOnTransferTokens(
		uint256 amountIn,
		uint256 amountOutMin,
		address[] calldata path,
		address to,
		uint256 deadline
	) external;
}
