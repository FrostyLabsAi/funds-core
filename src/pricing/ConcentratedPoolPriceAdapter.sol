// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {PoolPriceAdapterBase} from './PoolPriceAdapterBase.sol';
import {TickMath} from '../libraries/TickMath.sol';

/// @notice The Uniswap v3 / Slipstream pool views the adapter reads (same shapes on both; slot0
///         differs after its fourth field, so it is read raw).
interface IConcentratedPool {
	function observe(uint32[] calldata secondsAgos)
		external
		view
		returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

	function observations(uint256 index)
		external
		view
		returns (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized);
}

/// @title ConcentratedPoolPriceAdapter
/// @notice Prices one asset from its Uniswap v3 or Slipstream pool: the pool's time-weighted
///         average price over the last 30 minutes (or over all the history the pool has, if less),
///         times the ValueInterpreter's USD price of the pool's other token. One minimal clone per
///         asset (PoolPriceRegistrar); its Config is the clone's immutable args.
/// @dev Liquidity is the lower of (a) the quote token the pool holds now and (b) what the window's
///      harmonic-mean in-range liquidity holds as a full-range reserve. Liquidity added in this
///      transaction is not in (b); liquidity removed during the window — collected or not — pulls
///      (b) down at once, since the harmonic mean follows its lowest stretch.
contract ConcentratedPoolPriceAdapter is PoolPriceAdapterBase {
	uint256 private constant Q96 = 1 << 96;

	error PoolReadFailed();

	function _read(Config memory c, uint256 quoteUsd18) internal view override returns (uint256, uint256) {
		(int24 meanTick, uint128 meanLiquidity) = _consult(c.pool);
		uint256 sqrtP = TickMath.getSqrtRatioAtTick(meanTick);
		uint256 held = IERC20(c.quoteAsset).balanceOf(c.pool);
		// a full-range reserve of liquidity L at √P: token1 = L·√P, token0 = L/√P
		uint256 windowed = c.assetIsToken0 ? Math.mulDiv(meanLiquidity, sqrtP, Q96) : Math.mulDiv(meanLiquidity, Q96, sqrtP);
		uint256 liquidity = Math.mulDiv(Math.min(held, windowed), quoteUsd18, 10 ** c.quoteDecimals);
		return (liquidity, _usdPerAssetAtTick(c, sqrtP, quoteUsd18));
	}

	/// @dev Arithmetic-mean tick (rounded toward −∞) and harmonic-mean liquidity over the span,
	///      with Uniswap OracleLibrary.consult's semantics.
	function _consult(address pool) internal view returns (int24 meanTick, uint128 meanLiquidity) {
		uint32 span = _span(pool);
		uint32[] memory secondsAgos = new uint32[](2);
		secondsAgos[0] = span;
		(int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidity) = IConcentratedPool(pool).observe(secondsAgos);

		int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
		int56 spanSigned = int56(uint56(span));
		meanTick = int24(tickDelta / spanSigned);
		if (tickDelta < 0 && tickDelta % spanSigned != 0) meanTick--;

		uint160 splDelta = secondsPerLiquidity[1] - secondsPerLiquidity[0];
		meanLiquidity = uint128((uint256(span) * type(uint160).max) / (uint256(splDelta) << 32));
	}

	/// @dev min(WINDOW, age of the pool's oldest observation), found the way Uniswap's oracle does:
	///      the slot after the newest, or slot 0 while that slot is reserved but unwritten.
	function _span(address pool) internal view returns (uint32) {
		(bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature('slot0()'));
		if (!ok || data.length < 128) revert PoolReadFailed();
		(,, uint16 index, uint16 cardinality) = abi.decode(data, (uint160, int24, uint16, uint16));

		(uint32 oldest,,, bool initialized) = IConcentratedPool(pool).observations((uint256(index) + 1) % cardinality);
		if (!initialized) (oldest,,,) = IConcentratedPool(pool).observations(0);

		uint256 age = block.timestamp - oldest;
		if (age == 0) revert NoPriceHistory();
		return age < WINDOW ? uint32(age) : WINDOW;
	}

	/// @dev USD (18 decimals) per whole asset at sqrt price `sqrtP`, rounded down once:
	///      asset = token0: sqrtP² / 2^192 × 10^ad × quoteUsd18 / 10^qd;
	///      asset = token1: 2^192 / sqrtP² × 10^ad × quoteUsd18 / 10^qd.
	///      Ported unchanged from TwapAggregatorAdapterV2 (bounds analysis there): no overflow for
	///      decimals ≤ 38 (the registrar refuses more) and any quote price below $1e21.
	function _usdPerAssetAtTick(Config memory c, uint256 sqrtP, uint256 quoteUsd18) internal pure returns (uint256) {
		uint256 scale = 10 ** c.assetDecimals * quoteUsd18;
		uint256 quoteUnit = 10 ** c.quoteDecimals;
		if (sqrtP <= type(uint128).max) {
			uint256 ratioX192 = sqrtP * sqrtP;
			return c.assetIsToken0
				? Math.mulDiv(ratioX192, scale, 1 << 192) / quoteUnit
				: Math.mulDiv(1 << 192, scale, ratioX192) / quoteUnit;
		}
		if (c.assetIsToken0) return Math.mulDiv(Math.mulDiv(sqrtP, sqrtP, 1 << 64), scale, 1 << 128) / quoteUnit;
		return Math.mulDiv(1 << 192, scale, sqrtP * quoteUnit) / sqrtP;
	}
}
