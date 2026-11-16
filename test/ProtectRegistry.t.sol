// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {ProtectRegistry} from '../src/protect/ProtectRegistry.sol';

contract MockProtectedPosition {
	address public comptroller;

	constructor(address comptroller_) {
		comptroller = comptroller_;
	}
}

contract MockProtectComptroller {
	address public fundOwner;

	constructor(address fundOwner_) {
		fundOwner = fundOwner_;
	}
}

contract ProtectRegistryTest is Test {
	uint256 internal constant BTC = 1;
	uint256 internal constant SPCX = 105;

	ProtectRegistry internal registry;
	address internal alice = makeAddr('alice');
	address internal teth = makeAddr('tETH');

	event ProtectConfigured(
		address indexed user,
		uint256 indexed pairIndex,
		ProtectRegistry.Mode mode,
		address spotAsset,
		uint16 trailingBps,
		uint16 leverageX,
		bool enabled
	);

	function setUp() public {
		registry = new ProtectRegistry();
	}

	function _enabled(address user, uint256 pair) internal view returns (bool enabled) {
		(,,,,, enabled) = registry.configs(user, pair);
	}

	function _trailing(address user, uint256 pair) internal view returns (uint16 trailingBps) {
		(,, trailingBps,,,) = registry.configs(user, pair);
	}

	/// @dev Settings are per account AND pair: arming SPCX must not stop the trailing stop on BTC (founder 2026-11-03).
	function test_settingOnOneMarket_leavesAnotherMarketAlone() public {
		vm.startPrank(alice);
		registry.configure(ProtectRegistry.Mode.STOP, BTC, address(0), 50, 0);
		registry.configure(ProtectRegistry.Mode.HEDGE, SPCX, teth, 800, 2);
		vm.stopPrank();

		(ProtectRegistry.Mode btcMode, address btcSpot, uint16 btcTrail, uint16 btcLev,, bool btcOn) = registry.configs(alice, BTC);
		assertEq(uint8(btcMode), uint8(ProtectRegistry.Mode.STOP));
		assertEq(btcSpot, address(0));
		assertEq(btcTrail, 50);
		assertEq(btcLev, 0);
		assertTrue(btcOn);

		(ProtectRegistry.Mode spcxMode, address spcxSpot, uint16 spcxTrail, uint16 spcxLev,, bool spcxOn) = registry.configs(alice, SPCX);
		assertEq(uint8(spcxMode), uint8(ProtectRegistry.Mode.HEDGE));
		assertEq(spcxSpot, teth);
		assertEq(spcxTrail, 800);
		assertEq(spcxLev, 2);
		assertTrue(spcxOn);
	}

	function test_disablingOneMarket_leavesAnotherMarketOn() public {
		vm.startPrank(alice);
		registry.configure(ProtectRegistry.Mode.STOP, BTC, address(0), 50, 0);
		registry.configure(ProtectRegistry.Mode.HEDGE, SPCX, teth, 800, 2);
		registry.disable(SPCX);
		vm.stopPrank();
		assertTrue(_enabled(alice, BTC));
		assertFalse(_enabled(alice, SPCX));
	}

	function testFuzz_writesToOnePairNeverChangeAnother(uint256 a, uint256 b, uint16 trailA, uint16 trailB) public {
		vm.assume(a != b);
		trailA = uint16(bound(trailA, 1, 9_999));
		trailB = uint16(bound(trailB, 1, 9_999));
		vm.startPrank(alice);
		registry.configure(ProtectRegistry.Mode.STOP, a, address(0), trailA, 0);
		registry.configure(ProtectRegistry.Mode.STOP, b, address(0), trailB, 0);
		assertEq(_trailing(alice, a), trailA);
		registry.disable(b);
		assertEq(_trailing(alice, a), trailA);
		assertTrue(_enabled(alice, a));
		vm.stopPrank();
	}

	function test_configure_hedge_storesAndEmits() public {
		vm.expectEmit(true, true, false, true);
		emit ProtectConfigured(alice, SPCX, ProtectRegistry.Mode.HEDGE, teth, 800, 2, true);
		vm.prank(alice);
		registry.configure(ProtectRegistry.Mode.HEDGE, SPCX, teth, 800, 2);
		assertTrue(_enabled(alice, SPCX));
	}

	function test_configure_stampsTheTime() public {
		vm.warp(1_800_000_000);
		vm.prank(alice);
		registry.configure(ProtectRegistry.Mode.STOP, BTC, address(0), 500, 0);
		(,,,, uint40 updatedAt,) = registry.configs(alice, BTC);
		assertEq(updatedAt, 1_800_000_000);
	}

	function test_configure_stop_needsNoSpotAssetOrLeverage() public {
		vm.prank(alice);
		registry.configure(ProtectRegistry.Mode.STOP, 86, address(0), 500, 0);
		assertEq(_trailing(alice, 86), 500);
		assertTrue(_enabled(alice, 86));
	}

	function test_configure_validation() public {
		vm.startPrank(alice);
		vm.expectRevert(ProtectRegistry.BadTrailing.selector);
		registry.configure(ProtectRegistry.Mode.STOP, 0, address(0), 0, 0);
		vm.expectRevert(ProtectRegistry.BadTrailing.selector);
		registry.configure(ProtectRegistry.Mode.STOP, 0, address(0), 10_000, 0);
		vm.expectRevert(ProtectRegistry.SpotAssetRequired.selector);
		registry.configure(ProtectRegistry.Mode.HEDGE, 0, address(0), 800, 2);
		vm.expectRevert(ProtectRegistry.BadLeverage.selector);
		registry.configure(ProtectRegistry.Mode.HEDGE, 0, teth, 800, 0);
		vm.expectRevert(ProtectRegistry.BadLeverage.selector);
		registry.configure(ProtectRegistry.Mode.HEDGE, 0, teth, 800, 11);
		vm.stopPrank();
		assertEq(registry.pairsOf(alice).length, 0);
	}

	function test_neutral_validatesLikeHedge() public {
		vm.startPrank(alice);
		vm.expectRevert(ProtectRegistry.SpotAssetRequired.selector);
		registry.configure(ProtectRegistry.Mode.NEUTRAL, 0, address(0), 500, 2);
		vm.expectRevert(ProtectRegistry.BadLeverage.selector);
		registry.configure(ProtectRegistry.Mode.NEUTRAL, 0, teth, 500, 0);
		registry.configure(ProtectRegistry.Mode.NEUTRAL, 0, teth, 500, 2);
		vm.stopPrank();
		assertTrue(_enabled(alice, 0));
	}

	function test_disable_keepsConfigForReenable() public {
		vm.startPrank(alice);
		registry.configure(ProtectRegistry.Mode.HEDGE, SPCX, teth, 800, 2);
		vm.expectEmit(true, true, false, true);
		emit ProtectConfigured(alice, SPCX, ProtectRegistry.Mode.HEDGE, teth, 800, 2, false);
		registry.disable(SPCX);
		vm.stopPrank();
		assertFalse(_enabled(alice, SPCX));
		assertEq(_trailing(alice, SPCX), 800);
	}

	function test_disable_aPairNeverConfiguredReverts() public {
		vm.prank(alice);
		registry.configure(ProtectRegistry.Mode.STOP, BTC, address(0), 50, 0);
		vm.prank(alice);
		vm.expectRevert(ProtectRegistry.NotConfigured.selector);
		registry.disable(SPCX);
	}

	function test_pairsOf_listsEachPairOnce_andKeepsDisabledOnes() public {
		vm.startPrank(alice);
		registry.configure(ProtectRegistry.Mode.STOP, BTC, address(0), 50, 0);
		registry.configure(ProtectRegistry.Mode.HEDGE, SPCX, teth, 800, 2);
		registry.configure(ProtectRegistry.Mode.STOP, BTC, address(0), 75, 0);
		registry.disable(SPCX);
		vm.stopPrank();
		uint256[] memory pairs = registry.pairsOf(alice);
		assertEq(pairs.length, 2);
		assertEq(pairs[0], BTC);
		assertEq(pairs[1], SPCX);
	}

	function test_settings_areStrictlyPerUser() public {
		address bob = makeAddr('bob');
		vm.prank(alice);
		registry.configure(ProtectRegistry.Mode.STOP, BTC, address(0), 50, 0);
		assertFalse(_enabled(bob, BTC));
		assertEq(registry.pairsOf(bob).length, 0);
		vm.prank(bob);
		vm.expectRevert(ProtectRegistry.NotConfigured.selector);
		registry.disable(BTC);
		assertTrue(_enabled(alice, BTC));
	}

	function test_configureFor_fundManagerProtectsTheFundPosition() public {
		address manager = makeAddr('manager');
		address position = address(new MockProtectedPosition(address(new MockProtectComptroller(manager))));
		vm.startPrank(manager);
		registry.configureFor(position, ProtectRegistry.Mode.STOP, BTC, address(0), 50, 0);
		registry.configureFor(position, ProtectRegistry.Mode.HEDGE, SPCX, teth, 800, 2);
		registry.disableFor(position, SPCX);
		vm.stopPrank();
		assertTrue(_enabled(position, BTC));
		assertFalse(_enabled(position, SPCX));
		assertEq(registry.pairsOf(position).length, 2);
		assertFalse(_enabled(manager, BTC));
	}

	function test_configureFor_rejectsNonOwnersAndNonPositions() public {
		address manager = makeAddr('manager');
		address position = address(new MockProtectedPosition(address(new MockProtectComptroller(manager))));
		vm.prank(manager);
		registry.configureFor(position, ProtectRegistry.Mode.STOP, BTC, address(0), 50, 0);

		vm.startPrank(alice);
		vm.expectRevert(ProtectRegistry.NotFundOwner.selector);
		registry.configureFor(position, ProtectRegistry.Mode.STOP, SPCX, address(0), 50, 0);
		vm.expectRevert(ProtectRegistry.NotFundOwner.selector);
		registry.disableFor(position, BTC);
		vm.expectRevert(ProtectRegistry.NotFundOwner.selector);
		registry.configureFor(makeAddr('notAPosition'), ProtectRegistry.Mode.STOP, BTC, address(0), 50, 0);
		vm.stopPrank();
		assertTrue(_enabled(position, BTC));
		assertFalse(_enabled(position, SPCX));
	}
}
