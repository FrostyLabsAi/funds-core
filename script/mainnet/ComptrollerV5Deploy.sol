// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {ComptrollerV5} from '../../src/core/ComptrollerV5.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';

/// @notice The fund version 5 blueprint deployer (in kind pays the whole value; founder 2026-10-09), bound like the v4
///         rollout's to registrar V2 and the redemption queue. Shared by DeployComptrollerV5.s.sol and its fork
///         rehearsal (test/fork/ComptrollerV5Fork.t.sol).
library ComptrollerV5Deploy {
	function deploy(address registrarV2, address queue) internal returns (ComptrollerBlueprintDeployer) {
		// ComptrollerV5 only calls poolPricedAdapter and MIN_LIQUIDITY_USD on its registrar, which registrar V2 answers
		return new ComptrollerBlueprintDeployer(type(ComptrollerV5).creationCode, abi.encode(PoolPriceRegistrar(registrarV2), queue));
	}
}
