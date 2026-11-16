// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Comptroller} from '../src/core/Comptroller.sol';
import {FundProfileRegistry} from '../src/profile/FundProfileRegistry.sol';
import {RedemptionFixture} from './utils/RedemptionFixture.sol';

/// @notice A fund's links (founder 2026-10-11): only its owner publishes them, on a real fund v6.
contract FundProfileRegistryTest is RedemptionFixture {
	FundProfileRegistry internal profiles;
	string internal constant LINKS = '{"website":"https://example.com","x":"https://x.com/example"}';

	function setUp() public override {
		super.setUp();
		profiles = new FundProfileRegistry();
	}

	function test_theManagerPublishesTheFundsLinks() public {
		Comptroller fund = _fund();
		vm.expectEmit(address(profiles));
		emit FundProfileRegistry.ProfileSet(address(fund), LINKS);
		vm.prank(manager);
		profiles.setProfile(address(fund), LINKS);
		assertEq(profiles.profileOf(address(fund)), LINKS);
	}

	function test_onlyTheFundsOwner() public {
		Comptroller fund = _fund();
		_deposit(fund, alice, 1_000e6);
		vm.prank(alice); // an investor of the fund
		vm.expectRevert(FundProfileRegistry.NotFundOwner.selector);
		profiles.setProfile(address(fund), LINKS);
		vm.prank(stranger);
		vm.expectRevert(FundProfileRegistry.NotFundOwner.selector);
		profiles.setProfile(address(fund), LINKS);
		assertEq(bytes(profiles.profileOf(address(fund))).length, 0);
	}

	/// An address that is no fund (no code, or a contract without fundOwner) takes no record.
	function test_anAddressThatIsNoFundIsRefused() public {
		vm.prank(manager);
		vm.expectRevert();
		profiles.setProfile(address(0xbeef), LINKS);
		vm.prank(manager);
		vm.expectRevert();
		profiles.setProfile(address(usdc), LINKS);
	}

	function test_aRecordIsAtMost1024Bytes() public {
		Comptroller fund = _fund();
		string memory atCap = string(new bytes(1024));
		vm.prank(manager);
		profiles.setProfile(address(fund), atCap);
		assertEq(bytes(profiles.profileOf(address(fund))).length, 1024);

		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(FundProfileRegistry.ProfileTooLong.selector, 1025));
		profiles.setProfile(address(fund), string(new bytes(1025)));
	}

	function test_theManagerReplacesOrClearsTheLinks() public {
		Comptroller fund = _fund();
		vm.startPrank(manager);
		profiles.setProfile(address(fund), LINKS);
		profiles.setProfile(address(fund), '{"website":"https://example.org"}');
		assertEq(profiles.profileOf(address(fund)), '{"website":"https://example.org"}');
		profiles.setProfile(address(fund), '');
		vm.stopPrank();
		assertEq(bytes(profiles.profileOf(address(fund))).length, 0);
	}
}
