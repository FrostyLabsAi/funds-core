// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Vm} from 'forge-std/Vm.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';

/// @notice The VI's owner: the PoolPriceRegistrar after the pool-pricing switch-over, the TWAP v2
///         PriceListingModule before it. Both forward any VI admin call through `execute`.
interface IValueInterpreterAdmin {
	function execute(bytes calldata data) external returns (bytes memory);
}

/// @notice PoolPriceRegistrarV2's passthrough to the registrar it owns (owner only).
interface IRegistrarV2Passthrough {
	function callOldRegistrar(bytes calldata data) external returns (bytes memory result);
}

/// @notice Where a listing script's VI admin calls go: the VI's owner, called directly by its owner,
///         or — since registrar V2 took ownership of that registrar (2026-10-09) — through registrar
///         V2's `callOldRegistrar`, which only registrar V2's owner (the deployer) may call; once registrar V3
///         owns V2 (the Aero venue, 2026-10-25), through V3's `callOldRegistrar`, the same call one hop further.
struct ViAdmin {
	IValueInterpreterAdmin owner; // the VI's owner (today's registrar)
	IRegistrarV2Passthrough registrarV2; // that registrar's owner when it is registrar V2 (or V3 when V3 owns V2), else zero
}

using ListingModuleBook for ViAdmin global;

/// @title ListingModuleBook
/// @notice Who the listing scripts send VI admin calls through: the VI's current owner, provided it
///         is the registrar named in the pool-pricing book (deployments/base-mainnet-pool-pricing.json,
///         or POOL_PRICING_FILE) or the module named in the TWAP v2 book (…-twap-v2.json, or
///         TWAP_V2_FILE). Anything else is refused, so a listing never targets the wrong contract.
///         When that registrar is owned by the registrar V2 named in the v4 book
///         (deployments/base-mainnet-v4.json, or V4_FILE), calls go through registrar V2.
library ListingModuleBook {
	function admin(Vm vm, string memory genesisJson) internal view returns (ViAdmin memory) {
		address owner = ValueInterpreter(vm.parseJsonAddress(genesisJson, '.valueInterpreter')).owner();
		string memory poolFile = vm.envOr('POOL_PRICING_FILE', string('deployments/base-mainnet-pool-pricing.json'));
		if (vm.exists(poolFile) && vm.parseJsonAddress(vm.readFile(poolFile), '.registrar') == owner) {
			return ViAdmin(IValueInterpreterAdmin(owner), _registrarV2(vm, Ownable(owner).owner()));
		}
		string memory twapFile = vm.envOr('TWAP_V2_FILE', string('deployments/base-mainnet-twap-v2.json'));
		if (vm.exists(twapFile) && vm.parseJsonAddress(vm.readFile(twapFile), '.module') == owner) {
			return ViAdmin(IValueInterpreterAdmin(owner), IRegistrarV2Passthrough(address(0)));
		}
		revert('the VI is owned by neither the pool-pricing registrar nor the TWAP v2 module');
	}

	/// @notice One VI admin call (`data`, e.g. an encoded `addPrimitive`) through the VI's owner.
	function execute(ViAdmin memory self, bytes memory data) internal returns (bytes memory) {
		if (address(self.registrarV2) == address(0)) return self.owner.execute(data);
		bytes memory result = self.registrarV2.callOldRegistrar(abi.encodeCall(IValueInterpreterAdmin.execute, (data)));
		return abi.decode(result, (bytes));
	}

	/// @dev `registrarOwner` when it is the registrar V2 named in the v4 book — or, when V2 is owned by the registrar
	///      V3 named in the Aero registrar book (or AERO_REGISTRAR_FILE), V3 — else zero.
	function _registrarV2(Vm vm, address registrarOwner) private view returns (IRegistrarV2Passthrough) {
		string memory v4File = vm.envOr('V4_FILE', string('deployments/base-mainnet-v4.json'));
		if (!vm.exists(v4File) || vm.parseJsonAddress(vm.readFile(v4File), '.registrar') != registrarOwner) {
			return IRegistrarV2Passthrough(address(0));
		}
		string memory aeroFile = vm.envOr('AERO_REGISTRAR_FILE', string('deployments/base-mainnet-aero-registrar.json'));
		address v2Owner = Ownable(registrarOwner).owner();
		if (vm.exists(aeroFile) && vm.parseJsonAddress(vm.readFile(aeroFile), '.registrar') == v2Owner) {
			return IRegistrarV2Passthrough(v2Owner);
		}
		return IRegistrarV2Passthrough(registrarOwner);
	}
}
