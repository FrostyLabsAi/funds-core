// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {VerantaPerpPositionFactory} from '../src/positions/VerantaPerpPosition.sol';
import {IVerantaTradingRouter, IVerantaMulticall} from '../src/interfaces/external/IVeranta.sol';
import {MockVeranta} from '../test/utils/MockVeranta.sol';

/// @title DeployVerantaDemoVenue
/// @notice Wave 5: the Veranta perp external-position type (type 6) on Base Sepolia,
///         backed by a DEMO venue (the unit-test MockVeranta, deployed for real): same
///         two-step market opens (pending → fill), same delegation surface, tUSDC
///         collateral. `fillPending` is PUBLIC — anyone (the keeper, a test script, the
///         founder) can play operator, so the whole manager flow is testnet-testable.
///         The REAL Veranta contracts exist only on Base mainnet; that leg is proven on
///         the anvil fork (see README) and this registration keeps testnet 1:1 in shape.
///         (Live type registry: 1=hyperliquid, 2=limit orders, 3=uniswap v3 LP,
///         5=solana, 6=veranta perp; 4 reserved for Slipstream LP — mainnet.)
/// @dev NO --verify (unverified by design). Env: FACTORY, TUSDC, TETH, KEEPER.
///   forge script script/DeployVerantaDemoVenue.s.sol:DeployVerantaDemoVenue \
///     --rpc-url base_sepolia --private-key $PRIVATE_KEY --broadcast --slow
contract DeployVerantaDemoVenue is Script {
	uint256 internal constant VERANTA_TYPE_ID = 6;
	uint256 internal constant ETH_PAIR = 0; // mirrors Veranta mainnet: Crypto.ETH/USD = 0

	function run() external {
		FundFactory factory = FundFactory(vm.envAddress('FACTORY'));
		IERC20 tUsdc = IERC20(vm.envAddress('TUSDC'));
		address tEth = vm.envAddress('TETH');
		address keeper = vm.envAddress('KEEPER');

		vm.startBroadcast();
		MockVeranta venue = new MockVeranta(tUsdc);
		// The mock is router + multicall + USDC spender in one contract
		VerantaPerpPositionFactory positionFactory = new VerantaPerpPositionFactory(
			tUsdc,
			IVerantaTradingRouter(address(venue)),
			IVerantaMulticall(address(venue)),
			address(venue),
			keeper
		);
		positionFactory.setPairAsset(ETH_PAIR, tEth);
		factory.registerPositionType(VERANTA_TYPE_ID, address(positionFactory));
		vm.stopBroadcast();

		console2.log('DemoVeranta venue:', address(venue));
		console2.log('VerantaPerpPositionFactory (type 6):', address(positionFactory));
	}
}
