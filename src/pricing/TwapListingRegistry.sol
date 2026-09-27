// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {AggregatorV3Interface} from '../interfaces/AggregatorV3Interface.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {TwapAggregatorAdapter, IConcentratedPoolOracle} from './TwapAggregatorAdapter.sol';

interface IUniswapV3PoolFactory {
	function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// @dev ValueInterpreter.getAssetInfo (on the contract, not IValueInterpreter).
interface IValueInterpreterAssetInfo {
	function getAssetInfo(address asset)
		external
		view
		returns (address aggregator, uint32 heartbeat, uint8 assetDecimals, uint8 rateDecimals);
}

interface ISlipstreamPoolFactory {
	function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
}

/// @title TwapListingRegistry
/// @notice Lists long-tail assets on the TWAP price tier (docs/design/twap-oracle.md). A
///         listing is a CHECKED fact, not an owner's say-so about an address:
///         - the pool is resolved from the canonical factory (Uniswap v3 / Aerodrome
///           Slipstream `getPool`), never a caller-supplied address;
///         - the quote side is on an allow-list, each with its Chainlink feed;
///         - the asset must not already have a price in the ValueInterpreter (a higher tier
///           — Chainlink / Pyth — always wins);
///         - the adapter is deployed HERE with the protocol-fixed parameters (30-min window,
///           5% spot deviation, $50k ±10% harmonic-mean depth) and must price right now,
///           every guard passing, with the pool over the $50k floor.
///         After listing, the price keeps flowing even if the pool thins out; what changes is
///         the 72-HOUR CLOCK (founder decision 2026-09-24): `pokeFloor` — callable by anyone,
///         confirmed on-chain — starts it when the pool drops under the floor and clears it
///         when the pool recovers. Past 72h the asset is DELISTED: the terminal stops offering
///         it and the exposure policy pauses NEW deposits into funds still holding it (exits
///         and redemptions stay open; selling the position lifts the pause).
/// @dev Owner-listed at launch (founder decision 2026-09-23): `listers` holds the owner's
///      chosen addresses; a FROST-bond / community-vote module becomes a lister later.
///      This registry does NOT write to the ValueInterpreter — `addPrimitive` stays with
///      the VI owner (one Safe batch: list here, then vi.addPrimitive(asset, adapterOf(asset),
///      heartbeat)). Permissionless listing needs a narrow VI lister role, which ships with
///      that phase as a new VI version, so the deployed VI is untouched now.
contract TwapListingRegistry is Ownable2Step {
	/// @notice Protocol-fixed adapter parameters — not the lister's choice.
	uint32 public constant WINDOW = 30 minutes;
	uint16 public constant MAX_DEVIATION_BPS = 500;
	uint256 public constant MIN_DEPTH_USD = 50_000;
	/// @notice How long a pool may stay under the floor before its asset is delisted.
	uint256 public constant DELIST_GRACE = 72 hours;

	/// @dev Aerodrome runs TWO live Slipstream deployments on Base with liquidity split between
	///      them (verified 2026-09-24: AERO/USDC on the original, WETH/USDC + cbBTC/USDC deepest
	///      on the newer "gauges v3" one) — both are canonical, so both are listable.
	enum Venue {
		UniswapV3,
		Slipstream,
		Slipstream2
	}

	struct Quote {
		AggregatorV3Interface feed;
		uint32 heartbeat;
	}

	struct Listing {
		TwapAggregatorAdapter adapter;
		address pool;
		address quote;
		uint64 listedAt;
		uint64 belowFloorSince; // 0 = at/over the floor (as of the last poke)
	}

	IValueInterpreter public immutable valueInterpreter;
	IUniswapV3PoolFactory public immutable uniswapFactory;
	ISlipstreamPoolFactory public immutable slipstreamFactory;
	ISlipstreamPoolFactory public immutable slipstream2Factory;

	mapping(address => Quote) public quotes;
	mapping(address => Listing) public listings;
	mapping(address => bool) public listers;
	address[] internal listedAssets;

	event QuoteSet(address indexed quote, address feed, uint32 heartbeat);
	event ListerSet(address indexed lister, bool allowed);
	event Listed(address indexed asset, address indexed adapter, address pool, address quote, Venue venue);
	event FloorBreached(address indexed asset, uint256 since);
	event FloorRestored(address indexed asset);

	error ZeroAddress();
	error NotLister();
	error QuoteNotAllowed(address quote);
	error AlreadyPriced(address asset);
	error AlreadyListed(address asset);
	error NotListed(address asset);
	error PoolNotFound(address asset, address quote);
	error BelowFloorAtListing(uint256 depthUsd18);

	constructor(
		IValueInterpreter valueInterpreter_,
		IUniswapV3PoolFactory uniswapFactory_,
		ISlipstreamPoolFactory slipstreamFactory_,
		ISlipstreamPoolFactory slipstream2Factory_
	) Ownable(msg.sender) {
		if (
			address(valueInterpreter_) == address(0) || address(uniswapFactory_) == address(0)
				|| address(slipstreamFactory_) == address(0) || address(slipstream2Factory_) == address(0)
		) {
			revert ZeroAddress();
		}
		valueInterpreter = valueInterpreter_;
		uniswapFactory = uniswapFactory_;
		slipstreamFactory = slipstreamFactory_;
		slipstream2Factory = slipstream2Factory_;
		listers[msg.sender] = true;
		emit ListerSet(msg.sender, true);
	}

	// ─── owner config ───────────────────────────────────────────────────────────

	/// @notice Allow a quote token (USDC, WETH, cbBTC…) with its Chainlink USD feed;
	///         feed = 0 disallows it for NEW listings.
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
		returns (TwapAggregatorAdapter adapter)
	{
		if (!listers[msg.sender]) revert NotLister();
		Quote memory q = quotes[quote];
		if (address(q.feed) == address(0)) revert QuoteNotAllowed(quote);
		if (valueInterpreter.isSupportedAsset(asset)) revert AlreadyPriced(asset);
		if (address(listings[asset].adapter) != address(0)) revert AlreadyListed(asset);

		address pool = venue == Venue.UniswapV3
			? uniswapFactory.getPool(asset, quote, uint24(feeOrTickSpacing))
			: (venue == Venue.Slipstream ? slipstreamFactory : slipstream2Factory).getPool(asset, quote, feeOrTickSpacing);
		if (pool == address(0)) revert PoolNotFound(asset, quote);

		adapter = new TwapAggregatorAdapter(
			IConcentratedPoolOracle(pool),
			asset,
			q.feed,
			WINDOW,
			MIN_DEPTH_USD,
			MAX_DEVIATION_BPS,
			q.heartbeat,
			string.concat(IERC20Metadata(asset).symbol(), ' / USD (TWAP)')
		);
		// must price NOW (window served, spot on the average) with the pool over the floor
		adapter.latestRoundData();
		if (adapter.isBelowFloor()) revert BelowFloorAtListing(adapter.poolDepthUsd());

		listedAssets.push(asset);
		listings[asset] = Listing(adapter, pool, quote, uint64(block.timestamp), 0);
		emit Listed(asset, address(adapter), pool, quote, venue);
	}

	/// @notice Start or clear `asset`'s 72-hour clock from the pool's state RIGHT NOW. Anyone
	///         may call it (the keeper does, every pass; a manager whose pool recovered can clear
	///         it) — the chain, not the caller, decides. A pool that can no longer serve the
	///         window counts as under the floor.
	/// @return below whether the pool is under the floor now
	function pokeFloor(address asset) external returns (bool below) {
		Listing storage l = listings[asset];
		if (address(l.adapter) == address(0)) revert NotListed(asset);
		try l.adapter.isBelowFloor() returns (bool b) {
			below = b;
		} catch {
			below = true;
		}
		if (below && l.belowFloorSince == 0) {
			l.belowFloorSince = uint64(block.timestamp);
			emit FloorBreached(asset, block.timestamp);
		} else if (!below && l.belowFloorSince != 0) {
			l.belowFloorSince = 0;
			emit FloorRestored(asset);
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

	/// @notice True while the VI prices `asset` through this registry's adapter — the
	///         definition of a TWAP-tier holding the exposure policy caps.
	function isTwapPriced(address asset) public view returns (bool) {
		Listing storage l = listings[asset];
		if (address(l.adapter) == address(0)) return false;
		(address aggregator,,,) = IValueInterpreterAssetInfo(address(valueInterpreter)).getAssetInfo(asset);
		return aggregator == address(l.adapter);
	}

	function getListedAssets() external view returns (address[] memory) {
		return listedAssets;
	}
}
