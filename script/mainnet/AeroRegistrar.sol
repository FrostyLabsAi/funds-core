// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerV6} from '../../src/core/ComptrollerV6.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {IComptrollerDeployer} from '../../src/interfaces/IComptrollerDeployer.sol';
import {MinPoolLiquidityPolicy} from '../../src/policies/MinPoolLiquidityPolicy.sol';
import {UniswapV4SwapAdapter} from '../../src/adapters/UniswapV4SwapAdapter.sol';
import {IV4PoolManager} from '../../src/interfaces/external/IUniswapV4.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {PoolPriceRegistrarV2} from '../../src/pricing/PoolPriceRegistrarV2.sol';
import {PoolPriceRegistrarV3} from '../../src/pricing/PoolPriceRegistrarV3.sol';
import {FundsMainnet} from './FundsMainnet.sol';
import {V4Pricing} from './V4Pricing.sol';

/// @notice The Aero venue (FrostyFi 2026-10-25): PoolPriceRegistrarV3 over registrar V2, and what new funds need to be
///         built on it — V2's 2026-10-08 rollout, once more (V4Pricing): the long-tail policy on V3 (mandatory, in
///         place of V2's), a v4 swap adapter whose fund check names V3, and the ComptrollerV6 blueprint deployer on V3
///         with fund v6's own queue and perp config (FundV6Deploy). Shared by DeployAeroRegistrar.s.sol,
///         AeroRegistrarOwnerSteps.s.sol and test/fork/AeroRegistrarFork.t.sol.
library AeroRegistrar {
	/// @notice Aero's CL factory (Dromos-Labs metadex-slipstream-public cl-base.json; the factory() of Aero's
	///         SwapRouter 0x9Ee3…D418 and of every Aero CL pool, checked 2026-10-25).
	address internal constant AERO_FACTORY = 0x9CB220581b91b0C83223012FE69688b92aD07a76;
	address internal constant REGISTRAR_V2 = 0x60338a74c63EDeC7EC020cB9208DD234D9a2146F;
	/// @notice The mandatory long-tail policy since 2026-10-08: MinPoolLiquidityPolicy on registrar V2
	///         (deployments/base-mainnet-v4.json `policy`). Replaced by V3's wherever it is listed.
	address internal constant V2_POLICY = 0x4808F7d01f67FBec0160bb9F08CB9d20Cc7966f7;

	struct Deployed {
		PoolPriceRegistrarV3 registrar;
		MinPoolLiquidityPolicy policy;
		UniswapV4SwapAdapter v4Adapter;
		ComptrollerBlueprintDeployer fundV6Deployer;
	}

	error MandatoryPolicyNotFound(address policy);

	/// @param owner the registrar's and the v4 adapter's owner (the genesis deployer until the governance handoff)
	/// @param queueV2 fund v6's RedemptionQueueV2 (deployments/base-mainnet-fund-v6.json)
	/// @param perpConfig what every perp account names as positionFactory() (deployments/base-mainnet.json verantaFactory)
	function deploy(address owner, address queueV2, address perpConfig) internal returns (Deployed memory d) {
		d.registrar = new PoolPriceRegistrarV3(PoolPriceRegistrarV2(REGISTRAR_V2), AERO_FACTORY, owner);
		// the policy and ComptrollerV6 call only poolPricedAdapter and MIN_LIQUIDITY_USD, which V3 answers
		PoolPriceRegistrar asRegistrar = PoolPriceRegistrar(address(d.registrar));
		d.policy = new MinPoolLiquidityPolicy(asRegistrar);
		// the v4 adapter calls only isPoolApproved, isHookAllowed and hookOf (V2's, forwarded) and checks fund.registrar()
		d.v4Adapter = new UniswapV4SwapAdapter(
			IV4PoolManager(V4Pricing.POOL_MANAGER),
			PoolPriceRegistrarV2(address(d.registrar)),
			FundsMainnet.WETH,
			V4Pricing.TREASURY,
			V4Pricing.FEE_BPS,
			owner
		);
		d.fundV6Deployer = new ComptrollerBlueprintDeployer(
			type(ComptrollerV6).creationCode, abi.encode(asRegistrar, queueV2, perpConfig)
		);
	}

	/// @notice The owner's switch, re-runnable: V2 → V3 (Ownable2Step), the v4 adapter registered, V3's policy mandatory
	///         in V2's place, new funds built on V3. Run as the owner of V2 and of the factory.
	function ownerSteps(Deployed memory d, FundFactory factory) internal {
		PoolPriceRegistrarV2 v2 = PoolPriceRegistrarV2(REGISTRAR_V2);
		if (v2.owner() != address(d.registrar)) {
			if (v2.pendingOwner() != address(d.registrar)) v2.transferOwnership(address(d.registrar));
			d.registrar.acceptRegistrarV2();
		}
		if (!factory.isAdapterRegistered(address(d.v4Adapter))) factory.registerAdapter(address(d.v4Adapter));
		_replaceMandatoryPolicy(factory, V2_POLICY, address(d.policy));
		if (address(factory.comptrollerDeployer()) != address(d.fundV6Deployer)) {
			factory.setComptrollerDeployer(IComptrollerDeployer(address(d.fundV6Deployer)));
		}
	}

	/// @dev V4Pricing._replaceMandatoryPolicy: same hooks, the new policy in the old one's place, other mandatory
	///      policies kept; reverts unless the new policy ends up mandatory (final review 2026-10-08, L1).
	function _replaceMandatoryPolicy(FundFactory factory, address oldPolicy, address newPolicy) private {
		FundFactory.PolicyReg[] memory regs = factory.getMandatoryPolicies();
		bool changed;
		bool present;
		for (uint256 i; i < regs.length; ++i) {
			if (regs[i].policy == oldPolicy) {
				regs[i].policy = newPolicy;
				changed = true;
			}
			if (regs[i].policy == newPolicy) present = true;
		}
		if (!present) revert MandatoryPolicyNotFound(oldPolicy);
		if (changed) factory.setMandatoryPolicies(regs);
	}
}
