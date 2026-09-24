// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {AggregatorV3Interface} from '../interfaces/AggregatorV3Interface.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {IDerivativePriceFeed} from '../interfaces/IDerivativePriceFeed.sol';

/// @title ValueInterpreter
/// @notice Singleton pricing aggregator: values any registered asset in terms of any other
///         registered asset, exclusively via external USD oracle feeds.
/// @dev Successor to melon-v1 KyberPriceFeed (melon-v1/src/prices/KyberPriceFeed.sol — push
///      oracle with a trusted updater, dead pattern) using Enzyme v4's ValueInterpreter shape
///      (spec/architecture/release.md#valueinterpreter).
///
///      HARD RULES enforced here (see living doc):
///      - Prices come from registered aggregators only. Never pool spot state (Gamma, Jan 2024).
///      - Tokenized-stock wrappers register their OWN feed — never their underlying's (depeg is real).
///      - Staleness: each asset has a `heartbeat`; a price older than it reverts.
///        For equity feeds this doubles as the market-hours gate: feeds stop updating when the
///        underlying market closes, so GAV-dependent actions (deposit execution, value-based
///        redemption) revert outside market hours BY DESIGN. In-kind redemption never touches
///        pricing and stays available 24/7. Derivative feeds (CLMM positions etc.) come later
///        as v4-style derivative price feeds.
contract ValueInterpreter is IValueInterpreter, Ownable2Step {
	struct AssetInfo {
		AggregatorV3Interface aggregator; // USD-quoted feed
		uint32 heartbeat; // max price age in seconds
		uint8 assetDecimals; // cached ERC20 decimals
		uint8 rateDecimals; // cached aggregator decimals
	}

	struct DerivativeInfo {
		IDerivativePriceFeed feed; // resolves the derivative into primitive underlyings
		uint8 assetDecimals; // cached ERC20 decimals
	}

	uint256 private constant RATE_PRECISION = 1e18;
	/// @dev Bytecode cap (Gamma lesson #3: config is attack surface): no feed may ever be
	///      allowed to serve a price older than 7 days — covers weekends + long weekends
	///      for equities with margin, without permitting effectively-unbounded staleness.
	uint32 public constant MAX_HEARTBEAT = 7 days;

	mapping(address asset => AssetInfo) private assetInfo;
	mapping(address asset => DerivativeInfo) private derivativeInfo;

	/// @dev The side-pocket class ("ZeroPriceFeed"): assets deliberately valued at ZERO.
	///      Unpriceable moonshots (thin/new tokens with no defensible oracle) become
	///      holdable by risky-flagged funds without ever entering GAV — gains are
	///      recognized only on realization (sale into a priced asset). Zero cannot be
	///      manipulated: no oracle to pump, no fake NAV, no fee crystallization on paper
	///      gains. The trad-fund side pocket, enforced in bytecode.
	mapping(address asset => bool) public isZeroPricedAsset;

	event PrimitiveAdded(address indexed asset, address aggregator, uint32 heartbeat);
	event PrimitiveRemoved(address indexed asset);
	event DerivativeAdded(address indexed asset, address indexed feed);
	event DerivativeRemoved(address indexed asset);
	event ZeroPricedAssetAdded(address indexed asset);
	event ZeroPricedAssetRemoved(address indexed asset);

	error UnsupportedAsset(address asset);
	error StalePrice(address asset, uint256 updatedAt);
	error InvalidPrice(address asset, int256 answer);
	error HeartbeatAboveMax(uint32 heartbeat);
	error ZeroAddress();
	error AlreadyRegistered(address asset);
	error FeedDoesNotSupportAsset(address asset);
	error QuoteAssetMustBePrimitive(address asset);
	error AnswerOutOfBounds(address asset, int256 answer);
	error BadBounds();

	struct AnswerBounds {
		int256 min;
		int256 max;
	}

	/// @notice Optional per-asset sanity band. Chainlink aggregators PIN at their
	///         min/maxAnswer instead of reverting (LUNA-class failure) — an answer at
	///         or outside the recorded band reverts rather than mispricing GAV
	///         (security review 2026-09-22, M-7). Unset (0,0) = no check.
	mapping(address asset => AnswerBounds) public answerBounds;

	event AnswerBoundsSet(address indexed asset, int256 min, int256 max);

	/// @notice Chainlink L2 Sequencer Uptime Feed (Base: 0xBCF8…6433). Chainlink's docs
	///         require L2 consumers to check it: while the sequencer is down, feeds cannot
	///         update and only L1-forced transactions land, so every price is suspect —
	///         and right after it comes back, prices are still catching up. Unset (zero)
	///         on chains without one (Sepolia testnets). answer 0 = up, 1 = down;
	///         startedAt = when the status last changed.
	AggregatorV3Interface public sequencerUptimeFeed;
	/// @notice How long after the sequencer comes back up pricing stays refused.
	uint32 public sequencerGracePeriod;
	/// @dev Bytecode cap on the grace period (config is attack surface).
	uint32 public constant MAX_SEQUENCER_GRACE_PERIOD = 1 days;

	event SequencerUptimeFeedSet(address feed, uint32 gracePeriod);

	error SequencerDown();
	error SequencerGracePeriodNotOver(uint256 upSince);
	error BadGracePeriod(uint32 gracePeriod);

	constructor(address initialOwner) Ownable(initialOwner) {}

	/// @notice Record the sanity band for an asset's feed — use the aggregator's own
	///         min/maxAnswer or tighter. Either side may be 0 to skip that side.
	function setAnswerBounds(address asset, int256 min, int256 max) external onlyOwner {
		if (min != 0 && max != 0 && min >= max) revert BadBounds();
		answerBounds[asset] = AnswerBounds({min: min, max: max});
		emit AnswerBoundsSet(asset, min, max);
	}

	/// @notice Set (or clear, with the zero address) the L2 sequencer uptime check.
	function setSequencerUptimeFeed(address feed, uint32 gracePeriod) external onlyOwner {
		if (feed != address(0) && (gracePeriod == 0 || gracePeriod > MAX_SEQUENCER_GRACE_PERIOD)) {
			revert BadGracePeriod(gracePeriod);
		}
		sequencerUptimeFeed = AggregatorV3Interface(feed);
		sequencerGracePeriod = feed == address(0) ? 0 : gracePeriod;
		emit SequencerUptimeFeedSet(feed, sequencerGracePeriod);
	}

	// ─── Admin ───────────────────────────────────────────────────────────────────

	function addPrimitive(address asset, address aggregator, uint32 heartbeat) external onlyOwner {
		if (asset == address(0) || aggregator == address(0)) revert ZeroAddress();
		if (address(derivativeInfo[asset].feed) != address(0) || isZeroPricedAsset[asset]) {
			revert AlreadyRegistered(asset);
		}
		if (heartbeat == 0 || heartbeat > MAX_HEARTBEAT) revert HeartbeatAboveMax(heartbeat);

		assetInfo[asset] = AssetInfo({
			aggregator: AggregatorV3Interface(aggregator),
			heartbeat: heartbeat,
			assetDecimals: IERC20Metadata(asset).decimals(),
			rateDecimals: AggregatorV3Interface(aggregator).decimals()
		});

		emit PrimitiveAdded(asset, aggregator, heartbeat);
	}

	function removePrimitive(address asset) external onlyOwner {
		if (address(assetInfo[asset].aggregator) == address(0)) revert UnsupportedAsset(asset);
		delete assetInfo[asset];
		emit PrimitiveRemoved(asset);
	}

	/// @notice Register a derivative (vault share, LP token) priced by resolving into
	///         primitive underlyings via `feed`. Curation is the security boundary here:
	///         the feed trusts the derivative's own accounting (see ERC4626PriceFeed notes).
	function addDerivative(address asset, address feed) external onlyOwner {
		if (asset == address(0) || feed == address(0)) revert ZeroAddress();
		if (address(assetInfo[asset].aggregator) != address(0) || isZeroPricedAsset[asset]) {
			revert AlreadyRegistered(asset);
		}
		if (!IDerivativePriceFeed(feed).isSupportedAsset(asset)) revert FeedDoesNotSupportAsset(asset);

		derivativeInfo[asset] = DerivativeInfo({
			feed: IDerivativePriceFeed(feed),
			assetDecimals: IERC20Metadata(asset).decimals()
		});
		emit DerivativeAdded(asset, feed);
	}

	/// @notice Register a side-pocket asset (valued at zero until sold). Reverts if the
	///         asset already has a real price source — an asset is exactly one of:
	///         primitive, derivative, or zero-priced.
	function addZeroPricedAsset(address asset) external onlyOwner {
		if (asset == address(0)) revert ZeroAddress();
		if (address(assetInfo[asset].aggregator) != address(0) || address(derivativeInfo[asset].feed) != address(0)) {
			revert AlreadyRegistered(asset);
		}
		isZeroPricedAsset[asset] = true;
		emit ZeroPricedAssetAdded(asset);
	}

	function removeZeroPricedAsset(address asset) external onlyOwner {
		if (!isZeroPricedAsset[asset]) revert UnsupportedAsset(asset);
		delete isZeroPricedAsset[asset];
		emit ZeroPricedAssetRemoved(asset);
	}

	function removeDerivative(address asset) external onlyOwner {
		if (address(derivativeInfo[asset].feed) == address(0)) revert UnsupportedAsset(asset);
		delete derivativeInfo[asset];
		emit DerivativeRemoved(asset);
	}

	// ─── Pricing ─────────────────────────────────────────────────────────────────

	/// @inheritdoc IValueInterpreter
	/// @dev Base may be a primitive or a registered derivative; the QUOTE must be a
	///      primitive (denomination assets always are) — this plus the primitives-only
	///      rule for derivative underlyings makes pricing cycles impossible.
	function calcCanonicalAssetValue(address baseAsset, uint256 amount, address quoteAsset)
		external
		view
		returns (uint256 value)
	{
		if (baseAsset == quoteAsset) return amount;
		_checkSequencer();

		AssetInfo memory quote = assetInfo[quoteAsset];
		if (address(quote.aggregator) == address(0)) revert QuoteAssetMustBePrimitive(quoteAsset);
		uint256 quoteRate = _validatedRate(quoteAsset, quote);

		uint256 usdValue = _calcUsdValue(baseAsset, amount);
		value = Math.mulDiv(usdValue, 10 ** quote.assetDecimals, quoteRate);
	}

	/// @dev USD (1e18) value of `amount` of `asset` — primitive directly, derivative via
	///      its feed's primitive underlyings (derivative-of-derivative reverts).
	function _calcUsdValue(address asset, uint256 amount) private view returns (uint256 usdValue) {
		if (isZeroPricedAsset[asset]) return 0;

		AssetInfo memory info = assetInfo[asset];
		if (address(info.aggregator) != address(0)) {
			return Math.mulDiv(amount, _validatedRate(asset, info), 10 ** info.assetDecimals);
		}

		DerivativeInfo memory derivative = derivativeInfo[asset];
		if (address(derivative.feed) == address(0)) revert UnsupportedAsset(asset);

		(address[] memory underlyings, uint256[] memory underlyingAmounts) =
			derivative.feed.calcUnderlyingValues(asset, amount);
		for (uint256 i; i < underlyings.length; ++i) {
			AssetInfo memory underlying = assetInfo[underlyings[i]];
			if (address(underlying.aggregator) == address(0)) revert UnsupportedAsset(underlyings[i]);
			usdValue += Math.mulDiv(
				underlyingAmounts[i], _validatedRate(underlyings[i], underlying), 10 ** underlying.assetDecimals
			);
		}
	}

	/// @inheritdoc IValueInterpreter
	function isSupportedAsset(address asset) external view returns (bool) {
		return address(assetInfo[asset].aggregator) != address(0)
			|| address(derivativeInfo[asset].feed) != address(0) || isZeroPricedAsset[asset];
	}

	/// @inheritdoc IValueInterpreter
	function calcUsdRate(address asset) external view returns (uint256 rate) {
		if (isZeroPricedAsset[asset]) return 0;
		_checkSequencer();

		AssetInfo memory info = assetInfo[asset];
		if (address(info.aggregator) != address(0)) return _validatedRate(asset, info);

		DerivativeInfo memory derivative = derivativeInfo[asset];
		if (address(derivative.feed) == address(0)) revert UnsupportedAsset(asset);
		return _calcUsdValue(asset, 10 ** derivative.assetDecimals);
	}

	function getAssetInfo(address asset)
		external
		view
		returns (address aggregator, uint32 heartbeat, uint8 assetDecimals, uint8 rateDecimals)
	{
		AssetInfo memory info = assetInfo[asset];
		return (address(info.aggregator), info.heartbeat, info.assetDecimals, info.rateDecimals);
	}

	/// @dev Chainlink's L2 pattern (docs.chain.link/data-feeds/l2-sequencer-feeds): refuse
	///      to price while the sequencer is down, and for `sequencerGracePeriod` after it
	///      comes back. Anything but 0 counts as down (fail closed).
	function _checkSequencer() private view {
		AggregatorV3Interface feed = sequencerUptimeFeed;
		if (address(feed) == address(0)) return;
		(, int256 answer, uint256 startedAt,,) = feed.latestRoundData();
		if (answer != 0) revert SequencerDown();
		if (block.timestamp - startedAt <= sequencerGracePeriod) revert SequencerGracePeriodNotOver(startedAt);
	}

	/// @dev Returns the asset's USD rate scaled to 1e18, reverting on unregistered feeds,
	///      non-positive answers, and stale prices.
	function _validatedRate(address asset, AssetInfo memory info) private view returns (uint256) {
		if (address(info.aggregator) == address(0)) revert UnsupportedAsset(asset);

		(, int256 answer,, uint256 updatedAt,) = info.aggregator.latestRoundData();
		if (answer <= 0) revert InvalidPrice(asset, answer);
		if (block.timestamp > updatedAt + info.heartbeat) revert StalePrice(asset, updatedAt);
		AnswerBounds memory bounds = answerBounds[asset];
		if ((bounds.min != 0 && answer <= bounds.min) || (bounds.max != 0 && answer >= bounds.max)) {
			revert AnswerOutOfBounds(asset, answer);
		}

		return Math.mulDiv(uint256(answer), RATE_PRECISION, 10 ** info.rateDecimals);
	}
}
