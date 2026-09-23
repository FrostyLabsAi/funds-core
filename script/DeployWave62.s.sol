// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {VerantaPerpPosition, VerantaPerpPositionFactory} from '../src/positions/VerantaPerpPosition.sol';
import {IVerantaTradingRouter, IVerantaMulticall} from '../src/interfaces/external/IVeranta.sol';
import {MockVeranta} from '../test/utils/MockVeranta.sol';

/// @title DeployWave62 — collateral-field fix + keeper-v2 rails (fork-probe findings)
/// @notice The 2026-09-15 mainnet fork probe proved stored Veranta trades keep collateral
///         in `initialPosToken` (their source marks positionSizeUSDC "//dummy") — the old
///         position contract and demo venue both valued off positionSizeUSDC, mutually
///         consistent on Sepolia but WRONG against real Veranta. This wave redeploys:
///         (1) MockVeranta — faithful storage (collateral → initialPosToken on fill, dummy
///             left in positionSizeUSDC), honest partial closes, `updateMargin` (single-tx,
///             ~3bps venue fee) and the Pyth stand-in surface for keeper top-ups;
///         (2) a type-6 factory whose positions value stored trades by initialPosToken;
///         (3) repairs the rehearsal fund: close the old-venue hedge, sweep the position's
///             USDC home, swap in a fresh position on the new venue funded with the same
///             USDC, autopilot ON — the keeper re-opens the hedge on its next pass.
/// @dev Env: FACTORY, TUSDC, TETH, KEEPER, RIG_COMPTROLLER, RIG_OLD_VPOS.
contract DeployWave62 is Script {
	function run() external {
		FundFactory factory = FundFactory(vm.envAddress('FACTORY'));
		IERC20 tUsdc = IERC20(vm.envAddress('TUSDC'));
		address tEth = vm.envAddress('TETH');
		address keeper = vm.envAddress('KEEPER');
		Comptroller rig = Comptroller(vm.envAddress('RIG_COMPTROLLER'));
		VerantaPerpPosition oldVPos = VerantaPerpPosition(vm.envAddress('RIG_OLD_VPOS'));

		vm.startBroadcast();

		// 1) Faithful venue + fixed type-6 factory, registration swapped
		MockVeranta venue = new MockVeranta(tUsdc);
		VerantaPerpPositionFactory positionFactory = new VerantaPerpPositionFactory(
			tUsdc, IVerantaTradingRouter(address(venue)), IVerantaMulticall(address(venue)), address(venue), keeper
		);
		positionFactory.setPairAsset(0, tEth);
		factory.deregisterPositionType(6);
		factory.registerPositionType(6, address(positionFactory));

		// 2) Rehearsal fund repair: cancel stuck pending orders (escrow refund), close any
		//    live hedge on the OLD venue, sweep every USDC at the position home, drop it
		address[] memory noAssets = new address[](0);
		uint256[] memory noAmounts = new uint256[](0);
		IVerantaMulticall.PendingOrder[] memory pendings =
			oldVPos.verantaMulticall().getPendingOrder(address(oldVPos));
		for (uint256 i; i < pendings.length; ++i) {
			rig.callOnExternalPosition(
				address(oldVPos), noAssets, noAmounts, noAssets,
				abi.encode(
					uint8(VerantaPerpPosition.Action.CancelPendingMarketOrder), abi.encode(pendings[i].orderId)
				)
			);
		}
		(IVerantaMulticall.AggregatedTrade[] memory trades,) =
			oldVPos.verantaMulticall().getPositions(address(oldVPos));
		for (uint256 i; i < trades.length; ++i) {
			rig.callOnExternalPosition(
				address(oldVPos), noAssets, noAmounts, noAssets,
				abi.encode(
					uint8(VerantaPerpPosition.Action.CloseTrade),
					abi.encode(trades[i].trade.pairIndex, trades[i].trade.index, type(uint256).max, uint256(0))
				)
			);
		}
		uint256 sweep = tUsdc.balanceOf(address(oldVPos));
		address[] memory usdcOnly = new address[](1);
		usdcOnly[0] = address(tUsdc);
		rig.callOnExternalPosition(
			address(oldVPos), noAssets, noAmounts, usdcOnly,
			abi.encode(uint8(VerantaPerpPosition.Action.ReturnToVault), abi.encode(sweep))
		);
		rig.removeExternalPosition(address(oldVPos));

		// 3) Fresh position on the fixed venue, funded with the same USDC, autopilot ON —
		//    the keeper detects the under-hedge and re-opens the short trustlessly
		address newVPos = rig.createExternalPosition(6, '');
		uint256[] memory refund = new uint256[](1);
		refund[0] = sweep;
		rig.callOnExternalPosition(
			newVPos, usdcOnly, refund, noAssets,
			abi.encode(uint8(VerantaPerpPosition.Action.SetAutopilot), abi.encode(block.timestamp + 90 days))
		);

		vm.stopBroadcast();

		console2.log('W62_VENUE', address(venue));
		console2.log('W62_TYPE6_FACTORY', address(positionFactory));
		console2.log('W62_RIG_VPOS', newVPos);
		console2.log('W62_RIG_SWEPT_USDC', sweep);
		console2.log('W62_RIG_GAV', rig.calcGav());
	}
}
