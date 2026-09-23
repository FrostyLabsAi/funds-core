// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice Aerodrome Slipstream SwapRouter (exactInputSingle only).
/// @dev Verified against aerodrome-finance/slipstream periphery ISwapRouter: identical to
///      Uniswap v3 except pools are keyed by `int24 tickSpacing` instead of `uint24 fee`.
interface ISlipstreamSwapRouter {
	struct ExactInputSingleParams {
		address tokenIn;
		address tokenOut;
		int24 tickSpacing;
		address recipient;
		uint256 deadline;
		uint256 amountIn;
		uint256 amountOutMinimum;
		uint160 sqrtPriceLimitX96;
	}

	function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
