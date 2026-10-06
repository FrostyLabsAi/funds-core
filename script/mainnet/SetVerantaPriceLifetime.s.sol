// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {VerantaPriceStore} from '../../src/pricing/VerantaPriceStore.sol';
import {VerantaListing} from './VerantaListing.sol';
import {ListingModuleBook, IValueInterpreterAdmin} from './ListingModuleBook.sol';

/// @notice Perp prices on demand (founder 2026-10-05, PLAN_PERP_PULL_PRICING step 6): every Veranta
///         pair priced from the store gets a 10-minute heartbeat in the VI — see
///         VerantaListing.setPriceLifetime. One VI call per pair through the registrar (its owner
///         only: the deployer until the governance handoff), the same adapter, never unpriced.
///         Deploy the terminal and keeper that store prices on demand FIRST: from this step on, a
///         price older than 10 minutes can't value a fund. Rehearsed in
///         test/fork/VerantaUnpushedPairFork.t.sol (test_fork_tenMinutePriceLifetime).
///         Undo: LIFETIME=3600 (crypto; closed-market pairs were 432000) — run per group if needed.
///         Dry run (no --broadcast) prints the count; then:
///         forge script script/mainnet/SetVerantaPriceLifetime.s.sol --rpc-url <base> --broadcast --slow \
///              --account frosty-main --sender <deployer>   [LIFETIME=600] [STORE=…]
contract SetVerantaPriceLifetime is Script {
	function run() external {
		require(block.chainid == 8453, 'Base (8453) only');
		string memory json = vm.readFile(vm.envOr('DEPLOYMENTS_FILE', string('deployments/base-mainnet.json')));
		VerantaPerpPositionV2Factory factory = VerantaPerpPositionV2Factory(vm.parseJsonAddress(json, '.verantaFactory'));
		ValueInterpreter vi = ValueInterpreter(vm.parseJsonAddress(json, '.valueInterpreter'));
		IValueInterpreterAdmin admin = ListingModuleBook.admin(vm, json);
		VerantaPriceStore store = VerantaPriceStore(
			vm.envOr('STORE', vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-veranta.json'), '.store'))
		);
		uint32 lifetime = uint32(vm.envOr('LIFETIME', uint256(VerantaListing.PRICE_LIFETIME)));

		vm.startBroadcast();
		uint256 updated = VerantaListing.setPriceLifetime(store, admin, factory, vi, lifetime);
		vm.stopBroadcast();

		console2.log('store', address(store));
		console2.log('pairs set to a heartbeat of (s)', lifetime);
		console2.log('pairs updated', updated);
	}
}
