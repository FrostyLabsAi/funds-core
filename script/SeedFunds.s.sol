// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {MockERC20} from '../test/utils/Mocks.sol';

/// @title SeedFunds — phase 1: create demo funds + escrow deposits
/// @notice Creates three fictional demo funds and requests seed deposits from the deployer.
///         Deposit execution must wait out each fund's minRequestDuration (10 minutes here),
///         so run SeedExecute.s.sol AFTER ~10 minutes.
/// @dev Env (from DeployTestnet output): FACTORY, TUSDC.
///   forge script script/SeedFunds.s.sol --rpc-url base_sepolia --account <keystore> --broadcast
contract SeedFunds is Script {
	function run() external {
		FundFactory factory = FundFactory(vm.envAddress('FACTORY'));
		MockERC20 usdc = MockERC20(vm.envAddress('TUSDC'));

		vm.startBroadcast();
		address deployer = msg.sender;

		// Mock tUSDC mints freely; real (faucet) USDC will revert here and is skipped —
		// fund the deployer from https://faucet.circle.com in that case.
		try usdc.mint(deployer, 3_000_000e6) {} catch {}

		address[3] memory comptrollers;
		string[3] memory names = ['Frosty Alpha (demo)', 'Iceberg Yield (demo)', 'Glacier Delta Neutral (demo)'];
		string[3] memory symbols = ['frALPHA', 'frICE', 'frGDN'];
		uint16[3] memory perfFees = [uint16(1500), 1000, 2000];
		uint256[3] memory seeds = [uint256(1_000_000e6), 500_000e6, 250_000e6];

		for (uint256 i; i < 3; ++i) {
			comptrollers[i] = factory.createFund(
				FundFactory.FundConfig({
					name: names[i],
					symbol: symbols[i],
					denominationAsset: IERC20(address(usdc)),
					fundOwner: deployer,
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: perfFees[i],
					sharesActionTimelock: 1 hours,
					minRequestDuration: 10 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				})
			);
			usdc.approve(comptrollers[i], seeds[i]);
			Comptroller(comptrollers[i]).requestDeposit(seeds[i]);
			console2.log(names[i], comptrollers[i]);
		}

		vm.stopBroadcast();
		console2.log('Now wait >=10 minutes, then run SeedExecute.s.sol with COMPTROLLERS set.');
	}
}

/// @title SeedExecute — phase 2: execute the escrowed seed deposits
/// @dev Env: COMPTROLLER_1..3 (from SeedFunds output). Run >=10 minutes after SeedFunds.
contract SeedExecute is Script {
	function run() external {
		vm.startBroadcast();
		address deployer = msg.sender;

		for (uint256 i = 1; i <= 3; ++i) {
			address comptroller = vm.envOr(string.concat('COMPTROLLER_', vm.toString(i)), address(0));
			if (comptroller == address(0)) continue;
			Comptroller(comptroller).executeDepositRequest(deployer);
			console2.log('Executed seed deposit for', comptroller);
		}

		vm.stopBroadcast();
	}
}
