// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {UniswapV3LPPositionFactory} from '../src/positions/UniswapV3LPPosition.sol';
import {IUniswapV3NonfungiblePositionManager} from
	'../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';

/// @title DeployLpVenue
/// @notice Wave 4: the Uniswap v3 LP external-position type (type 3) against the REAL
///         Base Sepolia NonfungiblePositionManager — the delta-neutral strategy's long
///         leg. (Live type registry: 1=hyperliquid, 2=limit orders, 3=uniswap v3 LP,
///         5=solana; Slipstream LP takes 4 when Aerodrome infra exists — mainnet.)
/// @dev NO --verify (unverified by design). Env: FACTORY, NPM.
///   forge script script/DeployLpVenue.s.sol:DeployLpVenue \
///     --rpc-url base_sepolia --private-key $PRIVATE_KEY --broadcast --slow
contract DeployLpVenue is Script {
	uint256 internal constant LP_TYPE_ID = 3;

	function run() external {
		FundFactory factory = FundFactory(vm.envAddress('FACTORY'));
		IUniswapV3NonfungiblePositionManager npm =
			IUniswapV3NonfungiblePositionManager(vm.envAddress('NPM'));
		vm.startBroadcast();
		UniswapV3LPPositionFactory positionFactory = new UniswapV3LPPositionFactory(npm);
		factory.registerPositionType(LP_TYPE_ID, address(positionFactory));
		vm.stopBroadcast();
		console2.log('UniswapV3LPPositionFactory (type 3):', address(positionFactory));
	}
}
