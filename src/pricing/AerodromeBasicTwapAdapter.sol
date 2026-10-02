// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {AggregatorV3Interface} from '../interfaces/AggregatorV3Interface.sol';
import {ITwapPriceAdapter} from '../interfaces/ITwapPriceAdapter.sol';
import {TwapFloor} from '../libraries/TwapFloor.sol';

/// @notice The Aerodrome basic (v2-style) pool views the adapter reads, verified with cast on Base
///         against the clone implementation 0xA4e4…D6d7 (Solidity 0.8.19, checked arithmetic).
interface IAerodromeBasicPool {
	/// @notice 1800: an observation is written only when the last one is more than this old.
	function periodSize() external view returns (uint256);

	function observationLength() external view returns (uint256);

	function observations(uint256 index)
		external
		view
		returns (uint256 timestamp, uint256 reserve0Cumulative, uint256 reserve1Cumulative);

	function lastObservation()
		external
		view
		returns (uint256 timestamp, uint256 reserve0Cumulative, uint256 reserve1Cumulative);

	/// @notice Cumulative RESERVES (not prices, despite the name) at `block.timestamp`, including
	///         the current reserves × the seconds since the pool's last update.
	function currentCumulativePrices()
		external
		view
		returns (uint256 reserve0Cumulative, uint256 reserve1Cumulative, uint256 blockTimestamp);

	function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);

	function stable() external view returns (bool);

	function token0() external view returns (address);

	function token1() external view returns (address);
}

