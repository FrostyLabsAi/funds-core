// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Vm} from 'forge-std/Vm.sol';
import {PriceListingModule} from '../../src/pricing/PriceListingModule.sol';

/// @title ListingModuleBook
/// @notice The PriceListingModule the listing scripts send VI admin calls through: TWAP listing v2
///         made it the VI's owner (deployments/base-mainnet-twap-v2.json, or TWAP_V2_FILE). Refuses a
///         module that isn't the genesis VI's owner, so a listing never targets the wrong book.
library ListingModuleBook {
	function module(Vm vm, string memory genesisJson) internal view returns (PriceListingModule m) {
		string memory twapFile = vm.envOr('TWAP_V2_FILE', string('deployments/base-mainnet-twap-v2.json'));
		require(vm.exists(twapFile), 'TWAP v2 book not found: the VI is owned by the PriceListingModule it names');
		m = PriceListingModule(vm.parseJsonAddress(vm.readFile(twapFile), '.module'));
		address vi = vm.parseJsonAddress(genesisJson, '.valueInterpreter');
		require(address(m.valueInterpreter()) == vi, 'TWAP v2 module is not the genesis VI module');
		require(m.valueInterpreter().owner() == address(m), 'the module does not own the VI');
	}
}
