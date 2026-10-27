// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {B20VerantaPriceAdapter} from '../src/pricing/B20VerantaPriceAdapter.sol';
import {VerantaPriceStoreV2} from '../src/pricing/VerantaPriceStoreV2.sol';

/// @dev Answers only what the adapter reads from the V2 store.
contract MockStoreV2 {
	int64 public price;
	int16 public exponent;
	uint64 public confirmedUs;
	uint64 public feedUs;

	function set(int64 price_, int16 exponent_, uint64 confirmedUs_, uint64 feedUs_) external {
		(price, exponent, confirmedUs, feedUs) = (price_, exponent_, confirmedUs_, feedUs_);
	}

	function latest(uint256) external view returns (int64, int16, uint64) {
		return (price, exponent, confirmedUs);
	}

	function feedUpdatedUs(uint256) external view returns (uint64) {
		return feedUs;
	}
}

/// @dev A B20 stock token's `multiplier()` (1e18 = one share per token).
contract MockB20 {
	uint256 public multiplier;

	function setMultiplier(uint256 m) external {
		multiplier = m;
	}
}

contract B20VerantaPriceAdapterTest is Test {
	uint256 internal constant PAIR = 100;
	uint32 internal constant MAX_PUSH_AGE = 600;
	uint32 internal constant MAX_FEED_AGE = 432_000;
	uint256 internal constant MU_MULTIPLIER = 1_000_537_939_576_369_481; // NVDAc's, read on Base 2026-10-25

	MockStoreV2 internal store;
	MockB20 internal token;
	B20VerantaPriceAdapter internal adapter;
	uint256 internal now_ = 1_792_972_549; // Sun 2026-10-25 23:55:49 UTC

	function setUp() public {
		vm.warp(now_);
		store = new MockStoreV2();
		token = new MockB20();
		token.setMultiplier(MU_MULTIPLIER);
		adapter = new B20VerantaPriceAdapter(
			VerantaPriceStoreV2(address(store)), PAIR, address(token), MAX_PUSH_AGE, MAX_FEED_AGE, 'MUc / USD (Veranta x multiplier)'
		);
		// MU 879.92, confirmed now, last traded Friday close (two days earlier)
		store.set(87_992_000, -5, uint64(now_) * 1e6, uint64(now_ - 172_800) * 1e6);
	}

	function test_answerIsPriceTimesMultiplier() public view {
		(, int256 answer,, uint256 updatedAt,) = adapter.latestRoundData();
		assertEq(answer, int256((87_992_000_000 * MU_MULTIPLIER) / 1e18), '879.92 x 1.000537939... at 8 decimals');
		assertEq(updatedAt, now_, 'updatedAt is when Pyth last confirmed the price');
		assertEq(adapter.decimals(), 8);
	}

	function test_unchangedMultiplierIsOneToOne() public {
		token.setMultiplier(1e18);
		(, int256 answer,,,) = adapter.latestRoundData();
		assertEq(answer, 87_992_000_000);
	}

	function test_positiveExponentScalesUp() public {
		store.set(5, 2, uint64(now_) * 1e6, uint64(now_) * 1e6); // 500
		token.setMultiplier(1e18);
		(, int256 answer,,,) = adapter.latestRoundData();
		assertEq(answer, 500e8);
	}

	function test_staleConfirmationReverts() public {
		vm.warp(now_ + MAX_PUSH_AGE);
		adapter.latestRoundData(); // exactly at the limit still reads
		vm.warp(now_ + MAX_PUSH_AGE + 1);
		vm.expectRevert(abi.encodeWithSelector(B20VerantaPriceAdapter.StalePush.selector, now_));
		adapter.latestRoundData();
	}

	function test_feedOlderThanMaxFeedAgeReverts() public {
		// Pyth keeps confirming a halted stock's last trade: it prices for 5 days, then stops
		uint64 lastTrade = uint64(now_ - MAX_FEED_AGE - 1);
		store.set(87_992_000, -5, uint64(now_) * 1e6, lastTrade * 1e6);
		vm.expectRevert(abi.encodeWithSelector(B20VerantaPriceAdapter.StaleFeed.selector, lastTrade));
		adapter.latestRoundData();
	}

	function test_neverPushedReverts() public {
		store.set(0, 0, 0, 0);
		vm.expectRevert(abi.encodeWithSelector(B20VerantaPriceAdapter.NeverPushed.selector, PAIR));
		adapter.latestRoundData();
	}

	function test_zeroMultiplierReverts() public {
		token.setMultiplier(0);
		vm.expectRevert(B20VerantaPriceAdapter.BadMultiplier.selector);
		adapter.latestRoundData();
	}

	function test_exposesKeeperProbeGetters() public view {
		// funds-keeper discoverVerantaFeeds and the terminal's useStorePairs find store-priced assets by these three
		assertEq(address(adapter.store()), address(store));
		assertEq(adapter.pairIndex(), PAIR);
		assertEq(adapter.maxPushAge(), MAX_PUSH_AGE);
		assertEq(adapter.maxFeedAge(), MAX_FEED_AGE);
		assertEq(adapter.token(), address(token));
	}

	function test_constructorRefusesZeroes() public {
		vm.expectRevert(B20VerantaPriceAdapter.ZeroArgument.selector);
		new B20VerantaPriceAdapter(VerantaPriceStoreV2(address(0)), PAIR, address(token), MAX_PUSH_AGE, MAX_FEED_AGE, '');
		vm.expectRevert(B20VerantaPriceAdapter.ZeroArgument.selector);
		new B20VerantaPriceAdapter(VerantaPriceStoreV2(address(store)), PAIR, address(0), MAX_PUSH_AGE, MAX_FEED_AGE, '');
		vm.expectRevert(B20VerantaPriceAdapter.ZeroArgument.selector);
		new B20VerantaPriceAdapter(VerantaPriceStoreV2(address(store)), PAIR, address(token), 0, MAX_FEED_AGE, '');
		vm.expectRevert(B20VerantaPriceAdapter.ZeroArgument.selector);
		new B20VerantaPriceAdapter(VerantaPriceStoreV2(address(store)), PAIR, address(token), MAX_PUSH_AGE, 0, '');
	}
}
