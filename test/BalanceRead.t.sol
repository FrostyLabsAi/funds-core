// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {BalanceRead} from '../src/core/BalanceRead.sol';

contract BalanceReadHarness {
	function tryRead(address asset, address holder) external view returns (bool ok, uint256 amount) {
		return BalanceRead.tryRead(asset, holder);
	}
}

/// @dev balanceOf burns `burn` gas, then answers `balance`, or reverts while `reverts`.
contract GasToken {
	uint256 public burn;
	uint256 public balance = 7;
	bool public reverts;
	bool public short;

	function set(uint256 burn_, bool reverts_, bool short_) external {
		burn = burn_;
		reverts = reverts_;
		short = short_;
	}

	function balanceOf(address) external view returns (uint256) {
		uint256 start = gasleft();
		while (start - gasleft() < burn) {}
		require(!reverts, 'paused');
		if (short) {
			assembly ('memory-safe') {
				return(0, 16)
			}
		}
		return balance;
	}
}

/// @notice Fund version 6's balance read (founder 2026-10-11, D2): a token that can't answer reads as 0; a caller who
///         starves a healthy token's read gets CallStarved, never a 0.
contract BalanceReadTest is Test {
	BalanceReadHarness internal harness = new BalanceReadHarness();
	GasToken internal token = new GasToken();

	function test_aReadThatAnswersReturnsTheBalance() public view {
		(bool ok, uint256 amount) = harness.tryRead(address(token), address(this));
		assertTrue(ok);
		assertEq(amount, 7);
	}

	function test_aRevertingReadIsZero() public {
		token.set(0, true, false);
		(bool ok, uint256 amount) = harness.tryRead(address(token), address(this));
		assertFalse(ok);
		assertEq(amount, 0);
	}

	function test_aShortAnswerIsZero() public {
		token.set(0, false, true);
		(bool ok, uint256 amount) = harness.tryRead(address(token), address(this));
		assertFalse(ok);
		assertEq(amount, 0);
	}

	/// A read needing more than GAS counts as failed, with the caller's gas plentiful.
	function test_aReadOverTheAllowanceIsZero() public {
		token.set(BalanceRead.GAS + 1_000, false, false);
		(bool ok, uint256 amount) = harness.tryRead{gas: 2_000_000}(address(token), address(this));
		assertFalse(ok);
		assertEq(amount, 0);
	}

	/// A healthy read starved by the caller's gas reverts instead of reading 0.
	function test_aStarvedReadReverts() public {
		token.set(80_000, false, false); // within GAS, but more than a 70k caller can pass on
		vm.expectRevert(BalanceRead.CallStarved.selector);
		harness.tryRead{gas: 70_000}(address(token), address(this));
		(bool ok, uint256 amount) = harness.tryRead{gas: 400_000}(address(token), address(this));
		assertTrue(ok, 'given room, it reads');
		assertEq(amount, 7);
	}
}
