// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {console2} from 'forge-std/Script.sol';
import {ReleaseSteps} from '../release/ReleaseSteps.sol';
import {Release} from '../release/Release.sol';
import {B20LocalStandIns} from '../release/B20LocalStandIn.sol';
import {NewListings} from './NewListings.sol';

/// @notice Lists new assets on the release (deployments/base-mainnet-release.json), from a list in deployments/
///         (listings-<date>.json): Coinbase stocks on a Chainlink feed, Coinbase stocks on Veranta's price, Veranta perp
///         markets, pool-priced tokens. `vaults()` then lists every CLM vault of deployments/base-mainnet-clm-v2.json the
///         VI doesn't price yet (copy funds-yield's file over it first). Both skip what is already listed, so either can
///         be run again.
///         Coinbase stock tokens are a Base precompile Foundry can't run: the local run puts a stand-in at each
///         (B20LocalStandIn) and the recorded calls run against the real tokens, so the broadcast skips forge's on-chain
///         simulation, as ListRelease does. The deployer sends one transaction at a time (--slow).
///         Check (nothing sent):
///           LISTINGS=deployments/listings-<date>.json forge script script/listings/ListNewAssets.s.sol --rpc-url base \
///             --sender <deployer>
///         Send: add --account frosty-main --broadcast --skip-simulation --gas-estimate-multiplier 200 --slow
///         Vaults: the same two commands with --sig 'vaults()'
contract ListNewAssets is ReleaseSteps {
	string public constant CLM_VAULTS_PATH = 'deployments/base-mainnet-clm-v2.json';

	function run() external {
		require(block.chainid == 8453, 'Base mainnet only');
		Release.Deployed memory d = _read(vm.readFile(RELEASE_PATH));
		string memory list = vm.readFile(vm.envString('LISTINGS'));
		B20LocalStandIns.standIn(_tokens(list, '.chainlinkStocks'));
		B20LocalStandIns.standIn(_tokens(list, '.verantaStocks'));
		B20LocalStandIns.standIn(_tokens(list, '.poolPriced'));

		vm.startBroadcast();
		_list(d, list);
		vm.stopBroadcast();
	}

	function vaults() external {
		require(block.chainid == 8453, 'Base mainnet only');
		Release.Deployed memory d = _read(vm.readFile(RELEASE_PATH));
		address[] memory all = _clmVaults();
		uint256 listed;
		vm.startBroadcast();
		for (uint256 i; i < all.length; ++i) {
			if (!NewListings.clmVault(d, all[i])) continue;
			console2.log('vault listed', all[i]);
			++listed;
		}
		vm.stopBroadcast();
		console2.log('vaults listed', listed, 'of', all.length);
	}

	/// @dev Every entry of the list, in the order a dependency needs: feeds first, pools last.
	function _list(Release.Deployed memory d, string memory list) internal {
		for (uint256 i; _has(list, '.chainlinkStocks', i); ++i) {
			string memory at = _at('.chainlinkStocks', i);
			bool listed = NewListings.chainlinkStock(
				d, vm.parseJsonAddress(list, string.concat(at, '.token')), vm.parseJsonAddress(list, string.concat(at, '.feed'))
			);
			_log(vm.parseJsonString(list, string.concat(at, '.symbol')), 'its Chainlink feed', listed);
		}
		for (uint256 i; _has(list, '.verantaStocks', i); ++i) {
			string memory at = _at('.verantaStocks', i);
			string memory symbol = vm.parseJsonString(list, string.concat(at, '.symbol'));
			bool listed = NewListings.verantaStock(
				d,
				vm.parseJsonAddress(list, string.concat(at, '.token')),
				vm.parseJsonUint(list, string.concat(at, '.pair')),
				symbol,
				vm.parseJsonUint(list, string.concat(at, '.referencePrice'))
			);
			_log(symbol, 'Veranta\'s price', listed);
		}
		for (uint256 i; _has(list, '.perpMarkets', i); ++i) {
			string memory at = _at('.perpMarkets', i);
			string memory base = vm.parseJsonString(list, string.concat(at, '.base'));
			uint256 pairIndex = vm.parseJsonUint(list, string.concat(at, '.pair'));
			console2.log(string.concat(base, ' perp: pair'), pairIndex, 'marker', NewListings.perpMarket(d, pairIndex, base));
		}
		for (uint256 i; _has(list, '.poolPriced', i); ++i) {
			string memory at = _at('.poolPriced', i);
			bool listed = NewListings.poolPriced(
				d, vm.parseJsonAddress(list, string.concat(at, '.token')), vm.parseJsonAddress(list, string.concat(at, '.pool'))
			);
			_log(vm.parseJsonString(list, string.concat(at, '.symbol')), 'its pool', listed);
		}
	}

	/// @dev Every vault of the CLM record, which keys them by symbol.
	function _clmVaults() internal view returns (address[] memory all) {
		string memory record = vm.readFile(CLM_VAULTS_PATH);
		string[] memory symbols = vm.parseJsonKeys(record, '.vaults');
		all = new address[](symbols.length);
		for (uint256 i; i < symbols.length; ++i) {
			all[i] = vm.parseJsonAddress(record, string.concat('.vaults["', symbols[i], '"].vault'));
		}
	}

	/// @dev A section's tokens. Read one entry at a time: a `[*]` path over a single entry parses as one value, not a list.
	function _tokens(string memory list, string memory section) internal view returns (address[] memory tokens) {
		uint256 count;
		while (_has(list, section, count)) ++count;
		tokens = new address[](count);
		for (uint256 i; i < count; ++i) {
			tokens[i] = vm.parseJsonAddress(list, string.concat(_at(section, i), '.token'));
		}
	}

	function _has(string memory list, string memory section, uint256 i) private view returns (bool) {
		return vm.keyExistsJson(list, _at(section, i));
	}

	function _at(string memory section, uint256 i) private pure returns (string memory) {
		return string.concat(section, '[', vm.toString(i), ']');
	}

	function _log(string memory symbol, string memory how, bool listed) private pure {
		console2.log(string.concat(symbol, listed ? ': listed on ' : ': already listed on ', how));
	}
}
