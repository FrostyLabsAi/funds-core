// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console} from 'forge-std/Script.sol';
import {ClmVaultPriceFeed} from '../../src/pricing/ClmVaultPriceFeed.sol';
import {ClmFundsDeploy} from './ClmFundsDeploy.sol';

/// @notice Lists every vault of deployments/base-mainnet-clm.json (copied from funds-yield after a deploy) that the VI
///         doesn't price yet, on the live ClmVaultPriceFeed of deployments/base-mainnet-clm-funds.json, through
///         registrar V2 → today's registrar. For vaults added after DeployClmFunds (2026-10-14), which also deploys a
///         feed and an adapter; already-priced vaults are skipped. Rehearsed in test/fork/ListClmVaultsFork.t.sol.
///         Run: forge script script/mainnet/ListClmVaults.s.sol --rpc-url base --account frosty-main --sender <deployer>
///              --broadcast --slow
contract ListClmVaults is Script {
	string public constant CLM_PATH = 'deployments/base-mainnet-clm.json';
	string public constant CLM_FUNDS_PATH = 'deployments/base-mainnet-clm-funds.json';

	function run() external {
		string memory clm = vm.readFile(CLM_PATH);
		string[] memory symbols = vm.parseJsonKeys(clm, '.vaults');
		address[] memory vaults = new address[](symbols.length);
		for (uint256 i; i < symbols.length; ++i) {
			vaults[i] = vm.parseJsonAddress(clm, string.concat('.vaults.', symbols[i], '.vault'));
		}
		ClmVaultPriceFeed feed = ClmVaultPriceFeed(vm.parseJsonAddress(vm.readFile(CLM_FUNDS_PATH), '.feed'));
		vm.startBroadcast();
		uint256 listed = ClmFundsDeploy.listUnpriced(feed, vaults);
		vm.stopBroadcast();
		console.log('vaults in the book', vaults.length);
		console.log('vaults listed now', listed);
	}
}
