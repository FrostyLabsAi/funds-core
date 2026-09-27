// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {LimitOrderPositionFactory} from '../src/positions/LimitOrderPosition.sol';
import {UniswapV3LPPositionFactory} from '../src/positions/UniswapV3LPPosition.sol';
import {VerantaPerpPositionV2Factory} from '../src/positions/VerantaPerpPositionV2.sol';
import {IUniswapV3NonfungiblePositionManager} from
	'../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {
	IVerantaTradingRouter,
	IVerantaMulticall,
	IVerantaPairStorage,
	IVerantaReferral
} from '../src/interfaces/external/IVeranta.sol';

/// @title DeployWave8
/// @notice Base Sepolia wave after the 2026-09-24 security review + the 2026-09-27 governance
///         settings (commit a3520d4): a FundFactory with the settable ComptrollerDeployer, the
///         policy-swap allowlist and the M-1 pause carry-over, over the H-1 Comptroller
///         (risk-reducing position actions skip pricing) — so all three position types are new
///         too (IExternalPosition.isRiskReducing). Side-by-side: wave-7 funds keep running.
///         KEPT — runtime code identical to the committed source (bytecode-compared with
///         immutables masked, 2026-09-27): the swap / 4626 / compounder adapters, the
///         ProtocolFeeReserve, the compounders + feeds, AdvisorRegistry, ProtectRegistry, the
///         V2 demo venue, the TWAP floor demo. Also KEPT: the wave-7 ValueInterpreter — its only
///         change since is the L2 sequencer check, which has no feed to read on Base Sepolia.
///         NEW: FundFactory + deployers (25 bps protocol fee → the kept reserve), position types
///         2 / 3 / 6 (pair 0 = tETH on the kept venue, referral 'frostyfi'), a demo fund.
/// @dev NO --verify (unverified by design). The broadcaster becomes owner of everything.
///   Env: KEEPER (autopilot keeper — the V2 factory's delegate).
///   forge script script/DeployWave8.s.sol:DeployWave8 --rpc-url https://sepolia.base.org \
///     --private-key <deployer> --broadcast --slow
contract DeployWave8 is Script {
	address internal constant VALUE_INTERPRETER = 0xFe4045E483fB3Ab36e773EFd73de7F2440cC9eF6;
	address internal constant FEE_RESERVE = 0xfB9F3B45356aD531420D5fad5046d0E92F41Ac8c;
	address internal constant UNI_ADAPTER = 0xbbD4Ff0A7F4Afa0975539674D6fF21fcD138968C;
	address internal constant ERC4626_ADAPTER = 0x0F9A0476a91918e13A24e099B181cd0f501CE921;
	address internal constant COMPOUNDER_ADAPTER = 0x2F8E4986f269f979c525b18EFcD6E625e6734826;
	address internal constant VERANTA_VENUE = 0x2152f5A3796B23177ED19E51606fF827Be7c156A; // MockVeranta V2 (also Referral)
	address internal constant TUSDC = 0x75F31B7C00E6282CDCFd7B4124d8ab327bE3Ab4D;
	address internal constant TETH = 0xB949122bF2991edA2d660A2E99f2393ffE74Ae01;
	IUniswapV3NonfungiblePositionManager internal constant NPM =
		IUniswapV3NonfungiblePositionManager(0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2);
	bytes32 internal constant REFERRAL_CODE = 'frostyfi';
	uint16 internal constant PROTOCOL_FEE_BPS = 25;

	function run() external {
		require(block.chainid == 84532, 'Base Sepolia only');
		address keeper = vm.envAddress('KEEPER');

		vm.startBroadcast();
		FundFactory factory =
			new FundFactory(ValueInterpreter(VALUE_INTERPRETER), new ComptrollerDeployer(), new SharesVaultDeployer());
		factory.setProtocolFee(PROTOCOL_FEE_BPS, FEE_RESERVE);
		factory.registerAdapter(UNI_ADAPTER);
		factory.registerAdapter(ERC4626_ADAPTER);
		factory.registerAdapter(COMPOUNDER_ADAPTER);

		LimitOrderPositionFactory limitOrders = new LimitOrderPositionFactory();
		factory.registerPositionType(2, address(limitOrders));
		UniswapV3LPPositionFactory lp = new UniswapV3LPPositionFactory(NPM);
		factory.registerPositionType(3, address(lp));
		VerantaPerpPositionV2Factory perps = new VerantaPerpPositionV2Factory(
			IERC20(TUSDC),
			IVerantaTradingRouter(VERANTA_VENUE),
			IVerantaMulticall(VERANTA_VENUE),
			VERANTA_VENUE,
			IVerantaPairStorage(VERANTA_VENUE),
			keeper
		);
		perps.setPairAsset(0, TETH);
		perps.setReferral(IVerantaReferral(VERANTA_VENUE), REFERRAL_CODE);
		factory.registerPositionType(6, address(perps));

		Comptroller fund = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Wave 8 Demo Fund',
					symbol: 'frW8',
					denominationAsset: IERC20(TUSDC),
					fundOwner: msg.sender,
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: 0,
					sharesActionTimelock: 0,
					minRequestDuration: 1 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				})
			)
		);
		vm.stopBroadcast();

		console2.log('FUND_FACTORY          ', address(factory));
		console2.log('START_BLOCK           ', block.number);
		console2.log('COMPTROLLER_DEPLOYER  ', address(factory.comptrollerDeployer()));
		console2.log('LIMIT_ORDER_FACTORY   ', address(limitOrders));
		console2.log('LP_FACTORY            ', address(lp));
		console2.log('VERANTA_FACTORY       ', address(perps));
		console2.log('DEMO_FUND             ', address(fund));
		console2.log('DEMO_VAULT            ', address(fund.vault()));
		console2.log('KEEPER                ', keeper);
	}
}
