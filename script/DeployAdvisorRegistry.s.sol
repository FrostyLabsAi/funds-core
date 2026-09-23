// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {AdvisorRegistry} from '../src/protect/AdvisorRegistry.sol';

/// @notice Single-contract broadcast: the per-trader advisory-preferences registry
///         (side-by-side addition — touches nothing already deployed). After the
///         broadcast, wire the address into:
///           frosty-terminal  src/lib/tokens.ts INFRA.advisorRegistry
///           funds-keeper     env ADVISOR_REGISTRY
contract DeployAdvisorRegistry is Script {
	function run() external {
		vm.startBroadcast();
		AdvisorRegistry registry = new AdvisorRegistry();
		vm.stopBroadcast();
		console2.log('AdvisorRegistry:', address(registry));
	}
}
