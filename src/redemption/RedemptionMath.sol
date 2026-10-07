// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

/// @title RedemptionMath
/// @notice What a queued redemption pays (spec 2026-10-06 §5). A redeemer of `shares` out of
///         `supply` gets that fraction of the fund, always rounded down, so a redeemer is never paid
///         more than their share. Amounts are aligned with the snapshot's assets; the denomination
///         asset's slot carries the USDC.
library RedemptionMath {
	/// @dev One valuation of the fund, taken once per settlement (fees already settled).
	struct Snapshot {
		address denom;
		uint256 supply; // shares outstanding, escrowed ones included
		address[] assets; // tracked vault assets
		uint256[] balances;
		uint256[] values; // in the denomination; 0 where unreadable
		bool[] inKind; // pool-priced or unreadable: never paid in cash
		uint256 positionsValue; // every external position, managed minus debt, floored at 0 each
	}

	/// @notice Cash: the redeemer's share of every readable, non-pool-priced holding and of the
	///         positions, in USDC; their share of each pool-priced or unreadable token in kind
	///         (a pumped long-tail price can't pull cash out), as the instant cash exit does.
	function cashPayout(Snapshot memory s, uint256 shares) internal pure returns (uint256[] memory amounts) {
		amounts = new uint256[](s.assets.length);
		uint256 cashValue = s.positionsValue;
		for (uint256 i; i < s.assets.length; ++i) {
			if (s.inKind[i]) amounts[i] = Math.mulDiv(s.balances[i], shares, s.supply);
			else cashValue += s.values[i];
		}
		amounts[_denomIndex(s)] = Math.mulDiv(cashValue, shares, s.supply);
	}

	/// @notice In kind: the redeemer's share of every vault token, plus the share of the positions
	///         in USDC. A pro-rata unwind (close the share of each perp and LP, return the USDC)
	///         funds it exactly, so the remaining holders keep the rest of everything, hedges intact.
	function inKindPayout(Snapshot memory s, uint256 shares) internal pure returns (uint256[] memory amounts) {
		amounts = new uint256[](s.assets.length);
		uint256 d = _denomIndex(s);
		for (uint256 i; i < s.assets.length; ++i) {
			if (i != d) amounts[i] = Math.mulDiv(s.balances[i], shares, s.supply);
		}
		amounts[d] = Math.mulDiv(s.balances[d] + s.positionsValue, shares, s.supply);
	}

	/// @notice The fallback's payout to an overdue redeemer after the unwind (spec §6): their share
	///         of every vault token in kind, USDC up to their share of (vault USDC + positions), and
	///         any of that USDC share the vault can't pay (closes that didn't fill, LPs, limit
	///         orders) covered from the USDC beyond it, then from what remains of the readable,
	///         non-pool-priced tokens, pro rata by value (a pumped long-tail price must not pull extra
	///         value out). Nothing is ever forfeited (final review 2026-10-06, C2): when even that
	///         can't cover the whole request, only the shares it covers are paid (`paidShares`) and
	///         the rest stay queued. `usdcLeft` and `remaining` are what earlier payouts in this batch
	///         left; the caller subtracts this payout from them.
	function fallbackPayout(Snapshot memory s, uint256 shares, uint256 usdcLeft, uint256[] memory remaining)
		internal
		pure
		returns (uint256[] memory amounts, uint256 paidShares)
	{
		uint256 n = s.assets.length;
		amounts = new uint256[](n);
		uint256 d = _denomIndex(s);
		paidShares = _coverableShares(s, shares, usdcLeft, remaining, d);
		if (paidShares == 0) return (amounts, 0);
		uint256 target = Math.mulDiv(s.balances[d] + s.positionsValue, paidShares, s.supply);
		amounts[d] = Math.min(target, usdcLeft);
		uint256 shortfall = target - amounts[d];
		for (uint256 i; i < n; ++i) {
			if (i == d) continue;
			uint256 slice = Math.mulDiv(s.balances[i], paidShares, s.supply);
			amounts[i] = Math.min(slice, remaining[i]);
			// a slice an earlier payout's coverage used up is still owed: cover it too
			if (amounts[i] < slice && s.balances[i] != 0) {
				shortfall += Math.mulDiv(s.values[i], slice - amounts[i], s.balances[i]);
			}
		}
		uint256 extraUsdc = Math.min(shortfall, usdcLeft - amounts[d]);
		amounts[d] += extraUsdc;
		if (shortfall > extraUsdc) _cover(s, amounts, remaining, d, shortfall - extraUsdc);
	}

	/// @dev The most of `shares` whose full payout what is left can cover: the cash-able value (vault
	///      USDC, positions, readable non-pool-priced tokens) a share is owed, against the USDC and
	///      those tokens still in the vault.
	function _coverableShares(Snapshot memory s, uint256 shares, uint256 usdcLeft, uint256[] memory remaining, uint256 d)
		private
		pure
		returns (uint256)
	{
		uint256 owed = s.balances[d] + s.positionsValue;
		uint256 available = usdcLeft;
		for (uint256 i; i < s.assets.length; ++i) {
			if (!_covers(s, i, d)) continue;
			owed += s.values[i];
			available += Math.mulDiv(s.values[i], remaining[i], s.balances[i]);
		}
		if (Math.mulDiv(owed, shares, s.supply) <= available) return shares;
		return Math.mulDiv(available, s.supply, owed);
	}

	/// @dev Adds up to `shortfall` of value to `amounts` from what remains of the readable,
	///      non-pool-priced tokens, pro rata by value.
	function _cover(Snapshot memory s, uint256[] memory amounts, uint256[] memory remaining, uint256 d, uint256 shortfall)
		private
		pure
	{
		uint256[] memory leftValue = new uint256[](s.assets.length);
		uint256 totalLeft;
		for (uint256 i; i < s.assets.length; ++i) {
			if (!_covers(s, i, d)) continue;
			leftValue[i] = Math.mulDiv(s.values[i], remaining[i] - amounts[i], s.balances[i]);
			totalLeft += leftValue[i];
		}
		uint256 covered = Math.min(shortfall, totalLeft);
		if (covered == 0) return;
		for (uint256 i; i < s.assets.length; ++i) {
			if (leftValue[i] == 0) continue;
			amounts[i] += Math.mulDiv(Math.mulDiv(covered, leftValue[i], totalLeft), s.balances[i], s.values[i]);
		}
	}

	/// @dev A readable, non-pool-priced token other than the denomination: one that may cover.
	function _covers(Snapshot memory s, uint256 i, uint256 d) private pure returns (bool) {
		return i != d && !s.inKind[i] && s.balances[i] != 0 && s.values[i] != 0;
	}

	/// @notice The USDC a payout takes from the vault.
	function usdcNeeded(Snapshot memory s, uint256[] memory amounts) internal pure returns (uint256) {
		return amounts[_denomIndex(s)];
	}

	function _denomIndex(Snapshot memory s) internal pure returns (uint256) {
		for (uint256 i; i < s.assets.length; ++i) {
			if (s.assets[i] == s.denom) return i;
		}
		revert DenominationNotTracked();
	}

	error DenominationNotTracked();
}
