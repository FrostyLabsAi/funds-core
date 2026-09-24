// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {VerantaPerpPositionV2Factory} from '../src/positions/VerantaPerpPositionV2.sol';
import {
	IVerantaTradingRouter,
	IVerantaMulticall,
	IVerantaPairStorage,
	IVerantaReferral
} from '../src/interfaces/external/IVeranta.sol';
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
		// The mock is router + multicall + storage + pair storage + USDC spender in one contract
		VerantaPerpPositionV2Factory positionFactory = new VerantaPerpPositionV2Factory(
			tUsdc,
			IVerantaTradingRouter(address(venue)),
			IVerantaMulticall(address(venue)),
			address(venue),
			IVerantaPairStorage(address(venue)),
			keeper
		);
		positionFactory.setPairAsset(ETH_PAIR, tEth);
		// the mock also plays Veranta's Referral contract (LinkReferral is testable end to end)
		positionFactory.setReferral(IVerantaReferral(address(venue)), 'frostyfi');
		factory.registerPositionType(VERANTA_TYPE_ID, address(positionFactory));
		vm.stopBroadcast();

		console2.log('DemoVeranta venue:', address(venue));
		console2.log('VerantaPerpPositionV2Factory (type 6):', address(positionFactory));
	}
}
