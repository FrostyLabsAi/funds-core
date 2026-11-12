// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console} from 'forge-std/Script.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {AerodromeSlipstreamSwapAdapterV3} from '../../src/adapters/AerodromeSlipstreamSwapAdapterV3.sol';
import {ISlipstreamSwapRouter} from '../../src/interfaces/external/ISlipstreamSwapRouter.sol';
import {ClmFundsDeploy} from './ClmFundsDeploy.sol';
import {V4Pricing} from './V4Pricing.sol';

/// @notice The Aero spot adapter with a gas floor (founder 2026-11-12): AerodromeSlipstreamSwapAdapterV3 on Aero's
///         router, same Treasury and fee as DeployAeroAdapters' `aeroSwap`, registered on the fund factory. Aero's swap
///         hook takes about 7,800 more gas in a real transaction than in a fee-less estimate and MetaMask sends that
///         estimate with no margin, so buys ran out of gas (fund YAFT, 2026-11-12); the floor carries the margin in
///         the trade. `aeroSwap` (V2) stays registered: the keeper's sales and any open ticket keep working.
///         Rehearsed in test/fork/AeroGasFloorFork.t.sol. Touches no fund and no token.
///         Run: forge script script/mainnet/DeployAeroSwapAdapterV3.s.sol --rpc-url base --account frosty-main
///              --sender <deployer> --broadcast --slow --verify
///         Then the terminal: npx tsx indexer/mainnet-deployments.ts (it switches Aero trades to `aeroSwapV3`).
contract DeployAeroSwapAdapterV3 is Script {
	/// @notice Aero's Slipstream SwapRouter, as in DeployAeroAdapters (its factory() is Aero's CL factory 0x9CB2…7a76).
	address public constant AERO_SWAP_ROUTER = 0x9Ee35Bf1bd69a03c6F0393582030fCe8Bb93D418;
	string public constant OUTPUT_PATH = 'deployments/base-mainnet-aero-swap-v3.json';

	function run() external {
		vm.startBroadcast();
		AerodromeSlipstreamSwapAdapterV3 adapter = deployAdapter(msg.sender);
		FundFactory(ClmFundsDeploy.FUND_FACTORY).registerAdapter(address(adapter));
		vm.stopBroadcast();
		vm.writeJson(vm.serializeAddress('aeroSwapV3', 'aeroSwapV3', address(adapter)), OUTPUT_PATH);
		console.log('wrote', OUTPUT_PATH);
	}

	/// @param owner the adapter's owner (it sets the fee): the genesis deployer until the governance handoff
	function deployAdapter(address owner) public returns (AerodromeSlipstreamSwapAdapterV3) {
		return new AerodromeSlipstreamSwapAdapterV3(
			ISlipstreamSwapRouter(AERO_SWAP_ROUTER), V4Pricing.TREASURY, V4Pricing.FEE_BPS, owner
		);
	}
}
