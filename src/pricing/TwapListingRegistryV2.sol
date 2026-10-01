// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {AggregatorV3Interface} from '../interfaces/AggregatorV3Interface.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {IConcentratedPoolOracle} from './TwapAggregatorAdapter.sol';
import {TwapAggregatorAdapterV2} from './TwapAggregatorAdapterV2.sol';
import {IUniswapV3PoolFactory, ISlipstreamPoolFactory, IValueInterpreterAssetInfo} from './TwapListingRegistry.sol';

/// @title TwapListingRegistryV2
/// @notice Lists long-tail assets on the TWAP price tier, open to automation: a listing is
///         checked, not trusted.
///         - The pool comes from a canonical factory: Uniswap v3, or one of Aerodrome's three
///           Slipstream deployments (`getPool`).
///         - The pool's tick spacing is at least MIN_TICK_SPACING (10): Uniswap v3 fee tiers
///           100/200/300/400 (spacing 1/4/6/8 on Base) and Slipstream spacing 1 are refused.
///         - The pool keeps at least MIN_OBSERVATION_CARDINALITY (300) observations, so ordinary
///           trading can't push the 30-minute window out of its oracle history.
///         - The quote token is allow-listed with its Chainlink USD feed (USDC, WETH).
///         - The asset has no price in the ValueInterpreter yet (a higher tier always wins).
///         - The adapter is deployed here with fixed parameters, must price now, and must hold at
///           least MIN_DEPTH_USD of the QUOTE token within ±10% of the price. One-sided liquidity
///           of a self-priced token is not depth.
///         `repoint` moves a listing to a pool at least 25% deeper, or to any qualifying pool once
///         the current one is under the floor. `pokeFloor` runs the 72-hour delist clock: anyone
///         may START it; only a lister may CLEAR it (for anyone else that case is a no-op) or
///         record depth (`recordedDepthUsd18`, also written by `list` and `repoint`).
/// @dev Listers are granted explicitly (the PriceListingModule, which also writes the VI
///      primitive in the same transaction). `listings()` keeps v1's 5-field shape so v1 readers
///      (TwapFloorLens) keep working.
/// @dev Liquidity added and removed in the same transaction can inflate any depth snapshot, so it
///      must never clear a clock or raise a recorded depth; a real shortfall can't be faked upward.
contract TwapListingRegistryV2 is Ownable2Step {
	/// @notice Fixed adapter parameters, not the lister's choice.
	uint32 public constant WINDOW = 30 minutes;
	uint16 public constant MAX_DEVIATION_BPS = 500;
	uint256 public constant MIN_DEPTH_USD = 50_000;
	/// @notice How long a pool may stay under the floor before its asset is delisted.
	uint256 public constant DELIST_GRACE = 72 hours;
	/// @notice A repoint must reach a pool this much deeper (125%), unless the current one is under the floor.
	uint256 public constant REPOINT_MARGIN_BPS = 12_500;
	/// @notice Pools finer than this are refused: their depth walk can be bloated with dust ticks
	///         past any transaction's gas (a spacing-1 pool measured 26.5M), while at spacing ≥ 10
	///         even a fully initialized ±10% band costs about 4.2M, so MIN_READ_GAS is a real
	///         ceiling. The pools lost are stable or correlated pairs.
	int24 public constant MIN_TICK_SPACING = 10;
	/// @notice Pools must hold at least this many oracle observations. With one (common on young
	///         pools), any tick-changing trade leaves the pool unable to serve the 30-minute window
	///         for 30 minutes, pausing NAV-dependent actions of every fund holding the asset; 300
	///         removes that organic failure. Not window / block time (~900): a pool grows its ring
	///         only when a write lands on its last slot, so demanding 901 would stall listings of
	///         the existing 300–600 pools; the keeper calls increaseObservationCardinalityNext(901)
	///         on listed pools so they harden after their next wrap. Residual: a paid griefer making
	///         ≥ 300 tick-changing swaps in distinct blocks within 30 minutes; that pauses only
	///         NAV-dependent actions — sales and in-kind exits stay open.
	uint16 public constant MIN_OBSERVATION_CARDINALITY = 300;
	/// @notice Gas a depth read is guaranteed; a caller that forwards less and runs it dry gets
	///         ReadOutOfGas, while a read that exhausts at least this much counts as unanswerable
	///         (under the floor). It is a ceiling because of MIN_TICK_SPACING: no listable pool's
	///         honest read, dust included, comes near it.
	uint256 public constant MIN_READ_GAS = 8_000_000;
	uint256 private constant BPS = 10_000;

	enum Venue {
		UniswapV3,
		Slipstream,
		Slipstream2,
		Slipstream3
	}

	struct Quote {
		AggregatorV3Interface feed;
		uint32 heartbeat;
	}

	struct Listing {
		TwapAggregatorAdapterV2 adapter;
		address pool;
		address quote;
		uint64 listedAt;
		uint64 belowFloorSince; // 0 = at/over the floor (as of the last poke)
	}

	IValueInterpreter public immutable valueInterpreter;
	IUniswapV3PoolFactory public immutable uniswapFactory;
	ISlipstreamPoolFactory public immutable slipstreamFactory;
	ISlipstreamPoolFactory public immutable slipstream2Factory;
	ISlipstreamPoolFactory public immutable slipstream3Factory;

	mapping(address => Quote) public quotes;
	mapping(address => Listing) public listings;
	mapping(address => Venue) public venueOf;
	mapping(address => bool) public listers;
	/// @notice The quote-side depth last recorded by a lister (USD, 18 decimals).
	mapping(address => uint256) public recordedDepthUsd18;
	address[] internal listedAssets;

	event QuoteSet(address indexed quote, address feed, uint32 heartbeat);
	event ListerSet(address indexed lister, bool allowed);
	event Listed(address indexed asset, address indexed adapter, address pool, address quote, Venue venue, uint256 depthUsd18);
	event Repointed(address indexed asset, address indexed adapter, address pool, address quote, Venue venue, uint256 depthUsd18);
	event FloorBreached(address indexed asset, uint256 since);
	event FloorRestored(address indexed asset);
	event DepthRecorded(address indexed asset, uint256 depthUsd18);

	error ZeroAddress();
	error NotLister();
	error QuoteNotAllowed(address quote);
	error AlreadyPriced(address asset);
	error AlreadyListed(address asset);
	error NotListed(address asset);
	error PoolNotFound(address asset, address quote);
	error SamePool(address pool);
	error BelowFloorAtListing(uint256 depthUsd18);
	error NotDeepEnough(uint256 currentDepthUsd18, uint256 newDepthUsd18);
	error ReadOutOfGas();
	error TickSpacingTooFine(int24 tickSpacing);
	error ObservationCardinalityTooLow(uint16 cardinality);

	constructor(
		IValueInterpreter valueInterpreter_,
		IUniswapV3PoolFactory uniswapFactory_,
		ISlipstreamPoolFactory slipstreamFactory_,
		ISlipstreamPoolFactory slipstream2Factory_,
		ISlipstreamPoolFactory slipstream3Factory_
	) Ownable(msg.sender) {
		if (
			address(valueInterpreter_) == address(0) || address(uniswapFactory_) == address(0)
				|| address(slipstreamFactory_) == address(0) || address(slipstream2Factory_) == address(0)
				|| address(slipstream3Factory_) == address(0)
		) {
			revert ZeroAddress();
		}
		valueInterpreter = valueInterpreter_;
		uniswapFactory = uniswapFactory_;
		slipstreamFactory = slipstreamFactory_;
		slipstream2Factory = slipstream2Factory_;
		slipstream3Factory = slipstream3Factory_;
	}

	// ─── owner config ───────────────────────────────────────────────────────────

	/// @notice Allow a quote token with its Chainlink USD feed; feed = 0 disallows it for new listings.
	function setQuote(address quote, AggregatorV3Interface feed, uint32 heartbeat) external onlyOwner {
		if (quote == address(0)) revert ZeroAddress();
		quotes[quote] = Quote(feed, heartbeat);
		emit QuoteSet(quote, address(feed), heartbeat);
	}

	function setLister(address lister, bool allowed) external onlyOwner {
		listers[lister] = allowed;
		emit ListerSet(lister, allowed);
	}

	// ─── listing ────────────────────────────────────────────────────────────────

	/// @notice List `asset` against `quote` on the canonical pool of `venue`
	///         (`feeOrTickSpacing`: Uniswap fee tier, or Slipstream tick spacing).
	function list(address asset, address quote, Venue venue, int24 feeOrTickSpacing)
		external
		returns (TwapAggregatorAdapterV2 adapter)
	{
		if (!listers[msg.sender]) revert NotLister();
		if (valueInterpreter.isSupportedAsset(asset)) revert AlreadyPriced(asset);
		if (address(listings[asset].adapter) != address(0)) revert AlreadyListed(asset);

		address pool;
		uint256 depth;
		(adapter, pool, depth) = _qualify(asset, quote, venue, feeOrTickSpacing);

		listedAssets.push(asset);
		listings[asset] = Listing(adapter, pool, quote, uint64(block.timestamp), 0);
		venueOf[asset] = venue;
		emit Listed(asset, address(adapter), pool, quote, venue, depth);
		_recordDepth(asset, depth);
	}

	/// @notice Move `asset`'s listing to another canonical pool: at least REPOINT_MARGIN_BPS
	///         deeper, or any qualifying pool while the current one is under the floor / unanswerable.
	function repoint(address asset, address quote, Venue venue, int24 feeOrTickSpacing)
		external
		returns (TwapAggregatorAdapterV2 adapter)
	{
		if (!listers[msg.sender]) revert NotLister();
		Listing storage l = listings[asset];
		if (address(l.adapter) == address(0)) revert NotListed(asset);

		address pool;
		uint256 depth;
		(adapter, pool, depth) = _qualify(asset, quote, venue, feeOrTickSpacing);
		if (pool == l.pool) revert SamePool(pool);

		(bool currentOk, uint256 currentDepth) = _currentDepth(l.adapter);
		if (currentOk && depth < Math.mulDiv(currentDepth, REPOINT_MARGIN_BPS, BPS)) {
			revert NotDeepEnough(currentDepth, depth);
		}

		l.adapter = adapter;
		l.pool = pool;
		l.quote = quote;
		l.belowFloorSince = 0;
		venueOf[asset] = venue;
		emit Repointed(asset, address(adapter), pool, quote, venue, depth);
		_recordDepth(asset, depth);
	}

	/// @notice Start or clear `asset`'s 72-hour clock from the pool's current state; a pool that can
	///         no longer serve the window counts as under the floor. Anyone may start the clock. Only
	///         a lister may clear it (for anyone else that case is a no-op, not a revert), and a
	///         lister's poke also records the live depth (0 if the pool can't answer).
	/// @return below whether the pool is under the floor now
	function pokeFloor(address asset) external returns (bool below) {
		Listing storage l = listings[asset];
		if (address(l.adapter) == address(0)) revert NotListed(asset);
		// the adapter's isBelowFloor() is exactly this: every adapter here was built with MIN_DEPTH_USD
		(bool ok, uint256 depth) = _currentDepth(l.adapter);
		below = !ok;
		bool byLister = listers[msg.sender];
		if (below && l.belowFloorSince == 0) {
			l.belowFloorSince = uint64(block.timestamp);
			emit FloorBreached(asset, block.timestamp);
		} else if (!below && l.belowFloorSince != 0 && byLister) {
			l.belowFloorSince = 0;
			emit FloorRestored(asset);
		}
		if (byLister) _recordDepth(asset, depth);
	}

	// ─── views ──────────────────────────────────────────────────────────────────

	/// @notice The adapter a listing prices through; 0 if never listed.
	function adapterOf(address asset) external view returns (address) {
		return address(listings[asset].adapter);
	}

	/// @notice True once the pool has been under the floor for DELIST_GRACE (as of the last poke).
	function isDelisted(address asset) public view returns (bool) {
		uint64 since = listings[asset].belowFloorSince;
		return since != 0 && block.timestamp >= since + DELIST_GRACE;
	}

	/// @notice True while the VI prices `asset` through this registry's adapter (what the
	///         exposure policy caps and what `repoint` may rewrite).
	function isTwapPriced(address asset) public view returns (bool) {
		Listing storage l = listings[asset];
		if (address(l.adapter) == address(0)) return false;
		(address aggregator,,,) = IValueInterpreterAssetInfo(address(valueInterpreter)).getAssetInfo(asset);
		return aggregator == address(l.adapter);
	}

	function getListedAssets() external view returns (address[] memory) {
		return listedAssets;
	}

	function listedCount() external view returns (uint256) {
		return listedAssets.length;
	}

	/// @notice `limit` listed assets from `offset`, in listing order; empty past the end.
	function getListedAssetsPage(uint256 offset, uint256 limit) external view returns (address[] memory page) {
		uint256 n = listedAssets.length;
		if (offset >= n) return new address[](0);
		uint256 end = limit > n - offset ? n : offset + limit;
		page = new address[](end - offset);
		for (uint256 i = offset; i < end; ++i) {
			page[i - offset] = listedAssets[i];
		}
	}

	// ─── internals ──────────────────────────────────────────────────────────────

	/// @dev Resolve the canonical pool (spacing ≥ MIN_TICK_SPACING, cardinality ≥
	///      MIN_OBSERVATION_CARDINALITY), deploy its adapter, and require it to price now and hold
	///      the quote-side floor.
	function _qualify(address asset, address quote, Venue venue, int24 feeOrTickSpacing)
		internal
		returns (TwapAggregatorAdapterV2 adapter, address pool, uint256 depth)
	{
		Quote memory q = quotes[quote];
		if (address(q.feed) == address(0)) revert QuoteNotAllowed(quote);

		pool = _getPool(asset, quote, venue, feeOrTickSpacing);
		if (pool == address(0)) revert PoolNotFound(asset, quote);
		int24 spacing = IConcentratedPoolOracle(pool).tickSpacing();
		if (spacing < MIN_TICK_SPACING) revert TickSpacingTooFine(spacing);
		_requireObservationCardinality(pool);

		adapter = new TwapAggregatorAdapterV2(
			IConcentratedPoolOracle(pool),
			asset,
			q.feed,
			WINDOW,
			MIN_DEPTH_USD,
			MAX_DEVIATION_BPS,
			q.heartbeat,
			string.concat(IERC20Metadata(asset).symbol(), ' / USD (TWAP)')
		);
		// must price NOW (window served, spot on the average) with the quote side over the floor
		adapter.latestRoundData();
		depth = adapter.poolDepthUsd();
		if (depth < MIN_DEPTH_USD * 1e18) revert BelowFloorAtListing(depth);
	}

	/// @dev Revert unless `pool` holds MIN_OBSERVATION_CARDINALITY observations.
	function _requireObservationCardinality(address pool) internal view {
		uint16 cardinality = _observationCardinality(pool);
		if (cardinality < MIN_OBSERVATION_CARDINALITY) revert ObservationCardinalityTooLow(cardinality);
	}

	/// @dev slot0's fourth word, observationCardinality. Uniswap v3 and Slipstream share the first
	///      four words (sqrtPriceX96, tick, observationIndex, observationCardinality) and differ only
	///      after them; a failed or short read counts as 0.
	function _observationCardinality(address pool) internal view returns (uint16 cardinality) {
		(bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature('slot0()'));
		if (!ok || data.length < 128) return 0;
		(,,, cardinality) = abi.decode(data, (uint160, int24, uint16, uint16));
	}

	function _getPool(address asset, address quote, Venue venue, int24 feeOrTickSpacing) internal view returns (address) {
		if (venue == Venue.UniswapV3) {
			if (feeOrTickSpacing <= 0) return address(0);
			return uniswapFactory.getPool(asset, quote, uint24(feeOrTickSpacing));
		}
		ISlipstreamPoolFactory f = venue == Venue.Slipstream
			? slipstreamFactory
			: (venue == Venue.Slipstream2 ? slipstream2Factory : slipstream3Factory);
		return f.getPool(asset, quote, feeOrTickSpacing);
	}

	/// @dev (answerable, depth) of the current adapter; an adapter that reverts or sits under the
	///      floor counts as not answerable, so any qualifying pool may replace it. A read that ran
	///      out of gas (only the 1/64 kept back by EIP-150 is left) with under MIN_READ_GAS available
	///      is the caller's shortfall: it reverts ReadOutOfGas, so a starved call never counts a pool
	///      as under the floor. One that runs dry with MIN_READ_GAS or more is the pool's own failure
	///      (e.g. dust on thousands of ticks) and counts as unanswerable, so the clock can still start
	///      and a repoint can still move the listing.
	function _currentDepth(TwapAggregatorAdapterV2 adapter) internal view returns (bool ok, uint256 depth) {
		uint256 gasBefore = gasleft();
		try adapter.poolDepthUsd() returns (uint256 d) {
			return (d >= MIN_DEPTH_USD * 1e18, d);
		} catch {
			if (gasleft() <= gasBefore / 63 && gasBefore < MIN_READ_GAS) revert ReadOutOfGas();
			return (false, 0);
		}
	}

	/// @dev Only lister paths reach this: `list`, `repoint`, and a lister's `pokeFloor`.
	function _recordDepth(address asset, uint256 depthUsd18) internal {
		recordedDepthUsd18[asset] = depthUsd18;
		emit DepthRecorded(asset, depthUsd18);
	}
}
