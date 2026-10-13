// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console} from 'forge-std/Script.sol';
import {ClmVaultAdapter} from '../../src/adapters/ClmVaultAdapter.sol';
import {ClmVaultPriceFeed} from '../../src/pricing/ClmVaultPriceFeed.sol';
import {ClmFundsDeploy} from './ClmFundsDeploy.sol';

/// @notice Plan 2 (2026-10-13): lets funds hold FrostyFi CLM vault shares. Deploys ClmVaultPriceFeed and ClmVaultAdapter,
///         registers the adapter on the FundFactory, and lists every vault of deployments/base-mainnet-clm.json (copied
///         from funds-yield after its deploy) in the VI through registrar V2 → today's registrar. Touches no stock
///         token, so forge can run it.
///         Run: forge script script/mainnet/DeployClmFunds.s.sol --rpc-url base --account frosty-main --sender <deployer>
///              --broadcast --slow --verify
contract DeployClmFunds is Script {
	string public constant CLM_PATH = 'deployments/base-mainnet-clm.json';
	string public constant OUTPUT_PATH = 'deployments/base-mainnet-clm-funds.json';

	function run() external {
		string memory clm = vm.readFile(CLM_PATH);
		address strategyFactory = vm.parseJsonAddress(clm, '.strategyFactory');
		string[] memory symbols = vm.parseJsonKeys(clm, '.vaults');
		address[] memory vaults = new address[](symbols.length);
		for (uint256 i; i < symbols.length; ++i) {
			vaults[i] = vm.parseJsonAddress(clm, string.concat('.vaults.', symbols[i], '.vault'));
		}
		vm.startBroadcast();
		(ClmVaultPriceFeed feed, ClmVaultAdapter adapter) = ClmFundsDeploy.deploy(strategyFactory);
		ClmFundsDeploy.list(feed, vaults);
		vm.stopBroadcast();
		vm.serializeAddress('clmFunds', 'feed', address(feed));
		vm.writeJson(vm.serializeAddress('clmFunds', 'adapter', address(adapter)), OUTPUT_PATH);
		console.log('wrote', OUTPUT_PATH);
	}
}
