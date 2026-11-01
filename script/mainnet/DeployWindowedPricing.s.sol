// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {VmSafe} from 'forge-std/Vm.sol';
import {WindowedPricing} from './WindowedPricing.sol';

/// @notice Deploys the PRICING-POOL-01 rollout (WindowedPricing): the fixed-adapter registrar chain, its long-tail policy,
///         mandatory slippage policy, v4 swap adapter and CLM feed, and the ComptrollerV6 blueprint deployer on it. Switches nothing: the owner steps
///         are WindowedPricingOwnerSteps.s.sol, a separate reviewed step. Rehearsed in test/fork/WindowedPricingFork.t.sol.
///         Run as the genesis deployer:
///         forge script script/mainnet/DeployWindowedPricing.s.sol --rpc-url <base> \
///              --account frosty-main --sender <deployer> [--broadcast --slow --verify]
///         It writes deployments/base-mainnet-windowed-pricing.json.
contract DeployWindowedPricing is Script {
	string public constant OUTPUT_PATH = 'deployments/base-mainnet-windowed-pricing.json';

	function run() external returns (WindowedPricing.Deployed memory d) {
		require(block.chainid == 8453, 'Base (8453) only');
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		address deployer = vm.parseJsonAddress(genesis, '.deployer');
		require(msg.sender == deployer, 'run as the genesis deployer (--sender)');
		address queueV2 = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-fund-v6.json'), '.queueV2');
		address perpConfig = vm.parseJsonAddress(genesis, '.verantaFactory');
		address clmFactory = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-clm-v2.json'), '.strategyFactory');

		vm.startBroadcast(deployer);
		d = WindowedPricing.deploy(deployer, queueV2, perpConfig, clmFactory);
		vm.stopBroadcast();

		console2.log('PoolPriceRegistrarWindowed', address(d.base));
		console2.log('PoolPriceRegistrarV2 (new)', address(d.registrarV2));
		console2.log('PoolPriceRegistrarV3 (new)', address(d.registrar));
		console2.log('MinPoolLiquidityPolicy (new V3)', address(d.policy));
		console2.log('CumulativeSlippageTolerancePolicy (mandatory)', address(d.slippage));
		console2.log('UniswapV4SwapAdapter (new V3)', address(d.v4Adapter));
		console2.log('ClmVaultPriceFeed (new V3)', address(d.clmFeed));
		console2.log('ComptrollerV6 blueprint deployer (new V3)', address(d.fundV6Deployer));
		// a dry run's simulated address must never reach the address book
		if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return d;
		vm.serializeAddress('windowed', 'base', address(d.base));
		vm.serializeAddress('windowed', 'registrarV2', address(d.registrarV2));
		vm.serializeAddress('windowed', 'registrar', address(d.registrar));
		vm.serializeAddress('windowed', 'policy', address(d.policy));
		vm.serializeAddress('windowed', 'slippage', address(d.slippage));
		vm.serializeAddress('windowed', 'v4Adapter', address(d.v4Adapter));
		vm.serializeAddress('windowed', 'clmFeed', address(d.clmFeed));
		vm.serializeUint('windowed', 'startBlock', block.number);
		vm.writeJson(vm.serializeAddress('windowed', 'fundV6Deployer', address(d.fundV6Deployer)), OUTPUT_PATH);
	}
}
