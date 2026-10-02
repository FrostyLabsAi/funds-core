// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {TwapListingV2} from './TwapListingV2.sol';

/// @notice TWAP listing v2 on the LIVE Base genesis — what test/fork/TwapListingV2Fork rehearses.
///         Run by the genesis deployer while it still owns the ValueInterpreter and the FundFactory
///         (TwapListingV2 lists the seven steps): afterwards the VI is owned by the new
///         PriceListingModule, which the deployer owns until the governance handoff.
///         Known limit: funds created BEFORE this keep TwapExposurePolicy v1, which reads the empty
///         v1 registry — V2 listings are uncapped for them and the delisted-buy block does not
///         apply (today only the founder's degen fund, where caps are skipped anyway). A later
///         `createReconfigurationRequest` moves such a fund to v2, once the factory owner approves
///         `setPolicyReplacement(v1, v2)`.
///         Reads deployments/base-mainnet.json (valueInterpreter, factory, twapPolicy, deployer).
///         Writes deployments/base-mainnet-twap-v2.json: registry, module, policy, lens, the swap
///         adapters (slipstream3Adapter, uniswapV2Adapter, aerodromeBasicAdapter — all registered on
///         the factory), the registry's recorder (Uniswap v2 observation recorder) and adapter
///         deployers (clDeployer, v2Deployer, aeroDeployer), keeper (zero when unset), and
///         startBlock (a lower bound of the deploy block). Plans B (keeper) and C (terminal) read it.
///         Run: forge script script/mainnet/DeployTwapListingV2.s.sol --rpc-url <base> --account <keystore> \
///              --sender <deployer> --broadcast --slow [--verify]
///         Env: [TWAP_KEEPER] (the auto-lister's wallet; unset = add it later with module.setKeeper),
///              [DEPLOYMENTS_FILE] (default deployments/base-mainnet-twap-v2.json)
contract DeployTwapListingV2 is Script {
	string internal constant GENESIS_FILE = 'deployments/base-mainnet.json';

	function run() external {
		require(block.chainid == 8453, 'Base (8453) only');
		string memory file = vm.envOr('DEPLOYMENTS_FILE', string('deployments/base-mainnet-twap-v2.json'));
		// DEPLOYMENTS_FILE names the genesis book in the listing scripts: never write over it
		require(
			!vm.exists(file) || !vm.keyExistsJson(vm.readFile(file), '.valueInterpreter'),
			'DEPLOYMENTS_FILE is the genesis address book'
		);

		string memory genesis = vm.readFile(GENESIS_FILE);
		TwapListingV2.Config memory cfg = TwapListingV2.Config({
			deployer: vm.parseJsonAddress(genesis, '.deployer'),
			valueInterpreter: ValueInterpreter(vm.parseJsonAddress(genesis, '.valueInterpreter')),
			factory: FundFactory(vm.parseJsonAddress(genesis, '.factory')),
			twapPolicyV1: vm.parseJsonAddress(genesis, '.twapPolicy'),
			keeper: vm.envOr('TWAP_KEEPER', address(0))
		});
		require(msg.sender == cfg.deployer, 'run as the genesis deployer (it owns the VI and the factory)');
		if (cfg.keeper == address(0)) console2.log('TWAP_KEEPER unset: no keeper yet (module.setKeeper later)');
		else console2.log('TWAP_KEEPER', cfg.keeper);
		// the head before broadcasting: the deploy lands at or after it
		uint256 startBlock = block.number;

		vm.startBroadcast();
		TwapListingV2.Deployed memory d = TwapListingV2.deploy(cfg);
		vm.stopBroadcast();

		string memory k = 'twapV2';
		vm.serializeAddress(k, 'registry', address(d.registry));
		vm.serializeAddress(k, 'module', address(d.module));
		vm.serializeAddress(k, 'policy', address(d.policy));
		vm.serializeAddress(k, 'lens', address(d.lens));
		vm.serializeAddress(k, 'slipstream3Adapter', d.slipstream3Adapter);
		vm.serializeAddress(k, 'uniswapV2Adapter', d.uniswapV2Adapter);
		vm.serializeAddress(k, 'aerodromeBasicAdapter', d.aerodromeBasicAdapter);
		vm.serializeAddress(k, 'recorder', address(d.recorder));
		vm.serializeAddress(k, 'clDeployer', address(d.clDeployer));
		vm.serializeAddress(k, 'v2Deployer', address(d.v2Deployer));
		vm.serializeAddress(k, 'aeroDeployer', address(d.aeroDeployer));
		vm.serializeAddress(k, 'keeper', cfg.keeper);
		string memory out = vm.serializeUint(k, 'startBlock', startBlock);
		vm.writeJson(out, file);

		console2.log('TWAP listing v2 written to', file);
		console2.log('TwapListingRegistryV2', address(d.registry));
		console2.log('PriceListingModule (owns the VI)', address(d.module));
		console2.log('TwapExposurePolicyV2', address(d.policy));
		console2.log('TwapFloorLensV2', address(d.lens));
		console2.log('slipstream3Adapter', d.slipstream3Adapter);
		console2.log('uniswapV2Adapter', d.uniswapV2Adapter);
		console2.log('aerodromeBasicAdapter', d.aerodromeBasicAdapter);
		console2.log('UniswapV2ObservationRecorder', address(d.recorder));
		console2.log('clDeployer', address(d.clDeployer));
		console2.log('v2Deployer', address(d.v2Deployer));
		console2.log('aeroDeployer', address(d.aeroDeployer));
		console2.log('startBlock', startBlock);
	}
}
