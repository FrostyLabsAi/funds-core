// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerV6} from '../../src/core/ComptrollerV6.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {RedemptionQueueV2} from '../../src/redemption/RedemptionQueueV2.sol';
import {ClmVaultAdapter} from '../../src/adapters/ClmVaultAdapter.sol';
import {ClmVaultPriceFeed} from '../../src/pricing/ClmVaultPriceFeed.sol';
import {RedemptionQueueV2ShortDeadline} from '../../test/utils/RedemptionQueueV2ShortDeadline.sol';
import {ClmPoolConfig, IClmPoolDeployer, IClmStrategyFactoryAdmin} from '../../test/fork/utils/ClmFixture.sol';
import {ClmFundsDeploy} from '../mainnet/ClmFundsDeploy.sol';

/// @notice Rehearsal only (keeper plan 3, 2026-10-13): the world funds-keeper's test/fork/clm-rehearsal.test.ts runs
///         the real keeper passes against. A FrostyFi CLM vault on USDC/cbBTC (Slipstream-2) as narrow as it goes, so
///         a price push leaves its range (width 2: at 1 the alt range has no width and every deposit reverts, found
///         here 2026-10-13); the CLM feed and adapter; fund v6 on a 1-second-deadline queue; a fund whose manager
///         farms the vault and whose investor asks for half back. Each phase is its own run, on an anvil fork
///         of Base at block 52,385,115 started with --auto-impersonate, broadcast with --unlocked (the deployer is
///         impersonated); anvil's clock moves between phases, which a broadcast can't do:
///           forge script script/rehearsal/ClmKeeperWorld.s.sol --sig 'deploy(address,address,address)' <keeper> \
///             <manager> <investor> --rpc-url http://127.0.0.1:<port> --unlocked --sender <deployer> --broadcast --slow
///         Each prints `CLM_WORLD <name> <address>` lines; nothing is written in the repo but forge's ignored
///         broadcast/ and cache/ records. Never for mainnet.
contract ClmKeeperWorld is Script {
	string internal constant OUT = '../funds-yield/out/';
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
	address internal constant CLM_POOL = 0x160D7E9d948B16c163332a277b393c288408eb12; // USDC/cbBTC ts50, Slipstream-2
	address internal constant CLM_GAUGE = 0x7B0f1103746648FBfce9222f1266f79B934E16b2;
	address internal constant SLIPSTREAM2_SWAP_ADAPTER = 0xB09f3467eE7039bcA58F4b2E778E2bE3C7Cf7C1E;
	address internal constant TREASURY = 0x47b7702a4789912d0dfFDadC07c50395c293fF0A;
	string internal constant STRATEGY_NAME = 'FrostyClmStrategy-v1';
	uint256 internal constant DEPOSIT = 20_000e6;

	/// @notice The CLM (keeper = `keeper`, also its rebalancer), the feed and adapter with the vault listed, fund v6 on
	///         the short queue, and `manager`'s fund with `investor`'s deposit request (the test deals the USDC).
	function deploy(address keeper, address manager, address investor) external {
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		address deployer = vm.parseJsonAddress(genesis, '.deployer');
		FundFactory factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));

		vm.startBroadcast(deployer);
		(address strategyFactory, address vault) = _clmWithVault(deployer, keeper, vm.parseJsonAddress(genesis, '.valueInterpreter'));
		(ClmVaultPriceFeed feed, ClmVaultAdapter adapter) = ClmFundsDeploy.deploy(strategyFactory);
		address[] memory vaults = new address[](1);
		vaults[0] = vault;
		ClmFundsDeploy.list(feed, vaults);
		_print('adapter', address(adapter));
		_print('queue', address(_deployShortQueueFunds(factory, deployer, keeper, vm.parseJsonAddress(genesis, '.verantaFactory'))));
		vm.stopBroadcast();

		_print('fund', _fundWithDepositRequest(factory, manager, investor));
	}

	/// @dev The CLM core and the narrow USDC/cbBTC vault (width 2: two 50-tick spacings a side, so a push leaves it).
	function _clmWithVault(address deployer, address keeper, address vi) private returns (address strategyFactory, address vault) {
		address poolDeployer;
		(strategyFactory, poolDeployer) = _deployClm(deployer, keeper, vi);
		address strategy;
		(strategy, vault) = IClmPoolDeployer(poolDeployer).deployPool(
			ClmPoolConfig({
				compoundToken: USDC,
				gauge: CLM_GAUGE,
				maxTickDeviation: 5,
				pool: CLM_POOL,
				positionWidth: 2,
				symbol: 'USDC-cbBTC',
				twapInterval: 120
			})
		);
		_print('poolDeployer', poolDeployer);
		_print('strategy', strategy);
		_print('vault', vault);
	}

	/// @dev funds-yield's CLM core, as its DeployClm script and the ClmFixture deploy it.
	function _deployClm(address deployer, address keeper, address vi) private returns (address strategyFactory, address poolDeployer) {
		strategyFactory = _create('FrostyClmStrategyFactory.sol/FrostyClmStrategyFactory.json', abi.encode(keeper, TREASURY, vi, uint256(950)));
		address vaultFactory = _create('FrostyClmVaultFactory.sol/FrostyClmVaultFactory.json', abi.encode(address(0)));
		poolDeployer = _create('ClmPoolDeployer.sol/ClmPoolDeployer.json', abi.encode(strategyFactory, vaultFactory, deployer));
		IClmStrategyFactoryAdmin(strategyFactory).addStrategy(STRATEGY_NAME, _create('FrostyClmStrategy.sol/FrostyClmStrategy.json', ''));
		IClmStrategyFactoryAdmin(strategyFactory).addRebalancer(keeper);
	}

	/// @dev Fund v6 as FundV6Deploy builds it, on the 1-second-deadline queue (ClmGhostLiquidationFork's setup).
	function _deployShortQueueFunds(FundFactory factory, address deployer, address keeper, address perpConfig)
		private
		returns (RedemptionQueueV2 queue)
	{
		queue = new RedemptionQueueV2ShortDeadline(deployer);
		queue.setFactory(address(factory));
		queue.setKeeper(keeper, true);
		factory.setComptrollerDeployer(
			new ComptrollerBlueprintDeployer(
				type(ComptrollerV6).creationCode, abi.encode(ClmFundsDeploy.registrarV2(), queue, perpConfig)
			)
		);
	}

	function _fundWithDepositRequest(FundFactory factory, address manager, address investor) private returns (address fund) {
		vm.broadcast(manager);
		fund = factory.createFund(
			FundFactory.FundConfig({
				name: 'CLM rehearsal',
				symbol: 'frCLMr',
				denominationAsset: IERC20(USDC),
				fundOwner: manager,
				mgmtScaledPerSecondRate: 0,
				perfFeeBps: 0,
				sharesActionTimelock: 0,
				minRequestDuration: 1 minutes,
				executionWindow: 1 days,
				allowRiskyAssets: false
			})
		);
		vm.startBroadcast(investor);
		IERC20(USDC).approve(fund, DEPOSIT);
		ComptrollerV6(fund).requestDeposit(DEPOSIT, type(uint256).max);
		vm.stopBroadcast();
	}

	/// @notice After a minute: the deposit executes, and the manager buys cbBTC with half of it.
	function execute(address fund, address manager, address investor) external {
		vm.broadcast(manager);
		ComptrollerV6(fund).executeDepositRequest(investor);
		vm.broadcast(manager);
		ComptrollerV6(fund).callOnIntegration(SLIPSTREAM2_SWAP_ADAPTER, abi.encode(USDC, CBBTC, int24(50), DEPOSIT / 2, uint256(0)));
	}

	/// @notice Once the pool is calm again: the manager puts the fund's USDC and cbBTC into the vault.
	function depositClm(address fund, address manager, address adapter, address vault) external {
		address fundVault = address(ComptrollerV6(fund).vault());
		bytes memory deposit =
			abi.encode(uint8(0), vault, IERC20(USDC).balanceOf(fundVault), IERC20(CBBTC).balanceOf(fundVault), uint256(0));
		vm.broadcast(manager);
		ComptrollerV6(fund).callOnIntegration(adapter, deposit);
	}

	/// @notice The investor asks for half their shares back.
	function requestRedeem(address fund, address investor, address queue) external {
		IERC20 shares = IERC20(address(ComptrollerV6(fund).shares()));
		uint256 half = shares.balanceOf(investor) / 2;
		vm.startBroadcast(investor);
		shares.approve(queue, half);
		RedemptionQueueV2(queue).requestRedeem(fund, half);
		vm.stopBroadcast();
	}

	/// @dev A funds-yield artifact deployed by the broadcaster (funds-yield's compiler setup can't be imported here).
	function _create(string memory artifact, bytes memory args) private returns (address deployed) {
		bytes memory code = bytes.concat(vm.getCode(string.concat(OUT, artifact)), args);
		assembly ('memory-safe') {
			deployed := create(0, add(code, 0x20), mload(code))
		}
		require(deployed != address(0), artifact);
	}

	function _print(string memory name, address at) private pure {
		console2.log('CLM_WORLD', name, at);
	}
}
