// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {ComptrollerV6} from '../src/core/ComptrollerV6.sol';
import {ComptrollerV6Lib} from '../src/core/ComptrollerV6Lib.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {MinPoolLiquidityPolicy} from '../src/policies/MinPoolLiquidityPolicy.sol';
import {LimitOrderPositionFactory} from '../src/positions/LimitOrderPosition.sol';
import {RedemptionQueueV2} from '../src/redemption/RedemptionQueueV2.sol';
import {RedemptionFixtureV6} from './utils/RedemptionFixtureV6.sol';
import {StubClmStrategy, StubClmVault, StubVaultFeed} from './ComptrollerV6MarketClosed.t.sol';

/// @notice A pool-priced token reads 1 wei once its pool's liquidity shows gone in three of the adapter's five slices. An LP
///         holding nearly all of it can do that with three 2-second pulls, so the floor may be a real rug or a lie. A
///         deposit at it buys the token's share for nothing, and a manager settling at it pays the queue short (review
///         2026-11-01, High 2). Deposits wait; the queue waits for its deadline, so a real rug can't lock exits.
contract ComptrollerV6PoolFloorTest is RedemptionFixtureV6 {
	/// @dev Alice and Bob in for 10,000 each, half the fund in TKN at $1.
	function _tokenFund() internal returns (ComptrollerV6 fund) {
		fund = ComptrollerV6(factory.createFund(_config(0, 0, 0)));
		_deposit(fund, alice, 10_000e6);
		_deposit(fund, bob, 10_000e6);
		_swap(fund, usdc, tkn, 10_000e6, 10_000e6);
	}

	function _requestDeposit(ComptrollerV6 fund, address who, uint256 amount) internal {
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

	function _worth(ComptrollerV6 fund, address who) internal returns (uint256) {
		return fund.calcGav() * _sharesOf(fund, who) / fund.shares().totalSupply();
	}

	/// The reviewer's case: at the floor a deposit buys in at the fund's USDC alone, and keeps most of the token once the
	/// price returns. It waits, then buys at the fund's real value.
	function test_aDepositWaitsOutTheFloor_andBuysAtTheRealValue() public {
		ComptrollerV6 fund = _tokenFund();
		_requestDeposit(fund, carol, 20_000e6);
		_floor();
		vm.expectRevert(ComptrollerV6.PoolPriceUnsettled.selector);
		fund.executeDepositRequest(carol);

		_floorLifted();
		fund.executeDepositRequest(carol);
		assertApproxEqRel(_worth(fund, carol), 20_000e6, 1e15, 'no free gain');
		assertApproxEqRel(_worth(fund, alice), 10_000e6, 1e15, 'alice keeps her share');
	}

	function test_theQueueWaitsOutTheFloor_forTheManagerAndTheKeeper() public {
		ComptrollerV6 fund = _tokenFund();
		_request(fund, bob, _sharesOf(fund, bob) / 2);
		_floor();
		vm.prank(manager);
		vm.expectRevert(RedemptionQueueV2.PriceUnreadable.selector);
		queue.settle(address(fund), 1);
		vm.prank(keeper);
		vm.expectRevert(RedemptionQueueV2.PriceUnreadable.selector);
		queue.settle(address(fund), 1);

		_floorLifted();
		vm.prank(keeper);
		queue.settle(address(fund), 1);
		assertApproxEqRel(usdc.balanceOf(bob), 5_000e6, 1e15, 'a quarter of the fund, the token counted');
	}

	/// A real rug never locks exits: past the deadline the queue pays at what the fund is worth without the token.
	function test_aFloorThatLastsPastTheDeadlinePaysTheQueue() public {
		ComptrollerV6 fund = _tokenFund();
		_request(fund, bob, _sharesOf(fund, bob) / 2);
		_floor();
		skip(queue.deadline() + 1);
		_refreshFeeds();
		vm.prank(keeper);
		queue.settle(address(fund), 1);
		assertApproxEqRel(usdc.balanceOf(bob), 2_500e6, 1e15, 'a quarter of the USDC left: the token counts as nothing');
	}

	function test_cancellingNeverWaitsOnTheFloor() public {
		ComptrollerV6 fund = _tokenFund();
		_request(fund, bob, _sharesOf(fund, bob));
		_floor();
		vm.prank(bob);
		queue.cancel(address(fund));
		assertGt(_sharesOf(fund, bob), 0);
	}

	function test_aFundOffTheFloorIsUntouched() public {
		ComptrollerV6 fund = _tokenFund();
		_requestDeposit(fund, carol, 1_000e6);
		pool.setDip(1, 361, 1079); // in two slices only
		fund.executeDepositRequest(carol);
		assertGt(_sharesOf(fund, carol), 0);
	}

	/// The floor reaches the fund through a limit order too.
	function test_aFloorInsideAPositionStopsDeposits() public {
		ComptrollerV6 fund = _tokenFund();
		factory.registerPositionType(95, address(new LimitOrderPositionFactory()));
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
		vm.expectRevert(ComptrollerV6.PoolPriceUnsettled.selector);
		fund.executeDepositRequest(carol);
	}

	/// And through a CLM vault on the token.
	function test_aFloorInsideAClmVaultStopsDeposits() public {
		ComptrollerV6 fund = _tokenFund();
		StubClmVault vault = new StubClmVault(address(new StubClmStrategy(address(tkn), address(usdc))));
		registrar.execute(abi.encodeCall(ValueInterpreter.addDerivative, (address(vault), address(new StubVaultFeed(address(tkn))))));
		vm.prank(manager);
		fund.addTrackedAsset(address(vault));
		vault.mint(address(fund.vault()), 10e18);
		_requestDeposit(fund, carol, 1_000e6);
		_floor();
		vm.expectRevert(ComptrollerV6.PoolPriceUnsettled.selector);
		fund.executeDepositRequest(carol);
	}

	// ─── a rug in progress, before the window shows it ─────────────────────────

	/// The manager burns the pool's liquidity and tries to take their exit at the old price: it waits.
	function test_aRugInProgressStopsTheManagersExitAtTheOldPrice() public {
		ComptrollerV6 fund = _tokenFund();
		_request(fund, bob, _sharesOf(fund, bob) / 2);
		pool.setSpotLiquidity(PLENTY / 3);
		assertApproxEqRel(fund.calcGav(), 20_000e6, 1e15, 'the price still reads the window');
		vm.prank(manager);
		vm.expectRevert(RedemptionQueueV2.PriceUnreadable.selector);
		queue.settle(address(fund), 1);
	}

	function test_aRugInProgressStopsDeposits_andLiftsOnceTheLiquidityIsBack() public {
		ComptrollerV6 fund = _tokenFund();
		_requestDeposit(fund, carol, 1_000e6);
		pool.setSpotLiquidity(PLENTY / 3);
		vm.expectRevert(ComptrollerV6.PoolPriceUnsettled.selector);
		fund.executeDepositRequest(carol);
		pool.setSpotLiquidity(PLENTY);
		fund.executeDepositRequest(carol);
		assertGt(_sharesOf(fund, carol), 0);
	}

	// ─── selling at the floor ──────────────────────────────────────────

	/// At 1 wei the slippage policy would charge nothing: the manager could hand the fund's holding to their own pool.
	function test_theManagerCannotSellAtTheFloor() public {
		ComptrollerV6 fund = _tokenFund();
		_floor();
		router.setNextAmountOut(1);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(MinPoolLiquidityPolicy.SoldAtFloor.selector, address(tkn)));
		fund.callOnIntegration(address(uniAdapter), abi.encode(address(tkn), address(usdc), uint24(3000), uint256(10_000e6), uint256(0)));
	}

	function test_theManagerCanSellOffTheFloor() public {
		ComptrollerV6 fund = _tokenFund();
		_swap(fund, tkn, usdc, 10_000e6, 10_000e6);
		assertEq(_held(fund, tkn), 0);
	}

	/// The keeper's route isn't the manager's to pick, and whatever a sale brings in helps the overdue redeemer.
	function test_theKeeperCanStillSellAtTheFloorOnceOverdue() public {
		ComptrollerV6 fund = _tokenFund();
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
		ComptrollerV6 fund = _tokenFund();
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
		ComptrollerV6 fund = _tokenFund();
		_floor();
		vm.prank(stranger);
		vm.expectRevert();
		fund.writeOffAsset(address(tkn));
		assertEq(_held(fund, tkn), 10_000e6);
	}

	function test_aLiveTokenCannotBeWrittenOff() public {
		ComptrollerV6 fund = _tokenFund();
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(ComptrollerV6Lib.NotAtFloor.selector, address(tkn)));
		fund.writeOffAsset(address(tkn));
		assertEq(_held(fund, tkn), 10_000e6);
	}

	/// A draining pool isn't a dead one: the wait lifts by itself, and the token may yet be worth something.
	function test_aDrainingTokenCannotBeWrittenOff() public {
		ComptrollerV6 fund = _tokenFund();
		pool.setSpotLiquidity(PLENTY / 3);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(ComptrollerV6Lib.NotAtFloor.selector, address(tkn)));
		fund.writeOffAsset(address(tkn));
	}

	function test_aChainlinkTokenCannotBeWrittenOff() public {
		ComptrollerV6 fund = _tokenFund();
		_swap(fund, usdc, weth, 1_000e6, 0.5e18);
		wethFeed.setAnswer(1);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(ComptrollerV6Lib.NotAtFloor.selector, address(weth)));
		fund.writeOffAsset(address(weth));
	}
}
