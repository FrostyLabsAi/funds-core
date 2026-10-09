// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {VmSafe} from 'forge-std/Vm.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {ComptrollerV4Deploy} from './ComptrollerV4Deploy.sol';

/// @notice Deploys the fund version 4 blueprint deployer (ComptrollerV4: in kind refused while a fund
///         holds perps or LPs) on the live registrar and redemption queue. Rehearsed in
///         test/fork/ComptrollerV4Fork.t.sol. Run as the genesis deployer:
///         forge script script/mainnet/DeployComptrollerV4.s.sol --rpc-url <base> --account frosty-main \
///              --sender <deployer> [--broadcast --slow --verify]
///         Then, as a separate reviewed step, point new funds at V4:
///         cast send <factory> 'setComptrollerDeployer(address)' <fundV4Deployer> (from the deployer).
///         Funds already created keep their version (V3 funds keep the forfeiting in kind on chain; the
///         terminal no longer offers it).
contract DeployComptrollerV4 is Script {
	function run() external returns (ComptrollerBlueprintDeployer fundV4Deployer) {
		require(block.chainid == 8453, 'Base (8453) only');
		address deployer = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet.json'), '.deployer');
		require(msg.sender == deployer, 'run as the genesis deployer (--sender)');
		PoolPriceRegistrar registrar =
			PoolPriceRegistrar(vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-pool-pricing.json'), '.registrar'));
		address queue = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-redemption.json'), '.queue');

		vm.startBroadcast(deployer);
		fundV4Deployer = ComptrollerV4Deploy.deploy(registrar, queue);
		vm.stopBroadcast();

		console2.log('ComptrollerV4 blueprint deployer', address(fundV4Deployer));
		// a dry run's simulated address must never reach the address book
		if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return fundV4Deployer;
		string memory json = vm.serializeAddress('comptrollerV4', 'fundV4Deployer', address(fundV4Deployer));
		vm.writeJson(json, 'deployments/base-mainnet-comptroller-v4.json');
	}
}
