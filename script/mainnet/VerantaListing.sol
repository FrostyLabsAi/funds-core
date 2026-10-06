// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {PriceMarker} from '../../src/pricing/PriceMarker.sol';
import {VerantaPriceStore} from '../../src/pricing/VerantaPriceStore.sol';
import {VerantaPriceAdapter} from '../../src/pricing/VerantaPriceAdapter.sol';
import {IValueInterpreterAdmin} from './ListingModuleBook.sol';
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
///         (`admin.execute`: the pool-pricing registrar; its owner only).
library VerantaListing {
	/// @notice Pyth Lazer's verifier on Base — the one Veranta's PriceAggregator uses.
	address internal constant PYTH_LAZER_VERIFIER = 0xACeA761c27A909d4D3895128EBe6370FDE2dF481;
	IVerantaPairCatalog internal constant CATALOG = IVerantaPairCatalog(FundsMainnet.VERANTA_PAIR_STORAGE);
	/// @notice How old a stored Veranta price may be when the VI reads it (the primitive's heartbeat).
	uint32 internal constant PRICE_LIFETIME = 10 minutes;

	function listAll(VerantaPriceStore store, IValueInterpreterAdmin admin, VerantaPerpPositionV2Factory factory)
		internal
		returns (uint256 listed)
	{
		uint256 count = CATALOG.pairsCount();
		for (uint256 i; i < count; ++i) {
			if (factory.pairAsset(i) != address(0)) continue;
			(string memory from, string memory to,) = CATALOG.pairData(i);
			if (bytes(from).length == 0 || CATALOG.getLazerFeedId(i) == 0) continue;

			string memory pair = string.concat(from, '/', to);
			string memory symbol = keccak256(bytes(to)) == keccak256('USD') ? string.concat('vm', from) : string.concat('vm', from, to);
			PriceMarker marker = new PriceMarker(string.concat('Veranta ', pair), symbol);
			VerantaPriceAdapter adapter = new VerantaPriceAdapter(store, i, PRICE_LIFETIME, string.concat(pair, ' (Veranta)'));
			admin.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (address(marker), address(adapter), PRICE_LIFETIME)));
			factory.setPairAsset(i, address(marker));
			++listed;
		}
	}

	/// @notice Prices on demand (founder 2026-10-05): every pair priced from `store` gets a
	///         `lifetime` heartbeat in the VI, so a stored price older than that can't value a fund.
	///         Re-registers the SAME adapter (addPrimitive overwrites the entry in one call: the pair
	///         is never unpriced, so it is safe with open fund trades). Pairs priced elsewhere (ETH/BTC
	///         and the stock perps on Chainlink) and pairs already at `lifetime` are left alone, so a
	///         second run is a no-op. Reversible: run again with the old heartbeat.
	function setPriceLifetime(
		VerantaPriceStore store,
		IValueInterpreterAdmin admin,
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

	/// @dev A VerantaPriceAdapter on `store` for exactly this pair (a Chainlink feed answers neither).
	function _isStoreAdapter(address aggregator, VerantaPriceStore store, uint256 pairIndex) private view returns (bool) {
		(bool okStore, bytes memory s) = aggregator.staticcall(abi.encodeWithSignature('store()'));
		(bool okPair, bytes memory p) = aggregator.staticcall(abi.encodeWithSignature('pairIndex()'));
		return okStore && okPair && s.length == 32 && p.length == 32 && abi.decode(s, (address)) == address(store)
			&& abi.decode(p, (uint256)) == pairIndex;
	}
}
