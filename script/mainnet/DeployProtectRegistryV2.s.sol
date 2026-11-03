// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {ProtectRegistryV2} from '../../src/protect/ProtectRegistryV2.sol';

/// @notice ProtectRegistryV2 on Base mainnet: one protect setting per account and pair (founder
///         2026-11-03). Ownerless, holds no funds and no permissions, so nothing to hand to the timelock.
///         V1's address stays in deployments/base-mainnet-protect.json; AdvisorRegistry is unchanged.
///         Writes deployments/base-mainnet-protect-v2.json: protectRegistry, and startBlock (a lower
///         bound of the deploy block, the keepers' PROTECT_START_BLOCK).
///         Then: terminal `npx tsx indexer/mainnet-deployments.ts` (reads this file too); keepers
///         PROTECT_REGISTRY, PROTECT_START_BLOCK. Settings on V1 don't carry over: save them again.
///         Run: forge script script/mainnet/DeployProtectRegistryV2.s.sol --rpc-url <base> --account frosty-main --sender <deployer> --broadcast --verify
///         Env: [DEPLOYMENTS_FILE] (default deployments/base-mainnet-protect-v2.json)
contract DeployProtectRegistryV2 is Script {
	function run() external {
		require(block.chainid == 8453, 'Base (8453) only');
		// the head before broadcasting: the deploy lands at or after it
		uint256 startBlock = block.number;

		vm.startBroadcast();
		ProtectRegistryV2 protect = new ProtectRegistryV2();
		vm.stopBroadcast();

		string memory k = 'protect';
		vm.serializeAddress(k, 'protectRegistry', address(protect));
		string memory out = vm.serializeUint(k, 'startBlock', startBlock);
		string memory file = vm.envOr('DEPLOYMENTS_FILE', string('deployments/base-mainnet-protect-v2.json'));
		vm.writeJson(out, file);

		console2.log('ProtectRegistryV2', address(protect));
		console2.log('keeper PROTECT_START_BLOCK', startBlock);
	}
}
