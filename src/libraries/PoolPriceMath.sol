// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

/// @title PoolPriceMath
/// @notice Concentrated-liquidity pool math shared by the v4 price feed and registrar (spec 2026-10-08 §4.2),
///         ported from ConcentratedPoolPriceAdapter (deployed code left untouched).
library PoolPriceMath {
	uint256 private constant Q96 = 1 << 96;

	/// @dev The quote reserve a full-range position of `liquidity` holds at `sqrtP`: token1 = L·√P, token0 = L/√P.
	function quoteReserve(uint128 liquidity, uint256 sqrtP, bool assetIsToken0) internal pure returns (uint256) {
		return assetIsToken0 ? Math.mulDiv(liquidity, sqrtP, Q96) : Math.mulDiv(liquidity, Q96, sqrtP);
	}

	/// @dev USD (18 decimals) per whole asset at sqrt price `sqrtP`, rounded down once — ConcentratedPoolPriceAdapter
	///      ._usdPerAssetAtTick unchanged (no overflow for decimals ≤ 38 and any quote price below $1e21).
	function usdPerAssetAtSqrtP(uint256 sqrtP, bool assetIsToken0, uint8 assetDecimals, uint8 quoteDecimals, uint256 quoteUsd18)
		internal
		pure
		returns (uint256)
	{
		uint256 scale = 10 ** assetDecimals * quoteUsd18;
		uint256 quoteUnit = 10 ** quoteDecimals;
		if (sqrtP <= type(uint128).max) {
			uint256 ratioX192 = sqrtP * sqrtP;
			return assetIsToken0
				? Math.mulDiv(ratioX192, scale, 1 << 192) / quoteUnit
				: Math.mulDiv(1 << 192, scale, ratioX192) / quoteUnit;
		}
		if (assetIsToken0) return Math.mulDiv(Math.mulDiv(sqrtP, sqrtP, 1 << 64), scale, 1 << 128) / quoteUnit;
		return Math.mulDiv(1 << 192, scale, sqrtP * quoteUnit) / sqrtP;
	}
}
