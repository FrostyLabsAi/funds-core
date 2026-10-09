// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {PoolPriceRegistrarV2} from '../../src/pricing/PoolPriceRegistrarV2.sol';
import {V4PriceSampler} from '../../src/pricing/V4PriceSampler.sol';
import {MinPoolLiquidityPolicy} from '../../src/policies/MinPoolLiquidityPolicy.sol';
import {UniswapV4SwapAdapter} from '../../src/adapters/UniswapV4SwapAdapter.sol';
import {UniswapV3SwapAdapterV2} from '../../src/adapters/UniswapV3SwapAdapterV2.sol';
import {AerodromeSlipstreamSwapAdapterV2} from '../../src/adapters/AerodromeSlipstreamSwapAdapterV2.sol';
import {AerodromeBasicSwapAdapterV2} from '../../src/adapters/AerodromeBasicSwapAdapterV2.sol';
import {V4Pricing} from './V4Pricing.sol';

/// @notice V4Pricing.ownerSteps from the genesis deployer, on what DeployV4Pricing wrote to
///         deployments/base-mainnet-v4.json: today's registrar (owner of the ValueInterpreter) moves under registrar
///         V2; StockifyFeeHook and o1's two LaunchHooks (Treasury as referrer), the NVDAc/SPCXc/AAPLc/GOOGLc/METAc quotes
///         and the keeper are approved; the Admin Safe becomes a v4 pool approver and the launch pools (STFY, BLUECHIP,
///         RAWR, MOONBASE, BASEASS) are approved; the six adapters are registered; new funds get the long-tail policy on registrar V2 and
///         the ComptrollerV4 deployer on registrar V2. Each step skips what is already done, so a re-run sends only
///         what is missing. Rehearsed in test/fork/V4PricingRolloutFork.t.sol.
///         forge script script/mainnet/V4PricingOwnerSteps.s.sol --rpc-url <base> --account frosty-main \
///              --sender <deployer> [--broadcast --slow]
contract V4PricingOwnerSteps is Script {
	function run() external {
		require(block.chainid == 8453, 'Base (8453) only');
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		address deployer = vm.parseJsonAddress(genesis, '.deployer');
		require(msg.sender == deployer, 'run as the genesis deployer (--sender)');
		FundFactory factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		address oldPolicy = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-pool-pricing.json'), '.policy');
		V4Pricing.Deployment memory d = load(vm.readFile('deployments/base-mainnet-v4.json'));
		address safe = vm.parseJsonAddress(genesis, '.safe');

		vm.startBroadcast(deployer);
		V4Pricing.ownerSteps(d, factory, oldPolicy, safe);
		vm.stopBroadcast();

		console2.log('today\'s registrar owner', d.registrar.oldRegistrar().owner());
		console2.log('new funds deploy through', address(factory.comptrollerDeployer()));
	}

	function load(string memory json) public pure returns (V4Pricing.Deployment memory d) {
		d.sampler = V4PriceSampler(vm.parseJsonAddress(json, '.sampler'));
		d.registrar = PoolPriceRegistrarV2(vm.parseJsonAddress(json, '.registrar'));
		d.v4Adapter = UniswapV4SwapAdapter(payable(vm.parseJsonAddress(json, '.v4Adapter')));
		d.uniAdapter = UniswapV3SwapAdapterV2(vm.parseJsonAddress(json, '.uniAdapter'));
		d.slipstreamAdapter = AerodromeSlipstreamSwapAdapterV2(vm.parseJsonAddress(json, '.slipstreamAdapter'));
		d.slipstream2Adapter = AerodromeSlipstreamSwapAdapterV2(vm.parseJsonAddress(json, '.slipstream2Adapter'));
		d.slipstream3Adapter = AerodromeSlipstreamSwapAdapterV2(vm.parseJsonAddress(json, '.slipstream3Adapter'));
		d.aerodromeBasicAdapter = AerodromeBasicSwapAdapterV2(vm.parseJsonAddress(json, '.aerodromeBasicAdapter'));
		d.policy = MinPoolLiquidityPolicy(vm.parseJsonAddress(json, '.policy'));
		d.fundDeployer = ComptrollerBlueprintDeployer(vm.parseJsonAddress(json, '.fundDeployer'));
	}
}
