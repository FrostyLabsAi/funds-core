// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {ComptrollerLib} from '../../src/core/ComptrollerLib.sol';
import {RedemptionQueue} from '../../src/redemption/RedemptionQueue.sol';
import {ERC4626ExitAdapter} from '../../src/adapters/ERC4626ExitAdapter.sol';
import {BaseMainnet} from '../../script/release/BaseMainnet.sol';
import {ReleaseFork} from './utils/ReleaseFork.sol';

/// @notice A ghosted fund's ERC-4626 shares (founder 2026-10-14): the keeper exits Aave's static USDC vault (no route:
///         the redeem pays USDC) and static WETH vault (redeem, then WETH → USDC on Slipstream-1) through
///         ERC4626ExitAdapter, within the 3% cap, and the leaver is paid in USDC. The release on Base at block 52,607,800,
///         both vaults listed on the release's ERC4626PriceFeed as the live VI listed them; a 1-second deadline queue.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/ERC4626ExitFork.t.sol -vv
contract ERC4626ExitForkTest is ReleaseFork {
	address internal constant STATIC_USDC = 0xC768c589647798a6EE01A91FdE98EF2ed046DBD6;
	address internal constant STATIC_WETH = 0xe298b938631f750DD409fB18227C4a23dCdaab9b;
	address internal constant CBBTC = BaseMainnet.CBBTC;
	address internal constant SLIPSTREAM1_ROUTER = BaseMainnet.CL_SWAP_ROUTER;

	RedemptionQueue internal queue;
	ERC4626ExitAdapter internal exitAdapter;
	address internal erc4626Adapter;

	function _forkBlock() internal pure override returns (uint256) {
		return 52_607_800;
	}

	function setUp() public override {
		super.setUp();
		if (!forked) return;
		_listDerivative(STATIC_USDC, address(r.erc4626Feed));
		_listDerivative(STATIC_WETH, address(r.erc4626Feed));
		queue = _shortDeadlineQueue();
		exitAdapter = r.adapters.erc4626Exit;
		erc4626Adapter = address(r.adapters.erc4626);
	}

	function test_fork_keeperExitsUsdcAndWethVaultSharesIntoUsdc() public {
		vm.skip(!forked);
		Comptroller fund = _fundIn4626Vaults();
		address v = address(fund.vault());
		uint256 usdcShares = IERC20(STATIC_USDC).balanceOf(v);
		uint256 wethShares = IERC20(STATIC_WETH).balanceOf(v);
		_overdueRedemption(fund, queue);

		uint256 gavBefore = fund.calcGav();
		vm.startPrank(keeper);
		queue.liquidate(address(fund), address(exitAdapter), _exit(STATIC_USDC, usdcShares, new ERC4626ExitAdapter.Route[](0)));
		queue.liquidate(address(fund), address(exitAdapter), _exit(STATIC_WETH, wethShares, _wethToUsdc()));
		vm.stopPrank();
		assertEq(IERC20(STATIC_USDC).balanceOf(v), 0, 'every static USDC share exited');
		assertEq(IERC20(STATIC_WETH).balanceOf(v), 0, 'every static WETH share exited');
		assertEq(IERC20(WETH).balanceOf(v), 0, 'no WETH came back: it was sold');
		assertEq(IERC20(WETH).balanceOf(address(exitAdapter)), 0);
		assertEq(IERC20(USDC).balanceOf(address(exitAdapter)), 0);
		uint256 gavAfter = fund.calcGav();
		emit log_named_int('exit cost vs oracle value (USDC, 6 decimals)', int256(gavBefore) - int256(gavAfter));
		assertGt(gavAfter, gavBefore * 9_970 / 10_000, 'within the 3% cap, and far under it');
		assertApproxEqAbs(IERC20(USDC).balanceOf(v), gavAfter, 1, 'the fund is all USDC');

		uint256 shares = fund.shares().balanceOf(address(queue));
		uint256 supply = fund.shares().totalSupply();
		vm.prank(keeper);
		assertEq(queue.settle(address(fund), 1), 1);
		assertApproxEqAbs(IERC20(USDC).balanceOf(investor), gavAfter * shares / supply, 2, 'paid in USDC');
	}

	/// Two hops, WETH → cbBTC → USDC on Slipstream-1's ts100 pools: SlipstreamSell's router check passes on a whole fill
	/// and nothing stays in the router (review 2026-10-14).
	function test_fork_aTwoHopRouteExitsAndLeavesNothingInTheRouter() public {
		vm.skip(!forked);
		Comptroller fund = _fundIn4626Vaults();
		address v = address(fund.vault());
		uint256 wethShares = IERC20(STATIC_WETH).balanceOf(v);
		_overdueRedemption(fund, queue);
		ERC4626ExitAdapter.Route[] memory routes = new ERC4626ExitAdapter.Route[](1);
		routes[0] = ERC4626ExitAdapter.Route(
			SLIPSTREAM1_ROUTER, abi.encodePacked(WETH, int24(100), CBBTC, int24(100), USDC)
		);
		uint256 routerBtc = IERC20(CBBTC).balanceOf(SLIPSTREAM1_ROUTER);
		uint256 gavBefore = fund.calcGav();
		vm.prank(keeper);
		queue.liquidate(address(fund), address(exitAdapter), _exit(STATIC_WETH, wethShares, routes));
		assertEq(IERC20(STATIC_WETH).balanceOf(v), 0);
		assertEq(IERC20(CBBTC).balanceOf(v), 0, 'no cbBTC came back');
		assertEq(IERC20(CBBTC).balanceOf(SLIPSTREAM1_ROUTER), routerBtc, 'none left in the router');
		emit log_named_int('exit cost vs oracle value (USDC, 6 decimals)', int256(gavBefore) - int256(fund.calcGav()));
		assertGt(fund.calcGav(), gavBefore * 9_970 / 10_000, 'within the 3% cap, and far under it');
	}

	/// The plain ERC4626Adapter redeem returns WETH, which isn't a sale (ComptrollerLib._checkSale): why this adapter.
	function test_fork_aPlainRedeemIntoWethIsNotASale() public {
		vm.skip(!forked);
		Comptroller fund = _fundIn4626Vaults();
		uint256 wethShares = IERC20(STATIC_WETH).balanceOf(address(fund.vault()));
		_overdueRedemption(fund, queue);
		vm.prank(keeper);
		vm.expectRevert(ComptrollerLib.NotASale.selector);
		queue.liquidate(address(fund), erc4626Adapter, abi.encode(uint8(1), STATIC_WETH, wethShares, uint256(0)));
	}

	function _exit(address vault4626, uint256 shares, ERC4626ExitAdapter.Route[] memory routes)
		internal
		pure
		returns (bytes memory)
	{
		return abi.encode(vault4626, shares, uint256(0), USDC, routes);
	}

	/// @dev WETH → USDC on Slipstream-1's ts100 pool.
	function _wethToUsdc() internal pure returns (ERC4626ExitAdapter.Route[] memory routes) {
		routes = new ERC4626ExitAdapter.Route[](1);
		routes[0] = ERC4626ExitAdapter.Route(SLIPSTREAM1_ROUTER, abi.encodePacked(WETH, int24(100), USDC));
	}

	/// @dev 20k USDC in; the manager puts 8k in Aave's static USDC vault and buys ~8k of WETH for the static WETH vault.
	function _fundIn4626Vaults() internal returns (Comptroller fund) {
		fund = _fundWithDeposit(20_000e6);
		address v = address(fund.vault());
		vm.startPrank(manager);
		fund.callOnIntegration(erc4626Adapter, abi.encode(uint8(0), STATIC_USDC, uint256(8_000e6), uint256(0)));
		fund.callOnIntegration(address(r.adapters.uniswapV3), abi.encode(USDC, WETH, uint24(500), uint256(8_000e6), uint256(0)));
		fund.callOnIntegration(erc4626Adapter, abi.encode(uint8(0), STATIC_WETH, IERC20(WETH).balanceOf(v), uint256(0)));
		vm.stopPrank();
		assertGt(IERC20(STATIC_USDC).balanceOf(v), 0);
		assertGt(IERC20(STATIC_WETH).balanceOf(v), 0);
		assertEq(IERC20(WETH).balanceOf(v), 0);
	}
}
