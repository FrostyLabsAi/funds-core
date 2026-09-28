// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {VerantaPriceStore, IPythLazerVerifier, IVerantaLazerPairs} from '../../src/pricing/VerantaPriceStore.sol';
import {FundsMainnet} from './FundsMainnet.sol';
import {VerantaListing} from './VerantaListing.sol';

/// @notice Runbook step 3 (while the deployer still owns the VI and the perp factory): deploy the
///         Veranta price store (or reuse STORE) and list every Veranta pair genesis left unmapped —
///         see VerantaListing. Run AFTER list-coinbase-stocks.sh so the stock perps keep their
///         Coinbase-token mapping. Then set the keeper's VERANTA_PRICE_STORES to the store (it pushes
///         every pair a fund holds, every 5 minutes).
///         Run: forge script script/mainnet/ListVerantaPairs.s.sol --rpc-url <base> --broadcast --slow \
///              --private-key <deployer>   [STORE=<existing store>] [DEPLOYMENTS_FILE=…]
contract ListVerantaPairs is Script {
	function run() external {
		require(block.chainid == 8453, 'Base (8453) only');
		string memory json = vm.readFile(vm.envOr('DEPLOYMENTS_FILE', string('deployments/base-mainnet.json')));
		ValueInterpreter vi = ValueInterpreter(vm.parseJsonAddress(json, '.valueInterpreter'));
		VerantaPerpPositionV2Factory factory = VerantaPerpPositionV2Factory(vm.parseJsonAddress(json, '.verantaFactory'));

		vm.startBroadcast();
		VerantaPriceStore store = VerantaPriceStore(vm.envOr('STORE', address(0)));
		if (address(store) == address(0)) {
			store = new VerantaPriceStore(
				IPythLazerVerifier(VerantaListing.PYTH_LAZER_VERIFIER), IVerantaLazerPairs(FundsMainnet.VERANTA_PAIR_STORAGE)
			);
		}
		uint256 listed = VerantaListing.listAll(store, vi, factory);
		vm.stopBroadcast();

		vm.writeJson(vm.serializeAddress('veranta', 'store', address(store)), 'deployments/base-mainnet-veranta.json');
		console2.log('VerantaPriceStore', address(store));
		console2.log('pairs listed', listed);
	}
}
