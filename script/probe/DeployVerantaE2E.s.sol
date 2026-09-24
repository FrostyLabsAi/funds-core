// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../../src/core/FundComponentDeployers.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {IVerantaTradingRouter, IVerantaMulticall, IVerantaPairStorage} from '../../src/interfaces/external/IVeranta.sol';

/// @notice Anvil-fork ONLY: full-stack deploy for the Veranta keeper e2e — VI on real
///         Chainlink feeds, position factory vs the real Veranta contracts, one fund,
///         one VerantaPerpPositionV2. Broadcaster = fund manager.
contract DeployVerantaE2E is Script {
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant WETH = 0x4200000000000000000000000000000000000006;
	address internal constant CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
	address internal constant CHAINLINK_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
	address internal constant VERANTA_ROUTER = 0x44914408af82bC9983bbb330e3578E1105e11d4e;
	address internal constant VERANTA_STORAGE = 0x8a311D7048c35985aa31C131B9A13e03a5f7422d;
	address internal constant VERANTA_MULTICALL = 0xA7cFc43872F4D7B0E6141ee8c36f1F7FEe5d099e;
	address internal constant VERANTA_PAIR_STORAGE = 0x5db3772136e5557EFE028Db05EE95C84D76faEC4; // multicall.pairsStorage()

	function run() external {
		address keeper = vm.envAddress('E2E_KEEPER');
		vm.startBroadcast();

		ValueInterpreter interpreter = new ValueInterpreter(msg.sender);
		interpreter.addPrimitive(USDC, CHAINLINK_USDC_USD, 2 days);
		interpreter.addPrimitive(WETH, CHAINLINK_ETH_USD, 1 days);

		VerantaPerpPositionV2Factory positionFactory = new VerantaPerpPositionV2Factory(
			IERC20(USDC),
			IVerantaTradingRouter(VERANTA_ROUTER),
			IVerantaMulticall(VERANTA_MULTICALL),
			VERANTA_STORAGE,
			IVerantaPairStorage(VERANTA_PAIR_STORAGE),
			keeper
		);
		positionFactory.setPairAsset(0, WETH); // Crypto.ETH/USD

		FundFactory factory = new FundFactory(interpreter, new ComptrollerDeployer(), new SharesVaultDeployer());
		factory.registerPositionType(6, address(positionFactory));

		Comptroller comptroller = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Veranta E2E Fund',
					symbol: 'frE2E',
					denominationAsset: IERC20(USDC),
					fundOwner: msg.sender,
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: 0,
					sharesActionTimelock: 0,
					minRequestDuration: 30 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				})
			)
		);
		address position = comptroller.createExternalPosition(6, '');

		vm.stopBroadcast();

		console2.log('E2E_COMPTROLLER', address(comptroller));
		console2.log('E2E_VAULT', address(comptroller.vault()));
		console2.log('E2E_POSITION', position);
	}
}
