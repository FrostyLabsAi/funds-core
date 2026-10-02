// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {TwapListingRegistryV2} from './TwapListingRegistryV2.sol';
import {ITwapPriceAdapter} from '../interfaces/ITwapPriceAdapter.sol';

/// @title TwapFloorLensV2
/// @notice Paged version of TwapFloorLens for a registry with hundreds of listings: which assets
///         in [offset, offset+limit) would `pokeFloor` change now? A restore (clearing a clock)
///         only takes effect for a lister caller, i.e. the keeper via `PriceListingModule.pokeFloor`;
///         a stranger's poke only starts clocks.
/// @dev Same rule as v1 (an adapter that cannot answer counts as under the floor), per page, so
///      one eth_call stays within RPC gas caps.
/// @dev Matches the registry's floor test, except an out-of-gas read counts as due here (harmless in an eth_call).
/// @dev The floor is two-part (Ruling 23): `isBelowFloor()` walks a concentrated pool's band whenever its
///      reserve holds, so a page costs up to one band walk per concentrated listing — size pages by gas.
contract TwapFloorLensV2 {
	/// @notice Listed assets in [offset, offset+limit) whose pool state disagrees with the stored
	///         72-hour clock, in listing order.
	/// @return due the assets a poke would change
	/// @return nextOffset where the next page starts; `registry.listedCount()` means done
	function assetsNeedingPoke(TwapListingRegistryV2 registry, uint256 offset, uint256 limit)
		external
		view
		returns (address[] memory due, uint256 nextOffset)
	{
		address[] memory assets = registry.getListedAssetsPage(offset, limit);
		uint256 n = registry.listedCount();
		nextOffset = offset + assets.length;
		if (nextOffset > n) nextOffset = n;
		due = new address[](assets.length);
		uint256 count;
		for (uint256 i; i < assets.length; ++i) {
			(ITwapPriceAdapter adapter,,,, uint64 belowFloorSince) = registry.listings(assets[i]);
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
