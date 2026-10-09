// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {ComptrollerV4} from '../../src/core/ComptrollerV4.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';

/// @notice The fund version 4 blueprint deployer (no forfeiting in-kind exit; founder 2026-10-09), bound
///         like the live V3 one to the pool-price registrar and the redemption queue. Shared by
///         DeployComptrollerV4.s.sol and its fork rehearsal (test/fork/ComptrollerV4Fork.t.sol).
library ComptrollerV4Deploy {
	function deploy(PoolPriceRegistrar registrar, address queue) internal returns (ComptrollerBlueprintDeployer) {
		return new ComptrollerBlueprintDeployer(type(ComptrollerV4).creationCode, abi.encode(registrar, queue));
	}
}
