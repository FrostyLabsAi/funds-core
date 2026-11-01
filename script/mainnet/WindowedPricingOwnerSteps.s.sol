// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {CumulativeSlippageTolerancePolicy} from '../../src/policies/CumulativeSlippageTolerancePolicy.sol';
import {MinPoolLiquidityPolicy} from '../../src/policies/MinPoolLiquidityPolicy.sol';
import {UniswapV4SwapAdapter} from '../../src/adapters/UniswapV4SwapAdapter.sol';
import {ClmVaultPriceFeed} from '../../src/pricing/ClmVaultPriceFeed.sol';
import {PoolPriceRegistrarV2} from '../../src/pricing/PoolPriceRegistrarV2.sol';
import {PoolPriceRegistrarV3} from '../../src/pricing/PoolPriceRegistrarV3.sol';
import {PoolPriceRegistrarWindowed} from '../../src/pricing/PoolPriceRegistrarWindowed.sol';
import {WindowedPricing} from './WindowedPricing.sol';

/// @notice The owner's switch to the fixed-adapter chain (WindowedPricing), after DeployWindowedPricing.s.sol. Re-runnable:
///         each step skips what is done. New funds switch only once no token is left on an old clone, so the order is:
///         1. run this: chain wired, VI handed over, every token a forge script can run moved;
///         2. script/mainnet/migrate-windowed-b20.sh (B20 tokens and quotes, with cast);
///         3. run this again: new funds switch.
///         Run as the genesis deployer:
///         forge script script/mainnet/WindowedPricingOwnerSteps.s.sol --rpc-url <base> \
///              --account frosty-main --sender <deployer> [--broadcast --slow]
contract WindowedPricingOwnerSteps is Script {
	function run() external {
		require(block.chainid == 8453, 'Base (8453) only');
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		address deployer = vm.parseJsonAddress(genesis, '.deployer');
		require(msg.sender == deployer, 'run as the genesis deployer (--sender)');
		FundFactory factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		string memory book = vm.readFile('deployments/base-mainnet-windowed-pricing.json');
		WindowedPricing.Deployed memory d = WindowedPricing.Deployed({
			base: PoolPriceRegistrarWindowed(vm.parseJsonAddress(book, '.base')),
			registrarV2: PoolPriceRegistrarV2(vm.parseJsonAddress(book, '.registrarV2')),
			registrar: PoolPriceRegistrarV3(vm.parseJsonAddress(book, '.registrar')),
			policy: MinPoolLiquidityPolicy(vm.parseJsonAddress(book, '.policy')),
			slippage: CumulativeSlippageTolerancePolicy(vm.parseJsonAddress(book, '.slippage')),
			v4Adapter: UniswapV4SwapAdapter(payable(vm.parseJsonAddress(book, '.v4Adapter'))),
			clmFeed: ClmVaultPriceFeed(vm.parseJsonAddress(book, '.clmFeed')),
			fundV6Deployer: ComptrollerBlueprintDeployer(vm.parseJsonAddress(book, '.fundV6Deployer'))
		});

		vm.startBroadcast(deployer);
		WindowedPricing.wire(d);
		WindowedPricing.handOverVi(d);
		(uint256 moved, uint256 left) = WindowedPricing.moveAll(d);
		if (left == 0) WindowedPricing.switchNewFunds(d, factory);
		vm.stopBroadcast();

		console2.log('tokens moved this run', moved);
		console2.log('tokens left for migrate-windowed-b20.sh', left);
		console2.log('new funds deploy through', address(factory.comptrollerDeployer()));
	}
}
