// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {TwapFloorLens} from '../src/pricing/TwapFloorLens.sol';

/// @notice Single-contract broadcast: the stateless floor lens the TWAP floor-poke keeper
///         workflow reads (side-by-side addition — touches nothing already deployed; one
///         deployment per chain serves any TwapListingRegistry). After the broadcast, point the
///         workflow's read node at it with the chain's registry as the argument.
///         Run: forge script script/DeployTwapFloorLens.s.sol --rpc-url <rpc> --broadcast --private-key <key>
contract DeployTwapFloorLens is Script {
	function run() external {
		vm.startBroadcast();
		TwapFloorLens lens = new TwapFloorLens();
		vm.stopBroadcast();
		console2.log('TwapFloorLens:', address(lens));
	}
}
