// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {VmSafe} from 'forge-std/Vm.sol';
import {AeroRegistrar} from './AeroRegistrar.sol';

/// @notice Deploys the Aero venue (FrostyFi 2026-10-25, AeroRegistrar): PoolPriceRegistrarV3, its long-tail policy,
///         its v4 swap adapter and the ComptrollerV6 blueprint deployer on it. Switches nothing: the owner steps are
///         AeroRegistrarOwnerSteps.s.sol, a separate reviewed step. Rehearsed in test/fork/AeroRegistrarFork.t.sol.
///         Run as the genesis deployer:
///         forge script script/mainnet/DeployAeroRegistrar.s.sol --rpc-url <base> \
///              --account frosty-main --sender <deployer> [--broadcast --slow --verify]
///         It writes deployments/base-mainnet-aero-registrar.json.
contract DeployAeroRegistrar is Script {
	string public constant OUTPUT_PATH = 'deployments/base-mainnet-aero-registrar.json';

	function run() external returns (AeroRegistrar.Deployed memory d) {
		require(block.chainid == 8453, 'Base (8453) only');
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		address deployer = vm.parseJsonAddress(genesis, '.deployer');
		require(msg.sender == deployer, 'run as the genesis deployer (--sender)');
		address queueV2 = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-fund-v6.json'), '.queueV2');
		// what every perp account names as positionFactory() (V4 accounts too), as DeployFundV6
		address perpConfig = vm.parseJsonAddress(genesis, '.verantaFactory');

		vm.startBroadcast(deployer);
		d = AeroRegistrar.deploy(deployer, queueV2, perpConfig);
		vm.stopBroadcast();

		console2.log('PoolPriceRegistrarV3', address(d.registrar));
		console2.log('MinPoolLiquidityPolicy (V3)', address(d.policy));
		console2.log('UniswapV4SwapAdapter (V3)', address(d.v4Adapter));
		console2.log('ComptrollerV6 blueprint deployer (V3)', address(d.fundV6Deployer));
		// a dry run's simulated address must never reach the address book
		if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return d;
		vm.serializeAddress('aeroRegistrar', 'registrar', address(d.registrar));
		vm.serializeAddress('aeroRegistrar', 'policy', address(d.policy));
		vm.serializeAddress('aeroRegistrar', 'v4Adapter', address(d.v4Adapter));
		vm.serializeUint('aeroRegistrar', 'startBlock', block.number);
		string memory json = vm.serializeAddress('aeroRegistrar', 'fundV6Deployer', address(d.fundV6Deployer));
		vm.writeJson(json, OUTPUT_PATH);
	}
}
