// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {ComptrollerV3} from '../../src/core/ComptrollerV3.sol';
import {IVerantaMulticall, IVerantaTradingStorage} from '../../src/interfaces/external/IVeranta.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {VerantaPriceStore} from '../../src/pricing/VerantaPriceStore.sol';
import {RedemptionQueue} from '../../src/redemption/RedemptionQueue.sol';
import {PerpUnwinder} from '../../src/redemption/PerpUnwinder.sol';
import {FundsMainnet} from './FundsMainnet.sol';

/// @title RedemptionDeploy
/// @notice The redemption queue's contracts on Base (founder 2026-10-06; spec
///         docs/superpowers/specs/2026-10-06-redemption-queue-design.md §11): the shared queue
///         (owned by the caller until the governance handoff), the perp unwinder (approved,
///         switched OFF), and the blueprint deployer that makes new funds ComptrollerV3 bound to the
///         queue. It does not point the factory at the blueprint: that switch is its own reviewed step.
///         `owner` must be the broadcaster (script) or the pranked caller (tests): the owner-only
///         wiring calls below are sent by it.
///         Used by script/mainnet/DeployRedemptionQueue.s.sol and its fork rehearsal.
library RedemptionDeploy {
	struct Deployed {
		RedemptionQueue queue;
		PerpUnwinder perpUnwinder;
		ComptrollerBlueprintDeployer fundV3Deployer;
	}

	function deploy(address owner, address factory, address perpConfig, PoolPriceRegistrar registrar, VerantaPriceStore store)
		internal
		returns (Deployed memory d)
	{
		d.queue = new RedemptionQueue(owner);
		d.queue.setFactory(factory);
		d.perpUnwinder = new PerpUnwinder(
			perpConfig,
			store,
			IVerantaTradingStorage(FundsMainnet.VERANTA_STORAGE),
			IVerantaMulticall(FundsMainnet.VERANTA_MULTICALL),
			FundsMainnet.VERANTA_PAIR_STORAGE,
			IERC20(FundsMainnet.USDC)
		);
		d.queue.approveUnwinder(address(d.perpUnwinder), true); // approved, left OFF
		d.fundV3Deployer = new ComptrollerBlueprintDeployer(type(ComptrollerV3).creationCode, abi.encode(registrar, d.queue));
	}
}
