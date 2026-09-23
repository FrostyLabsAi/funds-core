// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';

contract PauseAndFeesTest is Test {
	FundFactory internal factory;
	ValueInterpreter internal interpreter;
	MockERC20 internal usdc;
	MockAggregator internal usdcFeed;
	Comptroller internal comptroller;

	address internal admin = makeAddr('admin');
	address internal guardian = makeAddr('guardian');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');
	address internal bob = makeAddr('bob');

	function setUp() public {
		vm.warp(30 days);
		interpreter = new ValueInterpreter(admin);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		usdcFeed = new MockAggregator(8, 1e8);
		vm.prank(admin);
		interpreter.addPrimitive(address(usdc), address(usdcFeed), 7 days);

		factory = new FundFactory(interpreter, new ComptrollerDeployer(), new SharesVaultDeployer()); // this test contract = factory owner
		factory.setGuardian(guardian);

		comptroller = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Frosty Alpha',
					symbol: 'frALPHA',
					denominationAsset: IERC20(address(usdc)),
					fundOwner: manager,
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: 1500,
					sharesActionTimelock: 0,
					minRequestDuration: 30 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				})
			)
		);

		usdc.mint(alice, 100_000e6);
		usdc.mint(bob, 100_000e6);
	}

	function _depositFor(address depositor, uint256 assets) internal {
		vm.startPrank(depositor);
		usdc.approve(address(comptroller), assets);
		comptroller.requestDeposit(assets);
		vm.stopPrank();
		skip(30 minutes);
		comptroller.executeDepositRequest(depositor);
	}

	// ─── settleFees poke ─────────────────────────────────────────────────────────

	function test_settleFees_pokeAccruesPerfFee_withoutDepositAction() public {
		_depositFor(alice, 1000e6);

		// +50% PnL, no deposit/redeem happening
		usdc.mint(address(comptroller.vault()), 500e6);

		// Anyone can poke; manager receives fee shares immediately
		uint256 expectedFeeShares = Math.mulDiv(75e6, 1000e18, 1500e6 - 75e6);
		vm.prank(bob);
		uint256 grossSharePrice = comptroller.settleFees();

		assertEq(comptroller.shares().balanceOf(manager), expectedFeeShares);
		assertEq(grossSharePrice, Math.mulDiv(1500e6, 1e18, 1000e18 + expectedFeeShares));
		assertEq(comptroller.highWaterMark(), grossSharePrice);

		// Second poke at unchanged NAV mints nothing (HWM holds)
		vm.prank(bob);
		comptroller.settleFees();
		assertEq(comptroller.shares().balanceOf(manager), expectedFeeShares);
	}

	function test_settleFees_revertsOnStaleFeeds() public {
		// Need a non-denomination asset so pricing actually hits the feed
		MockERC20 nvdax = new MockERC20('NVDA Wrapper', 'NVDAx', 18);
		MockAggregator nvdaxFeed = new MockAggregator(8, 180e8);
		vm.prank(admin);
		interpreter.addPrimitive(address(nvdax), address(nvdaxFeed), 4 hours);
		vm.prank(manager);
		comptroller.addTrackedAsset(address(nvdax));

		_depositFor(alice, 1000e6);
		nvdax.mint(address(comptroller.vault()), 1e18);

		skip(5 hours); // equity feed stale → perf fee can't be priced
		vm.expectRevert();
		comptroller.settleFees();
	}

	// ─── Owner pause (subscription switch) ───────────────────────────────────────

	function test_ownerPause_blocksDepositsBothStages_reversible() public {
		// Block at request stage
		vm.prank(manager);
		comptroller.setOwnerDepositsPaused(true);

		vm.startPrank(alice);
		usdc.approve(address(comptroller), 1000e6);
		vm.expectRevert(Comptroller.DepositsSuspended.selector);
		comptroller.requestDeposit(1000e6);
		vm.stopPrank();

		// Reopen, request, then pause again mid-flight: execute is blocked, cancel is not
		vm.prank(manager);
		comptroller.setOwnerDepositsPaused(false);
		vm.prank(alice);
		comptroller.requestDeposit(1000e6);
		skip(30 minutes);

		vm.prank(manager);
		comptroller.setOwnerDepositsPaused(true);
		vm.expectRevert(Comptroller.DepositsSuspended.selector);
		comptroller.executeDepositRequest(alice);

		vm.prank(alice);
		comptroller.cancelDepositRequest();
		assertEq(usdc.balanceOf(alice), 100_000e6);
	}

	// ─── Guardian lane ───────────────────────────────────────────────────────────

	function test_guardianPause_instantHalt_onlyOwnerUnpauses() public {
		vm.prank(guardian);
		factory.pauseFundDeposits(address(comptroller));
		assertTrue(comptroller.guardianDepositsPaused());

		vm.startPrank(alice);
		usdc.approve(address(comptroller), 1000e6);
		vm.expectRevert(Comptroller.DepositsSuspended.selector);
		comptroller.requestDeposit(1000e6);
		vm.stopPrank();

		// Neither the guardian nor the fund owner can unpause…
		vm.prank(guardian);
		vm.expectRevert();
		factory.unpauseFundDeposits(address(comptroller));

		vm.prank(manager);
		vm.expectRevert(Comptroller.OnlyFactory.selector);
		comptroller.setGuardianDepositsPaused(false);

		// …and the fund owner's own toggle cannot clear the guardian flag
		vm.prank(manager);
		comptroller.setOwnerDepositsPaused(false);
		assertTrue(comptroller.guardianDepositsPaused());

		// Only the factory owner (governance) re-enables
		factory.unpauseFundDeposits(address(comptroller));
		assertFalse(comptroller.guardianDepositsPaused());

		vm.prank(alice);
		comptroller.requestDeposit(1000e6);
	}

	function test_guardianRole_gates() public {
		vm.expectRevert(FundFactory.OnlyGuardian.selector);
		factory.pauseFundDeposits(address(comptroller));

		vm.prank(guardian);
		vm.expectRevert(abi.encodeWithSelector(FundFactory.UnknownFund.selector, alice));
		factory.pauseFundDeposits(alice);

		vm.prank(alice);
		vm.expectRevert();
		factory.setGuardian(alice);
	}

	// ─── Shutdown (one-way) ──────────────────────────────────────────────────────

	function test_shutdown_oneWay_redemptionsStayOpen() public {
		_depositFor(alice, 1000e6);

		vm.prank(alice);
		vm.expectRevert(Comptroller.OnlyFundOwner.selector);
		comptroller.shutDownFund();

		vm.prank(manager);
		comptroller.shutDownFund();
		assertTrue(comptroller.shutDown());

		// One-way: cannot shut down twice, no un-shutdown exists
		vm.prank(manager);
		vm.expectRevert(Comptroller.AlreadyShutDown.selector);
		comptroller.shutDownFund();

		// New deposits and new positions are dead
		vm.startPrank(bob);
		usdc.approve(address(comptroller), 1000e6);
		vm.expectRevert(Comptroller.DepositsSuspended.selector);
		comptroller.requestDeposit(1000e6);
		vm.stopPrank();

		vm.prank(manager);
		vm.expectRevert(Comptroller.AlreadyShutDown.selector);
		comptroller.createExternalPosition(1, '');

		// Both exit paths still work
		vm.startPrank(alice);
		comptroller.redeemSharesForDenominationAsset(400e18);
		comptroller.redeemSharesInKind(100e18);
		vm.stopPrank();
		assertEq(comptroller.shares().balanceOf(alice), 499e18); // 999e18 after the bootstrap seed − 500e18
	}
}
