// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {FundProfileRegistry} from '../src/profile/FundProfileRegistry.sol';

/// @notice Single-contract broadcast (testnets): the fund links registry (side-by-side addition — touches nothing
///         already deployed). After the broadcast, wire the address into:
///           frosty-terminal  src/lib/tokens.ts INFRA.fundProfileRegistry
contract DeployFundProfileRegistry is Script {
	function run() external {
		vm.startBroadcast();
		FundProfileRegistry profiles = new FundProfileRegistry();
		vm.stopBroadcast();
		console2.log('FundProfileRegistry:', address(profiles));
	}
}
