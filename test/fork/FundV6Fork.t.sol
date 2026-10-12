// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {ComptrollerV6} from '../../src/core/ComptrollerV6.sol';
import {ComptrollerV6Lib} from '../../src/core/ComptrollerV6Lib.sol';
import {RedemptionQueueV2} from '../../src/redemption/RedemptionQueueV2.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {FundV6Deploy} from '../../script/mainnet/FundV6Deploy.sol';
import {RedemptionQueueV2ShortDeadline} from '../utils/RedemptionQueueV2ShortDeadline.sol';

/// @notice Rehearsal of script/mainnet/DeployFundV6.s.sol on live Base (block 52,385,115, after the v4 rollout and fund
///         v5): FundV6Deploy as the genesis deployer on registrar V2 and the Veranta perp config, the factory pointed
///         at it (the separate reviewed step), then fund v6 on real contracts: the wiring, a real V4 perp account's
///         close of 0 refused, the instant exit in USDC, and a keeper's liquidation selling WETH on Uniswap.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/FundV6Fork.t.sol -vv
contract FundV6ForkTest is Test {
	uint256 internal constant FORK_BLOCK = 52_385_115;
	address internal constant USDC = FundsMainnet.USDC;
	address internal constant WETH = FundsMainnet.WETH;

	bool internal forked;
	address internal deployer;
	FundFactory internal factory;
	address internal registrarV2;
	address internal perpConfig;
	address internal uniAdapter;
	FundV6Deploy.Deployed internal d;
	address internal manager = makeAddr('manager');
	address internal investor = makeAddr('investor');
	address internal keeper = makeAddr('keeper');

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, FORK_BLOCK);
		forked = true;
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		deployer = vm.parseJsonAddress(genesis, '.deployer');
		factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		perpConfig = vm.parseJsonAddress(genesis, '.verantaFactory');
		uniAdapter = vm.parseJsonAddress(genesis, '.uniAdapter');
		registrarV2 = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-v4.json'), '.registrar');

		vm.startPrank(deployer);
		d = FundV6Deploy.deploy(deployer, address(factory), registrarV2, perpConfig, keeper);
		factory.setComptrollerDeployer(d.fundV6Deployer); // the separate reviewed step
		vm.stopPrank();
	}

	function test_fork_theDeployWiresTheQueueAndEveryNewFund() public {
		vm.skip(!forked);
		ComptrollerV6 fund = _fundWithDeposit('V6 wiring', 1_000e6);
		assertEq(address(fund.redemptionQueue()), address(d.queueV2));
		assertEq(address(fund.registrar()), registrarV2);
		assertEq(fund.perpConfig(), perpConfig);
		assertEq(address(d.queueV2.factory()), address(factory));
		assertTrue(d.queueV2.isKeeper(keeper));
		assertEq(d.queueV2.owner(), deployer);
		assertLt(address(fund).code.length, 24_577, 'EIP-170');
	}

	/// The perp config is what a real V4 account names: its close of 0 is refused, from the manager and the keeper.
	function test_fork_aRealV4AccountsCloseOfNothingIsRefused() public {
		vm.skip(!forked);
		ComptrollerV6 fund = _fundWithDeposit('V6 perp', 1_000e6);
		vm.prank(manager);
		address account = fund.createExternalPosition(FundsMainnet.VERANTA_PERP_TYPE, '');
		bytes memory nothing = abi.encode(uint8(1), abi.encode(uint256(129), uint256(0), uint256(0), uint256(730_600_000_000)));
		assertTrue(ComptrollerV6Lib.closesNothing(perpConfig, account, nothing));
		vm.prank(manager);
		vm.expectRevert(ComptrollerV6Lib.CloseOfNothing.selector);
		fund.callOnExternalPosition(account, new address[](0), new uint256[](0), new address[](0), nothing);
	}

	function test_fork_theInstantExitPaysUsdc() public {
		vm.skip(!forked);
		ComptrollerV6 fund = _fundWithDeposit('V6 instant', 1_000e6);
		uint256 half = fund.shares().balanceOf(investor) / 2;
		uint256 supply = fund.shares().totalSupply();
		vm.prank(investor);
		fund.redeemShares(half);
		assertEq(IERC20(USDC).balanceOf(investor), 1_000e6 * half / supply);
	}

	/// The manager ghosts: the keeper sells the fund's WETH on Uniswap's 0.05% pool within the 3% cap against
	/// Chainlink, then settles; the investor is paid in USDC. (A 1-second deadline queue keeps the ETH round fresh.)
	function test_fork_aKeeperLiquidatesWethOnUniswap_andSettlesInUsdc() public {
		vm.skip(!forked);
		RedemptionQueueV2 queue = new RedemptionQueueV2ShortDeadline(address(this));
		queue.setFactory(address(factory));
		queue.setKeeper(keeper, true);
		ComptrollerBlueprintDeployer shortDeployer =
			new ComptrollerBlueprintDeployer(type(ComptrollerV6).creationCode, abi.encode(registrarV2, queue, perpConfig));
		vm.prank(deployer);
		factory.setComptrollerDeployer(shortDeployer);
		ComptrollerV6 fund = _fundWithDeposit('V6 liquidation', 10_000e6);
		vm.prank(manager);
		fund.callOnIntegration(uniAdapter, abi.encode(USDC, WETH, uint24(500), uint256(8_000e6), uint256(0)));
		uint256 weth = IERC20(WETH).balanceOf(address(fund.vault()));
		assertGt(weth, 0);

		uint256 shares = fund.shares().balanceOf(investor) / 2;
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(address(queue), shares);
		queue.requestRedeem(address(fund), shares);
		vm.stopPrank();
		vm.warp(block.timestamp + 2);
		vm.roll(block.number + 1);
		assertTrue(queue.isOverdue(address(fund)));

		uint256 gavBefore = fund.calcGav();
		vm.prank(keeper);
		queue.liquidate(address(fund), uniAdapter, abi.encode(WETH, USDC, uint24(500), weth, uint256(0)));
		assertEq(IERC20(WETH).balanceOf(address(fund.vault())), 0, 'all sold');
		uint256 gavAfter = fund.calcGav();
		emit log_named_uint('liquidation loss vs Chainlink (USDC, 6 decimals)', gavBefore - gavAfter);
		assertGt(gavAfter, gavBefore * 9_970 / 10_000, 'within the 3% cap, and far under it');

		uint256 supply = fund.shares().totalSupply();
		vm.prank(keeper);
		assertEq(queue.settle(address(fund), 1), 1);
		assertApproxEqAbs(IERC20(USDC).balanceOf(investor), gavAfter * shares / supply, 2);
		assertEq(IERC20(WETH).balanceOf(investor), 0, 'never a token');
	}

	function _fundWithDeposit(string memory name, uint256 amount) internal returns (ComptrollerV6 fund) {
		fund = ComptrollerV6(
			factory.createFund(
				FundFactory.FundConfig({
					name: name,
					symbol: 'frV6',
					denominationAsset: IERC20(USDC),
					fundOwner: manager,
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: 0,
					sharesActionTimelock: 0,
					minRequestDuration: 1 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				})
			)
		);
		deal(USDC, investor, amount);
		vm.startPrank(investor);
		IERC20(USDC).approve(address(fund), amount);
		fund.requestDeposit(amount, type(uint256).max);
		vm.stopPrank();
		vm.warp(block.timestamp + 1 minutes);
		vm.roll(block.number + 30);
		fund.executeDepositRequest(investor);
	}
}
