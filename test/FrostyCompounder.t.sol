// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FrostyCompounder} from '../src/yield/FrostyCompounder.sol';
import {IUniswapV3NonfungiblePositionManager} from '../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {MockERC20, MockUniV3PositionManager} from './utils/Mocks.sol';

contract FrostyCompounderTest is Test {
	FrostyCompounder internal compounder;
	MockUniV3PositionManager internal npm;
	MockERC20 internal teth; // token0 (deployed first → lower address ensured below)
	MockERC20 internal tusdc; // token1
	address internal treasury = makeAddr('treasury');
	address internal alice = makeAddr('alice');
	address internal bob = makeAddr('bob');

	function setUp() public {
		npm = new MockUniV3PositionManager();
		MockERC20 a = new MockERC20('Test ETH', 'tETH', 18);
		MockERC20 b = new MockERC20('Test USDC', 'tUSDC', 6);
		// FrostyCompounder requires pool token ordering (token0 < token1)
		(teth, tusdc) = address(a) < address(b) ? (a, b) : (b, a);
		compounder = new FrostyCompounder(
			'Frosty Compounding tETH-tUSDC',
			'fcETHUSDC',
			IUniswapV3NonfungiblePositionManager(address(npm)),
			IERC20(address(teth)),
			IERC20(address(tusdc)),
			3000,
			887220,
			1500, // 15% of yield
			treasury
		);

		for (uint256 i; i < 2; ++i) {
			address user = i == 0 ? alice : bob;
			teth.mint(user, 1_000e18);
			tusdc.mint(user, 1_000_000e18);
			vm.startPrank(user);
			teth.approve(address(compounder), type(uint256).max);
			tusdc.approve(address(compounder), type(uint256).max);
			vm.stopPrank();
		}
	}

	function _deposit(address user, uint128 liquidity, uint256 amt0, uint256 amt1) internal returns (uint256) {
		npm.setNextLiquidity(liquidity);
		vm.prank(user);
		return compounder.deposit(amt0, amt1, 0, 0, 0);
	}

	function test_firstDeposit_mintsPositionAndLiquiditySharesOneToOne() public {
		uint256 shares = _deposit(alice, 5_000e6, 1e18, 2_500e18);
		// shares == liquidity units, minus the 1e6 bootstrap seed (donation-inflation defense)
		assertEq(shares, 4_999e6);
		assertEq(compounder.balanceOf(alice), 4_999e6);
		assertEq(compounder.balanceOf(compounder.BOOTSTRAP_SHARES_SINK()), 1e6);
		assertEq(compounder.totalSupply(), 5_000e6); // supply still mirrors position liquidity
		assertEq(compounder.tokenId(), 1);
		(uint128 liquidity,,) = compounder.positionState();
		assertEq(liquidity, 5_000e6);
	}

	function test_secondDepositor_getsProportionalShares_noDilution() public {
		_deposit(alice, 5_000e6, 1e18, 2_500e18);
		uint256 bobShares = _deposit(bob, 2_500e6, 1e18, 2_500e18);
		assertEq(bobShares, 2_500e6);
		assertEq(compounder.totalSupply(), 7_500e6);
		(uint128 liquidity,,) = compounder.positionState();
		assertEq(liquidity, 7_500e6); // supply always mirrors position liquidity
	}

	function test_compound_takesPerfFeeOnHarvestOnly_andReinvests() public {
		_deposit(alice, 5_000e6, 1e18, 2_500e18);
		// pool earns fees: 0.1 tETH + 250 tUSDC (fund the mock so collect can pay)
		teth.mint(address(npm), 1e18);
		tusdc.mint(address(npm), 1_000e18);
		npm.addOwedFees(1, 0.1e18, 250e18);

		npm.setNextLiquidity(400e6); // liquidity the reinvest adds
		compounder.compound();

		// 15% of the HARVEST to treasury — principal untouched
		assertEq(teth.balanceOf(treasury), 0.015e18);
		assertEq(tusdc.balanceOf(treasury), 37.5e18);
		// remainder reinvested into the SAME position; no new shares anywhere
		(uint128 liquidity,,) = compounder.positionState();
		assertEq(liquidity, 5_400e6);
		assertEq(compounder.totalSupply(), 5_000e6); // share value grew instead
		assertEq(teth.balanceOf(address(compounder)), 0);
		assertEq(tusdc.balanceOf(address(compounder)), 0);
	}

	function test_depositAndWithdraw_compoundPendingFeesFirst() public {
		_deposit(alice, 5_000e6, 1e18, 2_500e18);
		teth.mint(address(npm), 1e18);
		tusdc.mint(address(npm), 1_000e18);
		npm.addOwedFees(1, 0.1e18, 250e18);

		// bob's deposit triggers _compound() first — alice's pending fees fold in
		// BEFORE bob's shares exist, so he can't claim her yield
		npm.setNextLiquidity(400e6); // consumed by the compound's reinvest
		uint256 bobShares = _deposit(bob, 2_000e6, 1e18, 2_500e18);
		// (mock quirk: the same nextLiquidity applies to both the reinvest and bob's
		// add — the invariant that matters is treasury got its cut pre-deposit)
		assertEq(teth.balanceOf(treasury), 0.015e18);
		assertGt(bobShares, 0);
	}

	function test_withdraw_burnsSharesAndPaysProportionalPrincipal() public {
		uint256 shares = _deposit(alice, 5_000e6, 1e18, 2_500e18);
		npm.setNextDecreaseAmounts(0.5e18, 1_250e18);

		uint256 teth0 = teth.balanceOf(alice);
		uint256 tusdc0 = tusdc.balanceOf(alice);
		vm.prank(alice);
		(uint256 amount0, uint256 amount1) = compounder.withdraw(shares / 2, 0, 0);
		assertEq(amount0, 0.5e18);
		assertEq(amount1, 1_250e18);
		assertEq(teth.balanceOf(alice) - teth0, 0.5e18);
		assertEq(tusdc.balanceOf(alice) - tusdc0, 1_250e18);
		assertEq(compounder.balanceOf(alice), shares / 2);
	}

	function test_withdraw_moreThanBalance_reverts() public {
		_deposit(alice, 5_000e6, 1e18, 2_500e18);
		vm.prank(bob);
		vm.expectRevert(); // ERC20InsufficientBalance
		compounder.withdraw(1, 0, 0);
	}

	function test_feeSwitch_ownerOnly_andCapped() public {
		vm.prank(alice);
		vm.expectRevert();
		compounder.setPerfFee(2000);

		compounder.setPerfFee(3000); // exactly the cap is fine
		vm.expectRevert(FrostyCompounder.FeeTooHigh.selector);
		compounder.setPerfFee(3001);

		vm.expectRevert(FrostyCompounder.FeeTooHigh.selector);
		new FrostyCompounder(
			'x', 'x', IUniswapV3NonfungiblePositionManager(address(npm)),
			IERC20(address(teth)), IERC20(address(tusdc)), 3000, 887220, 3001, treasury
		);
	}

	function test_constructor_enforcesTokenOrdering() public {
		vm.expectRevert(FrostyCompounder.TokensOutOfOrder.selector);
		new FrostyCompounder(
			'x', 'x', IUniswapV3NonfungiblePositionManager(address(npm)),
			IERC20(address(tusdc)), IERC20(address(teth)), 3000, 887220, 1000, treasury
		);
	}

	function test_withdrawAfterCompound_includesTheYieldSlice() public {
		// REGRESSION (caught by the Sepolia-fork e2e): with 1:1 share↔liquidity, the
		// liquidity added by compound() was orphaned — a full exit left yield stranded.
		uint256 shares = _deposit(alice, 5_000e6, 1e18, 2_500e18);
		teth.mint(address(npm), 1e18);
		tusdc.mint(address(npm), 1_000e18);
		npm.addOwedFees(1, 0.1e18, 250e18);
		npm.setNextLiquidity(400e6);
		compounder.compound(); // position 5,400e6 · supply still 5,000e6

		npm.setNextDecreaseAmounts(1.05e18, 2_650e18);
		vm.prank(alice);
		compounder.withdraw(shares, 0, 0);

		// Alice's FULL slice (principal + compounded yield) is removed; only the
		// unredeemable bootstrap seed's slice stays staked: 5,400e6 × 1e6/5,000e6
		(uint128 liquidity,,) = compounder.positionState();
		assertEq(liquidity, 1_080_000);
		assertEq(compounder.totalSupply(), 1e6); // the seed itself
	}

	function test_depositAfterCompound_paysFairPriceForGrownShares() public {
		_deposit(alice, 5_000e6, 1e18, 2_500e18);
		teth.mint(address(npm), 1e18);
		tusdc.mint(address(npm), 1_000e18);
		npm.addOwedFees(1, 0.1e18, 250e18);
		npm.setNextLiquidity(400e6);
		compounder.compound(); // liquidity 5,400e6 backs 5,000e6 shares

		// bob adds 2,700e6 liquidity → shares = 2,700 × 5,000 / 5,400 = 2,500e6:
		// he pays the GROWN share price; alice's compounded yield stays hers
		uint256 bobShares = _deposit(bob, 2_700e6, 1e18, 2_500e18);
		assertEq(bobShares, 2_500e6);
	}

	// ─── H-4 (security review 2026-09-22): share-inflation defenses ─────────────

	function test_bootstrapBelowSeed_reverts() public {
		npm.setNextLiquidity(1e6); // exactly the seed — depositor would get 0
		vm.prank(alice);
		vm.expectRevert(FrostyCompounder.BootstrapTooSmall.selector);
		compounder.deposit(1e18, 2_500e18, 0, 0, 0);
	}

	function test_minShares_boundsASkewedMint() public {
		_deposit(alice, 5_000e6, 1e18, 2_500e18);
		// bob expects ≥ 2,500e6 shares but the pool only credits 2,000e6 liquidity
		npm.setNextLiquidity(2_000e6);
		vm.prank(bob);
		vm.expectRevert(abi.encodeWithSelector(FrostyCompounder.SharesBelowMin.selector, 2_000e6, 2_500e6));
		compounder.deposit(1e18, 2_500e18, 0, 0, 2_500e6);
	}

	function test_dustBootstrap_cannotSetUpInflation() public {
		// attacker bootstraps with near-dust: seed soaks it, attacker keeps 1 share
		uint256 eveShares = _deposit(alice, 1e6 + 1, 1e18, 2_500e18);
		assertEq(eveShares, 1);
		// victim's mint stays fine-grained against the seeded supply — the classic
		// "1 share for the victim" outcome is impossible (granularity ≥ seed)
		uint256 victimShares = _deposit(bob, 5_000e6, 1e18, 2_500e18);
		assertGt(victimShares, 4_000e6);
	}

	function test_zeroFee_sendsNothingToTreasury() public {
		compounder.setPerfFee(0);
		_deposit(alice, 5_000e6, 1e18, 2_500e18);
		teth.mint(address(npm), 1e18);
		tusdc.mint(address(npm), 1_000e18);
		npm.addOwedFees(1, 0.1e18, 250e18);
		npm.setNextLiquidity(400e6);
		compounder.compound();
		assertEq(teth.balanceOf(treasury), 0);
		assertEq(tusdc.balanceOf(treasury), 0);
	}
}
