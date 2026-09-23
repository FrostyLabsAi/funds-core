// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice Uniswap v3 periphery SwapRouter02 (exactInputSingle only). NOTE: unlike the
///         original SwapRouter, SwapRouter02 has NO deadline field in the params struct —
///         the two selectors are incompatible, and SwapRouter02 is what Uniswap deploys
///         on Base / Base Sepolia.
interface IUniswapV3SwapRouter {
	struct ExactInputSingleParams {
		address tokenIn;
		address tokenOut;
		uint24 fee;
		address recipient;
		uint256 amountIn;
		uint256 amountOutMinimum;
		uint160 sqrtPriceLimitX96;
	}

	function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
