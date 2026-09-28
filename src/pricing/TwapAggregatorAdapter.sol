// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {AggregatorV3Interface} from '../interfaces/AggregatorV3Interface.sol';
import {TickMath} from '../libraries/TickMath.sol';
import {LiquidityAmounts} from '../libraries/LiquidityAmounts.sol';

/// @notice The oracle surface Uniswap v3 and Aerodrome Slipstream pools share. slot0 differs
///         beyond (sqrtPriceX96, tick), so it is read raw.
interface IConcentratedPoolOracle {
	function token0() external view returns (address);
	function token1() external view returns (address);
	function observe(uint32[] calldata secondsAgos)
		external
		view
		returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
	function tickSpacing() external view returns (int24);
	function liquidity() external view returns (uint128);
	function tickBitmap(int16 wordPosition) external view returns (uint256);
}

/// @title TwapAggregatorAdapter
/// @notice Prices one asset from its concentrated-liquidity pool's time-weighted average over
///         `window`, times a Chainlink feed for the pool's other token, exposed as an
///         AggregatorV3 feed (18 decimals, so sub-cent tokens keep precision).
/// @dev Reverting guards (a revert pauses NAV-dependent actions of funds holding the asset;
///      in-kind redemption never prices):
///      1. window ≥ 30 min — holding a pool off-price that long costs every arbitrage in it;
///      2. spot within `maxDeviationBps` of the TWAP;
///      3. quote feed answer > 0 and within `quoteHeartbeat`;
///      4. observations cover the full window.
///      The liquidity floor does not revert: `isBelowFloor()` reports it, the registry runs a
///      72-hour clock, and the exposure caps bound what a thin pool can move. Depth = USD within
///      ±10% of the price, the lower of the window's harmonic-mean liquidity over the band and
///      what current liquidity actually holds in the band, so a tight range around spot cannot
///      pose as band-wide depth. `updatedAt` is the read's own timestamp.
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

	/// @notice USD per whole `asset` (18 decimals), reverting guards applied.
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

	/// @notice The ±10% depth in USD (18 decimals) that exposure caps are measured against;
	///         price guards not applied.
	function poolDepthUsd() external view returns (uint256) {
		return _depthUsd();
	}

	/// @notice True while the ±10% depth is under `minLiquidityUsd`.
	function isBelowFloor() external view returns (bool) {
		return _depthUsd() < minLiquidityUsd * 1e18;
	}

	/// @notice USD the pool's current liquidity holds within ±10% of spot, summed across
	///         initialized ticks.
	function spotBandDepthUsd() external view returns (uint256) {
		(int24 meanTick,) = _consult();
		return _spotBandDepthUsd18(meanTick, _quoteUsd18());
	}

	/// @dev min(window-weighted depth, current band depth)
	function _depthUsd() internal view returns (uint256) {
		(int24 meanTick, uint128 meanLiquidity) = _consult();
		uint256 quoteUsd18 = _quoteUsd18();
		uint256 weighted = _depthUsd18(meanTick, meanLiquidity, quoteUsd18);
		uint256 actual = _spotBandDepthUsd18(meanTick, quoteUsd18);
		return actual < weighted ? actual : weighted;
	}

	struct BandWalk {
		uint160 sqrtPrice;
		int24 spacing;
		int256 active;
		int24 prev;
		uint256 amount0;
		uint256 amount1;
	}

	/// @dev Walks the initialized ticks within ±10% of spot outward from the current price,
	///      summing each segment's token amounts at its active liquidity.
	function _spotBandDepthUsd18(int24 meanTick, uint256 quoteUsd18) internal view returns (uint256) {
		(bool ok, bytes memory data) = address(pool).staticcall(abi.encodeWithSignature('slot0()'));
		if (!ok || data.length < 64) revert ObservationWindowUnavailable();
		(uint160 sqrtPrice, int24 spotTick) = abi.decode(data, (uint160, int24));
		BandWalk memory w = BandWalk(sqrtPrice, pool.tickSpacing(), int256(uint256(pool.liquidity())), spotTick, 0, 0);
		int256 current = w.active;

		int24 upper = spotTick + BAND_UP_TICKS > TickMath.MAX_TICK ? TickMath.MAX_TICK : spotTick + BAND_UP_TICKS;
		_walkUp(w, spotTick, upper);
		w.active = current;
		w.prev = spotTick;
		int24 lower = spotTick - BAND_DOWN_TICKS < TickMath.MIN_TICK ? TickMath.MIN_TICK : spotTick - BAND_DOWN_TICKS;
		_walkDown(w, spotTick, lower);

		(uint256 assetAmount, uint256 quoteAmount) = assetIsToken0 ? (w.amount0, w.amount1) : (w.amount1, w.amount0);
		if (assetAmount > type(uint128).max) assetAmount = type(uint128).max; // conservative clamp
		uint256 quoteTotal = quoteAmount + _convertAtTick(meanTick, uint128(assetAmount), assetIsToken0);
		return Math.mulDiv(quoteTotal, quoteUsd18, 10 ** quoteDecimals);
	}

	/// @dev Upward from spot: segment [prev, t) at the active liquidity, then cross t (+net).
	function _walkUp(BandWalk memory w, int24 spotTick, int24 upper) internal view {
		int24 last = _compress(upper - 1, w.spacing);
		for (int24 c = _compress(spotTick, w.spacing) + 1; c <= last;) {
			int24 wordStart = (c >> 8) << 8;
			uint256 word = pool.tickBitmap(int16(c >> 8)) & (type(uint256).max << uint8(uint24(c - wordStart)));
			if (last - wordStart < 255) word &= type(uint256).max >> (255 - uint8(uint24(last - wordStart)));
			while (word != 0) {
				int24 t = (wordStart + int24(uint24(Math.log2(word & (~word + 1))))) * w.spacing;
				_addSegment(w, w.prev, t);
				w.active += _liquidityNet(t);
				w.prev = t;
				word &= word - 1;
			}
			c = wordStart + 256;
		}
		_addSegment(w, w.prev, upper);
	}

	/// @dev Downward from spot: segment [t, prev) at the active liquidity, then cross t (−net).
	function _walkDown(BandWalk memory w, int24 spotTick, int24 lower) internal view {
		int24 first = _compress(lower, w.spacing) + 1;
		for (int24 c = _compress(spotTick, w.spacing); c >= first;) {
			int24 wordStart = (c >> 8) << 8;
			uint256 word = pool.tickBitmap(int16(c >> 8)) & (type(uint256).max >> (255 - uint8(uint24(c - wordStart))));
			if (first > wordStart) word &= type(uint256).max << uint8(uint24(first - wordStart));
			while (word != 0) {
				uint256 bit = Math.log2(word);
				int24 t = (wordStart + int24(uint24(bit))) * w.spacing;
				_addSegment(w, t, w.prev);
				w.active -= _liquidityNet(t);
				w.prev = t;
				word &= ~(uint256(1) << bit);
			}
			c = wordStart - 1;
		}
		_addSegment(w, lower, w.prev);
	}

	/// @dev Add the token amounts the active liquidity holds on [lo, hi] at the current price.
	function _addSegment(BandWalk memory w, int24 lo, int24 hi) internal pure {
		if (w.active <= 0 || lo >= hi) return;
		uint128 l = w.active > int256(uint256(type(uint128).max)) ? type(uint128).max : uint128(uint256(w.active));
		(uint256 a0, uint256 a1) =
			LiquidityAmounts.getAmountsForLiquidity(w.sqrtPrice, TickMath.getSqrtRatioAtTick(lo), TickMath.getSqrtRatioAtTick(hi), l);
		w.amount0 += a0;
		w.amount1 += a1;
	}

	/// @dev ticks(t) starts (liquidityGross, liquidityNet) on both Uniswap v3 and Slipstream
	function _liquidityNet(int24 tick) internal view returns (int256) {
		(bool ok, bytes memory data) = address(pool).staticcall(abi.encodeWithSignature('ticks(int24)', tick));
		if (!ok || data.length < 64) revert ObservationWindowUnavailable();
		(, int128 net) = abi.decode(data, (uint128, int128));
		return int256(net);
	}

	/// @dev tick / spacing rounded toward −∞ (TickBitmap's compression)
	function _compress(int24 tick, int24 spacing) internal pure returns (int24 compressed) {
		compressed = tick / spacing;
		if (tick < 0 && tick % spacing != 0) compressed--;
	}

	/// @notice Arithmetic-mean tick (rounded toward −∞) and harmonic-mean liquidity over `window`.
	/// @dev Semantics of Uniswap OracleLibrary.consult.
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
	///      Adapted from Uniswap OracleLibrary.getQuoteAtTick.
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
