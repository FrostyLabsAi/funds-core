// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {VmSafe} from 'forge-std/Vm.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {ComptrollerV5Deploy} from './ComptrollerV5Deploy.sol';

/// @notice Deploys the fund version 5 blueprint deployer (ComptrollerV5: in kind pays the whole value) on registrar V2
///         and the redemption queue. Rehearsed in test/fork/ComptrollerV5Fork.t.sol. Run as the genesis deployer:
///         forge script script/mainnet/DeployComptrollerV5.s.sol --rpc-url <base> --account frosty-main \
///              --sender <deployer> [--broadcast --slow --verify]
///         Then, as a separate reviewed step, point new funds at V5:
///         cast send <factory> 'setComptrollerDeployer(address)' <fundV5Deployer> (from the deployer).
///         It writes deployments/base-mainnet-comptroller-v5.json; the governance handoff then expects that deployer
///         (TransferFundsGovernance). Funds already created keep their version.
contract DeployComptrollerV5 is Script {
	function run() external returns (ComptrollerBlueprintDeployer fundV5Deployer) {
		require(block.chainid == 8453, 'Base (8453) only');
		address deployer = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet.json'), '.deployer');
		require(msg.sender == deployer, 'run as the genesis deployer (--sender)');
		address registrarV2 = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-v4.json'), '.registrar');
		address queue = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-redemption.json'), '.queue');

		vm.startBroadcast(deployer);
		fundV5Deployer = ComptrollerV5Deploy.deploy(registrarV2, queue);
		vm.stopBroadcast();

		console2.log('ComptrollerV5 blueprint deployer (registrar V2)', address(fundV5Deployer));
		// a dry run's simulated address must never reach the address book
		if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return fundV5Deployer;
		string memory json = vm.serializeAddress('comptrollerV5', 'fundV5Deployer', address(fundV5Deployer));
		vm.writeJson(json, 'deployments/base-mainnet-comptroller-v5.json');
	}
}
