// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {RedemptionMath} from '../src/redemption/RedemptionMath.sol';

/// @notice The queue's payout math (spec 2026-10-06 §5): a redeemer of `shares` out of `supply`
///         gets that fraction, in cash or in kind, always rounded down.
contract RedemptionMathTest is Test {
	address internal constant USDC = address(0x1);
	address internal constant WETH = address(0x2);
	address internal constant TKN = address(0x3); // pool-priced: always paid in kind

	/// @dev vault: `usdcBal` USDC, 1 WETH worth `wethValue`, 500 TKN worth `tknValue`; positions `positions`.
	function _snap(uint256 usdcBal, uint256 wethValue, uint256 tknValue, uint256 positions, uint256 supply)
		internal
		pure
		returns (RedemptionMath.Snapshot memory s)
	{
		s.denom = USDC;
		s.supply = supply;
		s.assets = new address[](3);
		s.balances = new uint256[](3);
		s.values = new uint256[](3);
		s.inKind = new bool[](3);
		(s.assets[0], s.balances[0], s.values[0]) = (USDC, usdcBal, usdcBal);
		(s.assets[1], s.balances[1], s.values[1]) = (WETH, 1e18, wethValue);
		(s.assets[2], s.balances[2], s.values[2], s.inKind[2]) = (TKN, 500e6, tknValue, true);
		s.positionsValue = positions;
	}

	function test_cash_paysTheValueInUsdc_andTheLongTailInKind() public pure {
		RedemptionMath.Snapshot memory s = _snap(1_000e6, 2_000e6, 500e6, 3_000e6, 100e18);
		uint256[] memory a = RedemptionMath.cashPayout(s, 10e18); // 10%
		assertEq(a[0], 600e6, '10% of (1,000 USDC + 2,000 WETH + 3,000 positions)');
		assertEq(a[1], 0, 'WETH is paid in cash');
		assertEq(a[2], 50e6, '10% of the TKN, in kind');
	}

	function test_inKind_paysTokens_plusThePositionsShareInUsdc() public pure {
		RedemptionMath.Snapshot memory s = _snap(1_000e6, 2_000e6, 500e6, 3_000e6, 100e18);
		uint256[] memory a = RedemptionMath.inKindPayout(s, 10e18);
		assertEq(a[0], 400e6, '10% of (1,000 vault USDC + 3,000 positions)');
		assertEq(a[1], 0.1e18, '10% of the WETH');
		assertEq(a[2], 50e6, '10% of the TKN');
	}

	function test_aPumpedLongTailPriceAddsNoCash() public pure {
		RedemptionMath.Snapshot memory s = _snap(1_000e6, 2_000e6, 500_000e6, 3_000e6, 100e18);
		uint256[] memory a = RedemptionMath.cashPayout(s, 10e18);
		assertEq(a[0], 600e6, 'TKN at any price adds no cash');
	}

	function test_usdcNeeded_isTheDenominationAmount() public pure {
		RedemptionMath.Snapshot memory s = _snap(1_000e6, 2_000e6, 500e6, 3_000e6, 100e18);
		assertEq(RedemptionMath.usdcNeeded(s, RedemptionMath.cashPayout(s, 10e18)), 600e6);
		assertEq(RedemptionMath.usdcNeeded(s, RedemptionMath.inKindPayout(s, 10e18)), 400e6);
	}

	function testFuzz_cashNeverPaysMoreThanTheShare(uint256 shares, uint256 supply) public pure {
		supply = bound(supply, 1e18, 1e30);
		shares = bound(shares, 1, supply);
		RedemptionMath.Snapshot memory s = _snap(1_000e6, 2_000e6, 500e6, 3_000e6, supply);
		uint256[] memory a = RedemptionMath.cashPayout(s, shares);
		assertLe(a[0], Math.mulDiv(6_000e6, shares, supply));
		assertLe(a[2], Math.mulDiv(500e6, shares, supply));
	}

	function testFuzz_inKindNeverPaysMoreThanTheShare(uint256 shares, uint256 supply) public pure {
		supply = bound(supply, 1e18, 1e30);
		shares = bound(shares, 1, supply);
		RedemptionMath.Snapshot memory s = _snap(1_000e6, 2_000e6, 500e6, 3_000e6, supply);
		uint256[] memory a = RedemptionMath.inKindPayout(s, shares);
		assertLe(a[0], Math.mulDiv(4_000e6, shares, supply));
		assertLe(a[1], Math.mulDiv(1e18, shares, supply));
	}

	// ─── fallback (spec §6) ──────────────────────────────────────────────────────

	function _all(RedemptionMath.Snapshot memory s) internal pure returns (uint256[] memory remaining) {
		remaining = new uint256[](s.balances.length);
		for (uint256 i; i < remaining.length; ++i) {
			remaining[i] = s.balances[i];
		}
	}

	function test_fallback_paysFullUsdcWhenTheVaultHasIt() public pure {
		RedemptionMath.Snapshot memory s = _snap(5_000e6, 2_000e6, 500e6, 3_000e6, 100e18);
		(uint256[] memory a, uint256 paidShares) = RedemptionMath.fallbackPayout(s, 10e18, 5_000e6, _all(s));
		assertEq(a[0], 800e6, '10% of (5,000 USDC + 3,000 positions)');
		assertEq(a[1], 0.1e18);
		assertEq(paidShares, 10e18, 'all of it');
	}

	function test_fallback_coversTheShortfallFromWeth_neverFromThePoolPricedToken() public pure {
		// 50% of (1,000 USDC + 3,000 positions) = 2,000 USDC owed; only 1,000 in the vault
		RedemptionMath.Snapshot memory s = _snap(1_000e6, 2_000e6, 500e6, 3_000e6, 100e18);
		(uint256[] memory a, uint256 paidShares) = RedemptionMath.fallbackPayout(s, 50e18, 1_000e6, _all(s));
		assertEq(a[0], 1_000e6, 'all the USDC there is');
		// in kind 0.5 WETH; the 1,000 shortfall is 0.5 WETH more at $2,000
		assertEq(a[1], 1e18, 'the whole WETH');
		assertEq(a[2], 250e6, 'TKN only its pro-rata share, never coverage');
		assertEq(paidShares, 50e18);
	}

	/// Never forfeited (final review 2026-10-06, C2): what the vault can't cover stays queued. 90%
	/// would be owed 90% of (1,000 USDC + 3,000 positions + $2,000 WETH) = 5,400 in USDC and WETH;
	/// the vault has 3,000 of it, so 50 shares are paid in full (TKN in kind) and 40 wait.
	function test_fallback_paysOnlyTheSharesTheVaultCanCover() public pure {
		RedemptionMath.Snapshot memory s = _snap(1_000e6, 2_000e6, 500e6, 3_000e6, 100e18);
		(uint256[] memory a, uint256 paidShares) = RedemptionMath.fallbackPayout(s, 90e18, 1_000e6, _all(s));
		assertEq(paidShares, 50e18, '3,000 of 6,000 cash-able value');
		assertEq(a[0], 1_000e6);
		assertEq(a[1], 1e18, '0.5 in kind + 0.5 coverage');
		assertEq(a[2], 250e6, "TKN: the paid shares' slice only");
	}

	function test_fallback_respectsWhatEarlierPayoutsLeft() public pure {
		RedemptionMath.Snapshot memory s = _snap(1_000e6, 2_000e6, 500e6, 3_000e6, 100e18);
		uint256[] memory remaining = _all(s);
		remaining[1] = 0.2e18; // an earlier redeemer took most of the WETH
		(uint256[] memory a, uint256 paidShares) = RedemptionMath.fallbackPayout(s, 50e18, 1_000e6, remaining);
		// 1,000 USDC + 0.2 WETH ($400) left of 6,000 cash-able value: 23.33 of the 50 shares
		assertEq(paidShares, Math.mulDiv(100e18, 1_400e6, 6_000e6));
		assertEq(a[1], 0.2e18, 'never more than what is left');
		// the WETH slice that is gone is made up from the USDC beyond the target
		assertApproxEqAbs(a[0] + Math.mulDiv(a[1], 2_000e6, 1e18), Math.mulDiv(6_000e6, paidShares, 100e18), 2);
	}

	/// What a partial payment burns is exactly what it pays: the value paid in USDC and WETH is the
	/// paid shares' share of the cash-able value, never more, and short by rounding at most.
	function testFuzz_fallbackBurnsExactlyWhatItPays(uint256 shares, uint256 usdcLeft, uint256 wethLeft) public pure {
		RedemptionMath.Snapshot memory s = _snap(1_000e6, 2_000e6, 500e6, 3_000e6, 100e18);
		shares = bound(shares, 1, 100e18);
		uint256[] memory remaining = _all(s);
		remaining[0] = bound(usdcLeft, 0, 1_000e6);
		remaining[1] = bound(wethLeft, 0, 1e18);
		(uint256[] memory a, uint256 paidShares) = RedemptionMath.fallbackPayout(s, shares, remaining[0], remaining);
		assertLe(paidShares, shares);
		assertLe(a[0], remaining[0]);
		assertLe(a[1], remaining[1]);
		uint256 paid = a[0] + Math.mulDiv(a[1], 2_000e6, 1e18);
		uint256 owed = Math.mulDiv(6_000e6, paidShares, 100e18);
		assertLe(paid, owed, 'never overpaid');
		assertApproxEqAbs(paid, owed, 3, 'never short beyond rounding');
	}
}
