// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {FundsMainnet} from './FundsMainnet.sol';

/// @title FundsGovernance
/// @notice The FrostyFunds key migration as code — every owner moves off the deploying EOA
///         onto the TimelockController FROST's genesis created (shared governance, founder
///         decision 2026-09-24), the Safe stays guardian (one-way OFF switches only), and a
///         read-only {verify} proves the EOA holds nothing.
///         The timelock is FROST's, so by the time FrostyFunds launches the EOA has no timelock
///         role: the acceptOwnership batch is SCHEDULED BY THE SAFE (a proposer) and executed by
///         anyone once the delay passes (the timelock's execution is open).
///           {start}     (EOA)  hand the listing role to the timelock, drop the EOA's, and begin
///                              every two-step ownership transfer
///           {acceptBatch}      the calls the timelock must make — the Safe schedules them
///           (the timelock delay passes; anyone executes the batch)
///           {verify}           owners, pending owners, guardian, listers, wiring
library FundsGovernance {
	uint256 internal constant OWNED = 5;

	error NotHandedOff(address target, address owner);
	error StillPending(address target, address pending);
	error WrongGuardian(address guardian);
	error DeployerStillLister();
	error TimelockNotLister();
	error DeployerIsKeeper();
	error MandatoryPoliciesMissing(uint256 count);
	error SequencerCheckOff();

	function owned(FundsMainnet.Deployed memory d) internal pure returns (address[OWNED] memory o) {
		o[0] = address(d.valueInterpreter);
		o[1] = address(d.factory);
		o[2] = address(d.feeReserve);
		o[3] = address(d.twapRegistry);
		o[4] = address(d.verantaFactory);
	}

	/// @notice EOA step: listing role → timelock, EOA's listing role dropped, two-step transfers begun.
	function start(FundsMainnet.Deployed memory d, address timelock, address deployer) internal {
		d.twapRegistry.setLister(timelock, true);
		d.twapRegistry.setLister(deployer, false);
		address[OWNED] memory o = owned(d);
		for (uint256 i; i < OWNED; ++i) {
			Ownable2Step(o[i]).transferOwnership(timelock);
		}
	}

	/// @notice The timelock's acceptOwnership calls — the batch the Safe schedules.
	function acceptBatch(FundsMainnet.Deployed memory d)
		internal
		pure
		returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
	{
		address[OWNED] memory o = owned(d);
		targets = new address[](OWNED);
		values = new uint256[](OWNED);
		payloads = new bytes[](OWNED);
		for (uint256 i; i < OWNED; ++i) {
			targets[i] = o[i];
			payloads[i] = abi.encodeCall(Ownable2Step.acceptOwnership, ());
		}
	}

	/// @notice Revert on the first thing not where governance says it must be.
	function verify(FundsMainnet.Deployed memory d, address timelock, address safe, address deployer, address keeper)
		internal
		view
	{
		address[OWNED] memory o = owned(d);
		for (uint256 i; i < OWNED; ++i) {
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
