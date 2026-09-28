// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
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
library FundsGovernance {

	error NotHandedOff(address target, address owner);
	error StillPending(address target, address pending);
	error WrongGuardian(address guardian);
	error DeployerStillLister();
	error TimelockNotLister();
	error DeployerIsKeeper();
	error MandatoryPoliciesMissing(uint256 count);
	error SequencerCheckOff();

	/// @notice Every Ownable2Step genesis contract — the fee reserve only when genesis made one (FROST set).
	function owned(FundsMainnet.Deployed memory d) internal pure returns (address[] memory o) {
		bool reserve = address(d.feeReserve) != address(0);
		o = new address[](reserve ? 5 : 4);
		o[0] = address(d.valueInterpreter);
		o[1] = address(d.factory);
		o[2] = address(d.twapRegistry);
		o[3] = address(d.verantaFactory);
		if (reserve) o[4] = address(d.feeReserve);
	}

	/// @notice EOA step: listing role → timelock, EOA's listing role dropped, two-step transfers begun.
	function start(FundsMainnet.Deployed memory d, address timelock, address deployer) internal {
		d.twapRegistry.setLister(timelock, true);
		d.twapRegistry.setLister(deployer, false);
		address[] memory o = owned(d);
		for (uint256 i; i < o.length; ++i) {
			Ownable2Step(o[i]).transferOwnership(timelock);
		}
	}

	/// @notice The timelock's acceptOwnership calls — the batch the Safe schedules.
	function acceptBatch(FundsMainnet.Deployed memory d)
		internal
		pure
		returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
	{
		targets = owned(d);
		values = new uint256[](targets.length);
		payloads = new bytes[](targets.length);
		for (uint256 i; i < targets.length; ++i) {
			payloads[i] = abi.encodeCall(Ownable2Step.acceptOwnership, ());
		}
	}

	/// @notice Revert on the first thing not where governance says it must be.
	function verify(FundsMainnet.Deployed memory d, address timelock, address safe, address deployer, address keeper)
		internal
		view
	{
		address[] memory o = owned(d);
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
	}
}
