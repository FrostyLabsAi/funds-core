// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {VerantaPriceStore} from '../../src/pricing/VerantaPriceStore.sol';
import {VerantaListing} from './VerantaListing.sol';
import {ListingModuleBook, ViAdmin} from './ListingModuleBook.sol';

/// @notice Stock perps priced at Veranta's own price (founder 2026-10-06): the 13 stock perps mapped to
///         their Coinbase tokens (deployments/base-mainnet-stock-hedges.json) move to Veranta-priced
///         markers on the store — see VerantaListing.repointToStore. One marker, one adapter and two
///         calls per pair (addPrimitive through the registrar, setPairAsset on the perp factory): the
///         deployer owns both until the governance handoff.
///         ORDER:
///         1. funds-keeper and the terminal with the hedge table are deployed (they read the token↔perp
///            link from it, not from pairAsset, which this changes).
///         2. Every pair is clear: `.ops-scratch/list-assets.sh stock-perps` runs funds-keeper
///            src/tools/pair-holders.ts per pair first. A fund holding one of these pairs when it is
///            re-pointed loses that trade's coin leg from NAV (perps review 2026-10-05, must-fix 2).
///         Rehearsed in test/fork/RepointStockPerpsFork.t.sol. A second run is a no-op.
///         Undo a pair (only while no fund holds it): `cast send <verantaFactory> 'setPairAsset(uint256,address)'
///         <pair> <token>` — the token is still a VI primitive on its Chainlink feed.
///         Dry run (no --broadcast) prints the count; then:
///         forge script script/mainnet/RepointStockPerps.s.sol --rpc-url <base> --broadcast --slow \
///              --account frosty-main --sender <deployer>   [STORE=…] [HEDGES_FILE=…]
contract RepointStockPerps is Script {
	function run() external {
		require(block.chainid == 8453, 'Base (8453) only');
		string memory json = vm.readFile(vm.envOr('DEPLOYMENTS_FILE', string('deployments/base-mainnet.json')));
		VerantaPerpPositionV2Factory factory = VerantaPerpPositionV2Factory(vm.parseJsonAddress(json, '.verantaFactory'));
		ValueInterpreter vi = ValueInterpreter(vm.parseJsonAddress(json, '.valueInterpreter'));
		ViAdmin memory admin = ListingModuleBook.admin(vm, json);
		VerantaPriceStore store = VerantaPriceStore(
			vm.envOr('STORE', vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-veranta.json'), '.store'))
		);
		(uint256[] memory pairs, address[] memory tokens) =
			readHedges(vm.readFile(vm.envOr('HEDGES_FILE', string('deployments/base-mainnet-stock-hedges.json'))));

		vm.startBroadcast();
		uint256 repointed = VerantaListing.repointToStore(store, admin, factory, vi, pairs, tokens);
		vm.stopBroadcast();

		console2.log('store', address(store));
		console2.log('stock perps in the table', pairs.length);
		console2.log('pairs re-pointed to a Veranta-priced marker', repointed);
		for (uint256 k; k < pairs.length; ++k) {
			console2.log('pair', pairs[k], factory.pairAsset(pairs[k]));
		}
	}

	/// @notice The hedge table's (pairIndex, token) rows, in file order.
	function readHedges(string memory hedges) public view returns (uint256[] memory pairs, address[] memory tokens) {
		uint256 n;
		while (vm.keyExistsJson(hedges, string.concat('.hedges[', vm.toString(n), ']'))) ++n;
		pairs = new uint256[](n);
		tokens = new address[](n);
		for (uint256 k; k < n; ++k) {
			string memory row = string.concat('.hedges[', vm.toString(k), ']');
			pairs[k] = vm.parseJsonUint(hedges, string.concat(row, '.pairIndex'));
			tokens[k] = vm.parseJsonAddress(hedges, string.concat(row, '.token'));
		}
	}
}
