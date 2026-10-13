// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ComptrollerV6} from '../../src/core/ComptrollerV6.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {RedemptionQueueV2} from '../../src/redemption/RedemptionQueueV2.sol';
import {IFrostyClmVault} from '../../src/interfaces/external/IFrostyClm.sol';
import {RedemptionQueueV2ShortDeadline} from '../utils/RedemptionQueueV2ShortDeadline.sol';
import {ClmVaultAdapterForkTest} from './ClmVaultAdapterFork.t.sol';

/// @notice D2 (founder 2026-10-11): a v6 fund's yield lives in CLM vault shares, so when its manager ghosts, the
///         keeper's existing liquidation must turn them into USDC and the leaver must be paid in USDC.
contract ClmGhostLiquidationForkTest is ClmVaultAdapterForkTest {
	RedemptionQueueV2 internal queue;

	function setUp() public override {
		super.setUp();
		if (!ready) return;
		queue = new RedemptionQueueV2ShortDeadline(address(this));
		queue.setFactory(address(factory));
		queue.setKeeper(keeper, true);
		ComptrollerBlueprintDeployer shortDeployer = new ComptrollerBlueprintDeployer(
			type(ComptrollerV6).creationCode, abi.encode(registrarV2, queue, perpConfig)
		);
		vm.prank(deployer);
		factory.setComptrollerDeployer(shortDeployer);
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
		queue.liquidate(address(fund), address(adapter), _cbBtcExit(clmShares));
		assertEq(IFrostyClmVault(clmVault).balanceOf(v), 0, 'every vault share exited');
		uint256 gavAfter = fund.calcGav();
		emit log_named_uint('exit cost vs oracle value (USDC, 6 decimals)', gavBefore - gavAfter);
		assertGt(gavAfter, gavBefore * 9_970 / 10_000, 'within the 3% cap, and far under it');

		uint256 supply = fund.shares().totalSupply();
		vm.prank(keeper);
		assertEq(queue.settle(address(fund), 1), 1);
		assertApproxEqAbs(IERC20(USDC).balanceOf(investor), gavAfter * fundShares / supply, 2, 'paid in USDC');
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
