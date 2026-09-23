// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {AdvisorRegistry} from '../src/protect/AdvisorRegistry.sol';

contract AdvisorRegistryTest is Test {
	AdvisorRegistry internal registry;
	address internal alice = makeAddr('alice');

	event AdvisorConfigured(address indexed trader, bool enabled, uint32 intervalSeconds, uint32 maxFeeMicroUsdc);

	function setUp() public {
		registry = new AdvisorRegistry();
	}

	function test_unset_meansKeeperDefaultPolicy() public view {
		(bool enabled,,, uint64 updatedAt) = registry.configs(alice);
		assertFalse(enabled);
		assertEq(updatedAt, 0); // the keeper reads updatedAt == 0 as "never configured"
	}

	function test_configure_storesAndEmits() public {
		vm.expectEmit(true, false, false, true);
		emit AdvisorConfigured(alice, true, 3600, 100_000);
		vm.prank(alice);
		registry.configure(true, 3600, 100_000);

		(bool enabled, uint32 intervalSeconds, uint32 maxFeeMicroUsdc, uint64 updatedAt) = registry.configs(alice);
		assertTrue(enabled);
		assertEq(intervalSeconds, 3600);
		assertEq(maxFeeMicroUsdc, 100_000); // $0.10 per call cap
		assertGt(updatedAt, 0);
	}

	function test_configure_zeroInterval_meansKeeperDefault() public {
		vm.prank(alice);
		registry.configure(true, 0, 50_000);
		(, uint32 intervalSeconds,,) = registry.configs(alice);
		assertEq(intervalSeconds, 0);
	}

	function test_configure_rejectsSpamCadence() public {
		vm.prank(alice);
		vm.expectRevert(AdvisorRegistry.BadInterval.selector);
		registry.configure(true, 299, 50_000);

		vm.prank(alice);
		registry.configure(true, 300, 50_000); // exactly the floor is fine
		(, uint32 intervalSeconds,,) = registry.configs(alice);
		assertEq(intervalSeconds, 300);
	}

	function test_zeroFeeCap_freeTransportsOnly() public {
		vm.prank(alice);
		registry.configure(true, 0, 0);
		(bool enabled,, uint32 maxFeeMicroUsdc,) = registry.configs(alice);
		assertTrue(enabled);
		assertEq(maxFeeMicroUsdc, 0);
	}

	function test_disable_keepsCadenceAndCapForReenable() public {
		vm.startPrank(alice);
		registry.configure(true, 3600, 100_000);
		vm.expectEmit(true, false, false, true);
		emit AdvisorConfigured(alice, false, 3600, 100_000);
		registry.disable();
		vm.stopPrank();

		(bool enabled, uint32 intervalSeconds, uint32 maxFeeMicroUsdc, uint64 updatedAt) = registry.configs(alice);
		assertFalse(enabled);
		assertEq(intervalSeconds, 3600); // retained
		assertEq(maxFeeMicroUsdc, 100_000);
		assertGt(updatedAt, 0); // an explicit opt-out is NOT "unset"
	}

	function test_configs_areStrictlyPerTrader() public {
		vm.prank(alice);
		registry.configure(true, 3600, 100_000);
		(bool enabledOther,,, uint64 updatedAtOther) = registry.configs(makeAddr('bob'));
		assertFalse(enabledOther);
		assertEq(updatedAtOther, 0);
	}

	function test_configureFor_fundManagerSetsTheFundPosition() public {
		MockAdvisorComptroller fundComptroller = new MockAdvisorComptroller(alice);
		MockAdvisorTrader position = new MockAdvisorTrader(address(fundComptroller));

		vm.prank(alice); // alice is the fundOwner
		registry.configureFor(address(position), true, 7200, 50_000);
		(bool enabled, uint32 intervalSeconds, uint32 maxFeeMicroUsdc,) = registry.configs(address(position));
		assertTrue(enabled);
		assertEq(intervalSeconds, 7200);
		assertEq(maxFeeMicroUsdc, 50_000);

		vm.prank(alice);
		registry.disableFor(address(position));
		(bool enabledAfter,,,) = registry.configs(address(position));
		assertFalse(enabledAfter);
	}

	function test_configureFor_rejectsNonOwnersAndNonPositions() public {
		MockAdvisorComptroller fundComptroller = new MockAdvisorComptroller(alice);
		MockAdvisorTrader position = new MockAdvisorTrader(address(fundComptroller));

		vm.prank(makeAddr('stranger'));
		vm.expectRevert(AdvisorRegistry.NotFundOwner.selector);
		registry.configureFor(address(position), true, 0, 0);

		vm.prank(makeAddr('stranger'));
		vm.expectRevert(AdvisorRegistry.NotFundOwner.selector);
		registry.disableFor(address(position));

		// An EOA "trader" has no comptroller() — rejected, users must self-configure
		vm.prank(alice);
		vm.expectRevert(AdvisorRegistry.NotFundOwner.selector);
		registry.configureFor(makeAddr('someEoa'), true, 0, 0);
	}
}

contract MockAdvisorComptroller {
	address public fundOwner;

	constructor(address fundOwner_) {
		fundOwner = fundOwner_;
	}
}

contract MockAdvisorTrader {
	address public comptroller;

	constructor(address comptroller_) {
		comptroller = comptroller_;
	}
}
