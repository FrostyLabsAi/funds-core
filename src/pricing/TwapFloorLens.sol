// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {TwapListingRegistry} from './TwapListingRegistry.sol';
import {TwapAggregatorAdapter} from './TwapAggregatorAdapter.sol';

/// @title TwapFloorLens
/// @notice Read-only helper for floor keepers (the FrostyFi keeper workflow): which listed
///         assets would `pokeFloor` actually change right now? It applies the registry's own
///         rule — an adapter that cannot answer (the pool cannot serve the window) counts as
///         under the floor — inside a try/catch, so one unanswerable pool never reverts the
///         whole read. Stateless and registry-agnostic: one deployment serves any registry.
contract TwapFloorLens {
	/// @notice Listed assets whose pool state disagrees with the stored 72-hour clock: under
	///         the floor with no clock running, or back over it while one runs. In listing order.
	function assetsNeedingPoke(TwapListingRegistry registry) external view returns (address[] memory due) {
		address[] memory assets = registry.getListedAssets();
		due = new address[](assets.length);
		uint256 count;
		for (uint256 i; i < assets.length; ++i) {
			(TwapAggregatorAdapter adapter,,,, uint64 belowFloorSince) = registry.listings(assets[i]);
			bool below;
			try adapter.isBelowFloor() returns (bool b) {
				below = b;
			} catch {
				below = true;
			}
			if (below != (belowFloorSince != 0)) due[count++] = assets[i];
		}
		assembly ('memory-safe') {
			mstore(due, count)
		}
	}
}
