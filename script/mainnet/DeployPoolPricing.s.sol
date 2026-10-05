// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {VmSafe} from 'forge-std/Vm.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {PoolPricing} from './PoolPricing.sol';

/// @notice Step 1 of PoolPricing on Base: deploys the PoolPriceRegistrar, the long-tail policy and
///         the fund-v2 deployer (ComptrollerV2's build, with its linked FundValuation library, which
///         forge deploys first). Changes nothing live: the VI, the factory and every fund are
///         untouched until MigratePoolPricing. Run as the genesis deployer, which becomes the
///         registrar's owner. Writes deployments/base-mainnet-pool-pricing.json (registrar, policy,
///         fundDeployer, fundInitcodeHash, startBlock) on a broadcast only — a dry run writes
///         nothing. A second run refuses while that file exists. FundValuation's address is in the
///         broadcast record (broadcast/DeployPoolPricing.s.sol/8453/run-latest.json, `libraries`).
///         Run: forge script script/mainnet/DeployPoolPricing.s.sol --rpc-url <base> --account frosty-main \
///              --sender <deployer> [--broadcast --slow --verify]
///         Env: [DEPLOYMENTS_FILE] (default deployments/base-mainnet-pool-pricing.json)
contract DeployPoolPricing is Script {
	string internal constant GENESIS_FILE = 'deployments/base-mainnet.json';

	function run() external {
		require(block.chainid == 8453, 'Base (8453) only');
		string memory file = vm.envOr('DEPLOYMENTS_FILE', string('deployments/base-mainnet-pool-pricing.json'));
		require(!vm.exists(file), 'already deployed: the pool-pricing book exists (MigratePoolPricing is next)');

		string memory genesis = vm.readFile(GENESIS_FILE);
		address deployer = vm.parseJsonAddress(genesis, '.deployer');
		ValueInterpreter vi = ValueInterpreter(vm.parseJsonAddress(genesis, '.valueInterpreter'));
		require(msg.sender == deployer, 'run as the genesis deployer (it becomes the registrar owner)');
		// the head before broadcasting: the deploy lands at or after it
		uint256 startBlock = block.number;

		vm.startBroadcast();
		PoolPricing.Deployment memory d = PoolPricing.deploy(vi, deployer);
		vm.stopBroadcast();

		console2.log('PoolPriceRegistrar', address(d.registrar));
		console2.log('MinPoolLiquidityPolicy', address(d.policy));
		console2.log('fund v2 deployer', address(d.fundDeployer));
		if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
			console2.log('dry run: nothing written');
			return;
		}

		string memory k = 'poolPricing';
		vm.serializeAddress(k, 'registrar', address(d.registrar));
		vm.serializeAddress(k, 'policy', address(d.policy));
		vm.serializeAddress(k, 'fundDeployer', address(d.fundDeployer));
		vm.serializeBytes32(k, 'fundInitcodeHash', d.fundDeployer.initcodeHash());
		string memory out = vm.serializeUint(k, 'startBlock', startBlock);
		vm.writeJson(out, file);
		console2.log('written to', file);
	}
}
