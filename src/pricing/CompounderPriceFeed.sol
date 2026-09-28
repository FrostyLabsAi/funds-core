// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IDerivativePriceFeed} from '../interfaces/IDerivativePriceFeed.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {TickMath} from '../libraries/TickMath.sol';
import {LiquidityAmounts} from '../libraries/LiquidityAmounts.sol';
import {FrostyCompounder} from '../yield/FrostyCompounder.sol';

/// @title CompounderPriceFeed
/// @notice Derivative feed for FrostyCompounder shares: a share amount resolves to its pro-rata
///         slice of the position (liquidity split at the oracle-fair price) plus uncompounded fees.
///         One instance serves every compounder.
/// @dev The pool's spot price is never read, so a manipulated pool cannot move GAV. Pending fees
///      are counted gross; the compounder's perf fee is taken at compound().
contract CompounderPriceFeed is IDerivativePriceFeed {
	uint256 private constant Q96 = 0x1000000000000000000000000;

	IValueInterpreter public immutable valueInterpreter;

	error ZeroAddress();

	constructor(IValueInterpreter valueInterpreter_) {
		if (address(valueInterpreter_) == address(0)) revert ZeroAddress();
		valueInterpreter = valueInterpreter_;
	}

	/// @inheritdoc IDerivativePriceFeed
	function calcUnderlyingValues(address derivative, uint256 amount)
		external
		view
		returns (address[] memory underlyings, uint256[] memory underlyingAmounts)
	{
		FrostyCompounder compounder = FrostyCompounder(derivative);
		address token0 = address(compounder.token0());
		address token1 = address(compounder.token1());

		underlyings = new address[](2);
		underlyings[0] = token0;
		underlyings[1] = token1;
		underlyingAmounts = new uint256[](2);

		uint256 supply = compounder.totalSupply();
		if (supply == 0 || amount == 0) return (underlyings, underlyingAmounts);

		(uint128 liquidity, uint128 pending0, uint128 pending1) = compounder.positionState();
		uint128 proRataLiquidity = uint128((uint256(liquidity) * amount) / supply);

		if (proRataLiquidity != 0) {
			(uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
				_fairSqrtPriceX96(
					valueInterpreter.calcUsdRate(token0),
					valueInterpreter.calcUsdRate(token1),
					10 ** IERC20Metadata(token0).decimals(),
					10 ** IERC20Metadata(token1).decimals()
				),
				TickMath.getSqrtRatioAtTick(compounder.tickLower()),
				TickMath.getSqrtRatioAtTick(compounder.tickUpper()),
				proRataLiquidity
			);
			underlyingAmounts[0] = amount0;
			underlyingAmounts[1] = amount1;
		}

		// Uncompounded fees belong to holders pro-rata until the next compound()
		underlyingAmounts[0] += (uint256(pending0) * amount) / supply;
		underlyingAmounts[1] += (uint256(pending1) * amount) / supply;
	}

	/// @inheritdoc IDerivativePriceFeed
	function isSupportedAsset(address asset) external view returns (bool) {
		(bool ok, bytes memory ret) = asset.staticcall(abi.encodeCall(FrostyCompounder.positionState, ()));
		return ok && ret.length == 96;
	}

	/// @dev Oracle USD rates → the sqrtPrice the pool should have (same math as UniswapV3LPPosition).
	function _fairSqrtPriceX96(uint256 rate0, uint256 rate1, uint256 scale0, uint256 scale1)
		private
		pure
		returns (uint160)
	{
		uint256 ratioX96 = Math.mulDiv(Math.mulDiv(rate0, Q96, rate1), scale1, scale0);

		uint256 sqrtRatio =
			ratioX96 <= type(uint256).max >> 64 ? Math.sqrt(ratioX96 << 64) << 16 : Math.sqrt(ratioX96) << 48;

		if (sqrtRatio < TickMath.MIN_SQRT_RATIO) return TickMath.MIN_SQRT_RATIO;
		if (sqrtRatio > TickMath.MAX_SQRT_RATIO) return TickMath.MAX_SQRT_RATIO;
		return uint160(sqrtRatio);
	}
}
