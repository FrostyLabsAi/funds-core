// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {ReleaseFork} from './utils/ReleaseFork.sol';

/// @notice The gas floor against Aero's real swap hook (founder 2026-11-12), on Base at the block before fund YAFT's
///         buys ran out of gas: the release deployed there, a fund buys WETH on Aero's hooked WETH/USDC pool through the
///         release's Aero adapter (WETH, not the stock that failed: TSLAc is a B20 token, which Base's node runs and
///         Foundry can't; the hook is the pool factory's, the same contract on both pools).
///         A wallet's estimate is the least gas at which the transaction succeeds, made with no gas price. `_leastGas`
///         is that search. Aero's hook does more work once a priority fee is paid, so the same trade then needs more:
///         with the floor at 0 the estimate is not enough for the real transaction; with the floor the terminal sets
///         (its own estimate plus 1.5 fund-value reads) it is.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-contract AeroGasFloorFork -vv
contract AeroGasFloorForkTest is ReleaseFork {
	int24 internal constant TICK_SPACING = 50; // Aero WETH/USDC 0x4A7a…366c, hook 0xc0ED…e434
	uint256 internal constant AMOUNT = 500_000; // 0.5 USDC
	uint256 internal constant PRIORITY_FEE = 4_000_000; // 0.004 gwei, the failed buy's

	Comptroller internal fund;
	address internal fundVault;
	uint256 internal baseFee;

	/// @dev 2026-11-12 16:52 UTC; the failed buys start at 56,564,685.
	function _forkBlock() internal pure override returns (uint256) {
		return 56_560_000;
	}

	function setUp() public override {
		super.setUp();
		if (!forked) return;
		baseFee = block.basefee;
		fund = _fundWithDeposit(10e6);
		fundVault = address(fund.vault());
	}

	function test_floorOff_aWalletsEstimateIsTooLittleForTheRealTransaction() public {
		vm.skip(!forked);
		bytes memory trade = _aeroTrade(0);
		uint256 estimate = _leastGas(trade, false);
		uint256 needed = _leastGas(trade, true);
		emit log_named_uint('wallet estimate (no gas price)', estimate);
		emit log_named_uint('needed with a priority fee', needed);
		assertGt(needed, estimate, 'Aero\'s hook costs more once a priority fee is paid');

		assertFalse(_send(trade, estimate, true), 'the real transaction runs out of gas at the estimate');
		assertEq(IERC20(WETH).balanceOf(fundVault), 0, 'nothing bought');
	}

	function test_withTheFloor_aWalletsEstimateIsEnoughForTheRealTransaction() public {
		vm.skip(!forked);
		uint256 floor = _terminalFloor();
		bytes memory trade = _aeroTrade(floor);
		uint256 estimate = _leastGas(trade, false);
		uint256 needed = _leastGas(_aeroTrade(0), true);
		emit log_named_uint('floor the terminal sets', floor);
		emit log_named_uint('wallet estimate (no gas price)', estimate);
		emit log_named_uint('the trade needs, with a priority fee', needed);
		assertGt(estimate, needed, 'the estimate now carries the margin');

		uint256 usdcBefore = IERC20(USDC).balanceOf(fundVault);
		assertTrue(_send(trade, estimate, true), 'the real transaction goes through at the wallet\'s own estimate');
		assertGt(IERC20(WETH).balanceOf(fundVault), 0, 'the vault got its WETH');
		assertEq(usdcBefore - IERC20(USDC).balanceOf(fundVault), AMOUNT, 'for what the manager spent');
	}

	function test_withTheFloor_aHigherPriorityFeeChangesNothing() public {
		vm.skip(!forked);
		bytes memory trade = _aeroTrade(_terminalFloor());
		uint256 estimate = _leastGas(trade, false);
		vm.fee(baseFee);
		vm.txGasPrice(baseFee + 1 gwei);
		vm.prank(manager);
		(bool ok,) = address(fund).call{gas: estimate}(trade);
		assertTrue(ok, '1 gwei of priority fee, 250 times the failed buy\'s');
	}

	/// The terminal has to send the estimate made WITH the floor. The floor itself as the limit can't reach the adapter
	/// with the floor still left.
	function test_theFloorItselfAsTheLimit_isRefused() public {
		vm.skip(!forked);
		uint256 floor = _terminalFloor();
		assertFalse(_send(_aeroTrade(floor), floor, true), 'the limit must be the estimate, not the floor');
		assertEq(IERC20(WETH).balanceOf(fundVault), 0);
	}

	/// @dev What the terminal's tradeGasLimit works out before it sends (frosty-terminal src/lib/tradeGas.ts): the
	///      trade's own fee-less estimate plus one and a half fund-value reads.
	function _terminalFloor() internal returns (uint256) {
		uint256 before = gasleft();
		fund.calcGav();
		uint256 navRead = before - gasleft();
		return _leastGas(_aeroTrade(0), false) + (navRead * 3) / 2;
	}

	function _aeroTrade(uint256 minGasLeft) internal view returns (bytes memory) {
		bytes memory data = abi.encode(USDC, WETH, TICK_SPACING, AMOUNT, uint256(1), minGasLeft);
		return abi.encodeCall(Comptroller.callOnIntegration, (address(r.adapters.aero), data));
	}

	/// @dev One attempt as the manager with `gasLimit`, on the state as it stands. `fees` false is how a node runs an
	///      estimate that names no gas price (gas price and base fee 0); true is the mined transaction.
	function _send(bytes memory trade, uint256 gasLimit, bool fees) internal returns (bool ok) {
		vm.fee(fees ? baseFee : 0);
		vm.txGasPrice(fees ? baseFee + PRIORITY_FEE : 0);
		vm.prank(manager);
		(ok,) = address(fund).call{gas: gasLimit}(trade);
	}

	/// @dev The least gas at which the trade succeeds: a binary search, each try on the same state. Foundry keeps what a
	///      test has touched warm from one call to the next, so the figures run below a mined transaction's (YAFT's real
	///      buy needed 775,953); every comparison here is between searches made on that same footing.
	function _leastGas(bytes memory trade, bool fees) internal returns (uint256 high) {
		uint256 low = 100_000;
		high = 8_000_000;
		uint256 start = vm.snapshotState();
		require(_send(trade, high, fees), 'the trade fails even with 8M gas');
		vm.revertToState(start);
		while (high - low > 1) {
			uint256 mid = (low + high) / 2;
			uint256 snapshot = vm.snapshotState();
			bool ok = _send(trade, mid, fees);
			vm.revertToState(snapshot);
			if (ok) high = mid;
			else low = mid;
		}
	}
}
