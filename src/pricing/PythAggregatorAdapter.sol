// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {AggregatorV3Interface} from '../interfaces/AggregatorV3Interface.sol';
import {IPyth} from '../interfaces/external/IPyth.sol';

/// @title PythAggregatorAdapter
/// @notice One Pyth Core price id, exposed as a Chainlink AggregatorV3 feed — so the
///         ValueInterpreter prices Pyth-covered assets (oil, indexes, FX, long-tail equities)
///         through the exact same `addPrimitive` path as Chainlink, with ZERO protocol changes.
///         Chainlink stays primary wherever both exist (B20 equities, crypto majors, XAU/XAG);
///         these adapters fill the rest of the 120-pair Veranta universe.
/// @dev Design decisions (all fork-verified against the real Base deployment):
///      - STALENESS is two-layered: the VI's per-asset heartbeat stays the market-hours
///        gate (`updatedAt` = Pyth publishTime), and the adapter's own `maxPushAge`
///        additionally bounds how OLD a stored push may be (security review 2026-09-22,
///        H-3: `updatePriceFeeds` is permissionless and Hermes serves history, so a wide
///        heartbeat alone lets an actor pick any print inside it around GAV actions —
///        the keeper must push fresher than maxPushAge before GAV-dependent calls). Any
///        other consumer of this adapter MUST check `updatedAt`, per AggregatorV3
///        convention.
///      - CONFIDENCE is guarded here (AggregatorV3 has no conf channel): a read where
///        Pyth's confidence interval exceeds `maxConfBps` of price reverts — chaotic
///        prints block GAV rather than mispricing it. In-kind redemption never prices.
///      - EXPONENTS VARY per feed (ETH/USD -8, TSLA/USD and EUR/USD -5 — live-read) so
///        every answer is normalized to 8 decimals, the Chainlink USD convention.
///      - Pyth is a PULL oracle: the stored price is only as fresh as the last permissionless
///        `updatePriceFeeds` push. Long-tail feeds on Base sit stale for months (TSLA ~78d at
///        adapter-authoring time) — the keeper pushes Hermes payloads before GAV-dependent
///        actions on Pyth-priced assets. Until pushed, reads correctly revert as stale.
contract PythAggregatorAdapter is AggregatorV3Interface {
	uint256 private constant BPS_DENOM = 10_000;
	int32 private constant TARGET_EXPO = -8;
	int32 private constant MIN_EXPO = -32;

	IPyth public immutable pyth;
	bytes32 public immutable priceId;
	/// @notice Max Pyth confidence interval as bps of price before reads revert.
	uint16 public immutable maxConfBps;
	/// @notice Max age of the stored Pyth push before reads revert — the anti-cherry-pick
	///         bound; keep it far tighter than the VI heartbeat.
	uint32 public immutable maxPushAge;
	string public description;

	error ZeroArgument();
	error BadConfBps(uint16 confBps);
	error NonPositivePrice(int64 price);
	error ConfidenceTooWide(uint64 conf, int64 price);
	error UnsupportedExponent(int32 expo);
	error StalePythPush(uint256 publishTime);

	constructor(IPyth pyth_, bytes32 priceId_, uint16 maxConfBps_, uint32 maxPushAge_, string memory description_) {
		if (address(pyth_) == address(0) || priceId_ == bytes32(0) || maxPushAge_ == 0) revert ZeroArgument();
		if (maxConfBps_ == 0 || maxConfBps_ > BPS_DENOM) revert BadConfBps(maxConfBps_);
		pyth = pyth_;
		priceId = priceId_;
		maxConfBps = maxConfBps_;
		maxPushAge = maxPushAge_;
		description = description_;
	}

	/// @inheritdoc AggregatorV3Interface
	function decimals() external pure returns (uint8) {
		return 8;
	}

	/// @inheritdoc AggregatorV3Interface
	function latestRoundData()
		external
		view
		returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
	{
		IPyth.Price memory p = pyth.getPriceUnsafe(priceId);
		if (p.price <= 0) revert NonPositivePrice(p.price);
		if (uint256(p.conf) * BPS_DENOM > uint256(uint64(p.price)) * maxConfBps) {
			revert ConfidenceTooWide(p.conf, p.price);
		}
		if (p.expo > 0 || p.expo < MIN_EXPO) revert UnsupportedExponent(p.expo);
		if (block.timestamp > p.publishTime + maxPushAge) revert StalePythPush(p.publishTime);

		answer = int256(uint256(uint64(p.price)));
		if (p.expo > TARGET_EXPO) answer *= int256(10 ** uint256(int256(p.expo - TARGET_EXPO)));
		else if (p.expo < TARGET_EXPO) answer /= int256(10 ** uint256(int256(TARGET_EXPO - p.expo)));

		roundId = uint80(p.publishTime);
		answeredInRound = roundId;
		startedAt = p.publishTime;
		updatedAt = p.publishTime;
	}
}
