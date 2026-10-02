// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {TwapListingRegistryV2} from '../../src/pricing/TwapListingRegistryV2.sol';
import {TwapExposurePolicyV3} from '../../src/policies/TwapExposurePolicyV3.sol';
import {TwapPolicyV3} from './TwapPolicyV3.sol';

/// @notice TwapExposurePolicyV3 on the LIVE Base factory — what test/fork/TwapPolicyV3Fork rehearses.
///         Run by the genesis deployer while it still owns the FundFactory (TwapPolicyV3 lists the
///         three steps: 4 transactions). Reads deployments/base-mainnet.json (factory, twapPolicy,
///         deployer) and deployments/base-mainnet-twap-v2.json (registry, policy). Writes
///         deployments/base-mainnet-twap-policy-v3.json: policy, replaces (V2), startBlock (a lower
///         bound of the deploy block). StartFundsGovernance / Finish / Verify read it.
///         A second run reverts before sending anything (the mandatory list no longer names V2).
///         Run: forge script script/mainnet/DeployTwapPolicyV3.s.sol --rpc-url <base> --account <keystore> \
///              --sender <deployer> --broadcast --slow [--verify]
///         Env: [DEPLOYMENTS_FILE] (default deployments/base-mainnet-twap-policy-v3.json)
contract DeployTwapPolicyV3 is Script {
	string internal constant GENESIS_FILE = 'deployments/base-mainnet.json';
	string internal constant TWAP_V2_FILE = 'deployments/base-mainnet-twap-v2.json';

	function run() external {
		require(block.chainid == 8453, 'Base (8453) only');
		string memory file = vm.envOr('DEPLOYMENTS_FILE', string('deployments/base-mainnet-twap-policy-v3.json'));
		// DEPLOYMENTS_FILE must never name another address book: only a V3 book has `replaces`
		if (vm.exists(file)) {
			string memory existing = vm.readFile(file);
			require(vm.keyExistsJson(existing, '.replaces'), 'DEPLOYMENTS_FILE is another address book');
		}

		string memory genesis = vm.readFile(GENESIS_FILE);
		string memory twapV2 = vm.readFile(TWAP_V2_FILE);
		TwapPolicyV3.Config memory cfg = TwapPolicyV3.Config({
			deployer: vm.parseJsonAddress(genesis, '.deployer'),
			factory: FundFactory(vm.parseJsonAddress(genesis, '.factory')),
			registry: TwapListingRegistryV2(vm.parseJsonAddress(twapV2, '.registry')),
			policyV1: vm.parseJsonAddress(genesis, '.twapPolicy'),
			policyV2: vm.parseJsonAddress(twapV2, '.policy')
		});
		require(msg.sender == cfg.deployer, 'run as the genesis deployer (it owns the factory)');
		// the head before broadcasting: the deploy lands at or after it
		uint256 startBlock = block.number;

		vm.startBroadcast();
		TwapExposurePolicyV3 policy = TwapPolicyV3.deploy(cfg);
		vm.stopBroadcast();

		string memory k = 'twapPolicyV3';
		vm.serializeAddress(k, 'policy', address(policy));
		vm.serializeAddress(k, 'replaces', cfg.policyV2);
		string memory out = vm.serializeUint(k, 'startBlock', startBlock);
		vm.writeJson(out, file);

		console2.log('TwapExposurePolicyV3', address(policy));
		console2.log('mandatory on hooks 4, 0, 5, 6; approved replacement of V1', cfg.policyV1);
		console2.log('                                                and of V2', cfg.policyV2);
		console2.log('written to', file);
	}
}