/// @title AerodromeBasicTwapAdapter
/// @notice Prices one asset from its Aerodrome basic VOLATILE (x·y=k) pool's time-averaged reserves
///         over at least `window`, times a Chainlink feed for the pool's other token, exposed as an
///         AggregatorV3 feed (18 decimals).
/// @dev The pool records cumulative reserves at most once per 1800 s. The adapter takes the newest
///      observation at least `window` old — the last one, else the one before it (observations are
///      more than 1800 s apart, so with a 30-min window the one before always qualifies) — and
///      averages each reserve from it to now; the price is avgQuote / avgAsset × the quote feed,
///      rounded once at the end. Only time moves the cumulatives, so a swap in the reading block
///      can't move the average.
///      Reverting guards (a revert pauses NAV-dependent actions of funds holding the asset):
///      1. window ≥ 30 min, served by an observation at least that old;
///      2. spot (current reserves) within `maxDeviationBps` of the TWAP;
///      3. quote feed answer > 0 and within `quoteHeartbeat`.
///      Stable (sAMM) pools are refused: their curve is not x·y=k.
///      Two liquidity reads, both from `getReserves()` — never `balanceOf`, since `skim()` hands any
///      donation back to whoever calls it:
///      - Reserve = the QUOTE reserve (`quoteReserveUsd()`).
///      - Depth = the QUOTE an asset seller pulls out by moving the price −10%: on x·y=k the quote
///        reserve falls to √0.9 of itself, so depth = (1 − √0.9) × min(window-average, current)
///        quote reserve. It sizes exposure caps, the recorded depth and the repoint margin.
///      The floor is both (Ruling 23; `isBelowFloor()` reports it): reserve ≥ `minLiquidityUsd` AND
///      depth ≥ `minBandDepthUsd` = (1 − √0.9) of `minLiquidityUsd`. With the current reserve the
///      lower one, the second follows from the first; with the window average lower (liquidity
///      added, or the asset bought, within the window) it binds: reserve that arrived in the last
///      minutes does not lift the floor until it is in the average.
///      The average weights each second by the reserves held then, so liquidity parked at a
///      skewed price for a few seconds weighs in proportion to its size × time.
///      `updatedAt` is the read's own timestamp.
contract AerodromeBasicTwapAdapter is AggregatorV3Interface, ITwapPriceAdapter {
	uint32 public constant MIN_WINDOW = 30 minutes;
	uint16 public constant MAX_DEVIATION_BPS = 2_000;
	/// @notice floor((1 − √0.9) · 1e6): the share of the quote reserve a −10% move on x·y=k pays out.
	uint256 public constant BAND_QUOTE_PPM = TwapFloor.BAND_QUOTE_PPM;
	uint256 private constant BPS = 10_000;
	uint8 private constant ANSWER_DECIMALS = 18;

	IAerodromeBasicPool public immutable pool;
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
	error StablePool();
	error AssetNotInPool(address asset);
	error UnsupportedDecimals(uint8 decimals);
	error ObservationWindowUnavailable();
	error SpotDeviatesFromTwap(uint256 spotUsd, uint256 twapUsd);
	error QuoteNonPositive(int256 answer);
	error QuoteStale(uint256 updatedAt);
	error PriceRoundsToZero();

	constructor(
		IAerodromeBasicPool pool_,
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
		if (pool_.stable()) revert StablePool();

		address token0 = pool_.token0();
		address token1 = pool_.token1();
		if (asset_ != token0 && asset_ != token1) revert AssetNotInPool(asset_);
		assetIsToken0 = asset_ == token0;
		quoteAsset = assetIsToken0 ? token1 : token0;

		assetDecimals = IERC20Metadata(asset_).decimals();
		quoteDecimals = IERC20Metadata(quoteAsset).decimals();
		quoteFeedDecimals = quoteFeed_.decimals();
		// same bounds as the concentrated adapter; feeds are scaled UP to 18
		if (assetDecimals > 38) revert UnsupportedDecimals(assetDecimals);
		if (quoteDecimals > 38) revert UnsupportedDecimals(quoteDecimals);
		if (quoteFeedDecimals > ANSWER_DECIMALS) revert UnsupportedDecimals(quoteFeedDecimals);

		pool = pool_;
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
		(uint256 avgA, uint256 avgQ) = _twar();
		(uint256 rA, uint256 rQ) = _reserves();
		uint256 quoteUsd18 = _quoteUsd18();
		uint256 price = _usdPerAsset(avgQ, avgA, quoteUsd18);
		if (!_withinDeviation(rQ, rA, avgQ, avgA)) revert SpotDeviatesFromTwap(_usdPerAsset(rQ, rA, quoteUsd18), price);
		if (price == 0) revert PriceRoundsToZero();

		answer = int256(price);
		roundId = uint80(block.timestamp);
		answeredInRound = roundId;
		startedAt = block.timestamp;
		updatedAt = block.timestamp;
	}

	/// @notice USD (18 decimals) of the quote a −10% sell pulls out: (1 − √0.9) of the lower of the
	///         window-average and current quote reserves; price guards not applied.
	function poolDepthUsd() public view returns (uint256) {
		(, uint256 avgQ) = _twar();
		(, uint256 rQ) = _reserves();
		uint256 quoteOut = Math.mulDiv(avgQ < rQ ? avgQ : rQ, BAND_QUOTE_PPM, 1e6);
		return Math.mulDiv(quoteOut, _quoteUsd18(), 10 ** quoteDecimals);
	}

	/// @notice USD (18 decimals) of the pool's QUOTE reserve (`getReserves()`) × the quote feed.
	///         Reverts when the pool can't serve the window or the quote feed is non-positive or
	///         stale; the spot-deviation guard is not applied.
	function quoteReserveUsd() public view returns (uint256) {
		_twar();
		(, uint256 rQ) = _reserves();
		return Math.mulDiv(rQ, _quoteUsd18(), 10 ** quoteDecimals);
	}

	/// @notice True while the quote reserve is under `minLiquidityUsd` or the band depth under
	///         `minBandDepthUsd` (read only when the reserve holds).
	function isBelowFloor() external view returns (bool) {
		return quoteReserveUsd() < minLiquidityUsd * 1e18 || poolDepthUsd() < minBandDepthUsd * 1e18;
	}

	/// @dev Time-averaged reserves (raw units) from the newest observation at least `window` old
	///      (the last, else the one before it) to now.
	function _twar() internal view returns (uint256 avgA, uint256 avgQ) {
		uint256 len = pool.observationLength();
		(uint256 t, uint256 c0, uint256 c1) = pool.lastObservation();
		if (block.timestamp - t < window) {
			if (len < 2) revert ObservationWindowUnavailable();
			(t, c0, c1) = pool.observations(len - 2);
			if (block.timestamp - t < window) revert ObservationWindowUnavailable();
		}
		(uint256 n0, uint256 n1, uint256 tNow) = pool.currentCumulativePrices();
		uint256 dt = tNow - t;
		if (dt == 0) revert ObservationWindowUnavailable();
		(uint256 r0, uint256 r1) = ((n0 - c0) / dt, (n1 - c1) / dt);
		(avgA, avgQ) = assetIsToken0 ? (r0, r1) : (r1, r0);
		if (avgA == 0 || avgQ == 0) revert ObservationWindowUnavailable();
	}

	/// @dev USD (18 decimals) per whole asset for `quoteAmount` quote per `assetAmount` asset (raw
	///      units), rounded down ONCE: floor(quoteAmount × 10^ad × quoteUsd18 / (assetAmount × 10^qd)).
	///      The trailing division adds no rounding: floor(floor(x) / n) = floor(x / n).
	///      Bounds: 10^ad × quoteUsd18 fits for ad ≤ 38 and a quote < $1e21; mulDiv multiplies in 512
	///      bits and divides by the bare `assetAmount`, so no reserve size can overflow; its result is
	///      price × 10^qd, which fits for any price below 2^256 / 10^qd.
	function _usdPerAsset(uint256 quoteAmount, uint256 assetAmount, uint256 quoteUsd18) internal view returns (uint256) {
		return Math.mulDiv(quoteAmount, 10 ** assetDecimals * quoteUsd18, assetAmount) / 10 ** quoteDecimals;
	}

	/// @dev spot / TWAP = (rQ / rA) / (avgQ / avgA) = (rQ·avgA) / (avgQ·rA). Within the guard iff
	///      neither cross-product exceeds the other by more than maxDeviationBps — compared in 512 bits,
	///      so nothing rounds. rQ, avgQ × 12_000 must fit (quote reserves below 9e72 raw).
	function _withinDeviation(uint256 rQ, uint256 rA, uint256 avgQ, uint256 avgA) internal view returns (bool) {
		uint256 band = BPS + maxDeviationBps;
		return _productAtMost(rQ * BPS, avgA, avgQ * band, rA) && _productAtMost(avgQ * BPS, rA, rQ * band, avgA);
	}

	/// @dev a·b ≤ c·d, exactly
	function _productAtMost(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (bool) {
		(uint256 abHigh, uint256 abLow) = Math.mul512(a, b);
		(uint256 cdHigh, uint256 cdLow) = Math.mul512(c, d);
		return abHigh < cdHigh || (abHigh == cdHigh && abLow <= cdLow);
	}

	function _reserves() internal view returns (uint256 rA, uint256 rQ) {
		(uint256 r0, uint256 r1,) = pool.getReserves();
		(rA, rQ) = assetIsToken0 ? (r0, r1) : (r1, r0);
	}

	function _quoteUsd18() internal view returns (uint256) {
		(, int256 answer,, uint256 updatedAt,) = quoteFeed.latestRoundData();
		if (answer <= 0) revert QuoteNonPositive(answer);
		if (block.timestamp > updatedAt + quoteHeartbeat) revert QuoteStale(updatedAt);
		return uint256(answer) * 10 ** (ANSWER_DECIMALS - quoteFeedDecimals);
	}
}
