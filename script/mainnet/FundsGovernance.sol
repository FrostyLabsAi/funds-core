// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {PriceListingModule} from '../../src/pricing/PriceListingModule.sol';
import {TwapListingRegistryV2} from '../../src/pricing/TwapListingRegistryV2.sol';
import {CompounderFactory} from '../../src/yield/CompounderFactory.sol';
import {SlipstreamLPPositionV2Factory} from '../../src/positions/SlipstreamLPPositionV2.sol';
import {VerantaPerpPositionV3Factory} from '../../src/positions/VerantaPerpPositionV3.sol';
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
///           {start}     (EOA)  hand the listing role to the timelock, drop the EOA's, and begin
///                              every two-step ownership transfer
///           {acceptBatch}      the calls the timelock must make — the Safe schedules them
///           (the timelock delay passes; anyone executes the batch)
///           {verify}           owners, pending owners, guardian, listers, wiring
///         TWAP listing v2 (TwapListingV2, when deployed): the PriceListingModule owns the VI, so the
///         MODULE moves in the VI's place, plus TwapListingRegistryV2. The module stays the registry's
///         only lister; its keepers are the new owner's (the timelock's) to set. A zero {TwapV2}
///         means v2 is not deployed: every function then behaves exactly as genesis shipped it.
///         Fee compounders (CompoundersMainnet, after v2): the CompounderFactory and both
///         SlipstreamLPPositionV2 factories (types 4 / 7) move too; the V3 perp factory (type 6) is
///         ownerless and stays out of the list. A zero {Compounders} means not deployed — refused once
///         the module's compounder listing is wired, so a handoff can't leave them with the deployer.
library FundsGovernance {
	/// @notice TWAP listing v2 (TwapListingV2.Deployed); `module` zero = not deployed.
	struct TwapV2 {
		PriceListingModule module;
		TwapListingRegistryV2 registry;
		address policy; // the TWAP exposure policy every mandatory entry names: V2, or V3 once DeployTwapPolicyV3 ran
	}

	/// @notice Fee compounders + re-pointed position types (CompoundersMainnet.Deployed); `factory` zero = not deployed.
	struct Compounders {
		CompounderFactory factory;
		address feed; // CompounderPriceFeed the module lists vaults with
		SlipstreamLPPositionV2Factory slipstreamLp; // type 4
		SlipstreamLPPositionV2Factory slipstream2Lp; // type 7
		VerantaPerpPositionV3Factory perpV3; // type 6, ownerless
	}

	error NotHandedOff(address target, address owner);
	error StillPending(address target, address pending);
	error WrongGuardian(address guardian);
	error DeployerStillLister();
	error TimelockNotLister();
	error DeployerIsKeeper();
	error MandatoryPoliciesMissing(uint256 count);
	error SequencerCheckOff();
	error ModuleNotViOwner(address owner);
	error ModuleNotLister();
	error DeployerStillV2Lister();
	error DeployerIsModuleKeeper();
	error MandatoryPolicyNotV2(uint256 index, address policy);
	error CompoundersNeedTwapV2();
	error CompounderListingNotWired(address factory, address feed);
	error DeployerHoldsCompounderRole();
	error PositionTypeNotRepointed(uint256 typeId, address factory);
	error PerpFactoryHasOwner(address factory);
	error PerpConfigMismatch(address config);

	/// @notice Every Ownable2Step owner to hand off — the fee reserve only when genesis made one
	///         (FROST set); with TWAP v2 the module (which owns the VI) instead of the VI, plus
	///         the v2 registry; with the fee compounders the CompounderFactory and both Slipstream V2
	///         position factories.
	function owned(FundsMainnet.Deployed memory d, TwapV2 memory v2, Compounders memory c)
		internal
		pure
		returns (address[] memory o)
	{
		bool reserve = address(d.feeReserve) != address(0);
		bool twapV2 = address(v2.module) != address(0);
		bool compounders = address(c.factory) != address(0);
		o = new address[](4 + (twapV2 ? 1 : 0) + (compounders ? 3 : 0) + (reserve ? 1 : 0));
		uint256 n;
		if (twapV2) {
			o[n++] = address(v2.module);
			o[n++] = address(v2.registry);
		} else {
			o[n++] = address(d.valueInterpreter);
		}
		o[n++] = address(d.factory);
		o[n++] = address(d.twapRegistry);
		o[n++] = address(d.verantaFactory);
		if (compounders) {
			o[n++] = address(c.factory);
			o[n++] = address(c.slipstreamLp);
			o[n++] = address(c.slipstream2Lp);
		}
		if (reserve) o[n] = address(d.feeReserve);
	}

	/// @notice EOA step: listing role → timelock, EOA's listing role dropped, two-step transfers begun.
	///         With TWAP v2 the module must already own the VI — the VI itself is not transferred.
	///         The compounders must be exactly the ones the module lists (and need v2).
	function start(
		FundsMainnet.Deployed memory d,
		TwapV2 memory v2,
		Compounders memory c,
		address timelock,
		address deployer
	) internal {
		if (address(v2.module) != address(0) && d.valueInterpreter.owner() != address(v2.module)) {
			revert ModuleNotViOwner(d.valueInterpreter.owner());
		}
		_requireCompoundersMatch(v2, c);
		d.twapRegistry.setLister(timelock, true);
		d.twapRegistry.setLister(deployer, false);
		address[] memory o = owned(d, v2, c);
		for (uint256 i; i < o.length; ++i) {
			Ownable2Step(o[i]).transferOwnership(timelock);
		}
	}

	/// @notice The timelock's acceptOwnership calls — the batch the Safe schedules.
	function acceptBatch(FundsMainnet.Deployed memory d, TwapV2 memory v2, Compounders memory c)
		internal
		pure
		returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
	{
		targets = owned(d, v2, c);
		values = new uint256[](targets.length);
		payloads = new bytes[](targets.length);
		for (uint256 i; i < targets.length; ++i) {
			payloads[i] = abi.encodeCall(Ownable2Step.acceptOwnership, ());
		}
	}

	/// @notice Revert on the first thing not where governance says it must be.
	function verify(
		FundsMainnet.Deployed memory d,
		TwapV2 memory v2,
		Compounders memory c,
		address timelock,
		address safe,
		address deployer,
		address keeper
	) internal view {
		_requireCompoundersMatch(v2, c);
		address[] memory o = owned(d, v2, c);
		for (uint256 i; i < o.length; ++i) {
			address owner = Ownable(o[i]).owner();
			if (owner != timelock) revert NotHandedOff(o[i], owner);
			address pending = Ownable2Step(o[i]).pendingOwner();
			if (pending != address(0)) revert StillPending(o[i], pending);
		}
		if (d.factory.guardian() != safe) revert WrongGuardian(d.factory.guardian());
		if (d.twapRegistry.listers(deployer)) revert DeployerStillLister();
		if (!d.twapRegistry.listers(timelock)) revert TimelockNotLister();
		if (d.verantaFactory.autopilotKeeper() == deployer || keeper == deployer) revert DeployerIsKeeper();
		uint256 mandatory = d.factory.getMandatoryPolicies().length;
		if (mandatory != 4) revert MandatoryPoliciesMissing(mandatory);
		if (address(d.valueInterpreter.sequencerUptimeFeed()) != FundsMainnet.CL_SEQUENCER_UPTIME) revert SequencerCheckOff();
		if (address(v2.module) != address(0)) _verifyTwapV2(d, v2, deployer);
		if (address(c.factory) != address(0)) _verifyCompounders(d, c, deployer);
	}

	/// @dev Compounders need v2, and must be exactly what the module lists — a module wired to a
	///      factory with no compounders given would leave that factory (and the V2 LP factories) behind.
	function _requireCompoundersMatch(TwapV2 memory v2, Compounders memory c) private view {
		if (address(v2.module) == address(0)) {
			if (address(c.factory) != address(0)) revert CompoundersNeedTwapV2();
			return;
		}
		address listed = address(v2.module.compounderFactory());
		address feed = v2.module.compounderFeed();
		if (listed != address(c.factory) || feed != c.feed) revert CompounderListingNotWired(listed, feed);
	}

	/// @dev The compounder end state beyond the owned loop (which proved the CompounderFactory and both
	///      V2 LP factories owned by the timelock): the deployer holds no vault role, types 4 / 7 / 6
	///      answer the new factories, and the V3 perp factory has no owner and reads the live V2 config.
	function _verifyCompounders(FundsMainnet.Deployed memory d, Compounders memory c, address deployer) private view {
		if (c.factory.creators(deployer) || c.factory.compounders(deployer)) revert DeployerHoldsCompounderRole();
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

	/// @dev The v2 end state beyond the owned loop (which proved module + registry owned by the timelock):
	///      the module owns the VI outright, is the registry's lister, the deployer lists and keeps
	///      nothing, and every mandatory entry is TwapExposurePolicyV2.
	function _verifyTwapV2(FundsMainnet.Deployed memory d, TwapV2 memory v2, address deployer) private view {
		address module = address(v2.module);
		address viOwner = d.valueInterpreter.owner();
		if (viOwner != module) revert ModuleNotViOwner(viOwner);
		address viPending = d.valueInterpreter.pendingOwner();
		if (viPending != address(0)) revert StillPending(address(d.valueInterpreter), viPending);
		if (!v2.registry.listers(module)) revert ModuleNotLister();
		if (v2.registry.listers(deployer)) revert DeployerStillV2Lister();
		if (v2.module.keepers(deployer)) revert DeployerIsModuleKeeper();
		FundFactory.PolicyReg[] memory mandatory = d.factory.getMandatoryPolicies();
		for (uint256 i; i < mandatory.length; ++i) {
			if (mandatory[i].policy != v2.policy) revert MandatoryPolicyNotV2(i, mandatory[i].policy);
		}
	}
}
