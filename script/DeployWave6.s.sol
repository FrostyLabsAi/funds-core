// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {VerantaPerpPositionFactory} from '../src/positions/VerantaPerpPosition.sol';
import {IVerantaTradingRouter, IVerantaMulticall} from '../src/interfaces/external/IVeranta.sol';
import {MockVeranta} from '../test/utils/MockVeranta.sol';

/// @title DeployWave6
/// @notice The SET-ONCE RULESET factory redeploy (melon model, completed):
///         createFund(config, policies[]) registers the ruleset atomically at birth;
///         every fund carries a mandate (UnrestrictedMandatePolicy auto-attached when
///         none supplied — deployed BY the factory constructor); policies are frozen
///         forever (addPolicy = factory-only) and carry across reconfigurations;
///         on-chain name reservation + fundNameTaken(string) live check; deposit
///         cooldown floor now 1 minute. Also folds in the Veranta demo venue (type 6).
///         Existing VI/tokens/feeds/pools/adapters/position factories are REUSED —
///         only the factory layer is new. Old factory's funds retire (testnet).
/// @dev NO --verify (unverified by design). Env: VALUE_INTERPRETER, TUSDC, TETH, KEEPER.
///   forge script script/DeployWave6.s.sol:DeployWave6 \
///     --rpc-url base_sepolia --private-key $PRIVATE_KEY --broadcast --slow
contract DeployWave6 is Script {
	// Deployment of record (Base Sepolia) — reused as-is
	address internal constant UNI_ADAPTER = 0xB7d0C0Fc11DC4EB792833E83952713B0b7d2Fc56; // SwapRouter02-correct
	address internal constant AERO_ADAPTER = 0x18D008747a38770883B9B7245e4BcDF02263f11b;
	address internal constant ERC4626_ADAPTER = 0xA565A54c93d5981B4f751eDB65657E754bfa4B73;
	address internal constant HL_POSITION_FACTORY = 0xe643bB2c9394D71Bf14398CC385C74306d618Fbc; // type 1
	address internal constant LIMIT_ORDER_FACTORY = 0xF7eDacFc6850f16741ADed2530D0B375C76b1A03; // type 2
	address internal constant UNIV3_LP_FACTORY = 0x5C3E94576a9807d1e8c8b401603a968Af84a3236; // type 3
	address internal constant SOLANA_FACTORY = 0x749eb943B525D527cB0f913B73942E2617c3CC71; // type 5

	function run() external {
		ValueInterpreter interpreter = ValueInterpreter(vm.envAddress('VALUE_INTERPRETER'));
		IERC20 tUsdc = IERC20(vm.envAddress('TUSDC'));
		address tEth = vm.envAddress('TETH');
		address keeper = vm.envAddress('KEEPER');

		vm.startBroadcast();

		FundFactory factory =
			new FundFactory(interpreter, new ComptrollerDeployer(), new SharesVaultDeployer());

		factory.registerAdapter(UNI_ADAPTER);
		factory.registerAdapter(AERO_ADAPTER);
		factory.registerAdapter(ERC4626_ADAPTER);

		factory.registerPositionType(1, HL_POSITION_FACTORY);
		factory.registerPositionType(2, LIMIT_ORDER_FACTORY);
		factory.registerPositionType(3, UNIV3_LP_FACTORY);
		factory.registerPositionType(5, SOLANA_FACTORY);

		// Veranta demo venue (wave 5 folded in): the unit suite's MockVeranta deployed
		// for real — public fillPending = anyone plays operator on testnet
		MockVeranta venue = new MockVeranta(tUsdc);
		VerantaPerpPositionFactory verantaFactory = new VerantaPerpPositionFactory(
			tUsdc,
			IVerantaTradingRouter(address(venue)),
			IVerantaMulticall(address(venue)),
			address(venue),
			keeper
		);
		verantaFactory.setPairAsset(0, tEth); // mirrors Veranta mainnet: Crypto.ETH/USD = 0
		factory.registerPositionType(6, address(verantaFactory));

		vm.stopBroadcast();

		console2.log('W6_FUND_FACTORY', address(factory));
		console2.log('W6_UNRESTRICTED_MANDATE', factory.unrestrictedMandate());
		console2.log('W6_VERANTA_VENUE', address(venue));
		console2.log('W6_VERANTA_FACTORY_TYPE6', address(verantaFactory));
	}
}
