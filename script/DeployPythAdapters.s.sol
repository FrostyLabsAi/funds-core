// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {PythAggregatorAdapter} from '../src/pricing/PythAggregatorAdapter.sol';
import {IPyth} from '../src/interfaces/external/IPyth.sol';

/// @notice Batch-deploys PythAggregatorAdapters and registers each asset as a VI primitive.
///         POLICY (decision log): Chainlink stays PRIMARY wherever a feed exists (B20
///         equities, crypto majors, XAU/XAG — plain addPrimitive with the Chainlink
///         aggregator, no adapter); Pyth adapters fill the rest of the Veranta universe
///         (oil, indexes, FX, long-tail equities). Feed ids come from the Veranta pair
///         catalog — see script/config/pyth-pair-map.json (regenerate from
///         data.veranta.xyz/v2/trading before mainnet, ids can rotate on redeploys).
/// @dev Env:
///      VALUE_INTERPRETER — the VI this deployer owns
///      PYTH             — Pyth Core (Base mainnet 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a)
///      PYTH_PRIMITIVES  — comma list of `asset:0xPriceId:confBps:heartbeatSecs:maxPushAgeSecs`
///                         e.g. `0xToken:0x16dad5…32f1:200:14400:600` (2% conf cap, 4h
///                         heartbeat, pushes must be < 10 min old — the anti-cherry-pick
///                         bound, security review 2026-09-22 H-3)
///      Heartbeat guidance: crypto 1 days; FX 1 days; equities/commodities 4 hours during
///      the pusher rollout (equity feeds stop publishing off-hours — that IS the gate).
contract DeployPythAdapters is Script {
	function run() external {
		ValueInterpreter interpreter = ValueInterpreter(vm.envAddress('VALUE_INTERPRETER'));
		IPyth pyth = IPyth(vm.envAddress('PYTH'));
		string[] memory entries = vm.split(vm.envString('PYTH_PRIMITIVES'), ',');

		vm.startBroadcast();
		for (uint256 i; i < entries.length; ++i) {
			string[] memory parts = vm.split(entries[i], ':');
			require(parts.length == 5, 'entry must be asset:priceId:confBps:heartbeat:maxPushAge');
			address asset = vm.parseAddress(parts[0]);
			bytes32 priceId = vm.parseBytes32(parts[1]);
			uint16 confBps = uint16(vm.parseUint(parts[2]));
			uint32 heartbeat = uint32(vm.parseUint(parts[3]));
			uint32 maxPushAge = uint32(vm.parseUint(parts[4]));

			string memory label = string.concat(IERC20Metadata(asset).symbol(), '/USD (Pyth)');
			PythAggregatorAdapter adapter = new PythAggregatorAdapter(pyth, priceId, confBps, maxPushAge, label);
			interpreter.addPrimitive(asset, address(adapter), heartbeat);
			console2.log(label, asset, address(adapter));
		}
		vm.stopBroadcast();
	}
}
