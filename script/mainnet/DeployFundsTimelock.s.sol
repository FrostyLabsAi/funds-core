// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {TimelockController} from '@openzeppelin/contracts/governance/TimelockController.sol';

/// @notice The FrostyFunds governance timelock, for launching before FROST (founder decision
///         2026-09-28): a plain OZ TimelockController in FROST's genesis shape — the Safe proposes
///         and cancels, ANYONE executes once the delay passes, no admin (the timelock administers
///         its own roles, so every role change is itself a timelocked proposal). TransferFundsGovernance
///         then hands every FrostyFunds owner to it (TIMELOCK=<this>).
///         When FROST's governance exists, the Safe proposes `grantRole(PROPOSER_ROLE, <FROST governor>)`
///         on this timelock — shared governance without moving any FrostyFunds contract.
///         Run: forge script script/mainnet/DeployFundsTimelock.s.sol --rpc-url <base> --account <keystore> --broadcast
///         Env: [SAFE] (default: the live 2-of-3 on Base), [MIN_DELAY] seconds (default 2 days)
contract DeployFundsTimelock is Script {
	address internal constant BASE_SAFE = 0xB0f37bE90a8BD82D991Bf694F960C67198778B8B;

	function run() external {
		require(block.chainid == 8453, 'Base (8453) only');
		address safe = vm.envOr('SAFE', BASE_SAFE);
		uint256 minDelay = vm.envOr('MIN_DELAY', uint256(2 days));
		require(safe.code.length > 0, 'SAFE has no code on this chain');

		address[] memory proposers = new address[](1);
		proposers[0] = safe;
		address[] memory executors = new address[](1);
		executors[0] = address(0); // open execution

		vm.startBroadcast();
		TimelockController timelock = new TimelockController(minDelay, proposers, executors, address(0));
		vm.stopBroadcast();

		console2.log('FrostyFunds timelock', address(timelock));
		console2.log('min delay (s)', minDelay);
		console2.log('proposer + canceller', safe);
	}
}
