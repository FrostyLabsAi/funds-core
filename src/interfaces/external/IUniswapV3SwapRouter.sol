// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice Uniswap SwapRouter02 (exactInputSingle only), the router deployed on Base. Its params
///         have no deadline field, unlike the original SwapRouter (incompatible selectors).
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
