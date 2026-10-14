// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {ERC4626Mock} from '@openzeppelin/contracts/mocks/token/ERC4626Mock.sol';
import {ERC4626ExitAdapter} from '../src/adapters/ERC4626ExitAdapter.sol';
import {SlipstreamSell} from '../src/adapters/SlipstreamSell.sol';
import {MockERC20} from './utils/Mocks.sol';
import {MockSlipstreamRouter} from './utils/MockSlipstreamRouter.sol';

contract ERC4626ExitAdapterTest is Test {
	MockERC20 internal usdc = new MockERC20('USD Coin', 'USDC', 6);
	MockERC20 internal weth = new MockERC20('Wrapped Ether', 'WETH', 18);
	MockERC20 internal cbbtc = new MockERC20('Coinbase Wrapped BTC', 'cbBTC', 8);
	ERC4626Mock internal usdcVault = new ERC4626Mock(address(usdc));
	ERC4626Mock internal wethVault = new ERC4626Mock(address(weth));
	MockSlipstreamRouter internal router = new MockSlipstreamRouter();
	ERC4626ExitAdapter internal adapter;
	address internal fundVault = makeAddr('fundVault');

	function setUp() public {
		adapter = new ERC4626ExitAdapter(address(router), makeAddr('router2'), makeAddr('router3'));
		// the fund holds shares of both vaults; the comptroller would have moved them to the adapter before executeAction
		usdc.mint(address(this), 1_000e6);
		usdc.approve(address(usdcVault), 1_000e6);
		usdcVault.deposit(1_000e6, address(adapter));
		weth.mint(address(this), 10e18);
		weth.approve(address(wethVault), 10e18);
		wethVault.deposit(10e18, address(adapter));
	}

	function _route(address router_, address from, address to) internal pure returns (ERC4626ExitAdapter.Route[] memory routes) {
		routes = new ERC4626ExitAdapter.Route[](1);
		routes[0] = ERC4626ExitAdapter.Route({router: router_, path: abi.encodePacked(from, int24(100), to)});
	}

	function _exit(address vault, uint256 shares, ERC4626ExitAdapter.Route[] memory routes) internal view returns (bytes memory) {
		return abi.encode(vault, shares, uint256(7), address(usdc), routes);
	}

	function test_parse_sharesInOneAssetOut() public view {
		(address[] memory spend, uint256[] memory amounts, address[] memory incoming, uint256[] memory mins) =
			adapter.parseAssetsForAction(_exit(address(wethVault), 4e18, _route(address(router), address(weth), address(usdc))));
		assertEq(spend.length, 1);
		assertEq(spend[0], address(wethVault));
		assertEq(amounts[0], 4e18);
		assertEq(incoming.length, 1, 'one asset back: the shape a v6 liquidation sale needs');
		assertEq(incoming[0], address(usdc));
		assertEq(mins[0], 7);
	}

	function test_usdcVault_redeemsStraightIntoTheFund() public {
		uint256 shares = usdcVault.balanceOf(address(adapter));
		adapter.executeAction(fundVault, _exit(address(usdcVault), shares, new ERC4626ExitAdapter.Route[](0)));
		assertEq(usdc.balanceOf(fundVault), 1_000e6);
		assertEq(usdcVault.balanceOf(address(adapter)), 0);
		assertEq(usdc.balanceOf(address(adapter)), 0, 'holds nothing after a call');
	}

	function test_wethVault_redeemsThenSellsIntoUsdc() public {
		adapter.executeAction(fundVault, _exit(address(wethVault), 4e18, _route(address(router), address(weth), address(usdc))));
		assertEq(usdc.balanceOf(fundVault), 8e18, 'the router paid 2 units per WETH unit');
		assertEq(wethVault.balanceOf(address(adapter)), 6e18, 'only the given shares redeemed');
		assertEq(weth.balanceOf(address(adapter)), 0, 'every redeemed WETH sold');
		assertEq(usdc.balanceOf(address(adapter)), 0);
	}

	function test_partialFill_reverts_soNothingIsLeftForTheNextCaller() public {
		router.setFillBps(9_800);
		vm.expectRevert(abi.encodeWithSelector(SlipstreamSell.Unsold.selector, address(weth)));
		adapter.executeAction(fundVault, _exit(address(wethVault), 4e18, _route(address(router), address(weth), address(usdc))));
	}

	/// A later hop that fills part leaves its input in the router, whose sweepToken is anyone's (review 2026-10-14).
	function test_twoHops_aLaterHopsPartialFillReverts() public {
		ERC4626ExitAdapter.Route[] memory viaBtc = _route(address(router), address(weth), address(usdc));
		viaBtc[0].path = abi.encodePacked(address(weth), int24(100), address(cbbtc), int24(1), address(usdc));
		cbbtc.mint(address(router), 5); // dust the router already held doesn't count
		router.setMidLeftover(1);
		vm.expectRevert(abi.encodeWithSelector(SlipstreamSell.Unsold.selector, address(cbbtc)));
		adapter.executeAction(fundVault, _exit(address(wethVault), 4e18, viaBtc));

		router.setMidLeftover(0);
		adapter.executeAction(fundVault, _exit(address(wethVault), 4e18, viaBtc));
		assertEq(usdc.balanceOf(fundVault), 8e18, 'filled whole: paid');
		assertEq(cbbtc.balanceOf(address(router)), 5);
	}

	function test_routes_areCheckedBeforeAnythingMoves() public {
		ERC4626ExitAdapter.Route[] memory none = new ERC4626ExitAdapter.Route[](0);
		vm.expectRevert(abi.encodeWithSelector(ERC4626ExitAdapter.BadRoute.selector, 0));
		adapter.executeAction(fundVault, _exit(address(wethVault), 1e18, none)); // WETH needs a route to USDC

		vm.expectRevert(abi.encodeWithSelector(ERC4626ExitAdapter.BadRoute.selector, 0));
		adapter.executeAction(fundVault, _exit(address(usdcVault), 1e6, _route(address(router), address(usdc), address(weth)))); // USDC needs none

		vm.expectRevert(abi.encodeWithSelector(ERC4626ExitAdapter.NotARouter.selector, address(0xBAD)));
		adapter.executeAction(fundVault, _exit(address(wethVault), 1e18, _route(address(0xBAD), address(weth), address(usdc))));

		vm.expectRevert(abi.encodeWithSelector(ERC4626ExitAdapter.BadRoute.selector, 0));
		adapter.executeAction(fundVault, _exit(address(wethVault), 1e18, _route(address(router), address(usdc), address(usdc)))); // not from WETH

		vm.expectRevert(abi.encodeWithSelector(ERC4626ExitAdapter.BadRoute.selector, 0));
		adapter.executeAction(fundVault, _exit(address(wethVault), 1e18, _route(address(router), address(weth), address(weth)))); // not to USDC

		ERC4626ExitAdapter.Route[] memory bent = _route(address(router), address(weth), address(usdc));
		bent[0].path = abi.encodePacked(address(weth), int24(100), address(usdc), uint8(1));
		vm.expectRevert(abi.encodeWithSelector(ERC4626ExitAdapter.BadRoute.selector, 0));
		adapter.executeAction(fundVault, _exit(address(wethVault), 1e18, bent)); // malformed path

		assertEq(wethVault.balanceOf(address(adapter)), 10e18, 'nothing moved');
	}
}
