// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/// @title BalanceRead
/// @notice Fund version 6's balance read for valuation (founder 2026-10-11, D2): `balanceOf` with exactly GAS, one word
///         back, nothing more copied. A token whose balance can't be read (it reverts, answers less than a word, or
///         needs more than GAS) is valued at $0 until it reads again, so one broken or hostile token can't stop every
///         exit and deposit of the fund.
library BalanceRead {
	/// @dev USDC reads in ~10k gas, a stock token ~2.5k.
	uint256 internal constant GAS = 100_000;
	uint256 internal constant GAS_RESERVE = 200_000;

	error CallStarved();

	/// @notice `asset.balanceOf(holder)` with GAS: `ok` false (and `amount` 0) when it reverts or answers less than a
	///         word. A failure counts only when the call had all of GAS, so a caller can't starve a healthy token into
	///         reading as $0 (Gnosis Safe's safeTxGas pattern; EIP-150 forwards at most 63/64 of what is left).
	function tryRead(address asset, address holder) internal view returns (bool ok, uint256 amount) {
		bytes4 selector = IERC20.balanceOf.selector;
		uint256 allowance = GAS;
		uint256 gasBefore = gasleft();
		assembly ('memory-safe') {
			let ptr := mload(0x40)
			mstore(ptr, selector)
			mstore(add(ptr, 4), holder)
			ok := staticcall(allowance, asset, ptr, 0x24, ptr, 0x20)
			if lt(returndatasize(), 0x20) { ok := 0 }
			amount := mload(ptr)
		}
		if (!ok) {
			amount = 0;
			if (gasBefore < GAS + GAS / 63 + GAS_RESERVE) revert CallStarved();
		}
	}
}
