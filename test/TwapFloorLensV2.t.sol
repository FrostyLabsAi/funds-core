// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {TwapFloorLensV2} from '../src/pricing/TwapFloorLensV2.sol';
import {TwapListingRegistryV2} from '../src/pricing/TwapListingRegistryV2.sol';
import {IValueInterpreter} from '../src/interfaces/IValueInterpreter.sol';
import {TwapListingRegistryV2Harness, FloorProbeAdapter, TestVenues} from './TwapListingRegistryV2.t.sol';

/// @dev FloorProbeAdapter plus the real adapters' two-part `isBelowFloor()` (Ruling 23: quote
///      reserve under the MIN_QUOTE_RESERVE_USD every registry adapter is built with, or — read only
///      when the reserve holds — band depth under its MIN_BAND_DEPTH_USD), which is the read the lens
///      makes.
contract FloorProbeAdapterWithFloor is FloorProbeAdapter {
	/// @dev = TwapListingRegistryV2.MIN_QUOTE_RESERVE_USD (asserted in the tests)
	uint256 public constant MIN_LIQUIDITY_USD = 25_000;
	/// @dev = TwapListingRegistryV2.MIN_BAND_DEPTH_USD (asserted in the tests)
	uint256 public constant MIN_BAND_DEPTH_USD = 1_282;

	function isBelowFloor() external view returns (bool) {
		return this.quoteReserveUsd() < MIN_LIQUIDITY_USD * 1e18 || this.poolDepthUsd() < MIN_BAND_DEPTH_USD * 1e18;
	}
}

