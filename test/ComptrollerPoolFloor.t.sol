// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Comptroller} from '../src/core/Comptroller.sol';
import {ComptrollerLib} from '../src/core/ComptrollerLib.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {MinPoolLiquidityPolicy} from '../src/policies/MinPoolLiquidityPolicy.sol';
import {MockEscrowPositionFactory} from './utils/MockEscrowPosition.sol';
import {RedemptionQueue} from '../src/redemption/RedemptionQueue.sol';
import {RedemptionFixture} from './utils/RedemptionFixture.sol';
import {StubClmStrategy, StubClmVault, StubVaultFeed} from './ComptrollerMarketClosed.t.sol';

/// @notice A pool-priced token reads 1 wei once its pool's liquidity shows gone in three of the adapter's five slices. An LP
///         holding nearly all of it can do that with three 2-second pulls, so the floor may be a real rug or a lie. A
///         deposit at it buys the token's share for nothing, and a manager settling at it pays the queue short (review
///         2026-11-01, High 2). Deposits wait; the queue waits for its deadline, so a real rug can't lock exits.
contract ComptrollerPoolFloorTest is RedemptionFixture {
	/// @dev Alice and Bob in for 10,000 each, half the fund in TKN at $1.
	function _tokenFund() internal returns (Comptroller fund) {
		fund = Comptroller(factory.createFund(_config(0, 0, 0)));
		_deposit(fund, alice, 10_000e6);
		_deposit(fund, bob, 10_000e6);
		_swap(fund, usdc, tkn, 10_000e6, 10_000e6);
	}

	function _requestDeposit(Comptroller fund, address who, uint256 amount) internal {
		deal(address(usdc), who, amount);
		vm.startPrank(who);
		usdc.approve(address(fund), amount);
		fund.requestDeposit(amount, type(uint256).max);
		vm.stopPrank();
		skip(1 minutes);
	}

	function _floor() internal {
		pool.setDip(1, 0, 721);
	}

	function _floorLifted() internal {
		pool.setDip(0, 0, 0);
	}

	function _worth(Comptroller fund, address who) internal returns (uint256) {
		return fund.calcGav() * _sharesOf(fund, who) / fund.shares().totalSupply();
	}

	/// The reviewer's case: at the floor a deposit buys in at the fund's USDC alone, and keeps most of the token once the
	/// price returns. It waits, then buys at the fund's real value.
	function test_aDepositWaitsOutTheFloor_andBuysAtTheRealValue() public {
		Comptroller fund = _tokenFund();
		_requestDeposit(fund, carol, 20_000e6);
		_floor();
		vm.expectRevert(Comptroller.PoolPriceUnsettled.selector);
		fund.executeDepositRequest(carol);

		_floorLifted();
		fund.executeDepositRequest(carol);
		assertApproxEqRel(_worth(fund, carol), 20_000e6, 1e15, 'no free gain');
		assertApproxEqRel(_worth(fund, alice), 10_000e6, 1e15, 'alice keeps her share');
	}

	function test_theQueueWaitsOutTheFloor_forTheManagerAndTheKeeper() public {
		Comptroller fund = _tokenFund();
		_request(fund, bob, _sharesOf(fund, bob) / 2);
		_floor();
		vm.prank(manager);
		vm.expectRevert(RedemptionQueue.PriceUnreadable.selector);
		queue.settle(address(fund), 1);
		vm.prank(keeper);
		vm.expectRevert(RedemptionQueue.PriceUnreadable.selector);
		queue.settle(address(fund), 1);

		_floorLifted();
		vm.prank(keeper);
		queue.settle(address(fund), 1);
		assertApproxEqRel(usdc.balanceOf(bob), 5_000e6, 1e15, 'a quarter of the fund, the token counted');
	}

	/// A real rug never locks exits: past the deadline the queue pays at what the fund is worth without the token.
	function test_aFloorThatLastsPastTheDeadlinePaysTheQueue() public {
		Comptroller fund = _tokenFund();
		_request(fund, bob, _sharesOf(fund, bob) / 2);
		_floor();
		skip(queue.deadline() + 1);
		_refreshFeeds();
		vm.prank(keeper);
		queue.settle(address(fund), 1);
		assertApproxEqRel(usdc.balanceOf(bob), 2_500e6, 1e15, 'a quarter of the USDC left: the token counts as nothing');
	}

	function test_cancellingNeverWaitsOnTheFloor() public {
		Comptroller fund = _tokenFund();
		_request(fund, bob, _sharesOf(fund, bob));
		_floor();
		vm.prank(bob);
		queue.cancel(address(fund));
		assertGt(_sharesOf(fund, bob), 0);
	}

	function test_aFundOffTheFloorIsUntouched() public {
		Comptroller fund = _tokenFund();
		_requestDeposit(fund, carol, 1_000e6);
		pool.setDip(1, 361, 1079); // in two slices only
		fund.executeDepositRequest(carol);
		assertGt(_sharesOf(fund, carol), 0);
	}

	/// The floor reaches the fund through a position (an order) too.
	function test_aFloorInsideAPositionStopsDeposits() public {
		Comptroller fund = _tokenFund();
		factory.registerPositionType(95, address(new MockEscrowPositionFactory()));
		vm.prank(manager);
		address order = fund.createExternalPosition(95, '');
		address[] memory assets = new address[](1);
		uint256[] memory amounts = new uint256[](1);
		assets[0] = address(tkn);
		amounts[0] = 10_000e6;
		vm.prank(manager);
		fund.callOnExternalPosition(order, assets, amounts, new address[](0),
			abi.encode(uint8(0), abi.encode(address(tkn), address(usdc), uint128(10_000e6), uint128(10_000e6), uint64(block.timestamp + 30 days))));
		_requestDeposit(fund, carol, 1_000e6);
		_floor();
		vm.expectRevert(Comptroller.PoolPriceUnsettled.selector);
		fund.executeDepositRequest(carol);
	}

	/// And through a CLM vault on the token.
	function test_aFloorInsideAClmVaultStopsDeposits() public {
		Comptroller fund = _tokenFund();
		StubClmVault vault = new StubClmVault(address(new StubClmStrategy(address(tkn), address(usdc))));
		registrar.execute(abi.encodeCall(ValueInterpreter.addDerivative, (address(vault), address(new StubVaultFeed(address(tkn))))));
		vm.prank(manager);
		fund.addTrackedAsset(address(vault));
		vault.mint(address(fund.vault()), 10e18);
		_requestDeposit(fund, carol, 1_000e6);
		_floor();
		vm.expectRevert(Comptroller.PoolPriceUnsettled.selector);
		fund.executeDepositRequest(carol);
	}

	// ─── a rug in progress, before the window shows it ─────────────────────────

	/// The manager burns the pool's liquidity and tries to take their exit at the old price: it waits.
	function test_aRugInProgressStopsTheManagersExitAtTheOldPrice() public {
		Comptroller fund = _tokenFund();
		_request(fund, bob, _sharesOf(fund, bob) / 2);
		pool.setSpotLiquidity(PLENTY / 3);
		assertApproxEqRel(fund.calcGav(), 20_000e6, 1e15, 'the price still reads the window');
		vm.prank(manager);
		vm.expectRevert(RedemptionQueue.PriceUnreadable.selector);
		queue.settle(address(fund), 1);
	}

	function test_aRugInProgressStopsDeposits_andLiftsOnceTheLiquidityIsBack() public {
		Comptroller fund = _tokenFund();
		_requestDeposit(fund, carol, 1_000e6);
		pool.setSpotLiquidity(PLENTY / 3);
		vm.expectRevert(Comptroller.PoolPriceUnsettled.selector);
		fund.executeDepositRequest(carol);
		pool.setSpotLiquidity(PLENTY);
		fund.executeDepositRequest(carol);
		assertGt(_sharesOf(fund, carol), 0);
	}

	// ─── selling at the floor ──────────────────────────────────────────

	/// At 1 wei the slippage policy would charge nothing: the manager could hand the fund's holding to their own pool.
	function test_theManagerCannotSellAtTheFloor() public {
		Comptroller fund = _tokenFund();
		_floor();
		router.setNextAmountOut(1);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(MinPoolLiquidityPolicy.SoldAtFloor.selector, address(tkn)));
		fund.callOnIntegration(address(uniAdapter), abi.encode(address(tkn), address(usdc), uint24(3000), uint256(10_000e6), uint256(0)));
	}

	function test_theManagerCanSellOffTheFloor() public {
		Comptroller fund = _tokenFund();
		_swap(fund, tkn, usdc, 10_000e6, 10_000e6);
		assertEq(_held(fund, tkn), 0);
	}

	/// The keeper's route isn't the manager's to pick, and whatever a sale brings in helps the overdue redeemer.
	function test_theKeeperCanStillSellAtTheFloorOnceOverdue() public {
		Comptroller fund = _tokenFund();
		_request(fund, bob, _sharesOf(fund, bob));
		_floor();
		skip(queue.deadline() + 1);
		_refreshFeeds();
		router.setNextAmountOut(1_000e6);
		vm.prank(keeper);
		queue.liquidate(address(fund), address(uniAdapter), abi.encode(address(tkn), address(usdc), uint24(3000), uint256(10_000e6), uint256(0)));
		assertEq(_held(fund, tkn), 0);
	}

	// ─── the write-off ────────────────────────────────────────────

	address internal constant BURN = 0x000000000000000000000000000000000000dEaD;

	function test_writingOffADeadTokenBurnsIt_andEverythingStopsWaiting() public {
		Comptroller fund = _tokenFund();
		_request(fund, bob, _sharesOf(fund, bob) / 2);
		_requestDeposit(fund, carol, 1_000e6);
		_floor();
		vm.prank(manager);
		fund.writeOffAsset(address(tkn));

		assertEq(tkn.balanceOf(BURN), 10_000e6, 'burned');
		assertEq(_held(fund, tkn), 0);
		assertEq(fund.costBasis(address(tkn)), 0);
		address[] memory tracked = fund.getTrackedAssets();
		for (uint256 i; i < tracked.length; ++i) assertTrue(tracked[i] != address(tkn), 'untracked');

		fund.executeDepositRequest(carol);
		assertGt(_sharesOf(fund, carol), 0);
		vm.prank(keeper);
		queue.settle(address(fund), 1);
		assertGt(usdc.balanceOf(bob), 2_400e6, 'paid at once, at the fund without the token');
	}

	function test_onlyTheManagerWritesOff() public {
		Comptroller fund = _tokenFund();
		_floor();
		vm.prank(stranger);
		vm.expectRevert();
		fund.writeOffAsset(address(tkn));
		assertEq(_held(fund, tkn), 10_000e6);
	}

	function test_aLiveTokenCannotBeWrittenOff() public {
		Comptroller fund = _tokenFund();
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(ComptrollerLib.NotAtFloor.selector, address(tkn)));
		fund.writeOffAsset(address(tkn));
		assertEq(_held(fund, tkn), 10_000e6);
	}

	/// A draining pool isn't a dead one: the wait lifts by itself, and the token may yet be worth something.
	function test_aDrainingTokenCannotBeWrittenOff() public {
		Comptroller fund = _tokenFund();
		pool.setSpotLiquidity(PLENTY / 3);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(ComptrollerLib.NotAtFloor.selector, address(tkn)));
		fund.writeOffAsset(address(tkn));
	}

	function test_aChainlinkTokenCannotBeWrittenOff() public {
		Comptroller fund = _tokenFund();
		_swap(fund, usdc, weth, 1_000e6, 0.5e18);
		wethFeed.setAnswer(1);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(ComptrollerLib.NotAtFloor.selector, address(weth)));
		fund.writeOffAsset(address(weth));
	}

	// ─── a holding too small to matter (founder 2026-11-04) ───────────────────

	/// @dev Alice and Bob in for 10,000 each, `cost` USDC of it in TKN at $1.
	function _fundWithTokenCosting(uint256 cost) internal returns (Comptroller fund) {
		fund = Comptroller(factory.createFund(_config(0, 0, 0)));
		_deposit(fund, alice, 10_000e6);
		_deposit(fund, bob, 10_000e6);
		_swap(fund, usdc, tkn, cost, cost);
	}

	/// A deposit has no line: it waits at any size. Exits keep the line, so the queue still pays.
	function test_aSmallTokenAtTheFloorStopsDepositsButNotTheQueue() public {
		Comptroller fund = _fundWithTokenCosting(10e6); // 0.05% of 20,000
		_requestDeposit(fund, carol, 20_000e6);
		_request(fund, bob, _sharesOf(fund, bob));
		_floor();
		vm.expectRevert(Comptroller.PoolPriceUnsettled.selector);
		fund.executeDepositRequest(carol);
		vm.prank(keeper);
		queue.settle(address(fund), 1);
		assertApproxEqRel(usdc.balanceOf(bob), 10_000e6, 2e15, 'the queue paid');
	}

	/// Tool run 2026-11-05, Finding 1. With no wait here a deposit bought in at each floor and left with the token's worth, and the
	/// token stayed in the fund to do it again: $1M fell to $900,486 over 122 rounds on a $900 holding, to $250,024 over 3,182 on $250.
	function test_aDepositCantBuyInAtASmallFloor_soTheLoopIsClosed() public {
		Comptroller fund = Comptroller(factory.createFund(_config(0, 0, 0)));
		_deposit(fund, alice, 1_000_000e6);
		_swap(fund, usdc, tkn, 900e6, 900e6); // 0.09%
		uint256 before = _worth(fund, alice);
		_requestDeposit(fund, carol, 10_000_000e6);
		_floor();
		vm.expectRevert(Comptroller.PoolPriceUnsettled.selector);
		fund.executeDepositRequest(carol);
		_floorLifted();
		fund.executeDepositRequest(carol);
		assertApproxEqRel(_worth(fund, alice), before, 1e13, 'alice keeps her share of the token');
	}

	/// A drained token reads $0, so a real holding is judged by what it cost: 0.2% of the fund still stops everything.
	function test_aRealHoldingAtTheFloorStillStopsDeposits_byWhatItCost() public {
		Comptroller fund = _fundWithTokenCosting(40e6);
		_requestDeposit(fund, carol, 1_000e6);
		_request(fund, bob, _sharesOf(fund, bob));
		_floor();
		vm.expectRevert(Comptroller.PoolPriceUnsettled.selector);
		fund.executeDepositRequest(carol);
		vm.prank(keeper);
		vm.expectRevert(RedemptionQueue.PriceUnreadable.selector);
		queue.settle(address(fund), 1);
	}

	/// The griefing case, now that a sale takes the token off the list (founder 2026-11-05): the fund sold the token, its pool is
	/// dead, and anyone sends it 1 wei. It isn't tracked, so it stops nothing: the deposit goes in and the queue pays.
	function test_aWeiSentToASoldDeadTokenStopsNothing() public {
		Comptroller fund = _fundWithTokenCosting(10_000e6);
		_swap(fund, tkn, usdc, 10_000e6, 10_000e6);
		_requestDeposit(fund, carol, 1_000e6);
		_request(fund, bob, _sharesOf(fund, bob));
		_floor();
		tkn.mint(address(fund.vault()), 1);
		fund.executeDepositRequest(carol);
		assertGt(_sharesOf(fund, carol), 0, 'the deposit went in');
		vm.prank(keeper);
		queue.settle(address(fund), 1);
		assertApproxEqRel(usdc.balanceOf(bob), 10_000e6, 2e15, 'the queue paid');
	}

	/// A wei the sale left behind is still a holding: at a dead pool it stops deposits until the manager writes the token off,
	/// once: written off, it's off the list, so another wei does nothing. The queue never waits.
	function test_aWeiLeftOfADeadTokenStopsDepositsUntilWrittenOff_andNeverTheQueue() public {
		Comptroller fund = _fundWithTokenCosting(10_000e6);
		_swap(fund, tkn, usdc, 10_000e6 - 1, 10_000e6);
		_requestDeposit(fund, carol, 1_000e6);
		_request(fund, bob, _sharesOf(fund, bob));
		_floor();
		vm.expectRevert(Comptroller.PoolPriceUnsettled.selector);
		fund.executeDepositRequest(carol);
		vm.prank(keeper);
		queue.settle(address(fund), 1);
		assertApproxEqRel(usdc.balanceOf(bob), 10_000e6, 2e15, 'the queue paid');

		vm.prank(manager);
		fund.writeOffAsset(address(tkn));
		tkn.mint(address(fund.vault()), 1);
		fund.executeDepositRequest(carol);
		assertGt(_sharesOf(fund, carol), 0, 'the deposit went in');
	}

	function test_aSmallDrainingTokenStopsDepositsButNotTheQueue() public {
		Comptroller fund = _fundWithTokenCosting(10e6);
		_requestDeposit(fund, carol, 1_000e6);
		_request(fund, bob, _sharesOf(fund, bob));
		pool.setSpotLiquidity(PLENTY / 3);
		vm.expectRevert(Comptroller.PoolPriceUnsettled.selector);
		fund.executeDepositRequest(carol);
		vm.prank(keeper);
		queue.settle(address(fund), 1);
		assertApproxEqRel(usdc.balanceOf(bob), 10_000e6, 2e15, 'the queue paid');
	}

	function test_aSmallTokenDoesntBlockTheInstantExit() public {
		Comptroller fund = _fundWithTokenCosting(10e6);
		uint256 shares = _sharesOf(fund, bob) / 10;
		vm.prank(bob);
		fund.redeemShares(shares);
		assertApproxEqRel(usdc.balanceOf(bob), 1_000e6, 1e15);
	}

	function test_aRealTokenHoldingStillGoesThroughTheQueue() public {
		Comptroller fund = _fundWithTokenCosting(20e6); // 0.1%
		uint256 shares = _sharesOf(fund, bob);
		vm.prank(bob);
		vm.expectRevert(Comptroller.UseRedemptionQueue.selector);
		fund.redeemShares(shares);
	}

	/// A vault share has no cost on record and reads next to nothing once its pool drains, so its size can't be told: it waits.
	function test_aSmallVaultShareOnADrainedPoolStillStopsDeposits() public {
		Comptroller fund = _fundWithTokenCosting(10e6);
		StubClmVault vault = new StubClmVault(address(new StubClmStrategy(address(tkn), address(usdc))));
		registrar.execute(abi.encodeCall(ValueInterpreter.addDerivative, (address(vault), address(new StubVaultFeed(address(tkn))))));
		vm.prank(manager);
		fund.addTrackedAsset(address(vault));
		vault.mint(address(fund.vault()), 1);
		_swap(fund, tkn, usdc, 10e6, 10e6);
		_requestDeposit(fund, carol, 1_000e6);
		_floor();
		vm.expectRevert(Comptroller.PoolPriceUnsettled.selector);
		fund.executeDepositRequest(carol);
	}
}
