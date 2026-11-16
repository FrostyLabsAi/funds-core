// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Release} from './Release.sol';
import {ReleaseSteps} from './ReleaseSteps.sol';

/// @notice Step 1 of the release: deploys it on Base (Release.deploy) and writes every address to
///         deployments/base-mainnet-release.json. The VI stays with the deployer: run the listings next
///         (ListRelease.s.sol), which hands it to the registrar. Rehearsed with the listings by RehearseRelease.s.sol.
///         Dry run:  forge script script/release/DeployRelease.s.sol --rpc-url base --account frosty-main --sender <deployer> --offline
///         Broadcast: the same plus --broadcast. --offline stops forge looking up unknown selectors on api.openchain.xyz,
///         which hung the 2026-11-16 rehearsal (RPC and vm.rpc reads still work); it also turns off --verify, so verify
///         the contracts as a separate step afterwards.
contract DeployRelease is ReleaseSteps {
	function run() external returns (Release.Deployed memory d) {
		// RELEASE_OUT points a dry run elsewhere, so a simulation never leaves a release record behind
		d = _deployStep(vm.envOr('RELEASE_OUT', RELEASE_PATH));
	}
}
