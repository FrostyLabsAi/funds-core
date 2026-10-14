// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {ClmVaultExitAdapter} from '../src/adapters/ClmVaultExitAdapter.sol';
import {SlipstreamSell} from '../src/adapters/SlipstreamSell.sol';
import {MockERC20} from './utils/Mocks.sol';
import {MockSlipstreamRouter} from './utils/MockSlipstreamRouter.sol';

/// @dev A CLM vault stand-in: a withdrawal pays out what it holds of both tokens.
contract MockClmVaultForExit {
	MockERC20 internal t0;
	MockERC20 internal t1;

	constructor(MockERC20 t0_, MockERC20 t1_) {
		t0 = t0_;
		t1 = t1_;
	}

	function wants() external view returns (address, address) {
		return (address(t0), address(t1));
	}

	function withdraw(uint256, uint256, uint256) external {
		t0.transfer(msg.sender, t0.balanceOf(address(this)));
		t1.transfer(msg.sender, t1.balanceOf(address(this)));
	}
}

contract ClmVaultExitAdapterTest is Test {
	MockERC20 internal usdc = new MockERC20('USD Coin', 'USDC', 6);
	MockERC20 internal weth = new MockERC20('Wrapped Ether', 'WETH', 18);
	MockERC20 internal cbltc = new MockERC20('Coinbase Wrapped LTC', 'cbLTC', 8);
	MockSlipstreamRouter internal router = new MockSlipstreamRouter();
	ClmVaultExitAdapter internal adapter;
	address internal clmVault;
	address internal fundVault = makeAddr('fundVault');

	function setUp() public {
		adapter = new ClmVaultExitAdapter(address(router), makeAddr('router2'), makeAddr('router3'));
		clmVault = address(new MockClmVaultForExit(weth, cbltc)); // a pair with no USDC side
		weth.mint(clmVault, 3e18);
		cbltc.mint(clmVault, 5e8);
	}

	function _exit(ClmVaultExitAdapter.Route[] memory routes) internal view returns (bytes memory) {
		return abi.encode(uint8(2), clmVault, uint256(11), uint256(22), address(usdc), routes);
	}

	/// @dev cbLTC → WETH → USDC, then WETH → USDC (the withdrawn WETH and what the first route bought of it).
	function _routes() internal view returns (ClmVaultExitAdapter.Route[] memory routes) {
		routes = new ClmVaultExitAdapter.Route[](2);
		routes[0] = ClmVaultExitAdapter.Route(
			address(router), abi.encodePacked(address(cbltc), int24(200), address(weth), int24(100), address(usdc))
		);
		routes[1] = ClmVaultExitAdapter.Route(address(router), abi.encodePacked(address(weth), int24(100), address(usdc)));
	}

	function test_parse_exitOnly_oneIncomingAsset() public {
		(address[] memory spend, uint256[] memory amounts, address[] memory incoming, uint256[] memory mins) =
			adapter.parseAssetsForAction(_exit(_routes()));
		assertEq(spend.length, 1);
		assertEq(spend[0], clmVault);
		assertEq(amounts[0], 11);
		assertEq(incoming.length, 1, 'one asset: what the v6 keeper sale rule needs');
		assertEq(incoming[0], address(usdc));
		assertEq(mins[0], 22);
		vm.expectRevert(ClmVaultExitAdapter.UnknownAction.selector);
		adapter.parseAssetsForAction(abi.encode(uint8(1), clmVault, uint256(11), uint256(22), address(usdc), _routes()));
		vm.expectRevert(ClmVaultExitAdapter.UnknownAction.selector);
		adapter.executeAction(fundVault, abi.encode(uint8(0), clmVault, uint256(11), uint256(22), address(usdc), _routes()));
	}

	function test_exit_sellsBothSidesAndPaysOnlyUsdc() public {
		adapter.executeAction(fundVault, _exit(_routes()));
		// 5e8 cbLTC → 10e8 USDC units (the mock pays 2 per unit, whole path); 3e18 WETH → 6e18
		assertEq(usdc.balanceOf(fundVault), 10e8 + 6e18);
		assertEq(weth.balanceOf(fundVault), 0);
		assertEq(cbltc.balanceOf(fundVault), 0);
		assertEq(weth.balanceOf(address(adapter)), 0);
		assertEq(cbltc.balanceOf(address(adapter)), 0);
		assertEq(usdc.balanceOf(address(adapter)), 0, 'holds nothing after a call');
	}

	function test_exit_aLaterHopsPartialFillReverts() public {
		router.setMidLeftover(1);
		vm.expectRevert(abi.encodeWithSelector(SlipstreamSell.Unsold.selector, address(weth)));
		adapter.executeAction(fundVault, _exit(_routes()));
	}

	function test_exit_aFirstHopsPartialFillReverts() public {
		router.setFillBps(9_000);
		vm.expectRevert(abi.encodeWithSelector(SlipstreamSell.Unsold.selector, address(cbltc)));
		adapter.executeAction(fundVault, _exit(_routes()));
	}

	function test_exit_aTokenWithoutARouteReverts() public {
		ClmVaultExitAdapter.Route[] memory wethOnly = new ClmVaultExitAdapter.Route[](1);
		wethOnly[0] = _routes()[1];
		vm.expectRevert(abi.encodeWithSelector(SlipstreamSell.Unsold.selector, address(cbltc)));
		adapter.executeAction(fundVault, _exit(wethOnly));
	}

	function test_exit_routesAreChecked() public {
		ClmVaultExitAdapter.Route[] memory routes = _routes();
		routes[1].router = address(0xBAD);
		vm.expectRevert(abi.encodeWithSelector(ClmVaultExitAdapter.NotARouter.selector, address(0xBAD)));
		adapter.executeAction(fundVault, _exit(routes));

		routes = _routes();
		routes[1].path = abi.encodePacked(address(usdc), int24(100), address(usdc)); // from no pool token
		vm.expectRevert(abi.encodeWithSelector(ClmVaultExitAdapter.BadRoute.selector, 1));
		adapter.executeAction(fundVault, _exit(routes));

		routes = _routes();
		routes[0].path = abi.encodePacked(address(cbltc), int24(200), address(weth)); // ends elsewhere
		vm.expectRevert(abi.encodeWithSelector(ClmVaultExitAdapter.BadRoute.selector, 0));
		adapter.executeAction(fundVault, _exit(routes));

		routes = _routes();
		routes[1].path = abi.encodePacked(address(weth), int24(100), address(usdc), uint8(1)); // malformed
		vm.expectRevert(abi.encodeWithSelector(ClmVaultExitAdapter.BadRoute.selector, 1));
		adapter.executeAction(fundVault, _exit(routes));
	}

	function test_constructor_rejectsZero() public {
		vm.expectRevert(ClmVaultExitAdapter.ZeroAddress.selector);
		new ClmVaultExitAdapter(address(0), address(1), address(2));
	}
}
