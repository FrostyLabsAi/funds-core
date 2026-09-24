// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {RedstonePriceStore} from '../src/pricing/RedstonePriceStore.sol';
import {RedstoneAggregatorAdapter} from '../src/pricing/RedstoneAggregatorAdapter.sol';
import {PriceMarker} from '../src/pricing/PriceMarker.sol';

/// @notice The RedStone price tier: a RedstonePriceStore for redstone-primary-prod (or reuse
///         one), one RedstoneAggregatorAdapter per feed, a PriceMarker for underlyings with no
///         token on the chain (perp legs), and each asset registered as a VI primitive.
///         POLICY: Chainlink stays primary wherever it has a feed; RedStone fills the rest.
///         Perps: after this, the position-factory owner maps each pair with
///         `setPairAsset(pairIndex, marker)`.
/// @dev Env:
///      VALUE_INTERPRETER — the VI this deployer owns
///      REDSTONE_STORE    — optional: reuse an existing store instead of deploying one
///      REDSTONE_ENTRIES  — comma list of `asset:FEED_ID:heartbeatSecs:maxPushAgeSecs`, where
///                          asset is a token address or the word `marker` (deploys a
///                          PriceMarker named after the feed), e.g.
///                          `marker:ARB:86400:600,0xToken:KAITO:86400:600`
///      Heartbeat: crypto 1 day. EQUITIES: DO NOT LIST until RedStone's off-hours behaviour
///      is verified (if timestamps keep advancing while the market is closed, the heartbeat
///      stops being a market-hours gate).
contract DeployRedstoneTier is Script {
	function run() external {
		ValueInterpreter interpreter = ValueInterpreter(vm.envAddress('VALUE_INTERPRETER'));
		string[] memory entries = vm.split(vm.envString('REDSTONE_ENTRIES'), ',');

		vm.startBroadcast();
		RedstonePriceStore store = RedstonePriceStore(vm.envOr('REDSTONE_STORE', address(0)));
		if (address(store) == address(0)) store = new RedstonePriceStore('redstone-primary-prod', _primaryProdSigners(), 3);
		console2.log('redstoneStore', address(store));

		for (uint256 i; i < entries.length; ++i) {
			string[] memory parts = vm.split(entries[i], ':');
			require(parts.length == 4, 'entry must be asset:FEED_ID:heartbeat:maxPushAge');
			string memory feed = parts[1];
			address asset = keccak256(bytes(parts[0])) == keccak256('marker')
				? address(new PriceMarker(string.concat(feed, ' price marker'), string.concat('pm', feed)))
				: vm.parseAddress(parts[0]);
			string memory label = string.concat(IERC20Metadata(asset).symbol(), '/USD (RedStone)');
			RedstoneAggregatorAdapter adapter =
				new RedstoneAggregatorAdapter(store, bytes32(bytes(feed)), uint32(vm.parseUint(parts[3])), label);
			interpreter.addPrimitive(asset, address(adapter), uint32(vm.parseUint(parts[2])));
			console2.log(label, asset, address(adapter));
		}
		vm.stopBroadcast();
	}

	/// @dev redstone-primary-prod, threshold 3 — as published in RedStone's
	///      PrimaryProdDataServiceConsumerBase and seen signing on the gateway (2026-09-24)
	function _primaryProdSigners() internal pure returns (address[] memory s) {
		s = new address[](5);
		s[0] = 0x8BB8F32Df04c8b654987DAaeD53D6B6091e3B774;
		s[1] = 0xdEB22f54738d54976C4c0fe5ce6d408E40d88499;
		s[2] = 0x51Ce04Be4b3E32572C4Ec9135221d0691Ba7d202;
		s[3] = 0xDD682daEC5A90dD295d14DA4b0bec9281017b5bE;
		s[4] = 0x9c5AE89C4Af6aA32cE58588DBaF90d18a855B6de;
	}
}
