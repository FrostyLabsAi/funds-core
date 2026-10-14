// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console} from 'forge-std/Script.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ViaWethSellAdapter} from '../../src/adapters/ViaWethSellAdapter.sol';
import {FundsMainnet} from './FundsMainnet.sol';
import {V4Pricing} from './V4Pricing.sol';
import {ClmFundsDeploy} from './ClmFundsDeploy.sol';

/// @notice The v6 keeper's sale of a feed-priced token through WETH (exit audit 2026-10-14): deploys ViaWethSellAdapter
///         on Uniswap v3, Slipstream-1/2/3 and Aerodrome basic, with the protocol fee of the V2 spot adapters (5 bps to
///         the Treasury Safe, owner-set 0-10; the owner is the deployer until the governance handoff), and registers it
///         on the FundFactory. Rehearsed in test/fork/ViaWethSellFork.t.sol. Touches no stock token.
///         Run: forge script script/mainnet/DeployViaWethSell.s.sol --rpc-url base --account frosty-main --sender <deployer>
///              --broadcast --slow --verify
///         Then the keeper: LIQUIDATION_ADAPTERS.viaWeth = `adapter`.
contract DeployViaWethSell is Script {
	string public constant OUTPUT_PATH = 'deployments/base-mainnet-via-weth-sell.json';

	function run() external {
		vm.startBroadcast();
		ViaWethSellAdapter adapter = new ViaWethSellAdapter(
			FundsMainnet.WETH,
			FundsMainnet.UNI_SWAP_ROUTER02,
			FundsMainnet.CL_SWAP_ROUTER,
			FundsMainnet.CL2_SWAP_ROUTER,
			FundsMainnet.CL3_SWAP_ROUTER,
			FundsMainnet.AERODROME_ROUTER,
			FundsMainnet.AERODROME_POOL_FACTORY,
			V4Pricing.TREASURY,
			V4Pricing.FEE_BPS,
			msg.sender
		);
		FundFactory(ClmFundsDeploy.FUND_FACTORY).registerAdapter(address(adapter));
		vm.stopBroadcast();
		vm.writeJson(vm.serializeAddress('viaWethSell', 'adapter', address(adapter)), OUTPUT_PATH);
		console.log('wrote', OUTPUT_PATH);
	}
}
