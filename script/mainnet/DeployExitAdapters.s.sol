// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console} from 'forge-std/Script.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ERC4626ExitAdapter} from '../../src/adapters/ERC4626ExitAdapter.sol';
import {ClmVaultExitAdapter} from '../../src/adapters/ClmVaultExitAdapter.sol';
import {ClmFundsDeploy} from './ClmFundsDeploy.sol';

/// @notice The v6 keeper's exit adapters (2026-10-14): ERC4626ExitAdapter (ERC-4626 vault shares into USDC) and
///         ClmVaultExitAdapter (CLM vault shares, replacing ClmVaultAdapter's action 2 for the keeper: no route leaves a
///         token unsold in the router), both on the three Slipstream routers, both registered on the FundFactory.
///         Rehearsed in test/fork/ERC4626ExitFork.t.sol and ClmGhostLiquidationFork.t.sol. Touches no stock token.
///         Run: forge script script/mainnet/DeployExitAdapters.s.sol --rpc-url base --account frosty-main --sender <deployer>
///              --broadcast --slow --verify
///         Then the keeper: LIQUIDATION_ADAPTERS.erc4626Exit = `erc4626Exit`, CLM_ADAPTER = `clmExit`.
contract DeployExitAdapters is Script {
	string public constant OUTPUT_PATH = 'deployments/base-mainnet-exit-adapters.json';

	function run() external {
		vm.startBroadcast();
		ERC4626ExitAdapter erc4626Exit = new ERC4626ExitAdapter(
			ClmFundsDeploy.SLIPSTREAM1_ROUTER, ClmFundsDeploy.SLIPSTREAM2_ROUTER, ClmFundsDeploy.SLIPSTREAM3_ROUTER
		);
		ClmVaultExitAdapter clmExit = new ClmVaultExitAdapter(
			ClmFundsDeploy.SLIPSTREAM1_ROUTER, ClmFundsDeploy.SLIPSTREAM2_ROUTER, ClmFundsDeploy.SLIPSTREAM3_ROUTER
		);
		FundFactory(ClmFundsDeploy.FUND_FACTORY).registerAdapter(address(erc4626Exit));
		FundFactory(ClmFundsDeploy.FUND_FACTORY).registerAdapter(address(clmExit));
		vm.stopBroadcast();
		vm.serializeAddress('exitAdapters', 'erc4626Exit', address(erc4626Exit));
		vm.writeJson(vm.serializeAddress('exitAdapters', 'clmExit', address(clmExit)), OUTPUT_PATH);
		console.log('wrote', OUTPUT_PATH);
	}
}