/// @notice The lens must page the registry without ever reverting or overflowing, and name exactly
///         the assets in the page whose `pokeFloor` would change the stored 72-hour clock.
contract TwapFloorLensV2Test is Test {
	uint256 internal constant UNDER = 20_000e18; // quote reserve under the $25k floor
	uint256 internal constant OVER = 80_000e18;
	uint256 internal constant BAND_OVER = 4_000e18; // band over the $1,282 band floor
	uint256 internal constant BAND_UNDER = 1_281e18;

	function _venues() internal returns (TwapListingRegistryV2.Venues memory) {
		return TestVenues.build(
			IValueInterpreter(makeAddr('vi')),
			makeAddr('uni'),
			makeAddr('s1'),
			makeAddr('s2'),
			makeAddr('s3'),
			makeAddr('uniV2'),
			makeAddr('aero')
		);
	}

	function test_pagination() public {
		TwapListingRegistryV2 r = new TwapListingRegistryV2(_venues());
		TwapFloorLensV2 lens = new TwapFloorLensV2();
		(address[] memory due, uint256 next) = lens.assetsNeedingPoke(r, 0, 50);
		assertEq(due.length, 0);
		assertEq(next, 0);
		(due, next) = lens.assetsNeedingPoke(r, 99, 50);
		assertEq(due.length, 0, 'offset past the end is empty');
		assertEq(next, 0, 'next clamps to listedCount');
	}

	// ─── real entries (registry harness + probe adapters) ───────────────────────

	function _harness() internal returns (TwapListingRegistryV2Harness h) {
		h = new TwapListingRegistryV2Harness(_venues());
	}

	/// @dev List `name` on a fresh probe reading `reserve` (and a band over the band floor),
	///      appended to the listed-asset array.
	function _list(TwapListingRegistryV2Harness h, string memory name, uint256 reserve)
		internal
		returns (address asset, FloorProbeAdapterWithFloor probe)
	{
		asset = makeAddr(name);
		probe = new FloorProbeAdapterWithFloor();
		probe.setReserve(reserve);
		probe.setDepth(BAND_OVER);
		h.listOnProbe(asset, address(probe));
		h.pushListed(asset);
	}

	function test_pagesRealEntries() public {
		TwapListingRegistryV2Harness h = _harness();
		TwapFloorLensV2 lens = new TwapFloorLensV2();
		address stranger = makeAddr('stranger');

		(address start,) = _list(h, 'start', UNDER); // under, no clock: a poke would start it
		(address steady,) = _list(h, 'steady', OVER); // over, no clock: nothing to do
		(address restore, FloorProbeAdapterWithFloor restoreProbe) = _list(h, 'restore', UNDER);
		vm.prank(stranger);
		assertTrue(h.pokeFloor(restore), 'clock started while under');
		skip(1 hours);
		restoreProbe.setReserve(OVER); // recovered with the clock running: a keeper poke would clear it
		assertEq(restoreProbe.MIN_LIQUIDITY_USD(), h.MIN_QUOTE_RESERVE_USD(), 'probe floor = registry floor');
		assertEq(restoreProbe.MIN_BAND_DEPTH_USD(), h.MIN_BAND_DEPTH_USD(), 'probe band floor = registry band floor');
		assertEq(h.listedCount(), 3);

		(address[] memory due, uint256 next) = lens.assetsNeedingPoke(h, 0, 2);
		assertEq(due.length, 1, 'only start is due among the first two');
		assertEq(due[0], start);
		assertEq(next, 2);

		(due, next) = lens.assetsNeedingPoke(h, 2, 2);
		assertEq(due.length, 1, 'a page past the end is clipped');
		assertEq(due[0], restore);
		assertEq(next, 3);

		(due, next) = lens.assetsNeedingPoke(h, 3, 5);
		assertEq(due.length, 0, 'offset == listedCount is empty');
		assertEq(next, 3);

		(due, next) = lens.assetsNeedingPoke(h, 10, 5);
		assertEq(due.length, 0, 'offset past the end is empty');
		assertEq(next, 3, 'next clamps to listedCount');

		(due, next) = lens.assetsNeedingPoke(h, 0, type(uint256).max);
		assertEq(due.length, 2, 'an unbounded limit never overflows');
		assertEq(due[0], start);
		assertEq(due[1], restore);
		assertEq(next, 3);

		(due, next) = lens.assetsNeedingPoke(h, 1, type(uint256).max);
		assertEq(due.length, 1, 'an unbounded limit from a nonzero offset never overflows');
		assertEq(due[0], restore);
		assertEq(next, 3);

		// a stranger's pokes only start clocks: the restore stays due
		vm.startPrank(stranger);
		h.pokeFloor(start);
		h.pokeFloor(steady);
		h.pokeFloor(restore);
		vm.stopPrank();
		(due, next) = lens.assetsNeedingPoke(h, 0, type(uint256).max);
		assertEq(due.length, 1, 'a stranger never clears a clock');
		assertEq(due[0], restore);

		// the keeper (the registry's lister, via the module) clears it: nothing left to do
		address keeper = makeAddr('keeper');
		h.setLister(keeper, true);
		vm.prank(keeper);
		assertFalse(h.pokeFloor(restore));
		(due, next) = lens.assetsNeedingPoke(h, 0, type(uint256).max);
		assertEq(due.length, 0);
		assertEq(next, 3);
	}

	/// Ruling 23 through the lens: a pool holding the reserve floor with its band under the band
	/// floor is due (a poke would start its clock); once the clock runs it isn't; once the band is
	/// back it is due again (a keeper poke would clear it) — and the registry agrees each time
	function test_thinBandIsDue() public {
		TwapListingRegistryV2Harness h = _harness();
		TwapFloorLensV2 lens = new TwapFloorLensV2();
		(address thin, FloorProbeAdapterWithFloor probe) = _list(h, 'thin', OVER);
		_list(h, 'steady', OVER);
		probe.setDepth(BAND_UNDER);

		(address[] memory due,) = lens.assetsNeedingPoke(h, 0, 50);
		assertEq(due.length, 1, 'reserve over, band under: due');
		assertEq(due[0], thin);
		vm.prank(makeAddr('stranger'));
		assertTrue(h.pokeFloor(thin), 'the registry agrees: under');
		(due,) = lens.assetsNeedingPoke(h, 0, 50);
		assertEq(due.length, 0, 'clock running');

		probe.setDepth(BAND_OVER);
		(due,) = lens.assetsNeedingPoke(h, 0, 50);
		assertEq(due.length, 1, 'band back: a keeper poke would clear it');
		assertEq(due[0], thin);
		address keeper = makeAddr('keeper');
		h.setLister(keeper, true);
		vm.prank(keeper);
		assertFalse(h.pokeFloor(thin));
		(due,) = lens.assetsNeedingPoke(h, 0, 50);
		assertEq(due.length, 0);
	}

	/// the registry's rule: an adapter that can't answer counts as under the floor, and never
	/// reverts the page (it would kill the whole keeper run)
	function test_unanswerableCountsAsUnder() public {
		TwapListingRegistryV2Harness h = _harness();
		TwapFloorLensV2 lens = new TwapFloorLensV2();
		(address broken, FloorProbeAdapterWithFloor probe) = _list(h, 'broken', OVER);
		_list(h, 'steady', OVER);
		probe.setBroken(true);

		(address[] memory due, uint256 next) = lens.assetsNeedingPoke(h, 0, 50);
		assertEq(due.length, 1);
		assertEq(due[0], broken);
		assertEq(next, 2);

		vm.prank(makeAddr('stranger'));
		assertTrue(h.pokeFloor(broken));
		(due, next) = lens.assetsNeedingPoke(h, 0, 50);
		assertEq(due.length, 0, 'clock running, still unanswerable');
		assertEq(next, 2);
	}
}
