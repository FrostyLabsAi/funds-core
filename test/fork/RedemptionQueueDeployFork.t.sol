// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerV3} from '../../src/core/ComptrollerV3.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {VerantaPriceStore} from '../../src/pricing/VerantaPriceStore.sol';
import {Shares} from '../../src/fund/Shares.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {RedemptionDeploy} from '../../script/mainnet/RedemptionDeploy.sol';
import {RedemptionQueue} from '../../src/redemption/RedemptionQueue.sol';

/// @notice Rehearsal of script/mainnet/DeployRedemptionQueue.s.sol on live Base (block of the stock
///         re-point rehearsal, 2026-10-06): deploy as the genesis deployer, point the factory at the
///         V3 blueprint (the separate reviewed step), then a V3 fund with a real perp account takes a
///         queued redemption end to end. The unwinder stays approved but off.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/RedemptionQueueDeployFork.t.sol
contract RedemptionQueueDeployForkTest is Test {
	uint256 internal constant FORK_BLOCK = 52_252_744;

	bool internal forked;
	address internal deployer;
	FundFactory internal factory;
	RedemptionDeploy.Deployed internal d;
	address internal manager = makeAddr('manager');
	address internal investor = makeAddr('investor');

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, FORK_BLOCK);
		forked = true;
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		deployer = vm.parseJsonAddress(genesis, '.deployer');
		factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		PoolPriceRegistrar registrar =
			PoolPriceRegistrar(vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-pool-pricing.json'), '.registrar'));
		VerantaPriceStore store = VerantaPriceStore(vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-veranta.json'), '.store'));

		vm.startPrank(deployer);
		d = RedemptionDeploy.deploy(deployer, address(factory), vm.parseJsonAddress(genesis, '.verantaFactory'), registrar, store);
		vm.stopPrank();
	}

	function test_fork_deploysWiredAndSwitchedOff() public {
		vm.skip(!forked);
		assertEq(d.queue.owner(), deployer, 'the deployer owns the queue until the handoff');
		assertEq(address(d.queue.factory()), address(factory));
		assertTrue(d.queue.isUnwinderApproved(address(d.perpUnwinder)));
		assertFalse(d.queue.isUnwinderOn(address(d.perpUnwinder)), 'the unwinder is OFF');
		assertEq(Ownable(address(factory)).owner(), deployer, 'the deployer still owns the factory');
		// the guardian (read live from the factory) can switch it on
		vm.prank(factory.guardian());
		d.queue.setUnwinderOn(address(d.perpUnwinder), true);
		assertTrue(d.queue.isUnwinderOn(address(d.perpUnwinder)));
	}

	function test_fork_aV3FundWithAPerpAccountRedeemsThroughTheQueue() public {
		vm.skip(!forked);
		vm.prank(deployer);
		factory.setComptrollerDeployer(d.fundV3Deployer); // the separate reviewed step
		ComptrollerV3 fund = ComptrollerV3(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Queue rehearsal',
					symbol: 'frQR',
					denominationAsset: IERC20(FundsMainnet.USDC),
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
		assertEq(address(fund.redemptionQueue()), address(d.queue));
		deal(FundsMainnet.USDC, investor, 10_000e6);
		vm.startPrank(investor);
		IERC20(FundsMainnet.USDC).approve(address(fund), 10_000e6);
		fund.requestDeposit(10_000e6, type(uint256).max);
		vm.stopPrank();
		vm.warp(block.timestamp + 1 minutes);
		vm.roll(block.number + 30);
		fund.executeDepositRequest(investor);

		vm.prank(manager);
		address account = fund.createExternalPosition(FundsMainnet.VERANTA_PERP_TYPE, '');
		assertTrue(d.perpUnwinder.canUnwind(account), 'a real perp account is recognized');

		Shares shares = fund.shares();
		uint256 tenth = shares.balanceOf(investor) / 10;
		vm.prank(investor);
		vm.expectRevert(ComptrollerV3.UseRedemptionQueue.selector);
		fund.redeemShares(tenth);

		vm.startPrank(investor);
		shares.approve(address(d.queue), tenth);
		d.queue.requestRedeem(address(fund), tenth, RedemptionQueue.Mode.Cash);
		vm.stopPrank();
		uint256 supply = shares.totalSupply();
		d.queue.settle(address(fund), 10);
		assertEq(IERC20(FundsMainnet.USDC).balanceOf(investor), 10_000e6 * tenth / supply, 'a tenth, in cash');
	}
}
