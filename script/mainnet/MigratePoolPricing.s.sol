// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {MinPoolLiquidityPolicy} from '../../src/policies/MinPoolLiquidityPolicy.sol';
import {PoolPricing, IListingModule, ITwapListingRegistry} from './PoolPricing.sol';

/// @notice Steps 2–6 of PoolPricing on Base — the switch-over, rehearsed by
///         test/fork/PoolPricingFork.t.sol: the registrar takes the VI from the module, every
///         non-B20 TWAP listing moves to a pool adapter on its pool, the 15 approved tokens move to
///         Chainlink (each refused unless its feed is within 5% of its pool price), and new funds get
///         the long-tail policy and fund v2. One transaction per change (≈ 180); every step skips
///         what is already done, so a re-run after an interruption sends only what is missing.
///         Run as the genesis deployer (it owns the module, the factory and the registrar) AFTER
///         DeployPoolPricing, then run migrate-b20-listings.sh for the Coinbase B20 tokens, then
///         turn the funds-keeper lister off.
///         Run: forge script script/mainnet/MigratePoolPricing.s.sol --rpc-url <base> --account frosty-main \
///              --sender <deployer> [--broadcast --slow]
///         Env: [DEPLOYMENTS_FILE] (default deployments/base-mainnet-pool-pricing.json)
contract MigratePoolPricing is Script {
	string internal constant GENESIS_FILE = 'deployments/base-mainnet.json';
	string internal constant TWAP_V2_FILE = 'deployments/base-mainnet-twap-v2.json';

	function run() external {
		require(block.chainid == 8453, 'Base (8453) only');
		string memory genesis = vm.readFile(GENESIS_FILE);
		string memory twapV2 = vm.readFile(TWAP_V2_FILE);
		string memory book = vm.readFile(vm.envOr('DEPLOYMENTS_FILE', string('deployments/base-mainnet-pool-pricing.json')));

		address deployer = vm.parseJsonAddress(genesis, '.deployer');
		ValueInterpreter vi = ValueInterpreter(vm.parseJsonAddress(genesis, '.valueInterpreter'));
		FundFactory factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		IListingModule module = IListingModule(vm.parseJsonAddress(twapV2, '.module'));
		ITwapListingRegistry registry = ITwapListingRegistry(vm.parseJsonAddress(twapV2, '.registry'));
		PoolPriceRegistrar registrar = PoolPriceRegistrar(vm.parseJsonAddress(book, '.registrar'));
		MinPoolLiquidityPolicy policy = MinPoolLiquidityPolicy(vm.parseJsonAddress(book, '.policy'));
		ComptrollerBlueprintDeployer fundDeployer = ComptrollerBlueprintDeployer(vm.parseJsonAddress(book, '.fundDeployer'));

		require(msg.sender == deployer, 'run as the genesis deployer');
		require(registrar.owner() == deployer, 'the deployer must own the registrar');
		require(address(registrar.valueInterpreter()) == address(vi), 'the registrar is wired to another VI');
		require(address(policy.registrar()) == address(registrar), 'the policy reads another registrar');
		require(fundDeployer.initcodeHash() == vm.parseJsonBytes32(book, '.fundInitcodeHash'), 'fund v2 build changed');

		address[] memory listed = registry.getListedAssets();
		address[] memory assets = PoolPricing.withoutB20(listed);

		vm.startBroadcast();
		PoolPricing.takeOverValueInterpreter(module, registrar);
		uint256 moved = PoolPricing.migrateListings(registrar, registry, assets);
		uint256 chainlinked = PoolPricing.listOnChainlink(registrar, PoolPricing.chainlinkListings());
		PoolPricing.setMandatoryPolicy(factory, policy);
		PoolPricing.setFundVersion(factory, fundDeployer);
		vm.stopBroadcast();

		require(vi.owner() == address(registrar), 'the registrar does not own the VI');
		for (uint256 i; i < assets.length; ++i) {
			require(!registry.isTwapPriced(assets[i]), 'a listing is still on the TWAP registry');
		}
		require(address(factory.comptrollerDeployer()) == address(fundDeployer), 'new funds are not v2');

		uint256 b20Left;
		for (uint256 i; i < listed.length; ++i) {
			if (PoolPricing.isB20(listed[i]) && registry.isTwapPriced(listed[i])) ++b20Left;
		}
		console2.log('moved onto pool adapters', moved);
		console2.log('moved onto Chainlink', chainlinked);
		console2.log('B20 listings left for migrate-b20-listings.sh', b20Left);
	}
}
