// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {ERC4626PriceFeed} from '../../src/pricing/ERC4626PriceFeed.sol';
import {YieldListing} from './YieldListing.sol';
import {ListingModuleBook, ViAdmin} from './ListingModuleBook.sol';

/// @notice Runbook step 3, AFTER list-coinbase-stocks.sh (the IPOR stock vaults need their stock
///         priced): deploy one ERC4626PriceFeed (or reuse YIELD_FEED) and register every vault in
///         YieldListing as a VI derivative — Aave V3, Morpho, and the stock carry vaults. Funds
///         then deposit/redeem through the genesis ERC4626Adapter. Stock LP yields (Aerodrome
///         incl. gauge staking for AERO, Uniswap v3) need no listing beyond the stock script.
///         forge is safe here: registration reads only the vaults, never a B20 token.
///         Derivatives go through the VI's owner (ListingModuleBook: the pool-pricing registrar, or
///         the TWAP v2 module before the switch-over): the broadcaster must own it.
///         Run: forge script script/mainnet/ListYieldVaults.s.sol --rpc-url <base> --broadcast --account frosty-main --sender <deployer>
contract ListYieldVaults is Script {
	function run() external {
		require(block.chainid == 8453, 'Base (8453) only');
		string memory json = vm.readFile(vm.envOr('DEPLOYMENTS_FILE', string('deployments/base-mainnet.json')));
		ViAdmin memory admin = ListingModuleBook.admin(vm, json);
		ValueInterpreter vi = ValueInterpreter(vm.parseJsonAddress(json, '.valueInterpreter'));

		vm.startBroadcast();
		address feed = vm.envOr('YIELD_FEED', address(0));
		if (feed == address(0)) feed = address(new ERC4626PriceFeed());
		uint256 listed = YieldListing.listAll(admin, vi, feed, YieldListing.nonStockVaults());
		listed += YieldListing.listAll(admin, vi, feed, YieldListing.stockVaults());
		vm.stopBroadcast();

		console2.log('ERC4626PriceFeed', feed);
		console2.log('vaults listed', listed);
	}
}
