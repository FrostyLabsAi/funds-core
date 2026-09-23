// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {VerantaPerpPositionFactory} from '../src/positions/VerantaPerpPosition.sol';
import {IVerantaTradingRouter, IVerantaMulticall} from '../src/interfaces/external/IVeranta.sol';
import {MockVeranta} from '../test/utils/MockVeranta.sol';

/// @title DeployWave61 — demo-venue hotfix
/// @notice The wave-6 demo venue was missing `delegatedAction` (the KEEPER's path) —
///         only caught in the live rehearsal because unit coverage stopped at the
///         position's direct calls (gap now closed: test_delegatedAction_keeper…).
///         This wave: (1) deploys the FIXED MockVeranta + a new type-6 factory and swaps
///         the registration; (2) repairs the rehearsal fund — recovers the 3,000 tUSDC
///         from the dead position, removes it, opens a fresh one on the fixed venue,
///         refunds it, autopilot back ON.
/// @dev Env: FACTORY, TUSDC, TETH, KEEPER, RIG_COMPTROLLER, RIG_OLD_VPOS.
contract DeployWave61 is Script {
	function run() external {
		FundFactory factory = FundFactory(vm.envAddress('FACTORY'));
		IERC20 tUsdc = IERC20(vm.envAddress('TUSDC'));
		address tEth = vm.envAddress('TETH');
		address keeper = vm.envAddress('KEEPER');
		Comptroller rig = Comptroller(vm.envAddress('RIG_COMPTROLLER'));
		address oldVPos = vm.envAddress('RIG_OLD_VPOS');

		vm.startBroadcast();

		// 1) Fixed venue + factory swap
		MockVeranta venue = new MockVeranta(tUsdc);
		VerantaPerpPositionFactory positionFactory = new VerantaPerpPositionFactory(
			tUsdc, IVerantaTradingRouter(address(venue)), IVerantaMulticall(address(venue)), address(venue), keeper
		);
		positionFactory.setPairAsset(0, tEth);
		factory.deregisterPositionType(6);
		factory.registerPositionType(6, address(positionFactory));

		// 2) Rehearsal fund repair: recover escrow → drop dead position → fresh one
		address[] memory noAssets = new address[](0);
		uint256[] memory noAmounts = new uint256[](0);
		address[] memory usdcOnly = new address[](1);
		usdcOnly[0] = address(tUsdc);
		uint256[] memory refund = new uint256[](1);
		refund[0] = 3_000e6;

		rig.callOnExternalPosition(
			oldVPos, noAssets, noAmounts, usdcOnly, abi.encode(uint8(6), abi.encode(uint256(3_000e6)))
		);
		rig.removeExternalPosition(oldVPos);

		address newVPos = rig.createExternalPosition(6, '');
		rig.callOnExternalPosition(
			newVPos, usdcOnly, refund, noAssets, abi.encode(uint8(4), abi.encode(block.timestamp + 90 days))
		);

		vm.stopBroadcast();

		console2.log('W61_VENUE', address(venue));
		console2.log('W61_TYPE6_FACTORY', address(positionFactory));
		console2.log('W61_RIG_VPOS', newVPos);
		console2.log('W61_RIG_GAV', rig.calcGav());
	}
}
