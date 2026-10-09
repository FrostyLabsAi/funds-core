// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import {Shares} from '../fund/Shares.sol';
import {Vault} from '../fund/Vault.sol';
import {RedemptionMath} from '../redemption/RedemptionMath.sol';
import {ComptrollerV3Lib} from './ComptrollerV3Lib.sol';

/// @dev What the library reads back from the fund it runs for (address(this) under delegatecall).
interface IFundParts {
	function shares() external view returns (Shares);
	function vault() external view returns (Vault);
	function denominationAsset() external view returns (IERC20);
}

/// @title InKindRedemption
/// @notice Fund version 5's in-kind exit for a fund holding perps or LPs (founder 2026-10-09: no exit may pay a
///         redeemer less than their shares' value; TestFund4's V3 exit paid $1.97 for $9.51 of shares). It pays what
///         the queue's fallback pays (RedemptionMath.fallbackPayout, final review 2026-10-06 C2): the slice of every
///         vault token, the share of the positions in USDC, and what the vault's USDC can't pay of it covered from
///         its readable, non-pool-priced tokens, pro rata by value (a pumped long-tail price can't pull value out;
///         an unreadable token is paid as its slice only). All of it or nothing: when the vault can't cover the
///         whole request it reverts and the redeemer keeps the shares (the queue is then the exit). An external
///         library for EIP-170 room in the comptroller; it runs in the comptroller's context.
library InKindRedemption {
	error InKindNotCovered();

	/// @dev ComptrollerV3's event, so indexers read V5's exit like V3's.
	event SharesRedeemedInKind(address indexed redeemer, uint256 sharesAmount, address[] assets, uint256[] amounts);

	/// @notice What `sharesAmount` of `supply` takes, from a valuation snapshot (ComptrollerV3Lib.redemptionValue,
	///         fees already settled); reverts InKindNotCovered unless the vault covers all of it.
	function quote(bytes memory snapshot, address denom, uint256 sharesAmount, uint256 supply)
		public
		pure
		returns (address[] memory assets, uint256[] memory amounts)
	{
		RedemptionMath.Snapshot memory s;
		(s.assets, s.balances, s.values, s.inKind, s.positionsValue) =
			abi.decode(snapshot, (address[], uint256[], uint256[], bool[], uint256));
		s.denom = denom;
		s.supply = supply;
		uint256[] memory remaining = new uint256[](s.balances.length);
		for (uint256 i; i < remaining.length; ++i) {
			remaining[i] = s.balances[i];
		}
		uint256 paidShares;
		(amounts, paidShares) =
			RedemptionMath.fallbackPayout(s, sharesAmount, s.balances[RedemptionMath._denomIndex(s)], remaining);
		if (paidShares != sharesAmount) revert InKindNotCovered();
		assets = s.assets;
	}

	/// @notice Pays msg.sender (the redeemer: a delegatecall keeps the caller) and burns the shares. An empty
	///         `snapshot` (the fund holds no position): the slice of every tracked token, minus `assetsToSkip`
	///         (V3's in kind; a skipped slice stays with the holders). A valuation snapshot: the whole value, as
	///         quote; skipping isn't allowed then (it would forfeit that slice). The vault pays; a pool-priced token's
	///         cost basis leaves with its units. Reads the fund's parts back from it (EIP-170 room).
	function redeem(
		mapping(address => uint256) storage costBasis,
		EnumerableSet.AddressSet storage trackedAssets,
		bytes memory snapshot,
		uint256 sharesAmount,
		address[] memory assetsToSkip
	) external {
		IFundParts fund = IFundParts(address(this));
		Shares shares = fund.shares();
		Vault vault = fund.vault();
		address[] memory assets;
		uint256[] memory amounts;
		if (snapshot.length == 0) {
			(assets, amounts) =
				ComptrollerV3Lib.inKindSlice(trackedAssets, address(vault), sharesAmount, shares.totalSupply(), assetsToSkip);
		} else {
			if (assetsToSkip.length != 0) revert InKindNotCovered();
			(assets, amounts) = quote(snapshot, address(fund.denominationAsset()), sharesAmount, shares.totalSupply());
		}
		shares.burn(msg.sender, sharesAmount);
		ComptrollerV3Lib.payOut(costBasis, vault, msg.sender, assets, amounts);
		emit SharesRedeemedInKind(msg.sender, sharesAmount, assets, amounts);
	}
}
