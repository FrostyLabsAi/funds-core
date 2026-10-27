// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {VerantaPriceStoreV2} from '../src/pricing/VerantaPriceStoreV2.sol';
import {IPythLazerVerifier, IVerantaLazerPairs} from '../src/pricing/VerantaPriceStore.sol';

/// @dev Hands back the update as the verified payload (the fork tests use Pyth's real verifier).
contract MockLazerVerifier is IPythLazerVerifier {
	function verifyUpdate(bytes calldata update) external payable returns (bytes memory payload, address signer) {
		return (update, address(1));
	}

	function verification_fee() external pure returns (uint256) {
		return 1;
	}
}

contract MockLazerPairs is IVerantaLazerPairs {
	mapping(uint256 => uint256) public feedOf;

	function set(uint256 pairIndex, uint256 feedId) external {
		feedOf[pairIndex] = feedId;
	}

	function getLazerFeedId(uint256 pairIndex) external view returns (uint256) {
		return feedOf[pairIndex];
	}
}

contract VerantaPriceStoreV2Test is Test {
	uint256 internal constant PAIR = 100; // MU on Veranta
	uint32 internal constant FEED = 1234;
	uint64 internal constant FRIDAY_CLOSE_US = 1_792_799_999_950_000; // Fri 2026-10-23 23:59:59.95 UTC
	uint64 internal constant SUNDAY_US = 1_792_972_517_000_000; // Sun 2026-10-25 23:55:17 UTC

	VerantaPriceStoreV2 internal store;
	MockLazerPairs internal pairs;

	function setUp() public {
		pairs = new MockLazerPairs();
		pairs.set(PAIR, FEED);
		store = new VerantaPriceStoreV2(new MockLazerVerifier(), pairs);
		vm.warp(SUNDAY_US / 1e6 + 30);
	}

	/// A Lazer payload with one feed: price, exponent, confidence and the feed's update time.
	function _payload(uint32 feedId, int64 price, uint64 headerUs, uint64 feedUs) internal pure returns (bytes memory) {
		bytes memory header = abi.encodePacked(uint32(2479346549), headerUs, uint8(1), uint8(1)); // magic · time · channel · one feed
		bytes memory head = abi.encodePacked(feedId, uint8(4), uint8(0), price, uint8(4), int16(-2)); // id · 4 props · price · exponent
		return abi.encodePacked(header, head, uint8(5), uint64(10), uint8(12), uint8(1), feedUs); // confidence · update time
	}

	function _submit(int64 price, uint64 headerUs, uint64 feedUs) internal returns (bool) {
		return store.submit{value: 1}(PAIR, _payload(FEED, price, headerUs, feedUs));
	}

	function test_storesPriceConfirmedAndFeedTimes() public {
		assertTrue(_submit(87_992, SUNDAY_US, FRIDAY_CLOSE_US));
		(int64 price, int16 exponent, uint64 confirmedUs) = store.latest(PAIR);
		assertEq(price, 87_992);
		assertEq(exponent, -2);
		assertEq(confirmedUs, SUNDAY_US, 'timestampUs is when Pyth signed the price as current');
		assertEq(store.feedUpdatedUs(PAIR), FRIDAY_CLOSE_US, 'the stock last traded Friday');
	}

	function test_newerHeaderSameFeedReconfirms() public {
		_submit(87_992, SUNDAY_US, FRIDAY_CLOSE_US);
		assertTrue(_submit(87_992, SUNDAY_US + 24_000_000, FRIDAY_CLOSE_US), 'a later weekend packet re-confirms');
		(int64 price,, uint64 confirmedUs) = store.latest(PAIR);
		assertEq(price, 87_992);
		assertEq(confirmedUs, SUNDAY_US + 24_000_000);
		assertEq(store.feedUpdatedUs(PAIR), FRIDAY_CLOSE_US);
	}

	function test_olderFeedNeverRollsBack() public {
		_submit(87_992, SUNDAY_US, FRIDAY_CLOSE_US);
		// signed later, but carrying an older trade (an out-of-order relay): never stored
		assertFalse(_submit(80_000, SUNDAY_US + 1_000_000, FRIDAY_CLOSE_US - 3_600_000_000));
		(int64 price,, uint64 confirmedUs) = store.latest(PAIR);
		assertEq(price, 87_992);
		assertEq(confirmedUs, SUNDAY_US);
		assertEq(store.feedUpdatedUs(PAIR), FRIDAY_CLOSE_US);
	}

	function test_notNewerHeaderReturnsFalse() public {
		_submit(87_992, SUNDAY_US, FRIDAY_CLOSE_US);
		assertFalse(_submit(90_000, SUNDAY_US, FRIDAY_CLOSE_US), 'same header');
		assertFalse(_submit(90_000, SUNDAY_US - 1, FRIDAY_CLOSE_US), 'older header');
		(int64 price,,) = store.latest(PAIR);
		assertEq(price, 87_992);
	}

	function test_packetOlderThanMaxRelayAgeReverts() public {
		vm.warp(SUNDAY_US / 1e6 + store.MAX_RELAY_AGE());
		assertTrue(_submit(87_992, SUNDAY_US, FRIDAY_CLOSE_US), 'a minute-old packet is still news');
		// a newer packet relayed 61 s after Pyth signed it: refused, so a relayer can't pick from the adapter's lifetime
		uint64 later = SUNDAY_US + 10_000_000;
		vm.warp(later / 1e6 + store.MAX_RELAY_AGE() + 1);
		vm.expectRevert(abi.encodeWithSelector(VerantaPriceStoreV2.PacketTooOld.selector, later));
		_submit(87_992, later, FRIDAY_CLOSE_US);
	}

	function test_headerFromFutureReverts() public {
		uint64 future = uint64(block.timestamp + 1) * 1e6;
		vm.expectRevert(abi.encodeWithSelector(VerantaPriceStoreV2.FeedFromFuture.selector, future));
		_submit(87_992, future, FRIDAY_CLOSE_US);
	}

	function test_feedAfterHeaderReverts() public {
		vm.expectRevert(
			abi.encodeWithSelector(VerantaPriceStoreV2.FeedUpdateAfterHeader.selector, SUNDAY_US + 1, SUNDAY_US)
		);
		_submit(87_992, SUNDAY_US, SUNDAY_US + 1);
	}

	function test_wrongFeedReverts() public {
		vm.expectRevert(abi.encodeWithSelector(VerantaPriceStoreV2.FeedNotFound.selector, PAIR, FEED));
		store.submit{value: 1}(PAIR, _payload(FEED + 1, 87_992, SUNDAY_US, FRIDAY_CLOSE_US));
	}

	function test_nonPositiveReverts() public {
		vm.expectRevert(abi.encodeWithSelector(VerantaPriceStoreV2.NonPositivePrice.selector, PAIR));
		_submit(0, SUNDAY_US, FRIDAY_CLOSE_US);
	}

	/// The terminal writes this word for free NAV reads (frosty-terminal verantaPrices.ts packLatestV2, same numbers).
	function test_storageWordLayout() public {
		_submit(87_992, SUNDAY_US, FRIDAY_CLOSE_US);
		bytes32 slot = keccak256(abi.encode(PAIR, uint256(0)));
		uint256 word = uint256(vm.load(address(store), slot));
		uint256 expected = uint256(uint64(int64(87_992))) | (uint256(uint16(int16(-2))) << 64) | (uint256(SUNDAY_US) << 80)
			| (uint256(FRIDAY_CLOSE_US) << 144);
		assertEq(word, expected, 'price 0-63, exponent 64-79, confirmed 80-143, last trade 144-207');
		assertEq(bytes32(word), 0x00000000000000065e8ac7267cb000065eb2f1f7c340fffe00000000000157b8, 'the word packLatestV2 must produce');
	}

	function test_neverStoredReadsZero() public view {
		(int64 price,, uint64 confirmedUs) = store.latest(PAIR);
		assertEq(price, 0);
		assertEq(confirmedUs, 0);
		assertEq(store.feedUpdatedUs(PAIR), 0);
	}
}
