// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Strings} from '@openzeppelin/contracts/utils/Strings.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {PriceMarker} from '../../src/pricing/PriceMarker.sol';
import {VerantaPriceStore} from '../../src/pricing/VerantaPriceStore.sol';
import {VerantaPriceAdapter} from '../../src/pricing/VerantaPriceAdapter.sol';
import {VerantaPriceAdapterV2} from '../../src/pricing/VerantaPriceAdapterV2.sol';
import {VerantaPriceStoreV2} from '../../src/pricing/VerantaPriceStoreV2.sol';
import {ViAdmin} from './ListingModuleBook.sol';
import {FundsMainnet} from './FundsMainnet.sol';

/// @notice Veranta's PairStorage views the listing walks (verified ABI, impl 0x2511bF7e…).
interface IVerantaPairCatalog {
	function pairsCount() external view returns (uint256);

	function pairData(uint256 pairIndex) external view returns (string memory from, string memory to, uint256 numTiers);

	function getLazerFeedId(uint256 pairIndex) external view returns (uint256);

	function pairGroupIndex(uint256 pairIndex) external view returns (uint256);
}

/// @title VerantaListing
/// @notice Makes every Veranta pair tradeable by funds, priced at Veranta's own settlement price:
///         for each listed, Lazer-priced pair that is still unmapped, a PriceMarker + a
///         VerantaPriceAdapter on the store, registered as a VI primitive, then `setPairAsset`.
///         Pairs already mapped (genesis ETH/BTC, the Coinbase stock perps) are left as they are,
///         so running it twice is a no-op. Driven entirely by Veranta's on-chain catalog.
///         Price lifetime: 10 minutes for every group (prices on demand, founder 2026-10-05 —
///         PLAN_PERP_PULL_PRICING): whatever values a fund stores Veranta's current price first, so
///         an old price is never used. It was 1 hour for crypto and 5 days for closed-market groups
///         while a keeper pushed on a schedule. Lazer publishes closed-market prices too, so a
///         weekend never blocks a fund. The primitive is added through the VI's owner
///         (`admin.execute`: the pool-pricing registrar, through registrar V2 since 2026-10-09; see ListingModuleBook).
library VerantaListing {
	/// @notice Pyth Lazer's verifier on Base — the one Veranta's PriceAggregator uses.
	address internal constant PYTH_LAZER_VERIFIER = 0xACeA761c27A909d4D3895128EBe6370FDE2dF481;
	IVerantaPairCatalog internal constant CATALOG = IVerantaPairCatalog(FundsMainnet.VERANTA_PAIR_STORAGE);
	/// @notice How old a stored Veranta price may be when the VI reads it (the primitive's heartbeat).
	uint32 internal constant PRICE_LIFETIME = 10 minutes;
	/// @notice A closing market's last trade may be this old (VerantaPriceAdapterV2.maxFeedAge and the primitive's heartbeat):
	///         the same 5 days as a Coinbase stock's Chainlink primitive, over FundValuationV6.SESSION_HEARTBEAT.
	uint32 internal constant CLOSED_MARKET_LIFETIME = 5 days;

	/// @notice One pair moved by moveClosingMarkets, for the address book and an undo.
	struct MovedPair {
		uint256 pairIndex;
		address marker;
		address oldAdapter;
		address adapter;
	}

	function listAll(VerantaPriceStore store, ViAdmin memory admin, VerantaPerpPositionV2Factory factory)
		internal
		returns (uint256 listed)
	{
		uint256 count = CATALOG.pairsCount();
		for (uint256 i; i < count; ++i) {
			if (factory.pairAsset(i) != address(0)) continue;
			(string memory from,,) = CATALOG.pairData(i);
			if (bytes(from).length == 0 || CATALOG.getLazerFeedId(i) == 0) continue;
			_listPair(store, admin, factory, i);
			++listed;
		}
	}

	/// @notice Stock perps priced at Veranta's own price (founder 2026-10-06): each pair in `pairs`, still
	///         mapped to its Coinbase stock token `tokens[k]` (deployments/base-mainnet-stock-hedges.json),
	///         is listed like every other pair (marker + store adapter + 10-minute primitive) and re-pointed
	///         to the marker. Its perp is then valued at the price it settles at, not the token's Chainlink
	///         feed (which lags Veranta by up to ~0.4% in market hours, and prices GOOGL against Veranta's
	///         GOOG perp: ~0.9% on 2026-10-06), and a stock split no longer mis-values it.
	///         A pair already on a store marker is skipped, so a second run is a no-op. Anything else
	///         (unmapped, mapped elsewhere, no Lazer feed) reverts, so a stale table can't re-point a pair.
	///         It can't see fund holdings: re-pointing a pair a fund holds drops that trade's coin leg
	///         from NAV (perps review 2026-10-05, must-fix 2), so the caller checks every pair is clear
	///         first (funds-keeper src/tools/pair-holders.ts).
	function repointToStore(
		VerantaPriceStore store,
		ViAdmin memory admin,
		VerantaPerpPositionV2Factory factory,
		ValueInterpreter vi,
		uint256[] memory pairs,
		address[] memory tokens
	) internal returns (uint256 repointed) {
		require(pairs.length == tokens.length, 'pairs/tokens length');
		for (uint256 k; k < pairs.length; ++k) {
			uint256 i = pairs[k];
			address current = factory.pairAsset(i);
			if (current != address(0)) {
				(address aggregator,,,) = vi.getAssetInfo(current);
				if (_isStoreAdapter(aggregator, store, i)) continue;
			}
			require(current == tokens[k], string.concat('pair ', Strings.toString(i), ' is not mapped to its stock token'));
			require(CATALOG.getLazerFeedId(i) != 0, string.concat('pair ', Strings.toString(i), ' has no Lazer feed'));
			_listPair(store, admin, factory, i);
			++repointed;
		}
	}

	/// @dev Marker + store adapter (10-minute lifetime) + VI primitive, then the pair is mapped to the marker.
	function _listPair(VerantaPriceStore store, ViAdmin memory admin, VerantaPerpPositionV2Factory factory, uint256 i)
		private
		returns (address)
	{
		(string memory from, string memory to,) = CATALOG.pairData(i);
		string memory pair = string.concat(from, '/', to);
		string memory symbol = keccak256(bytes(to)) == keccak256('USD') ? string.concat('vm', from) : string.concat('vm', from, to);
		PriceMarker marker = new PriceMarker(string.concat('Veranta ', pair), symbol);
		VerantaPriceAdapter adapter = new VerantaPriceAdapter(store, i, PRICE_LIFETIME, string.concat(pair, ' (Veranta)'));
		admin.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (address(marker), address(adapter), PRICE_LIFETIME)));
		factory.setPairAsset(i, address(marker));
		return address(marker);
	}

	/// @notice Prices on demand (founder 2026-10-05): every pair priced from `store` gets a
	///         `lifetime` heartbeat in the VI, so a stored price older than that can't value a fund.
	///         Re-registers the SAME adapter (addPrimitive overwrites the entry in one call: the pair
	///         is never unpriced, so it is safe with open fund trades). Pairs priced elsewhere (ETH/BTC
	///         and the stock perps on Chainlink) and pairs already at `lifetime` are left alone, so a
	///         second run is a no-op. Reversible: run again with the old heartbeat.
	function setPriceLifetime(
		VerantaPriceStore store,
		ViAdmin memory admin,
		VerantaPerpPositionV2Factory factory,
		ValueInterpreter vi,
		uint32 lifetime
	) internal returns (uint256 updated) {
		uint256 count = CATALOG.pairsCount();
		for (uint256 i; i < count; ++i) {
			address marker = factory.pairAsset(i);
			if (marker == address(0)) continue;
			(address aggregator, uint32 heartbeat,,) = vi.getAssetInfo(marker);
			if (aggregator == address(0) || heartbeat == lifetime || !_isStoreAdapter(aggregator, store, i)) continue;
			admin.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (marker, aggregator, lifetime)));
			++updated;
		}
	}

	/// @notice Perps on markets that close stay priced while closed (red-team PF-01; founder 2026-11-03): every pair of those
	///         groups still on `storeV1` gets a VerantaPriceAdapterV2 on `storeV2`, registered on its SAME marker at
	///         CLOSED_MARKET_LIFETIME. addPrimitive overwrites the entry in one call, so it is safe with open fund trades.
	///         Crypto trades around the clock and stays where it is. A second run is a no-op.
	function moveClosingMarkets(
		VerantaPriceStore storeV1,
		VerantaPriceStoreV2 storeV2,
		ViAdmin memory admin,
		VerantaPerpPositionV2Factory factory,
		ValueInterpreter vi
	) internal returns (MovedPair[] memory moved) {
		uint256 count = CATALOG.pairsCount();
		MovedPair[] memory rows = new MovedPair[](count);
		uint256 n;
		for (uint256 i; i < count; ++i) {
			address marker = factory.pairAsset(i);
			if (marker == address(0) || !_marketCloses(CATALOG.pairGroupIndex(i))) continue;
			(address aggregator,,,) = vi.getAssetInfo(marker);
			if (aggregator == address(0) || !_isStoreAdapter(aggregator, storeV1, i)) continue;
			(string memory from, string memory to,) = CATALOG.pairData(i);
			VerantaPriceAdapterV2 adapter = new VerantaPriceAdapterV2(
				storeV2, i, PRICE_LIFETIME, CLOSED_MARKET_LIFETIME, string.concat(from, '/', to, ' (Veranta)')
			);
			admin.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (marker, address(adapter), CLOSED_MARKET_LIFETIME)));
			rows[n++] = MovedPair(i, marker, aggregator, address(adapter));
		}
		moved = new MovedPair[](n);
		for (uint256 k; k < n; ++k) moved[k] = rows[k];
	}

	/// @dev Veranta's pair groups that close, read from PairStorage on Base 2026-11-03: 2 FX (EUR, GBP), 3 commodities (XAU,
	///      XAG, WTI), 6 stocks and indices (US500, NVDA). 0, 1, 4 and 5 are crypto.
	function _marketCloses(uint256 group) private pure returns (bool) {
		return group == 2 || group == 3 || group == 6;
	}

	/// @dev A VerantaPriceAdapter on `store` for exactly this pair (a Chainlink feed answers neither).
	function _isStoreAdapter(address aggregator, VerantaPriceStore store, uint256 pairIndex) private view returns (bool) {
		(bool okStore, bytes memory s) = aggregator.staticcall(abi.encodeWithSignature('store()'));
		(bool okPair, bytes memory p) = aggregator.staticcall(abi.encodeWithSignature('pairIndex()'));
		return okStore && okPair && s.length == 32 && p.length == 32 && abi.decode(s, (address)) == address(store)
			&& abi.decode(p, (uint256)) == pairIndex;
	}
}
