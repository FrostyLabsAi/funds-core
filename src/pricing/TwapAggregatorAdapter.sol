// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {AggregatorV3Interface} from '../interfaces/AggregatorV3Interface.sol';
import {TickMath} from '../libraries/TickMath.sol';
import {LiquidityAmounts} from '../libraries/LiquidityAmounts.sol';

/// @notice The oracle surface Uniswap v3 AND Aerodrome Slipstream pools share (both verified
///         live on Base 2026-09-24: `observe(uint32[])` and a slot0 whose first two words are
///         (sqrtPriceX96, tick) — the rest of slot0 differs, so it is read raw).
interface IConcentratedPoolOracle {
	function token0() external view returns (address);
	function token1() external view returns (address);
	function observe(uint32[] calldata secondsAgos)
		external
		view
		returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/// @title TwapAggregatorAdapter
/// @notice Prices ONE asset from its concentrated-liquidity pool's own oracle — the
///         time-weighted average over `window` — composed with a Chainlink feed for the pool's
///         other token, exposed as an AggregatorV3 feed so the ValueInterpreter prices it
///         through the ordinary `addPrimitive` path (like PythAggregatorAdapter).
///         The fourth price tier: Chainlink → Pyth/RedStone → TWAP → side pocket
///         (docs/design/twap-oracle.md).
/// @dev Guards that REVERT (a revert pauses NAV-dependent actions of funds holding the asset
///      until it clears; in-kind redemption never prices and stays open):
///      1. WINDOW ≥ 30 min — holding a pool off-price for the whole window costs the
///         attacker every arbitrage in it.
///      2. SPOT vs TWAP within `maxDeviationBps` — a pool pushed off-price, or a real move
///         the average has not caught up to, pauses pricing for minutes instead of dealing
///         at a stale mark; it clears as the average converges.
///      3. QUOTE LEG: Chainlink answer > 0 and within `quoteHeartbeat`.
///      4. OBSERVATIONS must cover the full window (young pool / low cardinality reverts).
///      The LIQUIDITY FLOOR does NOT revert (founder decision 2026-09-24): under the floor the
///      price stays the market price and `isBelowFloor()` reports it — the registry starts a
///      72-hour clock, the manager is warned, and after 72h the exposure policy pauses NEW
///      deposits until the fund exits. Safe to keep pricing because the exposure caps bound
///      how much of NAV a thin pool can move. Depth is measured on the window's HARMONIC-MEAN
///      in-range liquidity (a liquidity pull drags it down) as the USD held within ±10% of the
///      TWAP price — not full-range-equivalent liquidity, which reads 14–30× the real deposits
///      on concentrated pools (Base 2026-09-24).
///      Answers carry 18 decimals (the VI reads `decimals()`), so sub-cent tokens keep
///      precision; `updatedAt` is the read's own timestamp — the price IS computed now.
contract TwapAggregatorAdapter is AggregatorV3Interface {
	uint32 public constant MIN_WINDOW = 30 minutes;
	uint16 public constant MAX_DEVIATION_BPS = 2_000;
	uint256 private constant BPS = 10_000;
	uint8 private constant ANSWER_DECIMALS = 18;
	// Depth band around the TWAP price: 1.0001^953 = 1.1000, 1.0001^-1054 = 0.9000
	int24 private constant BAND_UP_TICKS = 953;
	int24 private constant BAND_DOWN_TICKS = 1054;

	IConcentratedPoolOracle public immutable pool;
	address public immutable asset;
	address public immutable quoteAsset;
	bool public immutable assetIsToken0;
	AggregatorV3Interface public immutable quoteFeed;
	uint32 public immutable window;
	/// @notice Floor on the window's ±10% depth, whole USD.
	uint256 public immutable minLiquidityUsd;
	uint16 public immutable maxDeviationBps;
	uint32 public immutable quoteHeartbeat;
	uint8 private immutable assetDecimals;
	uint8 private immutable quoteDecimals;
	uint8 private immutable quoteFeedDecimals;
	string public description;

	error ZeroArgument();
	error WindowTooShort(uint32 window);
	error BadDeviation(uint16 bps);
	error AssetNotInPool(address asset);
	error UnsupportedDecimals(uint8 decimals);
	error ObservationWindowUnavailable();
	error SpotDeviatesFromTwap(int24 spotTick, int24 meanTick);
	error QuoteNonPositive(int256 answer);
	error QuoteStale(uint256 updatedAt);
	error PriceRoundsToZero();

	constructor(
		IConcentratedPoolOracle pool_,
		address asset_,
		AggregatorV3Interface quoteFeed_,
		uint32 window_,
		uint256 minLiquidityUsd_,
		uint16 maxDeviationBps_,
		uint32 quoteHeartbeat_,
		string memory description_
	) {
		if (address(pool_) == address(0) || asset_ == address(0) || address(quoteFeed_) == address(0)) revert ZeroArgument();
		if (minLiquidityUsd_ == 0 || quoteHeartbeat_ == 0) revert ZeroArgument();
		if (window_ < MIN_WINDOW) revert WindowTooShort(window_);
		if (maxDeviationBps_ == 0 || maxDeviationBps_ > MAX_DEVIATION_BPS) revert BadDeviation(maxDeviationBps_);

		address token0 = pool_.token0();
		address token1 = pool_.token1();
		if (asset_ != token0 && asset_ != token1) revert AssetNotInPool(asset_);
		assetIsToken0 = asset_ == token0;
		quoteAsset = assetIsToken0 ? token1 : token0;

		assetDecimals = IERC20Metadata(asset_).decimals();
		quoteDecimals = IERC20Metadata(quoteAsset).decimals();
		quoteFeedDecimals = quoteFeed_.decimals();
		// 10**decimals must fit the uint128 base amount; feeds are scaled UP to 18
		if (assetDecimals > 38) revert UnsupportedDecimals(assetDecimals);
		if (quoteDecimals > 38) revert UnsupportedDecimals(quoteDecimals);
		if (quoteFeedDecimals > ANSWER_DECIMALS) revert UnsupportedDecimals(quoteFeedDecimals);

		pool = pool_;
		asset = asset_;
		quoteFeed = quoteFeed_;
		window = window_;
		minLiquidityUsd = minLiquidityUsd_;
		maxDeviationBps = maxDeviationBps_;
		quoteHeartbeat = quoteHeartbeat_;
		description = description_;
	}

	/// @inheritdoc AggregatorV3Interface
	function decimals() external pure returns (uint8) {
		return ANSWER_DECIMALS;
	}

	/// @notice USD per whole `asset`, 18 decimals — the reverting guards enforced (the
	///         liquidity floor is reported by `isBelowFloor`, not enforced here).
	/// @inheritdoc AggregatorV3Interface
	function latestRoundData()
		external
		view
		returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
	{
		(int24 meanTick, uint128 meanLiquidity) = _consult();
		int24 spotTick = _spotTick();
		if (!_withinDeviation(spotTick, meanTick)) revert SpotDeviatesFromTwap(spotTick, meanTick);

		uint256 quoteUsd18 = _quoteUsd18();
		uint256 quotePerAsset = _convertAtTick(meanTick, uint128(10 ** assetDecimals), assetIsToken0);
		uint256 price = Math.mulDiv(quotePerAsset, quoteUsd18, 10 ** quoteDecimals);
		if (price == 0) revert PriceRoundsToZero();

		answer = int256(price);
		roundId = uint80(block.timestamp);
		answeredInRound = roundId;
		startedAt = block.timestamp;
		updatedAt = block.timestamp;
	}

	/// @notice The window's ±10% depth in USD (18 decimals), guards NOT applied — the
	///         liquidity figure exposure caps are measured against. Reverts only if the
	///         pool cannot serve the window or the quote feed is unusable.
	function poolDepthUsd() external view returns (uint256) {
		(int24 meanTick, uint128 meanLiquidity) = _consult();
		return _depthUsd18(meanTick, meanLiquidity, _quoteUsd18());
	}

	/// @notice True while the window's ±10% harmonic-mean depth is under `minLiquidityUsd`.
	function isBelowFloor() external view returns (bool) {
		(int24 meanTick, uint128 meanLiquidity) = _consult();
		return _depthUsd18(meanTick, meanLiquidity, _quoteUsd18()) < minLiquidityUsd * 1e18;
	}

	/// @notice Arithmetic-mean tick and harmonic-mean liquidity over `window`
	///         (Uniswap OracleLibrary.consult semantics, rounding the tick toward −∞).
	function consult() external view returns (int24 meanTick, uint128 harmonicMeanLiquidity) {
		return _consult();
	}

	function _consult() internal view returns (int24 meanTick, uint128 meanLiquidity) {
		uint32[] memory secondsAgos = new uint32[](2);
		secondsAgos[0] = window;
		try pool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidity) {
			int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
			int56 span = int56(uint56(window));
			meanTick = int24(tickDelta / span);
			if (tickDelta < 0 && tickDelta % span != 0) meanTick--;

			uint160 splDelta = secondsPerLiquidity[1] - secondsPerLiquidity[0];
			if (splDelta == 0) revert ObservationWindowUnavailable();
			meanLiquidity = uint128((uint256(window) * type(uint160).max) / (uint256(splDelta) << 32));
		} catch {
			revert ObservationWindowUnavailable();
		}
	}

