// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {console2} from 'forge-std/Script.sol';
import {Release} from './Release.sol';
import {ReleaseSteps} from './ReleaseSteps.sol';
import {ReleaseChecks} from './ReleaseChecks.sol';
import {B20LocalStandIns} from './B20LocalStandIn.sol';

/// @notice Read-only check of a deployed, listed release against today's system: the registrar owns the VI, every asset
///         is listed or deliberately left out, and every readable price, vault value and pair matches live
///         (ReleaseChecks). Run after the broadcast; nothing is sent (the stock tokens' stand-ins and the copied store
///         words exist only in forge's local run).
///         forge script script/release/CheckRelease.s.sol --rpc-url base --offline      (RELEASE_OUT=<record> for another)
contract CheckRelease is ReleaseSteps {
	function run() external {
		Release.Deployed memory d = _read(vm.readFile(vm.envOr('RELEASE_OUT', RELEASE_PATH)));
		string memory assets = vm.readFile(ASSETS_PATH);
		address[] memory primitives = vm.parseJsonAddressArray(assets, '.primitives');
		address[] memory derivatives = vm.parseJsonAddressArray(assets, '.derivatives');
		require(d.valueInterpreter.owner() == address(d.registrar), 'the registrar owns the VI');
		B20LocalStandIns.standIn(primitives);
		ReleaseChecks.checkListed(d, primitives, derivatives);
		ReleaseChecks.Rates memory rates = ReleaseChecks.compareRates(d, primitives);
		uint256 values = ReleaseChecks.compareValues(d, derivatives);
		uint256 pairs = ReleaseChecks.comparePairMap(d);
		console2.log('--- release check at block', block.number);
		console2.log('rates identical to live', rates.compared);
		console2.log('unreadable on both (stale now)', rates.unreadable);
		console2.log('v4 tokens waiting for samples', rates.warmingUp);
		console2.log('vault values identical to live', values);
		console2.log('pairs checked against live', pairs);
	}
}
