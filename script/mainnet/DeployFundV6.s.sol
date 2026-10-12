// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {VmSafe} from 'forge-std/Vm.sol';
import {FundV6Deploy} from './FundV6Deploy.sol';

/// @notice Deploys fund version 6 (USDC-only exit, founder 2026-10-11): RedemptionQueueV2 and the ComptrollerV6
///         blueprint deployer. Rehearsed in test/fork/FundV6Fork.t.sol. KEEPER_ADDRESS is the funds-keeper's Engine
///         wallet (the same address as its compose.production.yml), an address, never a key. Run as the genesis
///         deployer:
///         KEEPER_ADDRESS=<keeper> forge script script/mainnet/DeployFundV6.s.sol --rpc-url <base> \
///              --account frosty-main --sender <deployer> [--broadcast --slow --verify]
///         Then, as a separate reviewed step, point new funds at v6:
///         cast send <factory> 'setComptrollerDeployer(address)' <fundV6Deployer> (from the deployer).
///         It writes deployments/base-mainnet-fund-v6.json. Funds already created keep their version.
contract DeployFundV6 is Script {
	function run() external returns (FundV6Deploy.Deployed memory d) {
		require(block.chainid == 8453, 'Base (8453) only');
		address deployer = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet.json'), '.deployer');
		require(msg.sender == deployer, 'run as the genesis deployer (--sender)');
		address factory = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet.json'), '.factory');
		address registrarV2 = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-v4.json'), '.registrar');
		// what every perp account names as positionFactory() (V4 accounts too): the V2 config, as PerpUnwinder checks
		address perpConfig = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet.json'), '.verantaFactory');
		address keeper = vm.envAddress('KEEPER_ADDRESS');
		require(keeper != address(0) && keeper != deployer, 'KEEPER_ADDRESS: the keeper wallet, not the deployer');

		vm.startBroadcast(deployer);
		d = FundV6Deploy.deploy(deployer, factory, registrarV2, perpConfig, keeper);
		vm.stopBroadcast();

		console2.log('RedemptionQueueV2', address(d.queueV2));
		console2.log('ComptrollerV6 blueprint deployer', address(d.fundV6Deployer));
		// a dry run's simulated address must never reach the address book
		if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return d;
		vm.serializeAddress('fundV6', 'queueV2', address(d.queueV2));
		vm.serializeUint('fundV6', 'startBlock', block.number);
		string memory json = vm.serializeAddress('fundV6', 'fundV6Deployer', address(d.fundV6Deployer));
		vm.writeJson(json, 'deployments/base-mainnet-fund-v6.json');
	}
}
