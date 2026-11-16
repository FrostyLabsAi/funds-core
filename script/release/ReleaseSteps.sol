// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {VerantaPriceStore} from '../../src/pricing/VerantaPriceStore.sol';
import {ClmVaultPriceFeed} from '../../src/pricing/ClmVaultPriceFeed.sol';
import {ERC4626PriceFeed} from '../../src/pricing/ERC4626PriceFeed.sol';
import {ERC4626ExitValueFeed} from '../../src/pricing/ERC4626ExitValueFeed.sol';
import {VerantaPerpConfig} from '../../src/positions/VerantaPerpConfig.sol';
import {Release} from './Release.sol';
import {ReleaseListings} from './ReleaseListings.sol';
import {BaseMainnet} from './BaseMainnet.sol';
import {B20LocalStandIns} from './B20LocalStandIn.sol';

/// @notice The release's two broadcast steps, shared by DeployRelease, ListRelease and RehearseRelease so the rehearsal
///         runs exactly what mainnet runs: (1) deploy and write the record; (2) read the record, hand the VI to the
///         registrar and copy every listing.
abstract contract ReleaseSteps is Script {
	string public constant RELEASE_PATH = 'deployments/base-mainnet-release.json';
	string public constant ASSETS_PATH = 'deployments/release-assets.json';

	function _deployStep(string memory recordPath) internal returns (Release.Deployed memory d) {
		require(block.chainid == 8453, 'Base mainnet only');
		vm.startBroadcast();
		d = Release.deploy(
			Release.Config({
				owner: msg.sender,
				treasury: BaseMainnet.TREASURY,
				guardian: BaseMainnet.ADMIN_SAFE,
				keeper: BaseMainnet.KEEPER
			})
		);
		vm.stopBroadcast();
		_write(d, recordPath);
	}

	/// @dev The Coinbase stock tokens get a local stand-in first (B20LocalStandIn); the recorded calls are unchanged.
	function _listStep(string memory recordPath, string memory assets)
		internal
		returns (Release.Deployed memory d, ReleaseListings.Counts memory c)
	{
		require(block.chainid == 8453, 'Base mainnet only');
		d = _read(vm.readFile(recordPath));
		address[] memory primitives = vm.parseJsonAddressArray(assets, '.primitives');
		B20LocalStandIns.standIn(primitives);
		vm.startBroadcast();
		c = ReleaseListings.list(
			d, primitives, vm.parseJsonAddressArray(assets, '.derivatives'), vm.parseJsonAddressArray(assets, '.derivativeFeeds')
		);
		vm.stopBroadcast();
		_logCounts(c);
	}

	function _logCounts(ReleaseListings.Counts memory c) internal pure {
		console2.log('chainlink', c.chainlink);
		console2.log('quotes', c.quotes);
		console2.log('pools', c.pools);
		console2.log('perp markers', c.perps);
		console2.log('B20 stocks', c.stocks);
		console2.log('derivatives', c.derivatives);
		console2.log('pairs mapped', c.pairs);
		console2.log('left out (unmapped markers)', c.skipped);
		console2.log('left out (retired Chainlink feeds)', c.deadFeeds);
	}

	function _write(Release.Deployed memory d, string memory path) internal {
		string memory k = 'release';
		vm.serializeUint(k, 'chainId', block.chainid);
		vm.serializeUint(k, 'startBlock', block.number);
		vm.serializeAddress(k, 'valueInterpreter', address(d.valueInterpreter));
		vm.serializeAddress(k, 'registrar', address(d.registrar));
		vm.serializeAddress(k, 'sampler', address(d.sampler));
		vm.serializeAddress(k, 'queue', address(d.queue));
		vm.serializeAddress(k, 'perpConfig', address(d.perpConfig));
		vm.serializeAddress(k, 'perpFactory', address(d.perpFactory));
		vm.serializeAddress(k, 'comptrollerDeployer', address(d.comptrollerDeployer));
		vm.serializeAddress(k, 'sharesVaultDeployer', address(d.sharesVaultDeployer));
		vm.serializeAddress(k, 'factory', address(d.factory));
		vm.serializeAddress(k, 'minPoolLiquidityPolicy', address(d.minPoolLiquidity));
		vm.serializeAddress(k, 'slippagePolicy', address(d.slippage));
		vm.serializeAddress(k, 'verantaStore', address(d.verantaStore));
		vm.serializeAddress(k, 'clmFeed', address(d.clmFeed));
		vm.serializeAddress(k, 'erc4626Feed', address(d.erc4626Feed));
		vm.serializeAddress(k, 'erc4626ExitFeed', address(d.erc4626ExitFeed));
		vm.serializeAddress(k, 'protectRegistry', address(d.protectRegistry));
		vm.serializeAddress(k, 'advisorRegistry', address(d.advisorRegistry));
		vm.serializeAddress(k, 'profileRegistry', address(d.profileRegistry));
		Release.Adapters memory a = d.adapters;
		vm.serializeAddress(k, 'uniswapV3Adapter', address(a.uniswapV3));
		vm.serializeAddress(k, 'uniswapV4Adapter', address(a.uniswapV4));
		vm.serializeAddress(k, 'slipstream1Adapter', address(a.slipstream1));
		vm.serializeAddress(k, 'slipstream2Adapter', address(a.slipstream2));
		vm.serializeAddress(k, 'slipstream3Adapter', address(a.slipstream3));
		vm.serializeAddress(k, 'aeroAdapter', address(a.aero));
		vm.serializeAddress(k, 'aerodromeBasicAdapter', address(a.aerodromeBasic));
		vm.serializeAddress(k, 'viaWethSellAdapter', address(a.viaWeth));
		vm.serializeAddress(k, 'clmAdapter', address(a.clm));
		vm.serializeAddress(k, 'clmExitAdapter', address(a.clmExit));
		vm.serializeAddress(k, 'erc4626Adapter', address(a.erc4626));
		string memory json = vm.serializeAddress(k, 'erc4626ExitAdapter', address(a.erc4626Exit));
		vm.writeJson(json, path);
		console2.log('release written to', path);
	}

	/// @dev The contracts the listings touch, from the deploy step's record.
	function _read(string memory json) internal pure returns (Release.Deployed memory d) {
		d.valueInterpreter = ValueInterpreter(vm.parseJsonAddress(json, '.valueInterpreter'));
		d.registrar = PoolPriceRegistrar(vm.parseJsonAddress(json, '.registrar'));
		d.verantaStore = VerantaPriceStore(vm.parseJsonAddress(json, '.verantaStore'));
		d.clmFeed = ClmVaultPriceFeed(vm.parseJsonAddress(json, '.clmFeed'));
		d.erc4626Feed = ERC4626PriceFeed(vm.parseJsonAddress(json, '.erc4626Feed'));
		d.erc4626ExitFeed = ERC4626ExitValueFeed(vm.parseJsonAddress(json, '.erc4626ExitFeed'));
		d.perpConfig = VerantaPerpConfig(vm.parseJsonAddress(json, '.perpConfig'));
	}
}
