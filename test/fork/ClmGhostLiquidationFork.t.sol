// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ComptrollerV6} from '../../src/core/ComptrollerV6.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {RedemptionQueueV2} from '../../src/redemption/RedemptionQueueV2.sol';
import {IFrostyClmVault} from '../../src/interfaces/external/IFrostyClm.sol';
import {ClmVaultExitAdapter} from '../../src/adapters/ClmVaultExitAdapter.sol';
import {RedemptionQueueV2ShortDeadline} from '../utils/RedemptionQueueV2ShortDeadline.sol';
import {ClmVaultAdapterForkTest} from './ClmVaultAdapterFork.t.sol';

/// @notice D2 (founder 2026-10-11): a v6 fund's yield lives in CLM vault shares, so when its manager ghosts, the
///         keeper's existing liquidation must turn them into USDC and the leaver must be paid in USDC. The keeper exits
///         through ClmVaultExitAdapter (review 2026-10-14: no route leaves a token unsold in the router).
contract ClmGhostLiquidationForkTest is ClmVaultAdapterForkTest {
	RedemptionQueueV2 internal queue;
	ClmVaultExitAdapter internal exitAdapter;

	function setUp() public override {
		super.setUp();
		if (!ready) return;
		queue = new RedemptionQueueV2ShortDeadline(address(this));
		queue.setFactory(address(factory));
		queue.setKeeper(keeper, true);
		ComptrollerBlueprintDeployer shortDeployer = new ComptrollerBlueprintDeployer(
			type(ComptrollerV6).creationCode, abi.encode(registrarV2, queue, perpConfig)
		);
		exitAdapter = new ClmVaultExitAdapter(SLIPSTREAM1_ROUTER, SLIPSTREAM2_ROUTER, SLIPSTREAM3_ROUTER);
		vm.startPrank(deployer);
		factory.setComptrollerDeployer(shortDeployer);
		factory.registerAdapter(address(exitAdapter));
		vm.stopPrank();
	}

	function test_keeperExitsAGhostedFundsVaultShares() public {
		vm.skip(!ready);
		ComptrollerV6 fund = _fund(20_000e6);
		_managerDeposits(fund, 10_000e6);
		address v = address(fund.vault());
		uint256 clmShares = IFrostyClmVault(clmVault).balanceOf(v);
		assertGt(clmShares, 0);

		uint256 fundShares = fund.shares().balanceOf(investor) / 2;
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(address(queue), fundShares);
		queue.requestRedeem(address(fund), fundShares);
		vm.stopPrank();
		_settle(clmStrategy); // the deadline (short) passes, and the vault's calm/stake-time checks are clear
		vm.roll(block.number + 1);
		assertTrue(queue.isOverdue(address(fund)));

		uint256 gavBefore = fund.calcGav();
		vm.prank(keeper);
		queue.liquidate(address(fund), address(exitAdapter), _cbBtcExit(clmShares)); // same integrationData as action 2
		assertEq(IFrostyClmVault(clmVault).balanceOf(v), 0, 'every vault share exited');
		uint256 gavAfter = fund.calcGav();
		emit log_named_uint('exit cost vs oracle value (USDC, 6 decimals)', gavBefore - gavAfter);
		assertGt(gavAfter, gavBefore * 9_970 / 10_000, 'within the 3% cap, and far under it');

		uint256 supply = fund.shares().totalSupply();
		vm.prank(keeper);
		assertEq(queue.settle(address(fund), 1), 1);
		assertApproxEqAbs(IERC20(USDC).balanceOf(investor), gavAfter * fundShares / supply, 2, 'paid in USDC');
	}

	/// @dev Slipstream-1 WETH/cbLTC (no USDC side) through the exit adapter as the Comptroller would call it: cbLTC → WETH
	///      → USDC and WETH → USDC, nothing left behind here or in the router.
	function test_exitAdapter_routesANonUsdcPairToUsdc() public {
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

		ClmVaultExitAdapter.Route[] memory routes = new ClmVaultExitAdapter.Route[](2);
		routes[0] = ClmVaultExitAdapter.Route(SLIPSTREAM1_ROUTER, abi.encodePacked(CBLTC, int24(200), WETH, int24(100), USDC));
		routes[1] = ClmVaultExitAdapter.Route(SLIPSTREAM1_ROUTER, abi.encodePacked(WETH, int24(100), USDC));
		IERC20(s1Vault).transfer(address(exitAdapter), shares); // what the Comptroller does before executeAction
		uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
		uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
		uint256 routerWeth = IERC20(WETH).balanceOf(SLIPSTREAM1_ROUTER);
		exitAdapter.executeAction(address(this), abi.encode(uint8(2), s1Vault, shares, uint256(0), USDC, routes));

		assertGt(IERC20(USDC).balanceOf(address(this)) - usdcBefore, 0, 'paid in USDC');
		assertEq(IERC20(WETH).balanceOf(address(this)), wethBefore, 'no WETH came back');
		assertEq(IERC20(WETH).balanceOf(SLIPSTREAM1_ROUTER), routerWeth, 'none left in the router');
		assertEq(IERC20(WETH).balanceOf(address(exitAdapter)), 0);
		assertEq(IERC20(CBLTC).balanceOf(address(exitAdapter)), 0);
		assertEq(IERC20(s1Vault).balanceOf(address(exitAdapter)), 0);
	}

	function test_keeperCantExitIntoAnythingButUsdc() public {
		vm.skip(!ready);
		ComptrollerV6 fund = _fund(20_000e6);
		_managerDeposits(fund, 10_000e6);
		uint256 clmShares = IFrostyClmVault(clmVault).balanceOf(address(fund.vault()));
		uint256 fundShares = fund.shares().balanceOf(investor) / 2;
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(address(queue), fundShares);
		queue.requestRedeem(address(fund), fundShares);
		vm.stopPrank();
		_settle(clmStrategy);
		vm.roll(block.number + 1);
		vm.prank(keeper);
		vm.expectRevert(); // a plain withdraw returns two assets: ComptrollerV6Lib.NotASale
		queue.liquidate(address(fund), address(adapter), abi.encode(uint8(1), clmVault, clmShares, uint256(0), uint256(0)));
	}
}
