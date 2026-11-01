// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console} from 'forge-std/Script.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {ClmVaultPriceFeed} from '../../src/pricing/ClmVaultPriceFeed.sol';
import {ClmFundsDeploy} from './ClmFundsDeploy.sol';

/// @notice Lists every vault of deployments/base-mainnet-clm.json (copied from funds-yield after a deploy) that the VI
///         doesn't price yet, on the live feed (`_feed`), through registrar V3 → V2 → today's registrar. For vaults added after DeployClmFunds (2026-10-14), which also deploys a
///         feed and an adapter; already-priced vaults are skipped. Rehearsed in test/fork/ListClmVaultsFork.t.sol.
///         Run: forge script script/mainnet/ListClmVaults.s.sol --rpc-url base --account frosty-main --sender <deployer>
///              --broadcast --slow
///         CLM v2 on Aero (2026-10-25): CLM_BOOK=deployments/base-mainnet-clm-v2.json lists its vaults the same way (the
///         feed prices them as v1's: same strategy factory).
contract ListClmVaults is Script {
	string public constant CLM_PATH = 'deployments/base-mainnet-clm.json';
	string public constant CLM_FUNDS_PATH = 'deployments/base-mainnet-clm-funds.json';
	string public constant WINDOWED_PATH = 'deployments/base-mainnet-windowed-pricing.json';

	function run() external {
		string memory clm = vm.readFile(vm.envOr('CLM_BOOK', CLM_PATH));
		string[] memory symbols = vm.parseJsonKeys(clm, '.vaults');
		address[] memory vaults = new address[](symbols.length);
		for (uint256 i; i < symbols.length; ++i) {
			vaults[i] = vm.parseJsonAddress(clm, string.concat('.vaults.', symbols[i], '.vault'));
		}
		ClmVaultPriceFeed feed = _feed();
		vm.startBroadcast();
		uint256 listed = ClmFundsDeploy.listUnpriced(feed, vaults);
		vm.stopBroadcast();
		console.log('vaults in the book', vaults.length);
		console.log('vaults listed now', listed);
	}

	/// @dev A feed asks its own registrar about a vault's tokens, so new listings use the fixed chain's feed once it owns the VI
	///      (PRICING-POOL-01, 2026-11-01). Vaults listed before stay on the feed they were listed with.
	function _feed() private view returns (ClmVaultPriceFeed) {
		if (vm.exists(WINDOWED_PATH)) {
			string memory windowed = vm.readFile(WINDOWED_PATH);
			if (Ownable(ClmFundsDeploy.VALUE_INTERPRETER).owner() == vm.parseJsonAddress(windowed, '.base')) {
				return ClmVaultPriceFeed(vm.parseJsonAddress(windowed, '.clmFeed'));
			}
		}
		return ClmVaultPriceFeed(vm.parseJsonAddress(vm.readFile(CLM_FUNDS_PATH), '.feed'));
	}
}
