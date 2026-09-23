// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {LimitOrderPositionFactory} from '../src/positions/LimitOrderPosition.sol';

/// @title DeployLimitOrderVenue
/// @notice Wave 3: the on-chain order-book venue (LimitOrderPosition, type 2) —
///         resting limit orders for funds, fillable by anyone, fully on-chain valued.
/// @dev NO --verify (unverified by design). Env: FACTORY.
///   forge script script/DeployLimitOrderVenue.s.sol:DeployLimitOrderVenue \
///     --rpc-url base_sepolia --private-key $PRIVATE_KEY --broadcast --slow
contract DeployLimitOrderVenue is Script {
	uint256 internal constant LIMIT_ORDER_TYPE_ID = 2;

	function run() external {
		FundFactory factory = FundFactory(vm.envAddress('FACTORY'));
		vm.startBroadcast();
		LimitOrderPositionFactory positionFactory = new LimitOrderPositionFactory();
		factory.registerPositionType(LIMIT_ORDER_TYPE_ID, address(positionFactory));
		vm.stopBroadcast();
		console2.log('LimitOrderPositionFactory (type 2):', address(positionFactory));
	}
}
