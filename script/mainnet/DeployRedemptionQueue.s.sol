// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {VmSafe} from 'forge-std/Vm.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {VerantaPriceStore} from '../../src/pricing/VerantaPriceStore.sol';
import {RedemptionDeploy} from './RedemptionDeploy.sol';

/// @notice Deploys the redemption queue, the perp unwinder (approved, switched OFF) and the V3
///         blueprint deployer — see RedemptionDeploy. Rehearsed in
///         test/fork/RedemptionQueueDeployFork.t.sol. Run as the genesis deployer (it owns the
///         factory until the governance handoff; it becomes the queue's owner):
///         forge script script/mainnet/DeployRedemptionQueue.s.sol --rpc-url <base> --account frosty-main \
///              --sender <deployer> [--broadcast --slow --verify]
///         Then, as a separate reviewed step, point new funds at V3:
///         cast send <factory> 'setComptrollerDeployer(address)' <fundV3Deployer> (from the deployer).
///         The queue's ownership joins the governance handoff (FundsGovernance).
contract DeployRedemptionQueue is Script {
	function run() external returns (RedemptionDeploy.Deployed memory d) {
		require(block.chainid == 8453, 'Base (8453) only');
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		address deployer = vm.parseJsonAddress(genesis, '.deployer');
		require(msg.sender == deployer, 'run as the genesis deployer (--sender)');
		address factory = vm.parseJsonAddress(genesis, '.factory');
		address perpConfig = vm.parseJsonAddress(genesis, '.verantaFactory');
		PoolPriceRegistrar registrar =
			PoolPriceRegistrar(vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-pool-pricing.json'), '.registrar'));
		VerantaPriceStore store = VerantaPriceStore(vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-veranta.json'), '.store'));

		// the subgraph's queue data source starts here (manifest-base-mainnet.sh)
		uint256 startBlock = block.number;
		vm.startBroadcast(deployer);
		d = RedemptionDeploy.deploy(deployer, factory, perpConfig, registrar, store);
		vm.stopBroadcast();

		console2.log('RedemptionQueue', address(d.queue));
		console2.log('PerpUnwinder (approved, OFF)', address(d.perpUnwinder));
		console2.log('ComptrollerV3 blueprint deployer', address(d.fundV3Deployer));
		// a dry run's simulated addresses must never reach the address book
		if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return d;
		string memory key = 'redemption';
		vm.serializeAddress(key, 'queue', address(d.queue));
		vm.serializeAddress(key, 'perpUnwinder', address(d.perpUnwinder));
		vm.serializeAddress(key, 'fundV3Deployer', address(d.fundV3Deployer));
		string memory json = vm.serializeUint(key, 'startBlock', startBlock);
		vm.writeJson(json, 'deployments/base-mainnet-redemption.json');
	}
}
