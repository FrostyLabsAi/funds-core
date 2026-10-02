// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {AggregatorV3Interface} from '../interfaces/AggregatorV3Interface.sol';
import {ITwapPriceAdapter} from '../interfaces/ITwapPriceAdapter.sol';
import {TwapFloor} from '../libraries/TwapFloor.sol';
import {IUniswapV2Pair, UniswapV2ObservationRecorder} from './UniswapV2ObservationRecorder.sol';

/// @title UniswapV2TwapAdapter
/// @notice Prices one asset from its Uniswap v2 pair's time-weighted average price over at least
///         `window`, times a Chainlink feed for the pair's other token, exposed as an AggregatorV3
///         feed (18 decimals).
/// @dev A v2 pair keeps only its running cumulative prices, so `recorder` snapshots them (a keeper
///      every 10–15 min; anyone may). The adapter takes the newest snapshot at least `window` old and
///      averages the asset side's UQ112x112 cumulative from it to now (the pair's counterfactual
///      cumulative at this second): quote raw per asset raw × 2^112, price0 when the asset is
///      token0, price1 otherwise. The price is that average × the quote feed, rounded once at the
///      end. Only time moves the cumulatives, so a swap in the reading block can't move the average.
///      Reverting guards (a revert pauses NAV-dependent actions of funds holding the asset):
///      1. window ≥ 30 min, served by a recorded snapshot at least that old (else NoSnapshot);
///      2. spot (current reserves) within `maxDeviationBps` of the TWAP;
///      3. quote feed answer > 0 and within `quoteHeartbeat`.
///      Two liquidity reads, both from `getReserves()` — never `balanceOf`, since `skim()` hands any
///      donation back to whoever calls it:
///      - Reserve = the QUOTE reserve (`quoteReserveUsd()`).
///      - Depth = the quote an asset seller pulls out by moving the price −10% on x·y=k:
///        (1 − √0.9) of the current quote reserve. v2 keeps no time-weighted reserves, so this is the
///        live reserve; the exposure policy's min(live, recorded depth) bounds a same-block inflation.
///        v2 leaves the 0.3% LP fee in the reserves, so a real −10% sell pays ~5.124% (the fee-free
///        5.1316% overstates it by < 0.15%).
///      The floor is both (Ruling 23; `isBelowFloor()` reports it): reserve ≥ `minLiquidityUsd` AND
///      depth ≥ `minBandDepthUsd` = (1 − √0.9) of `minLiquidityUsd`. Depth is (1 − √0.9) of the same
///      current reserve, so the second follows from the first (to within one raw quote unit, and
///      exactly for the registry's 25,000: 1,282.9 ≥ 1,282); it is checked anyway, as on every
///      adapter.
///      `updatedAt` is the read's own timestamp.
contract UniswapV2TwapAdapter is AggregatorV3Interface, ITwapPriceAdapter {
	uint32 public constant MIN_WINDOW = 30 minutes;
	uint16 public constant MAX_DEVIATION_BPS = 2_000;
	/// @notice floor((1 − √0.9) · 1e6): the share of the quote reserve a −10% move on x·y=k pays out.
	uint256 public constant BAND_QUOTE_PPM = TwapFloor.BAND_QUOTE_PPM;
	uint256 private constant BPS = 10_000;
	uint8 private constant ANSWER_DECIMALS = 18;
	uint256 private constant Q112 = 1 << 112;

	IUniswapV2Pair public immutable pair;
	UniswapV2ObservationRecorder public immutable recorder;
	address public immutable asset;
	address public immutable quoteAsset;
	bool public immutable assetIsToken0;
	AggregatorV3Interface public immutable quoteFeed;
	uint32 public immutable window;
	/// @notice Floor on the QUOTE reserve (`quoteReserveUsd()`), whole USD.
	uint256 public immutable minLiquidityUsd;
	/// @notice Floor on the band depth (`poolDepthUsd()`), whole USD:
	///         TwapFloor.minBandDepthUsd(minLiquidityUsd) — 1,282 for the registry's 25,000.
	uint256 public immutable minBandDepthUsd;
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
	error SpotDeviatesFromTwap(uint256 spotUsd, uint256 twapUsd);
	error QuoteNonPositive(int256 answer);
	error QuoteStale(uint256 updatedAt);
	error PriceRoundsToZero();

	constructor(
		IUniswapV2Pair pair_,
		address asset_,
		AggregatorV3Interface quoteFeed_,
		UniswapV2ObservationRecorder recorder_,
		uint32 window_,
		uint256 minLiquidityUsd_,
		uint16 maxDeviationBps_,
		uint32 quoteHeartbeat_,
		string memory description_
	) {
		if (address(pair_) == address(0) || asset_ == address(0) || address(quoteFeed_) == address(0)) revert ZeroArgument();
		if (address(recorder_) == address(0) || minLiquidityUsd_ == 0 || quoteHeartbeat_ == 0) revert ZeroArgument();
		if (window_ < MIN_WINDOW) revert WindowTooShort(window_);
		if (maxDeviationBps_ == 0 || maxDeviationBps_ > MAX_DEVIATION_BPS) revert BadDeviation(maxDeviationBps_);

		address token0 = pair_.token0();
		address token1 = pair_.token1();
		if (asset_ != token0 && asset_ != token1) revert AssetNotInPool(asset_);
		assetIsToken0 = asset_ == token0;
		quoteAsset = assetIsToken0 ? token1 : token0;

		assetDecimals = IERC20Metadata(asset_).decimals();
		quoteDecimals = IERC20Metadata(quoteAsset).decimals();
		quoteFeedDecimals = quoteFeed_.decimals();
		// same bounds as the other TWAP adapters; feeds are scaled UP to 18
		if (assetDecimals > 38) revert UnsupportedDecimals(assetDecimals);
		if (quoteDecimals > 38) revert UnsupportedDecimals(quoteDecimals);
		if (quoteFeedDecimals > ANSWER_DECIMALS) revert UnsupportedDecimals(quoteFeedDecimals);

		pair = pair_;
		recorder = recorder_;
		asset = asset_;
		quoteFeed = quoteFeed_;
		window = window_;
		minLiquidityUsd = minLiquidityUsd_;
		minBandDepthUsd = TwapFloor.minBandDepthUsd(minLiquidityUsd_);
		maxDeviationBps = maxDeviationBps_;
		quoteHeartbeat = quoteHeartbeat_;
		description = description_;
	}

	/// @inheritdoc AggregatorV3Interface
	function decimals() external pure override(AggregatorV3Interface, ITwapPriceAdapter) returns (uint8) {
		return ANSWER_DECIMALS;
	}

	/// @notice USD per whole `asset` (18 decimals), reverting guards applied.
	/// @inheritdoc AggregatorV3Interface
	function latestRoundData()
		external
		view
		override(AggregatorV3Interface, ITwapPriceAdapter)
		returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
	{
		uint256 avgX112 = _averageX112();
		(uint256 rA, uint256 rQ) = _reserves();
		uint256 quoteUsd18 = _quoteUsd18();
		uint256 price = _usdPerAsset(avgX112, Q112, quoteUsd18);
		if (!_withinDeviation(rQ, rA, avgX112)) revert SpotDeviatesFromTwap(_usdPerAsset(rQ, rA, quoteUsd18), price);
		if (price == 0) revert PriceRoundsToZero();

		answer = int256(price);
		roundId = uint80(block.timestamp);
		answeredInRound = roundId;
		startedAt = block.timestamp;
		updatedAt = block.timestamp;
	}

	/// @notice Window-average QUOTE raw units per ASSET raw unit as UQ112x112, from the newest
	///         snapshot at least `window` old to now; no price guards.
	function consult() external view returns (uint256 avgX112) {
		return _averageX112();
	}

	/// @notice USD (18 decimals) of the quote a −10% sell pulls out: (1 − √0.9) of the current
	///         quote reserve; reverts when the window can't be served; price guards not applied.
	function poolDepthUsd() public view returns (uint256) {
		recorder.snapshotAtLeast(address(pair), window);
		(, uint256 rQ) = _reserves();
		uint256 quoteOut = Math.mulDiv(rQ, BAND_QUOTE_PPM, 1e6);
		return Math.mulDiv(quoteOut, _quoteUsd18(), 10 ** quoteDecimals);
	}

	/// @notice USD (18 decimals) of the pair's QUOTE reserve (`getReserves()`) × the quote feed.
	///         Reverts when the window can't be served or the quote feed is non-positive or stale;
	///         the spot-deviation guard is not applied.
	function quoteReserveUsd() public view returns (uint256) {
		recorder.snapshotAtLeast(address(pair), window);
		(, uint256 rQ) = _reserves();
		return Math.mulDiv(rQ, _quoteUsd18(), 10 ** quoteDecimals);
	}

	/// @notice True while the quote reserve is under `minLiquidityUsd` or the band depth under
	///         `minBandDepthUsd` (read only when the reserve holds).
	function isBelowFloor() external view returns (bool) {
		return quoteReserveUsd() < minLiquidityUsd * 1e18 || poolDepthUsd() < minBandDepthUsd * 1e18;
	}

	/// @dev Average of the asset side's cumulative (quote per asset, UQ112x112) from the newest
	///      snapshot at least `window` old to the pair's counterfactual cumulative now. Both deltas are
	///      `unchecked` because both wrap by design: the cumulatives mod 2^256, the uint32 timestamps
	///      mod 2^32. Each is exact while the span is under 2^32 s (the true cumulative delta is then
	///      < 2^224 × 2^32), and the span equals the snapshot's age (same uint32 "now"), so it is
	///      ≥ window > 0.
	function _averageX112() internal view returns (uint256 avgX112) {
		UniswapV2ObservationRecorder.Snapshot memory s = recorder.snapshotAtLeast(address(pair), window);
		(uint256 c0, uint256 c1, uint32 tNow) = recorder.currentCumulativePrices(address(pair));
		unchecked {
			uint32 dt = tNow - s.timestamp;
			avgX112 = assetIsToken0 ? (c0 - s.price0Cumulative) / dt : (c1 - s.price1Cumulative) / dt;
		}
	}

	/// @dev USD (18 decimals) per whole asset for `quoteAmount` quote per `assetAmount` asset (raw
	///      units), rounded down ONCE: floor(quoteAmount × 10^ad × quoteUsd18 / (assetAmount × 10^qd)).
	///      TWAP: (avgX112, 2^112); spot: (rQ, rA). The trailing division adds no rounding:
	///      floor(floor(x) / n) = floor(x / n).
	///      Bounds: 10^ad × quoteUsd18 fits for ad ≤ 38 and a quote < $1e21; mulDiv multiplies in 512
	///      bits and divides by the bare `assetAmount` (2^112 or a uint112 reserve), so no average
	///      (< 2^224) or reserve (< 2^112) can overflow it; its result is price × 10^qd, which fits for
	///      any price below 2^256 / 10^qd, and a result that can't fit reverts in mulDiv, never wraps.
	function _usdPerAsset(uint256 quoteAmount, uint256 assetAmount, uint256 quoteUsd18) internal view returns (uint256) {
		return Math.mulDiv(quoteAmount, 10 ** assetDecimals * quoteUsd18, assetAmount) / 10 ** quoteDecimals;
	}

	/// @dev spot / TWAP = (rQ / rA) / (avgX112 / 2^112) = (rQ·2^112) / (avgX112·rA). Within the guard
	///      iff neither cross-product exceeds the other by more than maxDeviationBps, compared in 512
	///      bits so nothing rounds. Every factor fits 256 bits: rQ, rA < 2^112 (uint112 reserves),
	///      avgX112 < 2^224 (a per-second price is ≤ (2^112 − 1)·2^112), BPS and the band < 2^14.
	function _withinDeviation(uint256 rQ, uint256 rA, uint256 avgX112) internal view returns (bool) {
		uint256 band = BPS + maxDeviationBps;
		return _productAtMost(rQ * BPS, Q112, avgX112 * band, rA) && _productAtMost(avgX112 * BPS, rA, rQ * band, Q112);
	}

	/// @dev a·b ≤ c·d, exactly
	function _productAtMost(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (bool) {
		(uint256 abHigh, uint256 abLow) = Math.mul512(a, b);
		(uint256 cdHigh, uint256 cdLow) = Math.mul512(c, d);
		return abHigh < cdHigh || (abHigh == cdHigh && abLow <= cdLow);
	}

	function _reserves() internal view returns (uint256 rA, uint256 rQ) {
		(uint112 r0, uint112 r1,) = pair.getReserves();
		(rA, rQ) = assetIsToken0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
	}

	function _quoteUsd18() internal view returns (uint256) {
		(, int256 answer,, uint256 updatedAt,) = quoteFeed.latestRoundData();
		if (answer <= 0) revert QuoteNonPositive(answer);
		if (block.timestamp > updatedAt + quoteHeartbeat) revert QuoteStale(updatedAt);
		return uint256(answer) * 10 ** (ANSWER_DECIMALS - quoteFeedDecimals);
	}
}
