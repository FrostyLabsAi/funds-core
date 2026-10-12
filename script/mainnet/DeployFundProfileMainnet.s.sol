// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {FundProfileRegistry} from '../../src/profile/FundProfileRegistry.sol';

/// @notice The fund links registry on Base mainnet (founder 2026-10-11): a fund's manager publishes its website and
///         social links for investors. Ownerless, holds no funds and no permissions: nothing to hand over.
///         Writes deployments/base-mainnet-profile.json: fundProfileRegistry.
///         Then: terminal `npx tsx indexer/mainnet-deployments.ts` (reads this file too).
///         Run: forge script script/mainnet/DeployFundProfileMainnet.s.sol --rpc-url <base> --account <keystore> --broadcast --verify
///         Env: [DEPLOYMENTS_FILE] (default deployments/base-mainnet-profile.json)
contract DeployFundProfileMainnet is Script {
	function run() external {
		require(block.chainid == 8453, 'Base (8453) only');

		vm.startBroadcast();
		FundProfileRegistry profiles = new FundProfileRegistry();
		vm.stopBroadcast();

		string memory out = vm.serializeAddress('profile', 'fundProfileRegistry', address(profiles));
		string memory file = vm.envOr('DEPLOYMENTS_FILE', string('deployments/base-mainnet-profile.json'));
		vm.writeJson(out, file);

		console2.log('FundProfileRegistry', address(profiles));
	}
}
