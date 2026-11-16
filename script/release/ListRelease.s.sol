// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {ReleaseListings} from './ReleaseListings.sol';
import {ReleaseSteps} from './ReleaseSteps.sol';

/// @notice Step 2 of the release: copies every listing from today's system (ReleaseListings: the feeds and vaults on
///         the VI while it is the deployer's, then the VI to the registrar, then the pools), reading the release's addresses from
///         deployments/base-mainnet-release.json and the asset list from deployments/release-assets.json. Refresh the
///         asset list first (script/release/release-assets.sh), so a token registered since is included.
///         Coinbase stock tokens are a Base precompile Foundry can't run: forge's local run puts a stand-in at each
///         (B20LocalStandIn), and the recorded calls run against the real tokens on chain. So the broadcast skips
///         forge's second, on-chain-state simulation and gives every transaction a gas margin:
///         forge script script/release/ListRelease.s.sol --rpc-url base --account frosty-main --sender <deployer> \
///           --broadcast --skip-simulation --gas-estimate-multiplier 200 --offline      (869 transactions; --resume)
///         --offline: see DeployRelease.
contract ListRelease is ReleaseSteps {
	function run() external returns (ReleaseListings.Counts memory c) {
		(, c) = _listStep(vm.envOr('RELEASE_OUT', RELEASE_PATH), vm.readFile(ASSETS_PATH));
	}
}
