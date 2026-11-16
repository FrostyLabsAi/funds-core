// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {VerantaPriceAdapter} from '../src/pricing/VerantaPriceAdapter.sol';
import {VerantaPriceStore} from '../src/pricing/VerantaPriceStore.sol';
import {MockStore} from './B20VerantaPriceAdapter.t.sol';

contract VerantaPriceAdapterTest is Test {
	uint256 internal constant PAIR = 105;
	uint32 internal constant MAX_PUSH_AGE = 600;
	uint32 internal constant MAX_FEED_AGE = 5 days;

	MockStore internal store;
	VerantaPriceAdapter internal adapter;
	uint256 internal now_ = 1_792_972_549; // Sun 2026-10-25 23:55:49 UTC

	function setUp() public {
		vm.warp(now_);
		store = new MockStore();
		adapter = new VerantaPriceAdapter(VerantaPriceStore(address(store)), PAIR, MAX_PUSH_AGE, MAX_FEED_AGE, 'MU/USD (Veranta)');
		// 879.92, confirmed now, last traded at Friday's close (two days earlier)
		store.set(87_992_000, -5, uint64(now_) * 1e6, uint64(now_ - 2 days) * 1e6);
	}

	/// A closed market reads its close, and `updatedAt` is that close: it's how the fund sees the market is closed.
	function test_aClosedMarketReadsItsClose_andAnswersTheLastTradesTime() public view {
		(uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = adapter.latestRoundData();
		assertEq(answer, 87_992_000_000, '879.92 at 8 decimals');
		assertEq(updatedAt, now_ - 2 days, 'the last trade, not the confirmation');
		assertEq(startedAt, updatedAt);
		assertEq(roundId, uint80(updatedAt));
		assertEq(answeredInRound, roundId);
		assertEq(adapter.decimals(), 8);
	}

	function test_positiveExponentScalesUp() public {
		store.set(5, 2, uint64(now_) * 1e6, uint64(now_) * 1e6);
		(, int256 answer,,,) = adapter.latestRoundData();
		assertEq(answer, 500e8);
	}

	function test_anExponentOutOfRangeReverts() public {
		store.set(5, -40, uint64(now_) * 1e6, uint64(now_) * 1e6);
		vm.expectRevert(abi.encodeWithSelector(VerantaPriceAdapter.ExponentOutOfRange.selector, int16(-40)));
		adapter.latestRoundData();
	}

	/// Nobody picks an old price: it must have been confirmed recently to be read.
	function test_aPriceNobodyReconfirmedReverts() public {
		vm.warp(now_ + MAX_PUSH_AGE);
		adapter.latestRoundData(); // exactly at the limit still reads
		vm.warp(now_ + MAX_PUSH_AGE + 1);
		vm.expectRevert(abi.encodeWithSelector(VerantaPriceAdapter.StalePush.selector, now_));
		adapter.latestRoundData();
	}

	/// Pyth keeps confirming a halted pair's last trade: it prices for 5 days, then stops.
	function test_aLastTradeOlderThanMaxFeedAgeReverts() public {
		uint64 lastTrade = uint64(now_ - MAX_FEED_AGE);
		store.set(87_992_000, -5, uint64(now_) * 1e6, lastTrade * 1e6);
		adapter.latestRoundData(); // exactly at the limit still reads
		lastTrade -= 1;
		store.set(87_992_000, -5, uint64(now_) * 1e6, lastTrade * 1e6);
		vm.expectRevert(abi.encodeWithSelector(VerantaPriceAdapter.StaleFeed.selector, lastTrade));
		adapter.latestRoundData();
	}

	function test_neverPushedReverts() public {
		store.set(0, 0, 0, 0);
		vm.expectRevert(abi.encodeWithSelector(VerantaPriceAdapter.NeverPushed.selector, PAIR));
		adapter.latestRoundData();
	}

	/// funds-keeper discoverVerantaFeeds and the terminal's useStorePairs find it by these; maxFeedAge marks the store's two-time layout.
	function test_exposesWhatTheKeeperAndTerminalProbe() public view {
		assertEq(address(adapter.store()), address(store));
		assertEq(adapter.pairIndex(), PAIR);
		assertEq(adapter.maxPushAge(), MAX_PUSH_AGE);
		assertEq(adapter.maxFeedAge(), MAX_FEED_AGE);
		assertEq(adapter.description(), 'MU/USD (Veranta)');
	}

	function test_constructorRefusesZeroes() public {
		vm.expectRevert(VerantaPriceAdapter.ZeroArgument.selector);
		new VerantaPriceAdapter(VerantaPriceStore(address(0)), PAIR, MAX_PUSH_AGE, MAX_FEED_AGE, '');
		vm.expectRevert(VerantaPriceAdapter.ZeroArgument.selector);
		new VerantaPriceAdapter(VerantaPriceStore(address(store)), PAIR, 0, MAX_FEED_AGE, '');
		vm.expectRevert(VerantaPriceAdapter.ZeroArgument.selector);
		new VerantaPriceAdapter(VerantaPriceStore(address(store)), PAIR, MAX_PUSH_AGE, 0, '');
	}
}
