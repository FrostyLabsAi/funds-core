// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice Aerodrome Slipstream SwapRouter: single-pool and multi-hop exact-in.
/// @dev Verified against aerodrome-finance/slipstream periphery ISwapRouter: identical to
///      Uniswap v3 except pools are keyed by `int24 tickSpacing` instead of `uint24 fee`.
///      Multi-hop path: token (20 bytes) | tickSpacing int24 (3 bytes) | token | … (verified source of
///      0x698C…A92F, SwapRouter.sol, 2026-10-13).
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

	struct ExactInputParams {
		bytes path;
		address recipient;
		uint256 deadline;
		uint256 amountIn;
		uint256 amountOutMinimum;
	}

	function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

	function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}
