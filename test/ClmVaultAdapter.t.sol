// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {ClmVaultAdapter} from '../src/adapters/ClmVaultAdapter.sol';

contract MockClmVaultForAdapter {
	address internal t0;
	address internal t1;

	constructor(address t0_, address t1_) {
		t0 = t0_;
		t1 = t1_;
	}

	function wants() external view returns (address, address) {
		return (t0, t1);
	}

	function withdraw(uint256, uint256, uint256) external {}
}

contract ClmVaultAdapterTest is Test {
	address internal constant T0 = address(0xA0);
	address internal constant T1 = address(0xA1);
	address internal constant OUT = address(0xA0);
	address internal constant R1 = address(0xB1);
	address internal constant R2 = address(0xB2);
	address internal constant R3 = address(0xB3);
	ClmVaultAdapter internal adapter;
	address internal vault;

	function setUp() public {
		adapter = new ClmVaultAdapter(R1, R2, R3);
		vault = address(new MockClmVaultForAdapter(T0, T1));
	}

	function _exit(ClmVaultAdapter.Route[] memory routes) internal view returns (bytes memory) {
		return abi.encode(uint8(2), vault, uint256(11), uint256(22), OUT, routes);
	}

	function test_parse_deposit() public view {
		(address[] memory spend, uint256[] memory amounts, address[] memory incoming, uint256[] memory mins) =
			adapter.parseAssetsForAction(abi.encode(uint8(0), vault, uint256(11), uint256(22), uint256(33)));
		assertEq(spend.length, 2);
		assertEq(spend[0], T0);
		assertEq(spend[1], T1);
		assertEq(amounts[0], 11);
		assertEq(amounts[1], 22);
		assertEq(incoming.length, 1);
		assertEq(incoming[0], vault);
		assertEq(mins[0], 33);
	}

	function test_parse_withdraw() public view {
		(address[] memory spend, uint256[] memory amounts, address[] memory incoming, uint256[] memory mins) =
			adapter.parseAssetsForAction(abi.encode(uint8(1), vault, uint256(11), uint256(22), uint256(33)));
		assertEq(spend.length, 1);
		assertEq(spend[0], vault);
		assertEq(amounts[0], 11);
		assertEq(incoming.length, 2);
		assertEq(incoming[0], T0);
		assertEq(incoming[1], T1);
		assertEq(mins[0], 22);
		assertEq(mins[1], 33);
	}

	function test_parse_exit_oneIncomingAsset() public view {
		ClmVaultAdapter.Route[] memory routes = new ClmVaultAdapter.Route[](1);
		routes[0] = ClmVaultAdapter.Route(R2, abi.encodePacked(T1, int24(50), OUT));
		(address[] memory spend, uint256[] memory amounts, address[] memory incoming, uint256[] memory mins) =
			adapter.parseAssetsForAction(_exit(routes));
		assertEq(spend.length, 1);
		assertEq(spend[0], vault);
		assertEq(amounts[0], 11);
		assertEq(incoming.length, 1, 'one asset: what the v6 keeper sale rule needs');
		assertEq(incoming[0], OUT);
		assertEq(mins[0], 22);
	}

	function test_parse_unknownAction_reverts() public {
		vm.expectRevert(ClmVaultAdapter.UnknownAction.selector);
		adapter.parseAssetsForAction(abi.encode(uint8(3), vault, uint256(0), uint256(0), uint256(0)));
	}

	function test_exit_refusesAnUnknownRouter() public {
		ClmVaultAdapter.Route[] memory routes = new ClmVaultAdapter.Route[](1);
		routes[0] = ClmVaultAdapter.Route(address(0xBAD), abi.encodePacked(T1, int24(50), OUT));
		vm.expectRevert(abi.encodeWithSelector(ClmVaultAdapter.NotARouter.selector, address(0xBAD)));
		adapter.executeAction(address(this), _exit(routes));
	}

	function test_exit_refusesARouteEndingElsewhere() public {
		ClmVaultAdapter.Route[] memory routes = new ClmVaultAdapter.Route[](1);
		routes[0] = ClmVaultAdapter.Route(R1, abi.encodePacked(T1, int24(50), address(0xCC)));
		vm.expectRevert(abi.encodeWithSelector(ClmVaultAdapter.BadRoute.selector, 0));
		adapter.executeAction(address(this), _exit(routes));
	}

	function test_exit_refusesARouteFromAnotherToken() public {
		ClmVaultAdapter.Route[] memory routes = new ClmVaultAdapter.Route[](1);
		routes[0] = ClmVaultAdapter.Route(R1, abi.encodePacked(address(0xDD), int24(50), OUT));
		vm.expectRevert(abi.encodeWithSelector(ClmVaultAdapter.BadRoute.selector, 0));
		adapter.executeAction(address(this), _exit(routes));
	}

	function test_exit_refusesAMalformedPath() public {
		ClmVaultAdapter.Route[] memory routes = new ClmVaultAdapter.Route[](1);
		routes[0] = ClmVaultAdapter.Route(R1, abi.encodePacked(T1, OUT));
		vm.expectRevert(abi.encodeWithSelector(ClmVaultAdapter.BadRoute.selector, 0));
		adapter.executeAction(address(this), _exit(routes));
	}

	function test_constructor_rejectsZero() public {
		vm.expectRevert(ClmVaultAdapter.ZeroAddress.selector);
		new ClmVaultAdapter(address(0), R2, R3);
		vm.expectRevert(ClmVaultAdapter.ZeroAddress.selector);
		new ClmVaultAdapter(R1, address(0), R3);
		vm.expectRevert(ClmVaultAdapter.ZeroAddress.selector);
		new ClmVaultAdapter(R1, R2, address(0));
	}
}
