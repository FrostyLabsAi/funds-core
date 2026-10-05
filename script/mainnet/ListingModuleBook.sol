// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Vm} from 'forge-std/Vm.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';

/// @notice The VI's owner: the PoolPriceRegistrar after the pool-pricing switch-over, the TWAP v2
///         PriceListingModule before it. Both forward any VI admin call through `execute`.
interface IValueInterpreterAdmin {
	function execute(bytes calldata data) external returns (bytes memory);
}

/// @title ListingModuleBook
/// @notice Who the listing scripts send VI admin calls through: the VI's current owner, provided it
///         is the registrar named in the pool-pricing book (deployments/base-mainnet-pool-pricing.json,
///         or POOL_PRICING_FILE) or the module named in the TWAP v2 book (…-twap-v2.json, or
///         TWAP_V2_FILE). Anything else is refused, so a listing never targets the wrong contract.
library ListingModuleBook {
	function admin(Vm vm, string memory genesisJson) internal view returns (IValueInterpreterAdmin) {
		address owner = ValueInterpreter(vm.parseJsonAddress(genesisJson, '.valueInterpreter')).owner();
		string memory poolFile = vm.envOr('POOL_PRICING_FILE', string('deployments/base-mainnet-pool-pricing.json'));
		if (vm.exists(poolFile) && vm.parseJsonAddress(vm.readFile(poolFile), '.registrar') == owner) {
			return IValueInterpreterAdmin(owner);
		}
		string memory twapFile = vm.envOr('TWAP_V2_FILE', string('deployments/base-mainnet-twap-v2.json'));
		if (vm.exists(twapFile) && vm.parseJsonAddress(vm.readFile(twapFile), '.module') == owner) {
			return IValueInterpreterAdmin(owner);
		}
		revert('the VI is owned by neither the pool-pricing registrar nor the TWAP v2 module');
	}
}
