// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {TwapListingRegistry} from '../src/pricing/TwapListingRegistry.sol';
import {TwapAggregatorAdapter} from '../src/pricing/TwapAggregatorAdapter.sol';

/// @notice Lists tMEME (DeployTmemeDemoPool) on the Veranta-testnet TWAP registry and adds its
///         price to the ValueInterpreter — the owner's two listing steps, one broadcast.
///         Needs the pool to hold 30 minutes of observations first.
///         Run: forge script script/ListTmemeVerantaTestnet.s.sol --rpc-url https://devnet-rpc.veranta.xyz --broadcast
///         Env: VT_DEPLOYER_KEY
contract ListTmemeVerantaTestnet is Script {
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant TMEME = 0x20495fe07aFcBc431230e4DdaF4D473E6e2eB4F2;
	ValueInterpreter internal constant VI = ValueInterpreter(0x5E56C3bF43b2214e3fccE9D515Ed684c0315Aa46);
	TwapListingRegistry internal constant REGISTRY = TwapListingRegistry(0xDD19b0d0f37E3893F5564C3559c35B1033e00Aa0);

	function run() external {
		vm.startBroadcast(vm.envUint('VT_DEPLOYER_KEY'));
		TwapAggregatorAdapter adapter = REGISTRY.list(TMEME, USDC, TwapListingRegistry.Venue.UniswapV3, 3000);
		VI.addPrimitive(TMEME, address(adapter), 1 hours);
		vm.stopBroadcast();

		(, int256 price,,,) = adapter.latestRoundData();
		console2.log('tMEME adapter', address(adapter));
		console2.log('price usd18', uint256(price));
		console2.log('depth usd18', adapter.poolDepthUsd());
	}
}
