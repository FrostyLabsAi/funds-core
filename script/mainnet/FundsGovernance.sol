// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IPolicy} from '../../src/interfaces/IPolicy.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {PoolPriceRegistrarV2} from '../../src/pricing/PoolPriceRegistrarV2.sol';
import {V4PriceSampler} from '../../src/pricing/V4PriceSampler.sol';
import {MinPoolLiquidityPolicy} from '../../src/policies/MinPoolLiquidityPolicy.sol';
import {CompounderFactory} from '../../src/yield/CompounderFactory.sol';
import {SlipstreamLPPositionV2Factory} from '../../src/positions/SlipstreamLPPositionV2.sol';
import {VerantaPerpPositionV3Factory} from '../../src/positions/VerantaPerpPositionV3.sol';
import {RedemptionQueue} from '../../src/redemption/RedemptionQueue.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {FundsMainnet} from './FundsMainnet.sol';

/// @title FundsGovernance
/// @notice The FrostyFunds key migration as code — every owner moves off the deploying EOA
///         onto the governance TimelockController, the Safe stays guardian (one-way OFF
///         switches only), and a read-only {verify} proves the EOA holds nothing.
///         The timelock: FrostyFunds launches before FROST (founder decision 2026-09-28), so it is
///         a plain OZ TimelockController (DeployFundsTimelock: Safe proposes, open execution, no
///         admin) — the shape FROST's genesis uses, so FROST's governance can be made a proposer
///         on it later (shared governance, founder decision 2026-09-24).
///         The EOA holds no timelock role: the acceptOwnership batch is SCHEDULED BY THE SAFE (a
///         proposer) and executed by anyone once the delay passes (the timelock's execution is open).
///           {start}     (EOA)  revoke the retired lister's compounder roles, begin every two-step
///                              ownership transfer
///           {acceptBatch}      the calls the timelock must make — the Safe schedules them
///           (the timelock delay passes; anyone executes the batch)
///           {verify}           owners, pending owners, guardian, keeper, pricing wiring, fund version
///         Rebuilt 2026-10-04 for the pool-pricing switch-over (PLAN_GOVERNANCE_HANDOFF_2026-10-04):
///         the PoolPriceRegistrar owns the VI, so the REGISTRAR moves in the VI's place; new funds are
///         fund v2 behind MinPoolLiquidityPolicy. The retired TWAP tier (listing module, registries
///         v1/v2) holds nothing but moves too, by address only (founder 2026-10-04: "the deployer
///         holds nothing"); its source is gone. Running the handoff stays the LAST launch step
///         (founder rule 2026-10-01).
///         Fee compounders (CompoundersMainnet): the CompounderFactory and both SlipstreamLPPositionV2
///         factories (types 4 / 7) move; the V3 perp factory (type 6) is ownerless and stays out.
///         Uniswap v4 (V4Pricing, 2026-10-08): once deployed, registrar V2 owns the registrar and moves in its place,
///         with the price sampler and the six fee-taking spot adapters (setting the protocol fee is an owner
///         power); new funds must then be ComptrollerV4 on registrar V2 behind its long-tail policy.
library FundsGovernance {
	/// @notice The pool-pricing switch-over (deployments/base-mainnet-pool-pricing.json).
	struct PoolPricing {
		PoolPriceRegistrar registrar; // owns the VI
		MinPoolLiquidityPolicy policy; // the only mandatory policy, on every hook it implements
		address fundDeployer; // ComptrollerBlueprintDeployer (fund v2): every new fund
		// the redemption queue (deployments/base-mainnet-redemption.json, founder 2026-10-06); zero until deployed
		address fundV3Deployer; // ComptrollerBlueprintDeployer (fund v3, bound to the queue)
		address redemptionQueue; // Ownable2Step: hands off with the rest
		// Uniswap v4 (deployments/base-mainnet-v4.json); zero until deployed
		PoolPriceRegistrarV2 registrarV2; // owns `registrar`; hands off in its place
		V4PriceSampler sampler; // Ownable2Step: approves the keeper
		address[6] v4Adapters; // V4Pricing.adaptersOf: Ownable2Step, the protocol fee is theirs to set
		MinPoolLiquidityPolicy policyV2; // the mandatory policy once v4 is live
		address registrarV2FundDeployer; // ComptrollerBlueprintDeployer (fund v3 on registrar V2): every new fund
	}

	/// @notice Fee compounders + re-pointed position types (CompoundersMainnet.Deployed); `factory` zero = not deployed.
	struct Compounders {
		CompounderFactory factory;
		SlipstreamLPPositionV2Factory slipstreamLp; // type 4
		SlipstreamLPPositionV2Factory slipstream2Lp; // type 7
		VerantaPerpPositionV3Factory perpV3; // type 6, ownerless
	}

	/// @notice The retired TWAP tier, by address (zero = not deployed): Ownable2Step owners that hold
	///         nothing since the switch-over, plus the funds-keeper lister wallet that kept roles on it.
	struct Retired {
		address registryV1; // genesis TwapListingRegistry
		address module; // PriceListingModule (owned the VI until 2026-10-04)
		address registryV2; // TwapListingRegistryV2
		address lister; // "Keeper · Lister" — its CompounderFactory roles are revoked at {start}
	}

	error NoPoolPricing();
	error RegistrarNotViOwner(address owner);
	error RegistrarNotWired(address valueInterpreter);
	error NotHandedOff(address target, address owner);
	error StillPending(address target, address pending);
	error WrongGuardian(address guardian);
	error DeployerIsKeeper();
	error MandatoryPoliciesMismatch(uint256 count, uint256 expected);
	error MandatoryPolicyMismatch(uint256 index, address policy);
	error NotFundV2(address comptrollerDeployer);
	error SequencerCheckOff();
	error HoldsCompounderRole(address account);
	error PositionTypeNotRepointed(uint256 typeId, address factory);
	error PerpFactoryHasOwner(address factory);
	error PerpConfigMismatch(address config);
	error QueueNotWired(address factory);
	error RegistrarNotUnderV2(address owner);
	error NotOnRegistrarV2(address comptrollerDeployer);
	error V4NotWired(address target);
	error DeployerIsPoolApprover();
	error SafeNotPoolApprover(address safe);

	/// @notice Every Ownable2Step owner to hand off: the registrar (owns the VI) instead of the VI — or registrar V2
	///         (owns the registrar) once v4 is deployed —, the FundFactory, the V2 perp config, the fee reserve
	///         only when genesis made one (FROST set), the fee compounders' three factories, the retired TWAP
	///         tier, the redemption queue, and v4's sampler and six spot adapters.
	function owned(FundsMainnet.Deployed memory d, PoolPricing memory p, Compounders memory c, Retired memory r)
		internal
		pure
		returns (address[] memory o)
	{
		if (address(p.registrar) == address(0)) revert NoPoolPricing();
		bool reserve = address(d.feeReserve) != address(0);
		bool compounders = address(c.factory) != address(0);
		uint256 retired = (r.registryV1 != address(0) ? 1 : 0) + (r.module != address(0) ? 1 : 0) + (r.registryV2 != address(0) ? 1 : 0);
		bool queue = p.redemptionQueue != address(0);
		bool v4 = address(p.registrarV2) != address(0);
		o = new address[](3 + (compounders ? 3 : 0) + (reserve ? 1 : 0) + retired + (queue ? 1 : 0) + (v4 ? 7 : 0));
		uint256 n;
		o[n++] = v4 ? address(p.registrarV2) : address(p.registrar);
		o[n++] = address(d.factory);
		o[n++] = address(d.verantaFactory);
		if (compounders) {
			o[n++] = address(c.factory);
			o[n++] = address(c.slipstreamLp);
			o[n++] = address(c.slipstream2Lp);
		}
		if (reserve) o[n++] = address(d.feeReserve);
		if (r.registryV1 != address(0)) o[n++] = r.registryV1;
		if (r.module != address(0)) o[n++] = r.module;
		if (r.registryV2 != address(0)) o[n++] = r.registryV2;
		if (queue) o[n++] = p.redemptionQueue;
		if (v4) {
			o[n++] = address(p.sampler);
			for (uint256 i; i < p.v4Adapters.length; ++i) {
				o[n++] = p.v4Adapters[i];
			}
		}
	}

	/// @notice EOA step: the retired lister loses its compounder roles, two-step transfers begin.
	///         The registrar must already own the VI — the VI itself is not transferred.
	function start(
		FundsMainnet.Deployed memory d,
		PoolPricing memory p,
		Compounders memory c,
		Retired memory r,
		address timelock
	) internal {
		_requireRegistrarOwnsVi(d, p);
		if (address(c.factory) != address(0) && r.lister != address(0)) {
			if (c.factory.creators(r.lister)) c.factory.setCreator(r.lister, false);
			if (c.factory.compounders(r.lister)) c.factory.setCompounder(r.lister, false);
		}
		address[] memory o = owned(d, p, c, r);
		for (uint256 i; i < o.length; ++i) {
			Ownable2Step(o[i]).transferOwnership(timelock);
		}
	}

	/// @notice The timelock's acceptOwnership calls — the batch the Safe schedules.
	function acceptBatch(FundsMainnet.Deployed memory d, PoolPricing memory p, Compounders memory c, Retired memory r)
		internal
		pure
		returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
	{
		targets = owned(d, p, c, r);
		values = new uint256[](targets.length);
		payloads = new bytes[](targets.length);
		for (uint256 i; i < targets.length; ++i) {
			payloads[i] = abi.encodeCall(Ownable2Step.acceptOwnership, ());
		}
	}

	/// @notice Revert on the first thing not where governance says it must be.
	function verify(
		FundsMainnet.Deployed memory d,
		PoolPricing memory p,
		Compounders memory c,
		Retired memory r,
		address timelock,
		address safe,
		address deployer,
		address keeper
	) internal view {
		address[] memory o = owned(d, p, c, r);
		for (uint256 i; i < o.length; ++i) {
			address owner = Ownable(o[i]).owner();
			if (owner != timelock) revert NotHandedOff(o[i], owner);
			address pending = Ownable2Step(o[i]).pendingOwner();
			if (pending != address(0)) revert StillPending(o[i], pending);
		}
		_requireRegistrarOwnsVi(d, p);
		address viPending = d.valueInterpreter.pendingOwner();
		if (viPending != address(0)) revert StillPending(address(d.valueInterpreter), viPending);
		if (d.factory.guardian() != safe) revert WrongGuardian(d.factory.guardian());
		if (d.verantaFactory.autopilotKeeper() == deployer || keeper == deployer) revert DeployerIsKeeper();
		_requireNewFunds(d.factory, p, deployer, safe);
		if (p.redemptionQueue != address(0) && address(RedemptionQueue(p.redemptionQueue).factory()) != address(d.factory)) {
			revert QueueNotWired(address(RedemptionQueue(p.redemptionQueue).factory()));
		}
		if (address(d.valueInterpreter.sequencerUptimeFeed()) != FundsMainnet.CL_SEQUENCER_UPTIME) revert SequencerCheckOff();
		if (address(c.factory) != address(0)) _verifyCompounders(d, c, deployer, r.lister);
	}

	/// @dev New funds: fund v2, or fund v3 once the redemption queue is deployed and switched to, behind the
	///      long-tail policy; once v4 is deployed, fund v4 on registrar V2 behind its policy (V4Pricing.ownerSteps),
	///      with the deployer no sampler keeper and no v4 pool approver, and the Safe one (founder 2026-10-08: approvals
	///      without the timelock).
	function _requireNewFunds(FundFactory factory, PoolPricing memory p, address deployer, address safe) private view {
		address comptrollerDeployer = address(factory.comptrollerDeployer());
		if (address(p.registrarV2) != address(0)) {
			if (p.sampler.isKeeper(deployer)) revert DeployerIsKeeper();
			if (p.registrarV2.isPoolApprover(deployer)) revert DeployerIsPoolApprover();
			if (!p.registrarV2.isPoolApprover(safe)) revert SafeNotPoolApprover(safe);
			_requireMandatoryPolicy(factory, p.policyV2);
			if (comptrollerDeployer != p.registrarV2FundDeployer) revert NotOnRegistrarV2(comptrollerDeployer);
			_requireV4Wired(p);
			return;
		}
		_requireMandatoryPolicy(factory, p.policy);
		if (comptrollerDeployer != p.fundDeployer && (p.fundV3Deployer == address(0) || comptrollerDeployer != p.fundV3Deployer)) {
			revert NotFundV2(comptrollerDeployer);
		}
	}

	/// @dev The v4 book's contracts are wired to registrar V2, not merely listed in it: the v4 adapter's and the
	///      policy's registrar, the sampler registrar V2 reads, and the registrar (and queue) the fund deployer builds
	///      funds on (final review 2026-10-08, I3).
	function _requireV4Wired(PoolPricing memory p) private view {
		address registrar = address(p.registrarV2);
		(bool ok, bytes memory ret) = p.v4Adapters[0].staticcall(abi.encodeWithSignature('registrar()'));
		if (!ok || ret.length != 32 || abi.decode(ret, (address)) != registrar) revert V4NotWired(p.v4Adapters[0]);
		if (address(p.policyV2.registrar()) != registrar) revert V4NotWired(address(p.policyV2));
		if (address(p.registrarV2.sampler()) != address(p.sampler)) revert V4NotWired(address(p.sampler));
		(address built, address queue) =
			abi.decode(ComptrollerBlueprintDeployer(p.registrarV2FundDeployer).extraConstructorArgs(), (address, address));
		if (built != registrar || (p.redemptionQueue != address(0) && queue != p.redemptionQueue)) {
			revert V4NotWired(p.registrarV2FundDeployer);
		}
	}

	/// @dev The registrar owns the VI it was built on (the switch-over ran); once v4 is deployed, registrar V2
	///      (built on that registrar) owns the registrar, with no transfer pending (V4Pricing.ownerSteps ran).
	function _requireRegistrarOwnsVi(FundsMainnet.Deployed memory d, PoolPricing memory p) private view {
		if (address(p.registrar) == address(0)) revert NoPoolPricing();
		address viOwner = d.valueInterpreter.owner();
		if (viOwner != address(p.registrar)) revert RegistrarNotViOwner(viOwner);
		address wired = address(p.registrar.valueInterpreter());
		if (wired != address(d.valueInterpreter)) revert RegistrarNotWired(wired);
		if (address(p.registrarV2) == address(0)) return;
		if (p.registrarV2.oldRegistrar() != p.registrar) revert RegistrarNotWired(address(p.registrarV2.oldRegistrar()));
		address registrarOwner = p.registrar.owner();
		if (registrarOwner != address(p.registrarV2)) revert RegistrarNotUnderV2(registrarOwner);
		address pending = p.registrar.pendingOwner();
		if (pending != address(0)) revert StillPending(address(p.registrar), pending);
	}

	/// @dev The mandatory list is exactly the long-tail policy on every hook it implements (PoolPricing.setMandatoryPolicy).
	function _requireMandatoryPolicy(FundFactory factory, MinPoolLiquidityPolicy policy) private view {
		IPolicy.PolicyHook[] memory hooks = policy.implementedHooks();
		FundFactory.PolicyReg[] memory mandatory = factory.getMandatoryPolicies();
		if (mandatory.length != hooks.length) revert MandatoryPoliciesMismatch(mandatory.length, hooks.length);
		for (uint256 i; i < hooks.length; ++i) {
			if (mandatory[i].hook != hooks[i] || mandatory[i].policy != address(policy)) {
				revert MandatoryPolicyMismatch(i, mandatory[i].policy);
			}
		}
	}

	/// @dev The compounder end state beyond the owned loop (which proved the CompounderFactory and both
	///      V2 LP factories owned by the timelock): neither the deployer nor the retired lister holds a
	///      vault role, types 4 / 7 / 6 answer the new factories, and the V3 perp factory has no owner
	///      and reads the live V2 config.
	function _verifyCompounders(FundsMainnet.Deployed memory d, Compounders memory c, address deployer, address lister)
		private
		view
	{
		if (c.factory.creators(deployer) || c.factory.compounders(deployer)) revert HoldsCompounderRole(deployer);
		if (lister != address(0) && (c.factory.creators(lister) || c.factory.compounders(lister))) {
			revert HoldsCompounderRole(lister);
		}
		_requireType(d.factory, FundsMainnet.SLIPSTREAM_LP_TYPE, address(c.slipstreamLp));
		_requireType(d.factory, FundsMainnet.SLIPSTREAM2_LP_TYPE, address(c.slipstream2Lp));
		_requireType(d.factory, FundsMainnet.VERANTA_PERP_TYPE, address(c.perpV3));
		(bool hasOwner, bytes memory ret) = address(c.perpV3).staticcall(abi.encodeWithSignature('owner()'));
		if (hasOwner && ret.length == 32) revert PerpFactoryHasOwner(address(c.perpV3));
		address config = address(c.perpV3.config());
		if (config != address(d.verantaFactory)) revert PerpConfigMismatch(config);
	}

	function _requireType(FundFactory factory, uint256 typeId, address expected) private view {
		address stored = factory.positionTypeFactories(typeId);
		if (stored != expected) revert PositionTypeNotRepointed(typeId, stored);
	}
}
