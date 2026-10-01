// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {PriceListingModule} from '../../src/pricing/PriceListingModule.sol';
import {TwapListingRegistryV2} from '../../src/pricing/TwapListingRegistryV2.sol';
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
library FundsGovernance {
	/// @notice TWAP listing v2 (TwapListingV2.Deployed); `module` zero = not deployed.
	struct TwapV2 {
		PriceListingModule module;
		TwapListingRegistryV2 registry;
		address policy; // TwapExposurePolicyV2 — every mandatory entry
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

	/// @notice Every Ownable2Step owner to hand off — the fee reserve only when genesis made one
	///         (FROST set); with TWAP v2 the module (which owns the VI) instead of the VI, plus
	///         the v2 registry.
	function owned(FundsMainnet.Deployed memory d, TwapV2 memory v2) internal pure returns (address[] memory o) {
		bool reserve = address(d.feeReserve) != address(0);
		bool twapV2 = address(v2.module) != address(0);
		o = new address[](4 + (twapV2 ? 1 : 0) + (reserve ? 1 : 0));
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
		if (reserve) o[n] = address(d.feeReserve);
	}

	/// @notice EOA step: listing role → timelock, EOA's listing role dropped, two-step transfers begun.
	///         With TWAP v2 the module must already own the VI — the VI itself is not transferred.
	function start(FundsMainnet.Deployed memory d, TwapV2 memory v2, address timelock, address deployer) internal {
		if (address(v2.module) != address(0) && d.valueInterpreter.owner() != address(v2.module)) {
			revert ModuleNotViOwner(d.valueInterpreter.owner());
		}
		d.twapRegistry.setLister(timelock, true);
		d.twapRegistry.setLister(deployer, false);
		address[] memory o = owned(d, v2);
		for (uint256 i; i < o.length; ++i) {
			Ownable2Step(o[i]).transferOwnership(timelock);
		}
	}

	/// @notice The timelock's acceptOwnership calls — the batch the Safe schedules.
	function acceptBatch(FundsMainnet.Deployed memory d, TwapV2 memory v2)
		internal
		pure
		returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
	{
		targets = owned(d, v2);
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
		address timelock,
		address safe,
		address deployer,
		address keeper
	) internal view {
		address[] memory o = owned(d, v2);
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