	function _spotTick() internal view returns (int24 tick) {
		(bool ok, bytes memory data) = address(pool).staticcall(abi.encodeWithSignature('slot0()'));
		if (!ok || data.length < 64) revert ObservationWindowUnavailable();
		(, tick) = abi.decode(data, (uint160, int24));
	}

	/// @dev (price ratio)² = (sqrtHi / sqrtLo)² ≤ 1 + maxDeviation, in either direction.
	function _withinDeviation(int24 spotTick, int24 meanTick) internal view returns (bool) {
		uint256 a = TickMath.getSqrtRatioAtTick(spotTick);
		uint256 b = TickMath.getSqrtRatioAtTick(meanTick);
		(uint256 hi, uint256 lo) = a > b ? (a, b) : (b, a);
		return Math.mulDiv(hi, hi, lo) <= Math.mulDiv(lo, BPS + maxDeviationBps, BPS);
	}

	function _quoteUsd18() internal view returns (uint256) {
		(, int256 answer,, uint256 updatedAt,) = quoteFeed.latestRoundData();
		if (answer <= 0) revert QuoteNonPositive(answer);
		if (block.timestamp > updatedAt + quoteHeartbeat) revert QuoteStale(updatedAt);
		return uint256(answer) * 10 ** (ANSWER_DECIMALS - quoteFeedDecimals);
	}

