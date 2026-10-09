// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {ComptrollerV3} from '../../src/core/ComptrollerV3.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {Shares} from '../../src/fund/Shares.sol';
import {RedemptionQueue} from '../../src/redemption/RedemptionQueue.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {ComptrollerV4Deploy} from '../../script/mainnet/ComptrollerV4Deploy.sol';

/// @notice Rehearsal of script/mainnet/DeployComptrollerV4.s.sol on live Base (block of the TestFund4
///         unwind rehearsal, 2026-10-09): deploy the V4 blueprint deployer on the live registrar and
///         queue as the genesis deployer, point the factory at it (the separate reviewed step), then a
///         V4 fund with a real Veranta perp account refuses in kind and redeems through the live queue,
///         while a pure-spot V4 fund still exits in kind.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/ComptrollerV4Fork.t.sol
contract ComptrollerV4ForkTest is Test {
	uint256 internal constant FORK_BLOCK = 52_363_085;
	address internal constant USDC = FundsMainnet.USDC;

	bool internal forked;
	FundFactory internal factory;
	PoolPriceRegistrar internal registrar;
	RedemptionQueue internal queue;
	ComptrollerBlueprintDeployer internal fundV4Deployer;
	address internal manager = makeAddr('manager');
	address internal investor = makeAddr('investor');

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, FORK_BLOCK);
		forked = true;
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		address deployer = vm.parseJsonAddress(genesis, '.deployer');
		factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		registrar = PoolPriceRegistrar(vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-pool-pricing.json'), '.registrar'));
		queue = RedemptionQueue(vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-redemption.json'), '.queue'));

		vm.startPrank(deployer);
		fundV4Deployer = ComptrollerV4Deploy.deploy(registrar, address(queue));
		factory.setComptrollerDeployer(fundV4Deployer); // the separate reviewed step
		vm.stopPrank();
	}

	function test_fork_aV4FundWithAPerpAccount_refusesInKind_andRedeemsThroughTheQueue() public {
		vm.skip(!forked);
		ComptrollerV3 fund = _fundWithDeposit('V4 perp rehearsal');
		assertEq(address(fund.redemptionQueue()), address(queue), 'bound to the live queue');
		assertEq(address(fund.registrar()), address(registrar), 'priced by the live registrar');
		vm.prank(manager);
		fund.createExternalPosition(FundsMainnet.VERANTA_PERP_TYPE, '');

		Shares shares = fund.shares();
		uint256 tenth = shares.balanceOf(investor) / 10;
		vm.startPrank(investor);
		vm.expectRevert(ComptrollerV3.UseRedemptionQueue.selector);
		fund.redeemSharesInKind(tenth);
		vm.expectRevert(ComptrollerV3.UseRedemptionQueue.selector);
		fund.redeemSharesInKindWithSkips(tenth, new address[](0));
		vm.expectRevert(ComptrollerV3.UseRedemptionQueue.selector);
		fund.redeemShares(tenth);

		shares.approve(address(queue), tenth);
		queue.requestRedeem(address(fund), tenth, RedemptionQueue.Mode.Cash);
		vm.stopPrank();
		uint256 supply = shares.totalSupply();
		queue.settle(address(fund), 10);
		assertEq(IERC20(USDC).balanceOf(investor), 10_000e6 * tenth / supply, 'a tenth, in cash, nothing forfeited');
	}

	function test_fork_aPureSpotV4Fund_stillExitsInKind() public {
		vm.skip(!forked);
		ComptrollerV3 fund = _fundWithDeposit('V4 spot rehearsal');
		uint256 tenth = fund.shares().balanceOf(investor) / 10;
		uint256 supply = fund.shares().totalSupply();
		vm.prank(investor);
		fund.redeemSharesInKind(tenth);
		assertEq(IERC20(USDC).balanceOf(investor), 10_000e6 * tenth / supply, 'a tenth of the whole fund');
	}

	function _fundWithDeposit(string memory name) internal returns (ComptrollerV3 fund) {
		fund = ComptrollerV3(
			factory.createFund(
				FundFactory.FundConfig({
					name: name,
					symbol: 'frV4',
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
		deal(USDC, investor, 10_000e6);
		vm.startPrank(investor);
		IERC20(USDC).approve(address(fund), 10_000e6);
		fund.requestDeposit(10_000e6, type(uint256).max);
		vm.stopPrank();
		vm.warp(block.timestamp + 1 minutes);
		vm.roll(block.number + 30);
		fund.executeDepositRequest(investor);
	}
}
