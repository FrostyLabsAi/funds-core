// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

/// @title LiquidityAmounts
/// @notice Read-side subset of Uniswap's periphery LiquidityAmounts: splits `liquidity` over
///         a tick range into its underlying token amounts at a given sqrt price.
/// @dev Canonical formulas, on OZ Math.mulDiv (512-bit intermediates). Rounds down — the
///      conservative direction for valuation.
library LiquidityAmounts {
	uint256 private constant Q96 = 0x1000000000000000000000000;

	/// @notice amount0 for `liquidity` between sqrtRatioA and sqrtRatioB (A < B).
	function getAmount0ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
		internal
		pure
		returns (uint256 amount0)
	{
		if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
		return
			Math.mulDiv(uint256(liquidity) << 96, sqrtRatioBX96 - sqrtRatioAX96, sqrtRatioBX96) / sqrtRatioAX96;
	}

	/// @notice amount1 for `liquidity` between sqrtRatioA and sqrtRatioB (A < B).
	function getAmount1ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
		internal
		pure
		returns (uint256 amount1)
	{
		if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
		return Math.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, Q96);
	}

	/// @notice Token amounts for `liquidity` over [sqrtRatioA, sqrtRatioB] at `sqrtRatioX96`.
	function getAmountsForLiquidity(
		uint160 sqrtRatioX96,
		uint160 sqrtRatioAX96,
		uint160 sqrtRatioBX96,
		uint128 liquidity
	) internal pure returns (uint256 amount0, uint256 amount1) {
		if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

		if (sqrtRatioX96 <= sqrtRatioAX96) {
			amount0 = getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
		} else if (sqrtRatioX96 < sqrtRatioBX96) {
			amount0 = getAmount0ForLiquidity(sqrtRatioX96, sqrtRatioBX96, liquidity);
			amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioX96, liquidity);
		} else {
			amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
		}
	}
}
