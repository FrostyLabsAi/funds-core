// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {ProtectRegistryV2} from '../src/protect/ProtectRegistryV2.sol';

contract MockProtectedPositionV2 {
	address public comptroller;

	constructor(address comptroller_) {
		comptroller = comptroller_;
	}
}

contract MockProtectComptrollerV2 {
	address public fundOwner;

	constructor(address fundOwner_) {
		fundOwner = fundOwner_;
	}
}

contract ProtectRegistryV2Test is Test {
	uint256 internal constant BTC = 1;
	uint256 internal constant SPCX = 105;

	ProtectRegistryV2 internal registry;
	address internal alice = makeAddr('alice');
	address internal teth = makeAddr('tETH');

	event ProtectConfigured(
		address indexed user,
		uint256 indexed pairIndex,
		ProtectRegistryV2.Mode mode,
		address spotAsset,
		uint16 trailingBps,
		uint16 leverageX,
		bool enabled
	);

	function setUp() public {
		registry = new ProtectRegistryV2();
	}

	function _enabled(address user, uint256 pair) internal view returns (bool enabled) {
		(,,,,, enabled) = registry.configs(user, pair);
	}

	function _trailing(address user, uint256 pair) internal view returns (uint16 trailingBps) {
		(,, trailingBps,,,) = registry.configs(user, pair);
	}

	/// @dev The reason V2 exists: arming SPCX used to silently stop the trailing stop on BTC.
	function test_settingOnOneMarket_leavesAnotherMarketAlone() public {
		vm.startPrank(alice);
		registry.configure(ProtectRegistryV2.Mode.STOP, BTC, address(0), 50, 0);
		registry.configure(ProtectRegistryV2.Mode.HEDGE, SPCX, teth, 800, 2);
		vm.stopPrank();

		(ProtectRegistryV2.Mode btcMode, address btcSpot, uint16 btcTrail, uint16 btcLev,, bool btcOn) = registry.configs(alice, BTC);
		assertEq(uint8(btcMode), uint8(ProtectRegistryV2.Mode.STOP));
		assertEq(btcSpot, address(0));
		assertEq(btcTrail, 50);
		assertEq(btcLev, 0);
		assertTrue(btcOn);

		(ProtectRegistryV2.Mode spcxMode, address spcxSpot, uint16 spcxTrail, uint16 spcxLev,, bool spcxOn) = registry.configs(alice, SPCX);
		assertEq(uint8(spcxMode), uint8(ProtectRegistryV2.Mode.HEDGE));
		assertEq(spcxSpot, teth);
		assertEq(spcxTrail, 800);
		assertEq(spcxLev, 2);
		assertTrue(spcxOn);
	}

	function test_disablingOneMarket_leavesAnotherMarketOn() public {
		vm.startPrank(alice);
		registry.configure(ProtectRegistryV2.Mode.STOP, BTC, address(0), 50, 0);
		registry.configure(ProtectRegistryV2.Mode.HEDGE, SPCX, teth, 800, 2);
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
		registry.configure(ProtectRegistryV2.Mode.STOP, a, address(0), trailA, 0);
		registry.configure(ProtectRegistryV2.Mode.STOP, b, address(0), trailB, 0);
		assertEq(_trailing(alice, a), trailA);
		registry.disable(b);
		assertEq(_trailing(alice, a), trailA);
		assertTrue(_enabled(alice, a));
		vm.stopPrank();
	}

	function test_configure_hedge_storesAndEmits() public {
		vm.expectEmit(true, true, false, true);
		emit ProtectConfigured(alice, SPCX, ProtectRegistryV2.Mode.HEDGE, teth, 800, 2, true);
		vm.prank(alice);
		registry.configure(ProtectRegistryV2.Mode.HEDGE, SPCX, teth, 800, 2);
		assertTrue(_enabled(alice, SPCX));
	}

	function test_configure_stampsTheTime() public {
		vm.warp(1_800_000_000);
		vm.prank(alice);
		registry.configure(ProtectRegistryV2.Mode.STOP, BTC, address(0), 500, 0);
		(,,,, uint40 updatedAt,) = registry.configs(alice, BTC);
		assertEq(updatedAt, 1_800_000_000);
	}

	function test_configure_stop_needsNoSpotAssetOrLeverage() public {
		vm.prank(alice);
		registry.configure(ProtectRegistryV2.Mode.STOP, 86, address(0), 500, 0);
		assertEq(_trailing(alice, 86), 500);
		assertTrue(_enabled(alice, 86));
	}

	function test_configure_validation() public {
		vm.startPrank(alice);
		vm.expectRevert(ProtectRegistryV2.BadTrailing.selector);
		registry.configure(ProtectRegistryV2.Mode.STOP, 0, address(0), 0, 0);
		vm.expectRevert(ProtectRegistryV2.BadTrailing.selector);
		registry.configure(ProtectRegistryV2.Mode.STOP, 0, address(0), 10_000, 0);
		vm.expectRevert(ProtectRegistryV2.SpotAssetRequired.selector);
		registry.configure(ProtectRegistryV2.Mode.HEDGE, 0, address(0), 800, 2);
		vm.expectRevert(ProtectRegistryV2.BadLeverage.selector);
		registry.configure(ProtectRegistryV2.Mode.HEDGE, 0, teth, 800, 0);
		vm.expectRevert(ProtectRegistryV2.BadLeverage.selector);
		registry.configure(ProtectRegistryV2.Mode.HEDGE, 0, teth, 800, 11);
		vm.stopPrank();
		assertEq(registry.pairsOf(alice).length, 0);
	}

	function test_neutral_validatesLikeHedge() public {
		vm.startPrank(alice);
		vm.expectRevert(ProtectRegistryV2.SpotAssetRequired.selector);
		registry.configure(ProtectRegistryV2.Mode.NEUTRAL, 0, address(0), 500, 2);
		vm.expectRevert(ProtectRegistryV2.BadLeverage.selector);
		registry.configure(ProtectRegistryV2.Mode.NEUTRAL, 0, teth, 500, 0);
		registry.configure(ProtectRegistryV2.Mode.NEUTRAL, 0, teth, 500, 2);
		vm.stopPrank();
		assertTrue(_enabled(alice, 0));
	}

	function test_disable_keepsConfigForReenable() public {
		vm.startPrank(alice);
		registry.configure(ProtectRegistryV2.Mode.HEDGE, SPCX, teth, 800, 2);
		vm.expectEmit(true, true, false, true);
		emit ProtectConfigured(alice, SPCX, ProtectRegistryV2.Mode.HEDGE, teth, 800, 2, false);
		registry.disable(SPCX);
		vm.stopPrank();
		assertFalse(_enabled(alice, SPCX));
		assertEq(_trailing(alice, SPCX), 800);
	}

	function test_disable_aPairNeverConfiguredReverts() public {
		vm.prank(alice);
		registry.configure(ProtectRegistryV2.Mode.STOP, BTC, address(0), 50, 0);
		vm.prank(alice);
		vm.expectRevert(ProtectRegistryV2.NotConfigured.selector);
		registry.disable(SPCX);
	}

	function test_pairsOf_listsEachPairOnce_andKeepsDisabledOnes() public {
		vm.startPrank(alice);
		registry.configure(ProtectRegistryV2.Mode.STOP, BTC, address(0), 50, 0);
		registry.configure(ProtectRegistryV2.Mode.HEDGE, SPCX, teth, 800, 2);
		registry.configure(ProtectRegistryV2.Mode.STOP, BTC, address(0), 75, 0);
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
		registry.configure(ProtectRegistryV2.Mode.STOP, BTC, address(0), 50, 0);
		assertFalse(_enabled(bob, BTC));
		assertEq(registry.pairsOf(bob).length, 0);
		vm.prank(bob);
		vm.expectRevert(ProtectRegistryV2.NotConfigured.selector);
		registry.disable(BTC);
		assertTrue(_enabled(alice, BTC));
	}

	function test_configureFor_fundManagerProtectsTheFundPosition() public {
		address manager = makeAddr('manager');
		address position = address(new MockProtectedPositionV2(address(new MockProtectComptrollerV2(manager))));
		vm.startPrank(manager);
		registry.configureFor(position, ProtectRegistryV2.Mode.STOP, BTC, address(0), 50, 0);
		registry.configureFor(position, ProtectRegistryV2.Mode.HEDGE, SPCX, teth, 800, 2);
		registry.disableFor(position, SPCX);
		vm.stopPrank();
		assertTrue(_enabled(position, BTC));
		assertFalse(_enabled(position, SPCX));
		assertEq(registry.pairsOf(position).length, 2);
		assertFalse(_enabled(manager, BTC));
	}

	function test_configureFor_rejectsNonOwnersAndNonPositions() public {
		address manager = makeAddr('manager');
		address position = address(new MockProtectedPositionV2(address(new MockProtectComptrollerV2(manager))));
		vm.prank(manager);
		registry.configureFor(position, ProtectRegistryV2.Mode.STOP, BTC, address(0), 50, 0);

		vm.startPrank(alice);
		vm.expectRevert(ProtectRegistryV2.NotFundOwner.selector);
		registry.configureFor(position, ProtectRegistryV2.Mode.STOP, SPCX, address(0), 50, 0);
		vm.expectRevert(ProtectRegistryV2.NotFundOwner.selector);
		registry.disableFor(position, BTC);
		vm.expectRevert(ProtectRegistryV2.NotFundOwner.selector);
		registry.configureFor(makeAddr('notAPosition'), ProtectRegistryV2.Mode.STOP, BTC, address(0), 50, 0);
		vm.stopPrank();
		assertTrue(_enabled(position, BTC));
		assertFalse(_enabled(position, SPCX));
	}
}
