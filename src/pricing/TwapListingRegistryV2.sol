// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {AggregatorV3Interface} from '../interfaces/AggregatorV3Interface.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {ITwapPriceAdapter} from '../interfaces/ITwapPriceAdapter.sol';
import {TwapFloor} from '../libraries/TwapFloor.sol';
import {IConcentratedPoolOracle} from './TwapAggregatorAdapter.sol';
import {IAerodromeBasicPool} from './AerodromeBasicTwapAdapter.sol';
import {IUniswapV2Pair, UniswapV2ObservationRecorder} from './UniswapV2ObservationRecorder.sol';
import {
	ConcentratedTwapAdapterDeployer,
	UniswapV2TwapAdapterDeployer,
	AerodromeBasicTwapAdapterDeployer
} from './TwapAdapterDeployers.sol';
import {IUniswapV3PoolFactory, ISlipstreamPoolFactory, IValueInterpreterAssetInfo} from './TwapListingRegistry.sol';

/// @notice Uniswap v2 factory (Base 0x8909…8eC6): the pair of two tokens in either order, 0 if none.
interface IUniswapV2Factory {
	function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// @notice Aerodrome basic PoolFactory (Base 0x420D…40Da): the pool of two tokens in either order
///         on one curve (`stable` = sAMM, else vAMM x·y=k), 0 if none.
interface IAerodromeBasicFactory {
	function getPool(address tokenA, address tokenB, bool stable) external view returns (address pool);
}

/// @title TwapListingRegistryV2
/// @notice Lists long-tail assets on the TWAP price tier, open to automation: a listing is
///         checked, not trusted.
///         - The pool comes from a canonical factory on one of six venues: Uniswap v3, Aerodrome's
///           three Slipstream deployments (concentrated liquidity), Uniswap v2 (`getPair`) and
///           Aerodrome basic (`getPool(asset, quote, false)`: VOLATILE pools only — a stable sAMM
///           pool is never listed). Uniswap v2 and Aerodrome basic have one pool per pair, so
///           their `feeOrTickSpacing` must be 0.
///         - Concentrated pools only: tick spacing at least MIN_TICK_SPACING (10) — Uniswap v3 fee
///           tiers 100/200/300/400 (spacing 1/4/6/8 on Base) and Slipstream spacing 1 are refused —
///           and at least MIN_OBSERVATION_CARDINALITY (300) observations, so ordinary trading can't
///           push the 30-minute window out of its oracle history. Uniswap v2 pairs are priced from
///           the permissionless UniswapV2ObservationRecorder's snapshots; Aerodrome basic pools
///           from their own observations.
///         - The quote token is allow-listed with its Chainlink USD feed (USDC, WETH).
///         - The asset has no price in the ValueInterpreter yet (a higher tier always wins).
///         - The adapter is built with fixed parameters (by one of three stateless deployers, so
///           this contract holds no adapter code), must price now, and must hold the floor.
///         The floor is two-part (Ruling 23) and gates listing and the delist clock: the QUOTE
///         RESERVE (the USDC/WETH the pool holds × its feed) ≥ MIN_QUOTE_RESERVE_USD AND the BAND
///         DEPTH (quote-token bids within −10% of the price) ≥ MIN_BAND_DEPTH_USD — what a
///         full-range pool holding the reserve floor has within −10%. A balance alone is not bids:
///         a concentrated pool's balance includes uncollected fees, liquidity removed but never
///         collected, and donations, so a pool rugged without collecting keeps its reserve with
///         nothing near the price; the band floor catches it. Uniswap v2 and Aerodrome basic pools
///         hold (1 − √0.9) of their reserve in band, so for them the band floor follows from the
///         reserve floor. The band is also what a lister records (`recordedDepthUsd18`, sizing the
///         exposure caps) and what the repoint margin compares. The asset's own side is never
///         counted in either read: a self-priced token can't inflate them.
///         `repoint` moves a listing to a pool whose band is at least 25% deeper, or to any
///         qualifying pool once the current one is under the floor (or can't be read).
///         `pokeFloor` runs the 72-hour delist clock: anyone may START it; only a lister may CLEAR
///         it (for anyone else that case is a no-op) or record depth (also written by `list` and
///         `repoint`).
/// @dev Listers are granted explicitly (the PriceListingModule, which also writes the VI
///      primitive in the same transaction). `listings()` keeps v1's 5-field shape so v1 readers
///      (TwapFloorLens) keep working.
/// @dev Liquidity added and removed in the same transaction can inflate any reserve or depth
///      snapshot, so it must never clear a clock or raise a recorded depth; a real shortfall can't
///      be faked upward.
contract TwapListingRegistryV2 is Ownable2Step {
	/// @notice Fixed adapter parameters, not the lister's choice.
	uint32 public constant WINDOW = 30 minutes;
	uint16 public constant MAX_DEVIATION_BPS = 500;
	/// @notice The floor's reserve part (listing and delist clock), whole USD: the QUOTE token
	///         (USDC/WETH) the pool holds × its Chainlink feed. ≈ $50k of pool liquidity, counted as
	///         twice the real USDC/WETH so a token's self-priced side can't inflate it.
	uint256 public constant MIN_QUOTE_RESERVE_USD = 25_000;
	/// @notice The floor's band part (listing and delist clock), whole USD: quote-token bids within
	///         −10% of the price. floor(25,000 × 51,316 / 1e6) = 1,282, what a full-range x·y=k pool
	///         holding exactly MIN_QUOTE_RESERVE_USD of quote has within −10%; every adapter built
	///         here derives the same minBandDepthUsd (TwapFloor.minBandDepthUsd(MIN_QUOTE_RESERVE_USD)).
	uint256 public constant MIN_BAND_DEPTH_USD = MIN_QUOTE_RESERVE_USD * TwapFloor.BAND_QUOTE_PPM / 1e6;
	/// @notice How long a pool may stay under the floor before its asset is delisted.
	uint256 public constant DELIST_GRACE = 72 hours;
	/// @notice A repoint must reach a pool whose band is this much deeper (125%), unless the current
	///         one is under the floor.
	uint256 public constant REPOINT_MARGIN_BPS = 12_500;
	/// @notice Concentrated pools finer than this are refused: their depth walk can be bloated with
	///         dust ticks past any transaction's gas (a spacing-1 pool measured 26.5M), while at
	///         spacing ≥ 10 even a fully initialized ±10% band costs about 4.2M, so MIN_READ_GAS is a
	///         real ceiling. The pools lost are stable or correlated pairs.
	int24 public constant MIN_TICK_SPACING = 10;
	/// @notice Concentrated pools must hold at least this many oracle observations. With one (common
	///         on young pools), any tick-changing trade leaves the pool unable to serve the 30-minute
	///         window for 30 minutes, pausing NAV-dependent actions of every fund holding the asset;
	///         300 removes that organic failure. Not window / block time (~900): a pool grows its
	///         ring only when a write lands on its last slot, so demanding 901 would stall listings
	///         of the existing 300–600 pools; the keeper calls increaseObservationCardinalityNext(901)
	///         on listed pools so they harden after their next wrap. Residual: a paid griefer making
	///         ≥ 300 tick-changing swaps in distinct blocks within 30 minutes; that pauses only
	///         NAV-dependent actions — sales and in-kind exits stay open.
	uint16 public constant MIN_OBSERVATION_CARDINALITY = 300;
	/// @notice Gas a reserve or band read is guaranteed; a caller that forwards less and runs it
	///         dry gets ReadOutOfGas, while a read that exhausts at least this much counts as
	///         unanswerable. It is a ceiling because of MIN_TICK_SPACING: no listable pool's honest
	///         read, dust included, comes near it.
	uint256 public constant MIN_READ_GAS = 8_000_000;
	uint256 private constant BPS = 10_000;

	/// @dev Append-only: the indices are stored (venueOf) and emitted.
	enum Venue {
		UniswapV3,
		Slipstream,
		Slipstream2,
		Slipstream3,
		UniswapV2,
		AerodromeBasic
	}

	/// @notice Everything the registry is wired to, fixed at construction; every field is required.
	struct Venues {
		IValueInterpreter valueInterpreter;
		IUniswapV3PoolFactory uniswapV3;
		ISlipstreamPoolFactory slipstream;
		ISlipstreamPoolFactory slipstream2;
		ISlipstreamPoolFactory slipstream3;
		IUniswapV2Factory uniswapV2;
		IAerodromeBasicFactory aerodromeBasic;
		UniswapV2ObservationRecorder recorder;
		ConcentratedTwapAdapterDeployer clDeployer;
		UniswapV2TwapAdapterDeployer v2Deployer;
		AerodromeBasicTwapAdapterDeployer aeroDeployer;
	}

	struct Quote {
		AggregatorV3Interface feed;
		uint32 heartbeat;
	}

	struct Listing {
		ITwapPriceAdapter adapter;
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
	IUniswapV2Factory public immutable uniswapV2Factory;
	IAerodromeBasicFactory public immutable aerodromeBasicFactory;
	/// @notice The snapshots every Uniswap v2 adapter here prices from.
	UniswapV2ObservationRecorder public immutable recorder;
	ConcentratedTwapAdapterDeployer public immutable clDeployer;
	UniswapV2TwapAdapterDeployer public immutable v2Deployer;
	AerodromeBasicTwapAdapterDeployer public immutable aeroDeployer;

	mapping(address => Quote) public quotes;
	mapping(address => Listing) public listings;
	mapping(address => Venue) public venueOf;
	mapping(address => bool) public listers;
	/// @notice The band depth last recorded by a lister (USD, 18 decimals).
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
	error BelowFloorAtListing(uint256 quoteReserveUsd18);
	/// @notice The pool holds the reserve floor but its band is under MIN_BAND_DEPTH_USD (a separate
	///         error so a keeper sees which part failed).
	error BandBelowFloorAtListing(uint256 depthUsd18);
	error NotDeepEnough(uint256 currentDepthUsd18, uint256 newDepthUsd18);
	error ReadOutOfGas();
	error TickSpacingTooFine(int24 tickSpacing);
	error ObservationCardinalityTooLow(uint16 cardinality);

	constructor(Venues memory venues) Ownable(msg.sender) {
		if (
			address(venues.valueInterpreter) == address(0) || address(venues.uniswapV3) == address(0)
				|| address(venues.slipstream) == address(0) || address(venues.slipstream2) == address(0)
				|| address(venues.slipstream3) == address(0) || address(venues.uniswapV2) == address(0)
				|| address(venues.aerodromeBasic) == address(0) || address(venues.recorder) == address(0)
				|| address(venues.clDeployer) == address(0) || address(venues.v2Deployer) == address(0)
				|| address(venues.aeroDeployer) == address(0)
		) {
			revert ZeroAddress();
		}
		valueInterpreter = venues.valueInterpreter;
		uniswapFactory = venues.uniswapV3;
		slipstreamFactory = venues.slipstream;
		slipstream2Factory = venues.slipstream2;
		slipstream3Factory = venues.slipstream3;
		uniswapV2Factory = venues.uniswapV2;
		aerodromeBasicFactory = venues.aerodromeBasic;
		recorder = venues.recorder;
		clDeployer = venues.clDeployer;
		v2Deployer = venues.v2Deployer;
		aeroDeployer = venues.aeroDeployer;
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

	/// @notice List `asset` against `quote` on the canonical pool of `venue` (`feeOrTickSpacing`:
	///         Uniswap v3 fee tier, Slipstream tick spacing, 0 for Uniswap v2 and Aerodrome basic).
	function list(address asset, address quote, Venue venue, int24 feeOrTickSpacing)
		external
		returns (ITwapPriceAdapter adapter)
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

	/// @notice Move `asset`'s listing to another canonical pool whose band is at least
	///         REPOINT_MARGIN_BPS deeper — or to any qualifying pool while the current one is under
	///         the two-part floor (either read under it or unanswerable).
	function repoint(address asset, address quote, Venue venue, int24 feeOrTickSpacing)
		external
		returns (ITwapPriceAdapter adapter)
	{
		if (!listers[msg.sender]) revert NotLister();
		Listing storage l = listings[asset];
		if (address(l.adapter) == address(0)) revert NotListed(asset);

		address pool;
		uint256 depth;
		(adapter, pool, depth) = _qualify(asset, quote, venue, feeOrTickSpacing);
		if (pool == l.pool) revert SamePool(pool);

		// over the floor means the band was read: the margin is measured against it
		(bool floorOk,, uint256 currentDepth) = _currentFloor(l.adapter);
		if (floorOk && depth < Math.mulDiv(currentDepth, REPOINT_MARGIN_BPS, BPS)) {
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

	/// @notice Start or clear `asset`'s 72-hour clock from the pool's current two-part floor (quote
	///         reserve and band depth); a pool that can no longer serve the window, or either read
	///         that can't be answered, counts as under the floor. Anyone may start the clock. Only a
	///         lister may clear it (for anyone else that case is a no-op, not a revert), and a
	///         lister's poke also records the live band depth (0 if it can't be read).
	/// @return below whether the pool is under the floor now
	function pokeFloor(address asset) external returns (bool below) {
		Listing storage l = listings[asset];
		if (address(l.adapter) == address(0)) revert NotListed(asset);
		// the adapter's isBelowFloor() is this test: every adapter here was built with
		// MIN_QUOTE_RESERVE_USD, so its minBandDepthUsd is MIN_BAND_DEPTH_USD
		(bool floorOk, bool bandRead, uint256 depth) = _currentFloor(l.adapter);
		below = !floorOk;
		bool byLister = listers[msg.sender];
		if (below && l.belowFloorSince == 0) {
			l.belowFloorSince = uint64(block.timestamp);
			emit FloorBreached(asset, block.timestamp);
		} else if (!below && l.belowFloorSince != 0 && byLister) {
			l.belowFloorSince = 0;
			emit FloorRestored(asset);
		}
		if (byLister) {
			if (!bandRead) (, depth) = _currentBandDepth(l.adapter);
			_recordDepth(asset, depth);
		}
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

	/// @dev Resolve the canonical pool, build its adapter through the venue's deployer (concentrated
	///      pools first pass spacing ≥ MIN_TICK_SPACING and cardinality ≥ MIN_OBSERVATION_CARDINALITY),
	///      require it to price now and hold both parts of the floor, and return its band depth.
	function _qualify(address asset, address quote, Venue venue, int24 feeOrTickSpacing)
		internal
		returns (ITwapPriceAdapter adapter, address pool, uint256 depth)
	{
		Quote memory q = quotes[quote];
		if (address(q.feed) == address(0)) revert QuoteNotAllowed(quote);

		pool = _getPool(asset, quote, venue, feeOrTickSpacing);
		if (pool == address(0)) revert PoolNotFound(asset, quote);
		if (venue == Venue.UniswapV2) {
			adapter = _deployUniswapV2(IUniswapV2Pair(pool), asset, q);
		} else if (venue == Venue.AerodromeBasic) {
			adapter = _deployAerodromeBasic(IAerodromeBasicPool(pool), asset, q);
		} else {
			int24 spacing = IConcentratedPoolOracle(pool).tickSpacing();
			if (spacing < MIN_TICK_SPACING) revert TickSpacingTooFine(spacing);
			_requireObservationCardinality(pool);
			adapter = _deployConcentrated(IConcentratedPoolOracle(pool), asset, q);
		}
		// must price NOW (window served, spot on the average) and hold the floor: reserve, then band
		adapter.latestRoundData();
		uint256 reserve = adapter.quoteReserveUsd();
		if (reserve < MIN_QUOTE_RESERVE_USD * 1e18) revert BelowFloorAtListing(reserve);
		depth = adapter.poolDepthUsd();
		if (depth < MIN_BAND_DEPTH_USD * 1e18) revert BandBelowFloorAtListing(depth);
	}

	function _deployConcentrated(IConcentratedPoolOracle pool, address asset, Quote memory q)
		internal
		returns (ITwapPriceAdapter)
	{
		return ITwapPriceAdapter(
			clDeployer.deploy(
				pool, asset, q.feed, WINDOW, MIN_QUOTE_RESERVE_USD, MAX_DEVIATION_BPS, q.heartbeat, _description(asset)
			)
		);
	}

	function _deployUniswapV2(IUniswapV2Pair pair, address asset, Quote memory q) internal returns (ITwapPriceAdapter) {
		return ITwapPriceAdapter(
			v2Deployer.deploy(
				pair, asset, q.feed, recorder, WINDOW, MIN_QUOTE_RESERVE_USD, MAX_DEVIATION_BPS, q.heartbeat, _description(asset)
			)
		);
	}

	function _deployAerodromeBasic(IAerodromeBasicPool pool, address asset, Quote memory q)
		internal
		returns (ITwapPriceAdapter)
	{
		return ITwapPriceAdapter(
			aeroDeployer.deploy(
				pool, asset, q.feed, WINDOW, MIN_QUOTE_RESERVE_USD, MAX_DEVIATION_BPS, q.heartbeat, _description(asset)
			)
		);
	}

	function _description(address asset) internal view returns (string memory) {
		return string.concat(IERC20Metadata(asset).symbol(), ' / USD (TWAP)');
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

	/// @dev The venue's canonical pool, 0 if none. Uniswap v2 and Aerodrome basic have one pool per
	///      pair (volatile, for Aerodrome), so a nonzero fee / spacing names none and the factory is
	///      not asked.
	function _getPool(address asset, address quote, Venue venue, int24 feeOrTickSpacing) internal view returns (address) {
		if (venue == Venue.UniswapV3) {
			if (feeOrTickSpacing <= 0) return address(0);
			return uniswapFactory.getPool(asset, quote, uint24(feeOrTickSpacing));
		}
		if (venue == Venue.UniswapV2) {
			if (feeOrTickSpacing != 0) return address(0);
			return uniswapV2Factory.getPair(asset, quote);
		}
		if (venue == Venue.AerodromeBasic) {
			if (feeOrTickSpacing != 0) return address(0);
			return aerodromeBasicFactory.getPool(asset, quote, false);
		}
		ISlipstreamPoolFactory f = venue == Venue.Slipstream
			? slipstreamFactory
			: (venue == Venue.Slipstream2 ? slipstream2Factory : slipstream3Factory);
		return f.getPool(asset, quote, feeOrTickSpacing);
	}

	/// @dev The current adapter against the two-part floor: (over it, band read, band depth). Over =
	///      the quote reserve ≥ MIN_QUOTE_RESERVE_USD AND the band ≥ MIN_BAND_DEPTH_USD, both answered;
	///      a read that reverts counts as under, so the clock can start and any qualifying pool may
	///      replace it. Like the adapters' isBelowFloor(), the band is read only once the reserve
	///      holds (`bandRead`; its depth is 0 if that read reverted), so a pool already under on its
	///      reserve costs no band walk. Each read has its own MIN_READ_GAS guard.
	function _currentFloor(ITwapPriceAdapter adapter) internal view returns (bool ok, bool bandRead, uint256 depthUsd) {
		(bool reserveOk, uint256 reserveUsd) = _currentReserve(adapter);
		if (!reserveOk || reserveUsd < MIN_QUOTE_RESERVE_USD * 1e18) return (false, false, 0);
		bool bandOk;
		(bandOk, depthUsd) = _currentBandDepth(adapter);
		return (bandOk && depthUsd >= MIN_BAND_DEPTH_USD * 1e18, true, depthUsd);
	}

	/// @dev (readable, quote reserve) of the current adapter; a reserve read that reverts is unreadable (0).
	function _currentReserve(ITwapPriceAdapter adapter) internal view returns (bool ok, uint256 reserveUsd) {
		uint256 gasBefore = gasleft();
		try adapter.quoteReserveUsd() returns (uint256 r) {
			return (true, r);
		} catch {
			_revertIfStarved(gasBefore);
			return (false, 0);
		}
	}

	/// @dev (readable, band depth) of the current adapter; a band read that reverts is unreadable (0).
	function _currentBandDepth(ITwapPriceAdapter adapter) internal view returns (bool ok, uint256 depthUsd) {
		uint256 gasBefore = gasleft();
		try adapter.poolDepthUsd() returns (uint256 d) {
			return (true, d);
		} catch {
			_revertIfStarved(gasBefore);
			return (false, 0);
		}
	}

	/// @dev After a read reverted: one that ran out of gas (only the 1/64 kept back by EIP-150 is
	///      left) with under MIN_READ_GAS available is the caller's shortfall — revert ReadOutOfGas, so
	///      a starved call never counts a pool as under the floor or records a 0 band. One that runs
	///      dry with MIN_READ_GAS or more is the pool's own failure (e.g. dust on thousands of ticks)
	///      and counts as unanswerable.
	function _revertIfStarved(uint256 gasBefore) internal view {
		if (gasleft() <= gasBefore / 63 && gasBefore < MIN_READ_GAS) revert ReadOutOfGas();
	}

	/// @dev Only lister paths reach this: `list`, `repoint`, and a lister's `pokeFloor`.
	function _recordDepth(address asset, uint256 depthUsd18) internal {
		recordedDepthUsd18[asset] = depthUsd18;
		emit DepthRecorded(asset, depthUsd18);
	}
}
