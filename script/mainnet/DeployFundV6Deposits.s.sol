// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {VmSafe} from 'forge-std/Vm.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {ComptrollerV6} from '../../src/core/ComptrollerV6.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';

/// @notice A new ComptrollerV6 blueprint: a closed market no longer stops a deposit (founder 2026-11-03). Same registrar,
///         queue and perp config as the live blueprint, read from it, so only the build changes. Funds already created
///         keep their version. Run as the factory's owner:
///         forge script script/mainnet/DeployFundV6Deposits.s.sol --rpc-url <base> --account frosty-main --sender <deployer> \
///              --slow [--broadcast --verify]
///         Then, as a separate step, point new funds at it:
///         cast send <factory> 'setComptrollerDeployer(address)' <fundV6Deployer> (from the deployer).
///         Writes deployments/base-mainnet-fund-v6-deposits.json, read by nothing but this runbook step.
contract DeployFundV6Deposits is Script {
	function run() external returns (ComptrollerBlueprintDeployer blueprint) {
		require(block.chainid == 8453, 'Base (8453) only');
		address deployer = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet.json'), '.deployer');
		require(msg.sender == deployer, 'run as the genesis deployer (--sender)');
		FundFactory factory = FundFactory(vm.parseJsonAddress(vm.readFile('deployments/base-mainnet.json'), '.factory'));
		bytes memory wiring = ComptrollerBlueprintDeployer(address(factory.comptrollerDeployer())).extraConstructorArgs();
		require(wiring.length != 0, 'the live blueprint has no wiring to copy');

		vm.startBroadcast(deployer);
		blueprint = new ComptrollerBlueprintDeployer(type(ComptrollerV6).creationCode, wiring);
		vm.stopBroadcast();

		console2.log('ComptrollerV6 blueprint deployer', address(blueprint));
		console2.log('replaces', address(factory.comptrollerDeployer()));
		// a dry run's simulated address must never reach the address book
		if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return blueprint;
		vm.serializeUint('fundV6Deposits', 'startBlock', block.number);
		string memory json = vm.serializeAddress('fundV6Deposits', 'fundV6Deployer', address(blueprint));
		vm.writeJson(json, 'deployments/base-mainnet-fund-v6-deposits.json');
	}
}
