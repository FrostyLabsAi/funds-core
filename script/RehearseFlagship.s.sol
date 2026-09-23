// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {IPolicy} from '../src/interfaces/IPolicy.sol';
import {AllowedExternalPositionTypesPolicy} from '../src/policies/AllowedExternalPositionTypesPolicy.sol';

interface IMintableToken {
	function mint(address to, uint256 amount) external;
}

/// @title RehearseFlagship (Base Sepolia, wave-6 factory)
/// @notice Flagship-on-Veranta-rails rehearsal, phase A: create a fund BORN with its
///         mandate (venue mandate: LP + veranta perps), fund the manager, request the
///         deposit (1-minute cooldown — the new floor in action).
///         Phase B (RehearseFlagshipB, ≥60s later): execute deposit → open the LP long
///         leg (real Sepolia Uniswap NPM, tUSDC/tETH full range) → open the Veranta
///         hedge position → fund it + SetAutopilot. The keeper then runs live.
/// @dev Env: FACTORY (wave 6), TUSDC, TETH.
contract RehearseFlagship is Script {
	function run() external {
		FundFactory factory = FundFactory(vm.envAddress('FACTORY'));
		address tUsdc = vm.envAddress('TUSDC');

		vm.startBroadcast();

		// Venue mandate: concentrated LP (3, 4) + veranta perps (6) — nothing else
		uint256[] memory venueIds = new uint256[](3);
		venueIds[0] = 3;
		venueIds[1] = 4;
		venueIds[2] = 6;
		AllowedExternalPositionTypesPolicy venues = new AllowedExternalPositionTypesPolicy(venueIds);

		FundFactory.PolicyReg[] memory regs = new FundFactory.PolicyReg[](1);
		regs[0] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.CreateExternalPosition, policy: address(venues)});

		Comptroller comptroller = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					// Names are reserved FOREVER (wave-6 set-once) — suffix each run
					name: string.concat('Flagship Rehearsal (veranta rails) #', vm.toString(block.timestamp)),
					symbol: 'frRIG',
					denominationAsset: IERC20(tUsdc),
					fundOwner: msg.sender,
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: 1500,
					sharesActionTimelock: 0,
					minRequestDuration: 60, // the new 1-minute floor, live
					executionWindow: 1 days,
					allowRiskyAssets: false
				}),
				regs
			)
		);

		IMintableToken(tUsdc).mint(msg.sender, 10_000e6);
		IERC20(tUsdc).approve(address(comptroller), 10_000e6);
		comptroller.requestDeposit(10_000e6);

		vm.stopBroadcast();

		console2.log('RIG_COMPTROLLER', address(comptroller));
		console2.log('RIG_VAULT', address(comptroller.vault()));
	}
}

/// @notice Phase B — run ≥60 seconds after phase A. Env: RIG_COMPTROLLER, TUSDC, TETH.
contract RehearseFlagshipB is Script {
	int24 internal constant FULL_RANGE_3000 = 887220;

	function run() external {
		Comptroller comptroller = Comptroller(vm.envAddress('RIG_COMPTROLLER'));
		address tUsdc = vm.envAddress('TUSDC');
		address tEth = vm.envAddress('TETH');
		address vault = address(comptroller.vault());

		vm.startBroadcast();

		comptroller.executeDepositRequest(msg.sender);

		// Long leg inventory: 1 tETH into the vault (demo tokens are open-mint) + track it
		IMintableToken(tEth).mint(vault, 1e18);
		comptroller.addTrackedAsset(tEth);

		// LP long leg (type 3): tUSDC/tETH 0.30% full range via the REAL Sepolia NPM
		(address token0, address token1) =
			tUsdc < tEth ? (tUsdc, tEth) : (tEth, tUsdc);
		address lpPosition = comptroller.createExternalPosition(3, abi.encode(token0, token1, uint24(3000)));

		(uint256 amount0, uint256 amount1) =
			token0 == tUsdc ? (uint256(2_500e6), uint256(1e18)) : (uint256(1e18), uint256(2_500e6));
		address[] memory transferAssets = new address[](2);
		transferAssets[0] = token0;
		transferAssets[1] = token1;
		uint256[] memory transferAmounts = new uint256[](2);
		transferAmounts[0] = amount0;
		transferAmounts[1] = amount1;
		comptroller.callOnExternalPosition(
			lpPosition,
			transferAssets,
			transferAmounts,
			new address[](0),
			abi.encode(uint8(0), abi.encode(-FULL_RANGE_3000, FULL_RANGE_3000, amount0, amount1, uint256(0), uint256(0)))
		);

		// Hedge leg (type 6): open, fund with 3,000 tUSDC, autopilot ON — one call each
		address verantaPosition = comptroller.createExternalPosition(6, '');
		address[] memory usdcOnly = new address[](1);
		usdcOnly[0] = tUsdc;
		uint256[] memory fundAmount = new uint256[](1);
		fundAmount[0] = 3_000e6;
		comptroller.callOnExternalPosition(
			verantaPosition,
			usdcOnly,
			fundAmount,
			new address[](0),
			abi.encode(uint8(4), abi.encode(block.timestamp + 90 days)) // SetAutopilot
		);

		vm.stopBroadcast();

		console2.log('RIG_LP_POSITION', lpPosition);
		console2.log('RIG_VERANTA_POSITION', verantaPosition);
		console2.log('RIG_GAV', comptroller.calcGav());
	}
}
