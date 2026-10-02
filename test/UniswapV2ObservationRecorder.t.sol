// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {UniswapV2ObservationRecorder} from '../src/pricing/UniswapV2ObservationRecorder.sol';

/// @notice Pair stand-in for the recorder's RING and SPACING logic only (the brief allows one for
///         that pure logic): non-zero reserves whose last update is always "now", so the recorder
///         stores the stand-in's cumulatives unchanged and no price math runs here. The cumulatives
///         equal block.timestamp (×2 for price1), which names each snapshot by the time it was taken,
///         past the uint32 wrap too. Every price path runs on real Uniswap v2 pairs in
///         UniswapV2TwapAdapterFork.t.sol.
contract RingPairStandIn {
	function token0() external pure returns (address) {
		return address(0xA0);
	}

	function token1() external pure returns (address) {
		return address(0xA1);
	}

	function getReserves() external view returns (uint112, uint112, uint32) {
		return (1e18, 1e18, uint32(block.timestamp % 2 ** 32));
	}

	function price0CumulativeLast() external view returns (uint256) {
		return block.timestamp;
	}

	function price1CumulativeLast() external view returns (uint256) {
		return 2 * block.timestamp;
	}
}

/// @notice The recorder's ring: spacing no-op, ring wrap, the newest-old-enough choice, uint32 time
///         wrap, and that recording as fast as allowed can never leave the 30-minute window unserved.
contract UniswapV2ObservationRecorderTest is Test {
	uint256 internal constant T0 = 1_790_000_000;
	uint32 internal constant WINDOW = 30 minutes;
	uint32 internal constant SPACING = 10 minutes;

	UniswapV2ObservationRecorder internal recorder;
	address internal pair;

	function setUp() public {
		recorder = new UniswapV2ObservationRecorder();
		pair = address(new RingPairStandIn());
		vm.warp(T0);
	}

	function test_constants() public view {
		assertEq(recorder.MIN_SPACING(), 10 minutes);
		assertEq(recorder.RING(), 16);
	}

	function test_noSnapshotBeforeAnyRecord() public {
		vm.expectRevert(abi.encodeWithSelector(UniswapV2ObservationRecorder.NoSnapshot.selector, pair));
		recorder.snapshotAtLeast(pair, 0);
		assertEq(recorder.count(pair), 0);
	}

	function test_firstRecordStoresSnapshotAndEmits() public {
		vm.expectEmit(true, false, false, true, address(recorder));
		emit UniswapV2ObservationRecorder.Recorded(pair, uint32(T0));
		assertTrue(recorder.record(pair));
		assertEq(recorder.count(pair), 1);
		assertEq(recorder.head(pair), 0);
		_assertSnapshotAt(recorder.snapshotAtLeast(pair, 0), T0);
	}

	/// @notice Within MIN_SPACING of the pair's last snapshot record() returns false and changes
	///         nothing (no event); at exactly MIN_SPACING it records.
	function test_spacingNoOp() public {
		assertTrue(recorder.record(pair));
		vm.warp(T0 + SPACING - 1);
		vm.recordLogs();
		assertFalse(recorder.record(pair), 'within spacing');
		assertEq(vm.getRecordedLogs().length, 0, 'no event');
		assertEq(recorder.count(pair), 1);
		assertEq(recorder.head(pair), 0);
		_assertSnapshotAt(recorder.snapshotAtLeast(pair, 0), T0);

		vm.warp(T0 + SPACING);
		assertTrue(recorder.record(pair), 'at spacing');
		assertEq(recorder.count(pair), 2);
		assertEq(recorder.head(pair), 1);
		_assertSnapshotAt(recorder.snapshotAtLeast(pair, 0), T0 + SPACING);
	}

	/// @notice Spacing is per pair: another pair records in the same second.
	function test_spacingIsPerPair() public {
		address other = address(new RingPairStandIn());
		assertTrue(recorder.record(pair));
		assertTrue(recorder.record(other));
		assertFalse(recorder.record(pair));
		assertEq(recorder.count(other), 1);
	}

	/// @notice 20 records into 16 slots: count stops at 16, head wraps to 19 mod 16, the 4 oldest are
	///         overwritten and every kept snapshot is still reachable by its exact age.
	function test_ringWraps() public {
		for (uint256 i; i < 20; i++) {
			vm.warp(T0 + i * SPACING);
			assertTrue(recorder.record(pair));
			assertEq(recorder.count(pair), i < 16 ? i + 1 : 16);
			assertEq(recorder.head(pair), i % 16);
		}
		uint256 now_ = T0 + 19 * SPACING;
		for (uint256 k = 4; k < 20; k++) {
			uint32 age = uint32(now_ - (T0 + k * SPACING));
			_assertSnapshotAt(recorder.snapshotAtLeast(pair, age), T0 + k * SPACING);
		}
		uint32 oldestAge = uint32(now_ - (T0 + 4 * SPACING));
		vm.expectRevert(abi.encodeWithSelector(UniswapV2ObservationRecorder.NoSnapshot.selector, pair));
		recorder.snapshotAtLeast(pair, oldestAge + 1);
	}

	/// @notice Irregular records; each minAge returns the NEWEST snapshot at least that old, with
	///         the boundary inclusive (age == minAge qualifies, minAge + 1 moves to the older one).
	function test_snapshotAtLeastPicksNewestOldEnough() public {
		uint256[4] memory at = [T0, T0 + 700, T0 + 1900, T0 + 2600];
		for (uint256 i; i < 4; i++) {
			vm.warp(at[i]);
			assertTrue(recorder.record(pair));
		}
		vm.warp(T0 + 3700); // ages 3700, 3000, 1800, 1100
		_assertSnapshotAt(recorder.snapshotAtLeast(pair, 0), at[3]);
		_assertSnapshotAt(recorder.snapshotAtLeast(pair, 1100), at[3]);
		_assertSnapshotAt(recorder.snapshotAtLeast(pair, 1101), at[2]);
		_assertSnapshotAt(recorder.snapshotAtLeast(pair, WINDOW), at[2]);
		_assertSnapshotAt(recorder.snapshotAtLeast(pair, WINDOW + 1), at[1]);
		_assertSnapshotAt(recorder.snapshotAtLeast(pair, 3000), at[1]);
		_assertSnapshotAt(recorder.snapshotAtLeast(pair, 3001), at[0]);
		_assertSnapshotAt(recorder.snapshotAtLeast(pair, 3700), at[0]);
		vm.expectRevert(abi.encodeWithSelector(UniswapV2ObservationRecorder.NoSnapshot.selector, pair));
		recorder.snapshotAtLeast(pair, 3701);
	}

	/// @notice Someone calls record() every minute for 5 hours (vm.warp + vm.roll each time), so a
	///         snapshot lands every 10 minutes, as fast as spacing allows. Before 30 minutes of
	///         history nothing serves the window; at every step after, a snapshot ≥ 30 min old exists,
	///         it is the newest such one, and it is never more than window + spacing old: the 16-slot
	///         ring spans ≥ 150 minutes, so spam can't push the window's snapshot out.
	function test_spamCannotStarveWindow() public {
		uint256[] memory taken = new uint256[](40);
		uint256 n;
		for (uint256 t; t <= 5 hours; t += 1 minutes) {
			vm.warp(T0 + t);
			vm.roll(block.number + 30);
			bool expected = n == 0 || block.timestamp - taken[n - 1] >= SPACING;
			assertEq(recorder.record(pair), expected, 'records exactly when spacing allows');
			if (expected) taken[n++] = block.timestamp;

			if (t < WINDOW) {
				vm.expectRevert(abi.encodeWithSelector(UniswapV2ObservationRecorder.NoSnapshot.selector, pair));
				recorder.snapshotAtLeast(pair, WINDOW);
				continue;
			}
			uint256 want = _newestAtLeast(taken, n, WINDOW);
			UniswapV2ObservationRecorder.Snapshot memory s = recorder.snapshotAtLeast(pair, WINDOW);
			_assertSnapshotAt(s, want);
			assertLt(block.timestamp - want, WINDOW + SPACING, 'within window + spacing');
		}
		assertEq(n, 31, 'one snapshot per 10 minutes');
		assertEq(recorder.count(pair), 16);
	}

	/// @notice Any record() cadence (gaps 1 s to 20 min): once the first snapshot is a window old,
	///         the window is always served, by the newest snapshot at least that old.
	function testFuzz_windowAlwaysServed(uint16[48] memory gaps) public {
		uint256[] memory taken = new uint256[](49);
		uint256 n;
		assertTrue(recorder.record(pair));
		taken[n++] = block.timestamp;
		for (uint256 i; i < gaps.length; i++) {
			vm.warp(block.timestamp + bound(gaps[i], 1, 20 minutes));
			if (recorder.record(pair)) taken[n++] = block.timestamp;
			if (block.timestamp - taken[0] < WINDOW) continue;
			_assertSnapshotAt(recorder.snapshotAtLeast(pair, WINDOW), _newestAtLeast(taken, n, WINDOW));
		}
	}

	/// @notice block.timestamp crosses 2^32 (Feb 2106): the stored uint32 timestamps wrap and the
	///         spacing and age deltas are taken mod 2^32, as UniswapV2OracleLibrary does.
	function test_timestampWrap() public {
		uint256 wrap = 2 ** 32;
		vm.warp(wrap - 500);
		assertTrue(recorder.record(pair));
		vm.warp(wrap + 99); // 599 s later
		assertFalse(recorder.record(pair), 'spacing across the wrap');
		vm.warp(wrap + 100); // 600 s later
		assertTrue(recorder.record(pair), 'records 600 s later');
		_assertSnapshotAt(recorder.snapshotAtLeast(pair, 0), wrap + 100);
		assertEq(recorder.snapshotAtLeast(pair, 0).timestamp, 100, 'uint32 timestamp wrapped');

		vm.warp(wrap + 1300); // ages 1800 and 1200
		_assertSnapshotAt(recorder.snapshotAtLeast(pair, 1200), wrap + 100);
		_assertSnapshotAt(recorder.snapshotAtLeast(pair, 1201), wrap - 500);
		_assertSnapshotAt(recorder.snapshotAtLeast(pair, WINDOW), wrap - 500);
		vm.expectRevert(abi.encodeWithSelector(UniswapV2ObservationRecorder.NoSnapshot.selector, pair));
		recorder.snapshotAtLeast(pair, WINDOW + 1);
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	/// @dev The stand-in's cumulatives are (t, 2t) at the time t of the snapshot.
	function _assertSnapshotAt(UniswapV2ObservationRecorder.Snapshot memory s, uint256 t) internal pure {
		assertEq(s.timestamp, uint32(t % 2 ** 32), 'timestamp');
		assertEq(s.price0Cumulative, t, 'price0Cumulative');
		assertEq(s.price1Cumulative, 2 * t, 'price1Cumulative');
	}

	function _newestAtLeast(uint256[] memory taken, uint256 n, uint32 minAge) internal view returns (uint256) {
		for (uint256 j = n; j > 0; j--) {
			if (taken[j - 1] + minAge <= block.timestamp) return taken[j - 1];
		}
		revert('no snapshot old enough');
	}
}
