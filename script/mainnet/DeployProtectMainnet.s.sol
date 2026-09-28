// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {ProtectRegistry} from '../../src/protect/ProtectRegistry.sol';
import {AdvisorRegistry} from '../../src/protect/AdvisorRegistry.sol';

/// @notice Protect Mode on Base mainnet, right after genesis (founder: Protect is part of the launch).
///         ProtectRegistry: a fund's manager publishes trailing-stop / hedge protection for the fund's
///         Veranta position. AdvisorRegistry: the manager's advice switch, cadence and per-call fee cap.
///         Both are ownerless and hold no funds and no permissions — nothing to hand to the timelock.
///         Writes deployments/base-mainnet-protect.json: protectRegistry, advisorRegistry, and
///         startBlock (a lower bound of the deploy block — the protect keeper's PROTECT_START_BLOCK).
///         Then: terminal `npx tsx indexer/mainnet-deployments.ts` (reads this file too); keepers
///         PROTECT_REGISTRY, PROTECT_START_BLOCK, ADVISOR_REGISTRY.
///         Run: forge script script/mainnet/DeployProtectMainnet.s.sol --rpc-url <base> --account <keystore> --broadcast --verify
///         Env: [DEPLOYMENTS_FILE] (default deployments/base-mainnet-protect.json)
contract DeployProtectMainnet is Script {
	function run() external {
		require(block.chainid == 8453, 'Base (8453) only');
		// the head before broadcasting: the deploy lands at or after it
		uint256 startBlock = block.number;

		vm.startBroadcast();
		ProtectRegistry protect = new ProtectRegistry();
		AdvisorRegistry advisor = new AdvisorRegistry();
		vm.stopBroadcast();

		string memory k = 'protect';
		vm.serializeAddress(k, 'protectRegistry', address(protect));
		vm.serializeAddress(k, 'advisorRegistry', address(advisor));
		string memory out = vm.serializeUint(k, 'startBlock', startBlock);
		string memory file = vm.envOr('DEPLOYMENTS_FILE', string('deployments/base-mainnet-protect.json'));
		vm.writeJson(out, file);

		console2.log('ProtectRegistry', address(protect));
		console2.log('AdvisorRegistry', address(advisor));
		console2.log('keeper PROTECT_START_BLOCK', startBlock);
	}
}
