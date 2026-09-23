// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {ProtectRegistry} from '../src/protect/ProtectRegistry.sol';

contract ProtectRegistryTest is Test {
	ProtectRegistry internal registry;
	address internal alice = makeAddr('alice');
	address internal teth = makeAddr('tETH');

	event ProtectConfigured(
		address indexed user,
		ProtectRegistry.Mode mode,
		uint256 pairIndex,
		address spotAsset,
		uint16 trailingBps,
		uint16 leverageX,
		bool enabled
	);

	function setUp() public {
		registry = new ProtectRegistry();
	}

	function test_configure_hedge_storesAndEmits() public {
		vm.expectEmit(true, false, false, true);
		emit ProtectConfigured(alice, ProtectRegistry.Mode.HEDGE, 0, teth, 800, 2, true);
		vm.prank(alice);
		registry.configure(ProtectRegistry.Mode.HEDGE, 0, teth, 800, 2);

		(ProtectRegistry.Mode mode, uint256 pairIndex, address spotAsset, uint16 trailingBps, uint16 leverageX,, bool enabled)
			= registry.configs(alice);
		assertEq(uint8(mode), uint8(ProtectRegistry.Mode.HEDGE));
		assertEq(pairIndex, 0);
		assertEq(spotAsset, teth);
		assertEq(trailingBps, 800);
		assertEq(leverageX, 2);
		assertTrue(enabled);
	}

	function test_configure_stop_needsNoSpotAssetOrLeverage() public {
		vm.prank(alice);
		registry.configure(ProtectRegistry.Mode.STOP, 86, address(0), 500, 0);
		(,,, uint16 trailingBps,,, bool enabled) = registry.configs(alice);
		assertEq(trailingBps, 500);
		assertTrue(enabled);
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
	}

	function test_disable_keepsConfigForReenable() public {
		vm.startPrank(alice);
		registry.configure(ProtectRegistry.Mode.HEDGE, 0, teth, 800, 2);
		registry.disable();
		vm.stopPrank();

		(,, address spotAsset, uint16 trailingBps,,, bool enabled) = registry.configs(alice);
		assertFalse(enabled);
		assertEq(spotAsset, teth); // retained
		assertEq(trailingBps, 800);
	}

	function test_configs_areStrictlyPerUser() public {
		vm.prank(alice);
		registry.configure(ProtectRegistry.Mode.HEDGE, 0, teth, 800, 2);
		(,,,,,, bool enabledOther) = registry.configs(makeAddr('bob'));
		assertFalse(enabledOther);
	}

	function test_configureFor_fundManagerProtectsTheFundPosition() public {
		MockProtectComptroller fundComptroller = new MockProtectComptroller(alice);
		MockProtectTrader position = new MockProtectTrader(address(fundComptroller));

		vm.prank(alice); // alice is the fundOwner
		registry.configureFor(address(position), ProtectRegistry.Mode.STOP, 0, address(0), 500, 0);
		(,,, uint16 trailingBps,,, bool enabled) = registry.configs(address(position));
		assertEq(trailingBps, 500);
		assertTrue(enabled);

		vm.prank(alice);
		registry.disableFor(address(position));
		(,,,,,, bool enabledAfter) = registry.configs(address(position));
		assertFalse(enabledAfter);
	}

	function test_configureFor_rejectsNonOwnersAndNonPositions() public {
		MockProtectComptroller fundComptroller = new MockProtectComptroller(alice);
		MockProtectTrader position = new MockProtectTrader(address(fundComptroller));

		vm.prank(makeAddr('stranger'));
		vm.expectRevert(ProtectRegistry.NotFundOwner.selector);
		registry.configureFor(address(position), ProtectRegistry.Mode.STOP, 0, address(0), 500, 0);

		// An EOA "trader" has no comptroller() — rejected, users must self-configure
		vm.prank(alice);
		vm.expectRevert(ProtectRegistry.NotFundOwner.selector);
		registry.configureFor(makeAddr('someEoa'), ProtectRegistry.Mode.STOP, 0, address(0), 500, 0);
	}

	function test_neutralMode_reservedSlot_validatesLikeHedge() public {
		vm.prank(alice);
		vm.expectRevert(ProtectRegistry.SpotAssetRequired.selector);
		registry.configure(ProtectRegistry.Mode.NEUTRAL, 0, address(0), 500, 2);

		vm.prank(alice);
		registry.configure(ProtectRegistry.Mode.NEUTRAL, 0, teth, 500, 2);
		(ProtectRegistry.Mode mode,,,,,, bool enabled) = registry.configs(alice);
		assertEq(uint8(mode), uint8(ProtectRegistry.Mode.NEUTRAL));
		assertTrue(enabled);
	}
}

contract MockProtectComptroller {
	address public fundOwner;

	constructor(address fundOwner_) {
		fundOwner = fundOwner_;
	}
}

contract MockProtectTrader {
	address public comptroller;

	constructor(address comptroller_) {
		comptroller = comptroller_;
	}
}
