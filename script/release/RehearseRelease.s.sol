// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {console2} from 'forge-std/Script.sol';
import {Release} from './Release.sol';
import {ReleaseListings} from './ReleaseListings.sol';
import {ReleaseSteps} from './ReleaseSteps.sol';
import {ReleaseChecks} from './ReleaseChecks.sol';

/// @notice Rehearses the whole release in one local run on a Base fork, never broadcast: step 1 (DeployRelease) as the
///         deployer, its record written and read back, step 2 (ListRelease) from that record, then the checks that the
///         release prices as today's system does (ReleaseChecks). Pin the fork to the asset list's block so forge's
///         fork cache serves the reads and every rate is comparable:
///         forge script script/release/RehearseRelease.s.sol --fork-url <base rpc> \
///           --fork-block-number "$(jq .block deployments/release-assets.json)" --sender <deployer> --skip-simulation --offline
///         --skip-simulation: forge's second pass replays the transactions on a fresh fork, where the Coinbase stock
///         tokens can't run (B20LocalStandIn); this run already executed every one of them.
contract RehearseRelease is ReleaseSteps {
	string public constant REHEARSAL_RECORD = 'deployments/release-rehearsal.json';

	function run() external {
		string memory assets = vm.readFile(ASSETS_PATH);
		require(block.number == vm.parseJsonUint(assets, '.block'), 'fork at the asset list block');
		uint256 gasBefore = gasleft();
		Release.Deployed memory deployed = _deployStep(REHEARSAL_RECORD);
		uint256 deployGas = gasBefore - gasleft();

		gasBefore = gasleft();
		(Release.Deployed memory d, ReleaseListings.Counts memory c) = _listStep(REHEARSAL_RECORD, assets);
		uint256 listGas = gasBefore - gasleft();
		vm.removeFile(REHEARSAL_RECORD);
		require(address(d.registrar) == address(deployed.registrar), 'the record names the deployed registrar');
		require(d.valueInterpreter.owner() == address(d.registrar), 'the registrar owns the VI');

		address[] memory primitives = vm.parseJsonAddressArray(assets, '.primitives');
		address[] memory derivatives = vm.parseJsonAddressArray(assets, '.derivatives');
		require(
			c.chainlink + c.pools + c.perps + c.stocks + c.skipped + c.deadFeeds + 3 == primitives.length,
			'every primitive accounted for (3 quotes in step 1)'
		);
		require(c.derivatives == derivatives.length, 'every derivative listed');
		ReleaseChecks.checkListed(d, primitives, derivatives);
		ReleaseChecks.Rates memory rates = ReleaseChecks.compareRates(d, primitives);
		uint256 values = ReleaseChecks.compareValues(d, derivatives);
		uint256 pairs = ReleaseChecks.comparePairMap(d);

		console2.log('--- rehearsal at block', block.number);
		console2.log('step 1 gas (local run)', deployGas);
		console2.log('step 2 gas (local run)', listGas);
		console2.log('rates identical to live', rates.compared);
		console2.log('unreadable on both (stale now)', rates.unreadable);
		console2.log('v4 tokens waiting for samples', rates.warmingUp);
		console2.log('vault values identical to live', values);
		console2.log('pairs checked against live', pairs);
	}
}
