// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {VmSafe} from 'forge-std/Vm.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {V4Pricing} from './V4Pricing.sol';

/// @notice Deploys Uniswap v4 pricing and the fee-taking spot adapters — V4Pricing.deploy — owned by the genesis
///         deployer. Spec docs/superpowers/specs/2026-10-08-uniswap-v4-memestocks-design.md; rehearsed with the
///         owner steps in test/fork/V4PricingRolloutFork.t.sol. Nothing live changes until the owner steps run:
///         forge script script/mainnet/DeployV4Pricing.s.sol --rpc-url <base> --account frosty-main \
///              --sender <deployer> [--broadcast --slow --verify]
///         Then, as a separate reviewed step, V4PricingOwnerSteps.s.sol (same sender).
contract DeployV4Pricing is Script {
	function run() external returns (V4Pricing.Deployment memory d) {
		require(block.chainid == 8453, 'Base (8453) only');
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		address deployer = vm.parseJsonAddress(genesis, '.deployer');
		require(msg.sender == deployer, 'run as the genesis deployer (--sender)');
		PoolPriceRegistrar oldRegistrar =
			PoolPriceRegistrar(vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-pool-pricing.json'), '.registrar'));
		address queue = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-redemption.json'), '.queue');

		// the keeper and the subgraph start reading registrar V2 and the sampler here
		uint256 startBlock = block.number;
		vm.startBroadcast(deployer);
		d = V4Pricing.deploy(deployer, oldRegistrar, queue);
		vm.stopBroadcast();

		console2.log('V4PriceSampler', address(d.sampler));
		console2.log('PoolPriceRegistrarV2', address(d.registrar));
		console2.log('UniswapV4SwapAdapter', address(d.v4Adapter));
		console2.log('UniswapV3SwapAdapterV2', address(d.uniAdapter));
		console2.log('AerodromeSlipstreamSwapAdapterV2 (CL1)', address(d.slipstreamAdapter));
		console2.log('AerodromeSlipstreamSwapAdapterV2 (CL2)', address(d.slipstream2Adapter));
		console2.log('AerodromeSlipstreamSwapAdapterV2 (CL3)', address(d.slipstream3Adapter));
		console2.log('AerodromeBasicSwapAdapterV2', address(d.aerodromeBasicAdapter));
		console2.log('MinPoolLiquidityPolicy (registrar V2)', address(d.policy));
		console2.log('ComptrollerV4 blueprint deployer (registrar V2)', address(d.fundDeployer));
		// a dry run's simulated addresses must never reach the address book
		if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return d;
		vm.writeJson(serialize(d, startBlock), 'deployments/base-mainnet-v4.json');
	}

	/// @notice The address book entry V4PricingOwnerSteps.load reads back (the rehearsal round-trips it).
	function serialize(V4Pricing.Deployment memory d, uint256 startBlock) public returns (string memory) {
		string memory key = 'v4';
		vm.serializeAddress(key, 'sampler', address(d.sampler));
		vm.serializeAddress(key, 'registrar', address(d.registrar));
		vm.serializeAddress(key, 'v4Adapter', address(d.v4Adapter));
		vm.serializeAddress(key, 'uniAdapter', address(d.uniAdapter));
		vm.serializeAddress(key, 'slipstreamAdapter', address(d.slipstreamAdapter));
		vm.serializeAddress(key, 'slipstream2Adapter', address(d.slipstream2Adapter));
		vm.serializeAddress(key, 'slipstream3Adapter', address(d.slipstream3Adapter));
		vm.serializeAddress(key, 'aerodromeBasicAdapter', address(d.aerodromeBasicAdapter));
		vm.serializeAddress(key, 'policy', address(d.policy));
		vm.serializeAddress(key, 'fundDeployer', address(d.fundDeployer));
		return vm.serializeUint(key, 'startBlock', startBlock);
	}
}
