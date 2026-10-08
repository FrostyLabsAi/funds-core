// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {VmSafe} from 'forge-std/Vm.sol';
import {VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {VerantaPerpPositionV4Factory} from '../../src/positions/VerantaPerpPositionV4.sol';

/// @notice Deploys the stateless, ownerless VerantaPerpPositionV4 type factory over the live perp config
///         (the genesis V2 factory: pair map, autopilot keeper, referral). Spec
///         docs/superpowers/specs/2026-10-08-perp-account-v4-design.md §7; rehearsed in
///         test/fork/PerpAccountV4RolloutFork.t.sol. One transaction, any sender works (nothing is owned);
///         run it as the genesis deployer anyway, it signs the next step too:
///         forge script script/mainnet/DeployPerpAccountV4.s.sol --rpc-url <base> --account frosty-main \
///              --sender <deployer> [--broadcast --slow --verify]
///         Then, as a separate reviewed step, point position type 6 at it (the deployer still owns the
///         FundFactory; after the governance handoff this is a timelock proposal):
///         cast send <factory> 'registerPositionType(uint256,address)' 6 <perpV4Factory> (from the deployer).
///         Existing perp accounts keep their own contracts; only new accounts become V4.
contract DeployPerpAccountV4 is Script {
	function run() external returns (VerantaPerpPositionV4Factory v4Factory) {
		require(block.chainid == 8453, 'Base (8453) only');
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		address deployer = vm.parseJsonAddress(genesis, '.deployer');
		require(msg.sender == deployer, 'run as the genesis deployer (--sender)');
		VerantaPerpPositionV2Factory config = VerantaPerpPositionV2Factory(vm.parseJsonAddress(genesis, '.verantaFactory'));
		address factory = vm.parseJsonAddress(genesis, '.factory');

		uint256 startBlock = block.number;
		vm.startBroadcast(deployer);
		v4Factory = deploy(config);
		vm.stopBroadcast();

		console2.log('VerantaPerpPositionV4Factory', address(v4Factory));
		console2.log('next (reviewed, from the deployer): cast send', factory);
		console2.log("  'registerPositionType(uint256,address)' 6", address(v4Factory));
		// a dry run's simulated address must never reach the address book
		if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return v4Factory;
		string memory key = 'perpV4';
		vm.serializeAddress(key, 'perpV4Factory', address(v4Factory));
		string memory json = vm.serializeUint(key, 'startBlock', startBlock);
		vm.writeJson(json, 'deployments/base-mainnet-perp-v4.json');
	}

	/// @notice The deployment itself, also run by the fork rehearsal: the factory, bound to the live config.
	function deploy(VerantaPerpPositionV2Factory config) public returns (VerantaPerpPositionV4Factory v4Factory) {
		require(address(config).code.length > 0, 'perp config not deployed');
		v4Factory = new VerantaPerpPositionV4Factory(config);
		require(v4Factory.config() == config, 'bound to the live config');
	}
}
