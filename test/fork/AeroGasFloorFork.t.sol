// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerV6} from '../../src/core/ComptrollerV6.sol';
import {AerodromeSlipstreamSwapAdapterV3} from '../../src/adapters/AerodromeSlipstreamSwapAdapterV3.sol';
import {ClmFundsDeploy} from '../../script/mainnet/ClmFundsDeploy.sol';
import {DeployAeroSwapAdapterV3} from '../../script/mainnet/DeployAeroSwapAdapterV3.s.sol';

/// @notice The gas floor against Aero's real swap hook (founder 2026-11-12), on Base at the block before fund YAFT's
///         buys ran out of gas. The live fund, as its manager, buys WETH on Aero's hooked WETH/USDC pool (WETH, not the
///         stock that failed: TSLAc is a B20 token, which Base's node runs and Foundry can't; the hook is the pool
///         factory's, the same contract on both pools).
///         A wallet's estimate is the least gas at which the transaction succeeds, made with no gas price. `_leastGas`
///         is that search. Aero's hook does more work once a priority fee is paid, so the same trade then needs more:
///         through today's adapter the estimate is not enough for the real transaction; through V3 with the floor the
///         terminal sets (its own estimate plus 1.5 fund-value reads) it is.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-contract AeroGasFloorFork -vv
contract AeroGasFloorForkTest is Test {
	uint256 internal constant FORK_BLOCK = 56_560_000; // 2026-11-12 16:52 UTC; the failed buys start at 56,564,685
	address internal constant DEPLOYER = 0xaE51f2EfE70e57b994BE8F7f97C4dC824c51802a; // factory owner, and YAFT's manager
	address internal constant YAFT = 0x162841b07341f950099E295ea52dB3b21880Bc8e; // v6 fund, holds 1.002478 USDC here
	address internal constant AERO_SWAP_V2 = 0x3c4378db0bCc219E4B6cb652cAE8d5596Cb59810; // base-mainnet-aero-adapters.json aeroSwap
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant WETH = 0x4200000000000000000000000000000000000006;
	int24 internal constant TICK_SPACING = 50; // Aero WETH/USDC 0x4A7a…366c, hook 0xc0ED…e434
	uint256 internal constant AMOUNT = 500_000; // 0.5 USDC
	uint256 internal constant PRIORITY_FEE = 4_000_000; // 0.004 gwei, the failed buy's

	bool internal ready;
	ComptrollerV6 internal fund = ComptrollerV6(YAFT);
	AerodromeSlipstreamSwapAdapterV3 internal v3;
	address internal fundVault;
	uint256 internal baseFee;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, FORK_BLOCK);
		ready = true;
		baseFee = block.basefee;
		fundVault = address(fund.vault());
		v3 = new DeployAeroSwapAdapterV3().deployAdapter(DEPLOYER);
		vm.prank(DEPLOYER);
		FundFactory(ClmFundsDeploy.FUND_FACTORY).registerAdapter(address(v3));
	}

	function test_todaysAdapter_aWalletsEstimateIsTooLittleForTheRealTransaction() public {
		vm.skip(!ready);
		bytes memory trade = _trade(AERO_SWAP_V2, abi.encode(USDC, WETH, TICK_SPACING, AMOUNT, uint256(1)));
		uint256 estimate = _leastGas(trade, false);
		uint256 needed = _leastGas(trade, true);
		emit log_named_uint('wallet estimate (no gas price)', estimate);
		emit log_named_uint('needed with a priority fee', needed);
		assertGt(needed, estimate, 'Aero\'s hook costs more once a priority fee is paid');

		assertFalse(_send(trade, estimate, true), 'the real transaction runs out of gas at the estimate');
		assertEq(IERC20(WETH).balanceOf(fundVault), 0, 'nothing bought');
	}

	function test_floorOff_v3IsTodaysAdapter() public {
		vm.skip(!ready);
		bytes memory trade = _v3Trade(0);
		uint256 estimate = _leastGas(trade, false);
		assertGt(_leastGas(trade, true), estimate);
		assertFalse(_send(trade, estimate, true), 'with the floor at 0 nothing has changed');
	}

	function test_withTheFloor_aWalletsEstimateIsEnoughForTheRealTransaction() public {
		vm.skip(!ready);
		uint256 floor = _terminalFloor();
		bytes memory trade = _v3Trade(floor);
		uint256 estimate = _leastGas(trade, false);
		uint256 needed = _leastGas(_v3Trade(0), true);
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
		vm.skip(!ready);
		bytes memory trade = _v3Trade(_terminalFloor());
		uint256 estimate = _leastGas(trade, false);
		vm.fee(baseFee);
		vm.txGasPrice(baseFee + 1 gwei);
		vm.prank(DEPLOYER);
		(bool ok,) = YAFT.call{gas: estimate}(trade);
		assertTrue(ok, '1 gwei of priority fee, 250 times the failed buy\'s');
	}

	/// The terminal has to send the estimate made WITH the floor. The floor itself as the limit can't reach the adapter
	/// with the floor still left.
	function test_theFloorItselfAsTheLimit_isRefused() public {
		vm.skip(!ready);
		uint256 floor = _terminalFloor();
		assertFalse(_send(_v3Trade(floor), floor, true), 'the limit must be the estimate, not the floor');
		assertEq(IERC20(WETH).balanceOf(fundVault), 0);
	}

	/// @dev What the terminal's tradeGasLimit works out before it sends (frosty-terminal src/lib/tradeGas.ts): the
	///      trade's own fee-less estimate plus one and a half fund-value reads.
	function _terminalFloor() internal returns (uint256) {
		uint256 before = gasleft();
		fund.calcGav();
		uint256 navRead = before - gasleft();
		return _leastGas(_v3Trade(0), false) + (navRead * 3) / 2;
	}

	function _v3Trade(uint256 minGasLeft) internal view returns (bytes memory) {
		return _trade(address(v3), abi.encode(USDC, WETH, TICK_SPACING, AMOUNT, uint256(1), minGasLeft));
	}

	function _trade(address adapter, bytes memory data) internal pure returns (bytes memory) {
		return abi.encodeCall(ComptrollerV6.callOnIntegration, (adapter, data));
	}

	/// @dev One attempt as the manager with `gasLimit`, on the state as it stands. `fees` false is how a node runs an
	///      estimate that names no gas price (gas price and base fee 0); true is the mined transaction.
	function _send(bytes memory trade, uint256 gasLimit, bool fees) internal returns (bool ok) {
		vm.fee(fees ? baseFee : 0);
		vm.txGasPrice(fees ? baseFee + PRIORITY_FEE : 0);
		vm.prank(DEPLOYER);
		(ok,) = YAFT.call{gas: gasLimit}(trade);
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
