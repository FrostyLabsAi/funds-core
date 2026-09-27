// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {PriceMarker} from '../../src/pricing/PriceMarker.sol';
import {VerantaPriceStore} from '../../src/pricing/VerantaPriceStore.sol';
import {VerantaPriceAdapter} from '../../src/pricing/VerantaPriceAdapter.sol';
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
///         Max age: 24/7 crypto groups 1 hour; closed-market groups (forex, commodities,
///         equities) 5 days, so weekends and holidays never block a fund (founder rule).
library VerantaListing {
	/// @notice Pyth Lazer's verifier on Base — the one Veranta's PriceAggregator uses.
	address internal constant PYTH_LAZER_VERIFIER = 0xACeA761c27A909d4D3895128EBe6370FDE2dF481;
	IVerantaPairCatalog internal constant CATALOG = IVerantaPairCatalog(FundsMainnet.VERANTA_PAIR_STORAGE);
	uint32 internal constant CRYPTO_MAX_AGE = 1 hours;
	uint32 internal constant CLOSED_MARKET_MAX_AGE = 5 days;

	/// @notice Veranta groups CRYPTO1..CRYPTO4 (0, 1, 4, 5 — data.veranta.xyz groupInfo 2026-09-27);
	///         2 = FOREX, 3 = COMMODITIES, 6 = equities
	function isCryptoGroup(uint256 group) internal pure returns (bool) {
		return group == 0 || group == 1 || group == 4 || group == 5;
	}

	function listAll(VerantaPriceStore store, ValueInterpreter vi, VerantaPerpPositionV2Factory factory)
		internal
		returns (uint256 listed)
	{
		uint256 count = CATALOG.pairsCount();
		for (uint256 i; i < count; ++i) {
			if (factory.pairAsset(i) != address(0)) continue;
			(string memory from, string memory to,) = CATALOG.pairData(i);
			if (bytes(from).length == 0 || CATALOG.getLazerFeedId(i) == 0) continue;

			uint32 maxAge = isCryptoGroup(CATALOG.pairGroupIndex(i)) ? CRYPTO_MAX_AGE : CLOSED_MARKET_MAX_AGE;
			string memory pair = string.concat(from, '/', to);
			string memory symbol = keccak256(bytes(to)) == keccak256('USD') ? string.concat('vm', from) : string.concat('vm', from, to);
			PriceMarker marker = new PriceMarker(string.concat('Veranta ', pair), symbol);
			VerantaPriceAdapter adapter = new VerantaPriceAdapter(store, i, maxAge, string.concat(pair, ' (Veranta)'));
			vi.addPrimitive(address(marker), address(adapter), maxAge);
			factory.setPairAsset(i, address(marker));
			++listed;
		}
	}
}
