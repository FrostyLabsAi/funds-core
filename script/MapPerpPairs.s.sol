// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {VerantaPerpPositionV2Factory} from '../src/positions/VerantaPerpPositionV2.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';

/// @notice Maps Veranta pairs to the VI-priced asset their perp legs are valued in
///         (`setPairAsset`) — the step that makes a pair tradeable by funds. Refuses an asset
///         the VI cannot price (the position would refuse to open anyway).
///         Before running: confirm each pairIndex on the TARGET chain (pair indexes can differ
///         between mainnet and Veranta's testnet fork) — e.g. its pairs(i) feed id.
/// @dev Env: POSITION_FACTORY, VALUE_INTERPRETER, PAIR_ASSETS = comma list of `pairIndex:asset`
contract MapPerpPairs is Script {
	function run() external {
		VerantaPerpPositionV2Factory factory = VerantaPerpPositionV2Factory(vm.envAddress('POSITION_FACTORY'));
		ValueInterpreter interpreter = ValueInterpreter(vm.envAddress('VALUE_INTERPRETER'));
		string[] memory entries = vm.split(vm.envString('PAIR_ASSETS'), ',');

		vm.startBroadcast();
		for (uint256 i; i < entries.length; ++i) {
			string[] memory parts = vm.split(entries[i], ':');
			require(parts.length == 2, 'entry must be pairIndex:asset');
			uint256 pairIndex = vm.parseUint(parts[0]);
			address asset = vm.parseAddress(parts[1]);
			require(interpreter.isSupportedAsset(asset), 'asset not priced by the VI');
			factory.setPairAsset(pairIndex, asset);
			console2.log('pair', pairIndex, asset);
		}
		vm.stopBroadcast();
	}
}
