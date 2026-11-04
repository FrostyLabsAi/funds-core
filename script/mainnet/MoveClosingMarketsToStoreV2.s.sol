// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {VmSafe} from 'forge-std/Vm.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {VerantaPriceStore} from '../../src/pricing/VerantaPriceStore.sol';
import {VerantaPriceStoreV2} from '../../src/pricing/VerantaPriceStoreV2.sol';
import {VerantaListing} from './VerantaListing.sol';
import {ListingModuleBook, ViAdmin} from './ListingModuleBook.sol';

/// @notice Perps on markets that close stay priced over a closed market (red-team PF-01; founder 2026-11-03): see
///         VerantaListing.moveClosingMarkets. Safe with open fund trades: the marker never changes and the pair is never
///         unpriced, though a held pair reads NeverPushed until its first V2 price is stored (the keeper's next push). A
///         second run is a no-op, so it also picks up pairs listed later. Rehearsed in
///         test/fork/MoveClosingMarketsFork.t.sol. The keeper already pushes the V2 store (VERANTA_PRICE_STORES) and the
///         terminal reads it from the adapter's maxFeedAge(). Run as the genesis deployer. Dry run (no --broadcast) prints
///         the count; then:
///         forge script script/mainnet/MoveClosingMarketsToStoreV2.s.sol --rpc-url <base> --account frosty-main \
///              --sender <deployer> --slow --broadcast
///         Writes deployments/base-mainnet-perp-prices-v2.json. Undo a pair: re-add its old adapter with a 600 s heartbeat
///         (`addPrimitive` through registrar V3's callOldRegistrar).
contract MoveClosingMarketsToStoreV2 is Script {
	function run() external {
		require(block.chainid == 8453, 'Base (8453) only');
		string memory json = vm.readFile('deployments/base-mainnet.json');
		require(msg.sender == vm.parseJsonAddress(json, '.deployer'), 'run as the genesis deployer (--sender)');
		VerantaPerpPositionV2Factory factory = VerantaPerpPositionV2Factory(vm.parseJsonAddress(json, '.verantaFactory'));
		ValueInterpreter vi = ValueInterpreter(vm.parseJsonAddress(json, '.valueInterpreter'));
		ViAdmin memory admin = ListingModuleBook.admin(vm, json);
		VerantaPriceStore storeV1 = VerantaPriceStore(vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-veranta.json'), '.store'));
		VerantaPriceStoreV2 storeV2 = VerantaPriceStoreV2(vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-veranta-stocks.json'), '.store'));

		vm.startBroadcast();
		VerantaListing.MovedPair[] memory moved = VerantaListing.moveClosingMarkets(storeV1, storeV2, admin, factory, vi);
		vm.stopBroadcast();

		console2.log('pairs moved to the V2 store', moved.length);
		// a dry run's simulated addresses must never reach the address book, and a no-op run must not wipe it
		if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || moved.length == 0) return;
		string memory rows;
		for (uint256 k; k < moved.length; ++k) {
			rows = string.concat(
				rows,
				k == 0 ? '' : ',',
				'{"pair":', vm.toString(moved[k].pairIndex),
				',"marker":"', vm.toString(moved[k].marker),
				'","oldAdapter":"', vm.toString(moved[k].oldAdapter),
				'","adapter":"', vm.toString(moved[k].adapter), '"}'
			);
		}
		vm.writeFile(
			'deployments/base-mainnet-perp-prices-v2.json',
			string.concat('{"store":"', vm.toString(address(storeV2)), '","moved":[', rows, ']}\n')
		);
	}
}
