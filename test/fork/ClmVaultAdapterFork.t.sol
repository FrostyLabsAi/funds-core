// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {IFrostyClmVault} from '../../src/interfaces/external/IFrostyClm.sol';
import {ClmVaultAdapter} from '../../src/adapters/ClmVaultAdapter.sol';
import {ClmVaultPriceFeed} from '../../src/pricing/ClmVaultPriceFeed.sol';
import {ReleaseFork} from './utils/ReleaseFork.sol';
import {ClmFixture, MockClmVi} from './utils/ClmFixture.sol';

/// @notice A fund deposits into and leaves a FrostyFi CLM vault (built from funds-yield's own artifacts) through the
///         release's ClmVaultAdapter, valued by a ClmVaultPriceFeed on the release's VI (Base fork, block 52,385,115).
///         Plus a Slipstream-1 pair with no USDC side, exited to USDC in one action.
contract ClmVaultAdapterForkTest is ReleaseFork, ClmFixture {
	bool internal ready;
	address internal poolDeployer;
	ClmVaultAdapter internal adapter;
	ClmVaultPriceFeed internal feed;
	address internal clmVault;
	address internal clmStrategy;

	function _forkBlock() internal pure virtual override returns (uint256) {
		return 52_385_115;
	}

	function setUp() public virtual override {
		if (!_clmReady()) return;
		super.setUp();
		if (!forked) return;
		ready = true;
		address strategyFactory;
		(strategyFactory, poolDeployer) = _deployClm(keeper, address(new MockClmVi()));
		(clmVault, clmStrategy) = _deployCbBtcVault(poolDeployer);
		feed = new ClmVaultPriceFeed(r.valueInterpreter, strategyFactory, address(r.registrar));
		adapter = r.adapters.clm;
		_listDerivative(clmVault, address(feed));
	}

	/// @dev The exit route for the cbBTC vault: cbBTC → USDC on its own Slipstream-2 pool (ts50).
	function _cbBtcExit(uint256 shares) internal view returns (bytes memory) {
		ClmVaultAdapter.Route[] memory routes = new ClmVaultAdapter.Route[](1);
		routes[0] = ClmVaultAdapter.Route(SLIPSTREAM2_ROUTER, abi.encodePacked(CBBTC, int24(50), USDC));
		return abi.encode(uint8(2), clmVault, shares, uint256(0), USDC, routes);
	}

	function _fund(uint256 amount) internal returns (Comptroller fund) {
		fund = _fundWithDeposit(amount);
	}

	/// @dev The manager buys cbBTC with part of the USDC, then deposits both into the CLM vault.
	function _managerDeposits(Comptroller fund, uint256 usdcForBtc) internal {
		vm.startPrank(manager);
		fund.callOnIntegration(
			address(r.adapters.slipstream2), abi.encode(USDC, CBBTC, int24(50), usdcForBtc, uint256(0), uint256(0))
		);
		_settle(clmStrategy);
		address v = address(fund.vault());
		fund.callOnIntegration(
			address(adapter),
			abi.encode(uint8(0), clmVault, IERC20(USDC).balanceOf(v), IERC20(CBBTC).balanceOf(v), uint256(0))
		);
		vm.stopPrank();
	}

	function test_deposit_returnsLeftoversAndKeepsNothing() public {
		vm.skip(!ready);
		// Seed the vault first: an empty vault's first deposit takes both amounts whole, so nothing would be left over.
		deal(USDC, address(this), 10_000e6);
		_buyCbBtc(address(this), 0.05e8);
		_settle(clmStrategy);
		IERC20(USDC).approve(clmVault, type(uint256).max);
		IERC20(CBBTC).approve(clmVault, type(uint256).max);
		IFrostyClmVault(clmVault).deposit(IERC20(USDC).balanceOf(address(this)), 0.05e8, 0);
		_settle(clmStrategy);

		Comptroller fund = _fund(20_000e6);
		uint256 gavBefore = fund.calcGav();
		_managerDeposits(fund, 5_000e6); // ~15k USDC + ~5k of cbBTC: the vault's ratio leaves USDC over
		address v = address(fund.vault());
		assertGt(IFrostyClmVault(clmVault).balanceOf(v), 0, 'the fund holds vault shares');
		assertGt(IERC20(USDC).balanceOf(v), 0, 'the USDC the ratio did not take came back to the fund');
		assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
		assertEq(IERC20(CBBTC).balanceOf(address(adapter)), 0);
		assertEq(IFrostyClmVault(clmVault).balanceOf(address(adapter)), 0);
		// The swap's pool fee and the vault's imbalance fee cost a little: within 0.5% of GAV.
		assertApproxEqRel(fund.calcGav(), gavBefore, 0.005e18, 'NAV carries the vault shares at oracle value');
	}

	function test_withdraw_bringsBothTokensBack() public {
		vm.skip(!ready);
		Comptroller fund = _fund(20_000e6);
		_managerDeposits(fund, 10_000e6);
		address v = address(fund.vault());
		uint256 shares = IFrostyClmVault(clmVault).balanceOf(v);
		_settle(clmStrategy);
		uint256 gavBefore = fund.calcGav();
		vm.prank(manager);
		fund.callOnIntegration(address(adapter), abi.encode(uint8(1), clmVault, shares, uint256(0), uint256(0)));
		assertEq(IFrostyClmVault(clmVault).balanceOf(v), 0);
		assertApproxEqRel(fund.calcGav(), gavBefore, 0.003e18);
	}

	function test_exit_sellsTheOtherSideIntoUsdc() public {
		vm.skip(!ready);
		Comptroller fund = _fund(20_000e6);
		_managerDeposits(fund, 10_000e6);
		address v = address(fund.vault());
		uint256 btcBefore = IERC20(CBBTC).balanceOf(v);
		uint256 shares = IFrostyClmVault(clmVault).balanceOf(v);
		_settle(clmStrategy);
		vm.prank(manager);
		fund.callOnIntegration(address(adapter), _cbBtcExit(shares));
		assertEq(IFrostyClmVault(clmVault).balanceOf(v), 0);
		assertEq(IERC20(CBBTC).balanceOf(v), btcBefore, 'no cbBTC came back: it was sold');
		assertEq(IERC20(CBBTC).balanceOf(address(adapter)), 0);
	}

	/// @dev Slipstream-1 WETH/cbLTC (no USDC side), straight through the adapter as the Comptroller would call it:
	///      cbLTC → WETH → USDC and WETH → USDC on Slipstream-1, one action, nothing left behind.
	function test_exit_routesANonUsdcPairToUsdc() public {
		vm.skip(!ready);
		(address s1Vault, address s1Strategy) = _deployWethCbLtcVault(poolDeployer);
		deal(WETH, address(this), 5e18);
		_buyCbLtc(address(this), 50e8);
		_settle(s1Strategy);
		IERC20(WETH).approve(s1Vault, type(uint256).max);
		IERC20(CBLTC).approve(s1Vault, type(uint256).max);
		IFrostyClmVault(s1Vault).deposit(IERC20(WETH).balanceOf(address(this)), IERC20(CBLTC).balanceOf(address(this)), 0);
		uint256 shares = IFrostyClmVault(s1Vault).balanceOf(address(this));
		_settle(s1Strategy);

		ClmVaultAdapter.Route[] memory routes = new ClmVaultAdapter.Route[](2);
		routes[0] = ClmVaultAdapter.Route(SLIPSTREAM1_ROUTER, abi.encodePacked(CBLTC, int24(200), WETH, int24(100), USDC));
		routes[1] = ClmVaultAdapter.Route(SLIPSTREAM1_ROUTER, abi.encodePacked(WETH, int24(100), USDC));
		IERC20(s1Vault).transfer(address(adapter), shares); // what the Comptroller does before executeAction
		uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
		uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
		adapter.executeAction(address(this), abi.encode(uint8(2), s1Vault, shares, uint256(0), USDC, routes));

		assertGt(IERC20(USDC).balanceOf(address(this)) - usdcBefore, 0, 'paid in USDC');
		assertEq(IERC20(WETH).balanceOf(address(this)), wethBefore, 'no WETH came back');
		assertEq(IERC20(WETH).balanceOf(address(adapter)), 0);
		assertEq(IERC20(CBLTC).balanceOf(address(adapter)), 0);
		assertEq(IERC20(s1Vault).balanceOf(address(adapter)), 0);
	}

	function test_exit_withAMissingRouteReverts() public {
		vm.skip(!ready);
		Comptroller fund = _fund(20_000e6);
		_managerDeposits(fund, 10_000e6);
		uint256 shares = IFrostyClmVault(clmVault).balanceOf(address(fund.vault()));
		_settle(clmStrategy);
		ClmVaultAdapter.Route[] memory none = new ClmVaultAdapter.Route[](0);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(ClmVaultAdapter.Unsold.selector, CBBTC));
		fund.callOnIntegration(address(adapter), abi.encode(uint8(2), clmVault, shares, uint256(0), USDC, none));
	}
}