	/// @dev USD of the tokens `liquidity` holds between −10% and +10% of the mean price,
	///      the asset side converted to quote at the mean tick.
	function _depthUsd18(int24 meanTick, uint128 liquidity, uint256 quoteUsd18) internal view returns (uint256) {
		int24 lowerTick = meanTick - BAND_DOWN_TICKS < TickMath.MIN_TICK ? TickMath.MIN_TICK : meanTick - BAND_DOWN_TICKS;
		int24 upperTick = meanTick + BAND_UP_TICKS > TickMath.MAX_TICK ? TickMath.MAX_TICK : meanTick + BAND_UP_TICKS;
		(uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
			TickMath.getSqrtRatioAtTick(meanTick),
			TickMath.getSqrtRatioAtTick(lowerTick),
			TickMath.getSqrtRatioAtTick(upperTick),
			liquidity
		);
		(uint256 assetAmount, uint256 quoteAmount) = assetIsToken0 ? (amount0, amount1) : (amount1, amount0);
		if (assetAmount > type(uint128).max) assetAmount = type(uint128).max; // conservative clamp
		uint256 quoteTotal = quoteAmount + _convertAtTick(meanTick, uint128(assetAmount), assetIsToken0);
		return Math.mulDiv(quoteTotal, quoteUsd18, 10 ** quoteDecimals);
	}

	/// @dev `baseAmount` of one pool token → the other token at `tick` (raw units).
	///      Uniswap OracleLibrary.getQuoteAtTick, on OZ mulDiv.
	function _convertAtTick(int24 tick, uint128 baseAmount, bool baseIsToken0) internal pure returns (uint256) {
		uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
		if (sqrtRatioX96 <= type(uint128).max) {
			uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
			return baseIsToken0 ? Math.mulDiv(ratioX192, baseAmount, 1 << 192) : Math.mulDiv(1 << 192, baseAmount, ratioX192);
		}
		uint256 ratioX128 = Math.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
		return baseIsToken0 ? Math.mulDiv(ratioX128, baseAmount, 1 << 128) : Math.mulDiv(1 << 128, baseAmount, ratioX128);
	}
}
