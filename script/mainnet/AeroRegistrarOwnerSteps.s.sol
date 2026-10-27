// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {MinPoolLiquidityPolicy} from '../../src/policies/MinPoolLiquidityPolicy.sol';
import {UniswapV4SwapAdapter} from '../../src/adapters/UniswapV4SwapAdapter.sol';
import {PoolPriceRegistrarV3} from '../../src/pricing/PoolPriceRegistrarV3.sol';
import {AeroRegistrar} from './AeroRegistrar.sol';

/// @notice The owner's switch to the Aero venue (AeroRegistrar.ownerSteps), after DeployAeroRegistrar.s.sol: registrar
///         V2 handed to V3, V3's v4 adapter registered, V3's long-tail policy mandatory in V2's place, new funds built
///         on V3. Re-runnable; funds already created keep their registrar. Run as the genesis deployer:
///         forge script script/mainnet/AeroRegistrarOwnerSteps.s.sol --rpc-url <base> \
///              --account frosty-main --sender <deployer> [--broadcast --slow]
contract AeroRegistrarOwnerSteps is Script {
	function run() external {
		require(block.chainid == 8453, 'Base (8453) only');
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		address deployer = vm.parseJsonAddress(genesis, '.deployer');
		require(msg.sender == deployer, 'run as the genesis deployer (--sender)');
		FundFactory factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		string memory book = vm.readFile('deployments/base-mainnet-aero-registrar.json');
		AeroRegistrar.Deployed memory d = AeroRegistrar.Deployed({
			registrar: PoolPriceRegistrarV3(vm.parseJsonAddress(book, '.registrar')),
			policy: MinPoolLiquidityPolicy(vm.parseJsonAddress(book, '.policy')),
			v4Adapter: UniswapV4SwapAdapter(payable(vm.parseJsonAddress(book, '.v4Adapter'))),
			fundV6Deployer: ComptrollerBlueprintDeployer(vm.parseJsonAddress(book, '.fundV6Deployer'))
		});

		vm.startBroadcast(deployer);
		AeroRegistrar.ownerSteps(d, factory);
		vm.stopBroadcast();

		console2.log('registrar V2 owned by', d.registrar.registrarV2().owner());
		console2.log('new funds deploy through', address(factory.comptrollerDeployer()));
	}
}
