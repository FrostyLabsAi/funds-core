// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {ComptrollerV6} from '../../src/core/ComptrollerV6.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {RedemptionQueueV2} from '../../src/redemption/RedemptionQueueV2.sol';

/// @notice Fund version 6 (USDC-only exit; founder 2026-10-11, PLAN_CASH_ONLY_EXIT_2026-10-11.md): RedemptionQueueV2
///         (owned by `owner`, wired to the factory, `keeper` approved) and the blueprint
///         deployer that builds ComptrollerV6 on registrar V2, that queue and the Veranta perp config (what every perp
///         account, V4 included, names as positionFactory()). It does not
///         point the factory at the blueprint: that switch is its own reviewed step. `owner` must be the broadcaster
///         (script) or the pranked caller (tests). Shared by DeployFundV6.s.sol and its fork rehearsal.
library FundV6Deploy {
	struct Deployed {
		RedemptionQueueV2 queueV2;
		ComptrollerBlueprintDeployer fundV6Deployer;
	}

	function deploy(address owner, address factory, address registrarV2, address perpConfig, address keeper)
		internal
		returns (Deployed memory d)
	{
		d.queueV2 = new RedemptionQueueV2(owner);
		d.queueV2.setFactory(factory);
		d.queueV2.setKeeper(keeper, true);
		// ComptrollerV6 only calls poolPricedAdapter on its registrar, which registrar V2 answers
		d.fundV6Deployer = new ComptrollerBlueprintDeployer(
			type(ComptrollerV6).creationCode, abi.encode(PoolPriceRegistrar(registrarV2), d.queueV2, perpConfig)
		);
	}
}
