// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {AerodromeSlipstreamSwapAdapter} from '../src/adapters/AerodromeSlipstreamSwapAdapter.sol';
import {ISlipstreamSwapRouter} from '../src/interfaces/external/ISlipstreamSwapRouter.sol';
import {MockERC20, MockSwapRouter} from './utils/Mocks.sol';

/// @notice The gas floor on Aero swaps (founder 2026-11-12): a plain swap with the floor at 0, and a swap that
///         refuses to start on less gas than the caller named. The reason, and the proof against Aero's real hook, are
///         in test/fork/AeroGasFloorFork.t.sol.
contract AerodromeSlipstreamSwapAdapterTest is Test {
	uint256 internal constant FLOOR = 300_000;

	MockERC20 internal usdc;
	MockERC20 internal tkn;
	MockSwapRouter internal router;
	AerodromeSlipstreamSwapAdapter internal adapter;
	address internal treasury = makeAddr('treasury');
	address internal owner = makeAddr('owner');
	address internal vault = makeAddr('vault');

	function setUp() public {
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		tkn = new MockERC20('Token', 'TKN', 18);
		router = new MockSwapRouter();
		adapter = new AerodromeSlipstreamSwapAdapter(ISlipstreamSwapRouter(address(router)), treasury, 5, owner);
		router.setNextAmountOut(7e18);
		// the Comptroller's order: spend assets to the adapter, then executeAction
		usdc.mint(address(adapter), 10_000e6);
	}

	function _data(uint256 minGasLeft) internal view returns (bytes memory) {
		return abi.encode(address(usdc), address(tkn), int24(10), uint256(10_000e6), uint256(1), minGasLeft);
	}

	function test_floorOff_isV2_fiveBpsToTheTreasury_andTheRestSwappedToTheVault() public {
		adapter.executeAction(vault, _data(0));
		assertEq(usdc.balanceOf(treasury), 5e6, '5 bps');
		assertEq(usdc.balanceOf(address(router)), 9_995e6, 'the rest is swapped');
		assertEq(tkn.balanceOf(vault), 7e18);
		assertEq(usdc.balanceOf(address(adapter)), 0, 'nothing left behind');
		assertEq(router.lastTickSpacing(), 10);
		assertEq(router.lastRecipient(), vault);
	}

	function test_parse_spendsTheFullAmount_andTheFloorIsNoAsset() public view {
		(address[] memory spend, uint256[] memory amounts, address[] memory incoming, uint256[] memory mins) =
			adapter.parseAssetsForAction(_data(FLOOR));
		assertEq(spend.length, 1);
		assertEq(spend[0], address(usdc));
		assertEq(amounts[0], 10_000e6, 'the fee is part of what the fund spends');
		assertEq(incoming.length, 1);
		assertEq(incoming[0], address(tkn));
		assertEq(mins[0], 1);
	}

	function test_belowTheFloor_theSwapNeverStarts_andNothingMoves() public {
		// 300,000 forwarded: by the check a little of it is spent on decoding, so less than the floor is left
		(bool ok, bytes memory err) =
			address(adapter).call{gas: FLOOR}(abi.encodeCall(adapter.executeAction, (vault, _data(FLOOR))));
		assertFalse(ok, 'refused');
		assertEq(bytes4(err), AerodromeSlipstreamSwapAdapter.GasBelowFloor.selector);
		assertEq(usdc.balanceOf(treasury), 0, 'no fee taken');
		assertEq(usdc.balanceOf(address(adapter)), 10_000e6, 'nothing swapped');
		assertEq(tkn.balanceOf(vault), 0);
	}

	function test_belowTheFloor_saysWhatWasLeftAndWhatWasAsked() public {
		(, bytes memory err) = address(adapter).call{gas: FLOOR}(abi.encodeCall(adapter.executeAction, (vault, _data(FLOOR))));
		(uint256 gasLeft, uint256 minGasLeft) = abi.decode(_stripSelector(err), (uint256, uint256));
		assertEq(minGasLeft, FLOOR);
		assertLt(gasLeft, FLOOR);
		assertGt(gasLeft, FLOOR - 5_000, 'the check comes first: only the decoding is spent before it');
	}

	function test_atTheFloor_theSwapRuns() public {
		// 5,000 over the floor covers the decoding before the check; the mock swap itself needs far less than the floor
		(bool ok,) = address(adapter).call{gas: FLOOR + 5_000}(abi.encodeCall(adapter.executeAction, (vault, _data(FLOOR))));
		assertTrue(ok, 'enough gas: the floor is met');
		assertEq(tkn.balanceOf(vault), 7e18);
		assertEq(usdc.balanceOf(treasury), 5e6);
	}

	/// The floor is what makes a wallet's estimate carry the margin: the least gas that succeeds is the floor, not the
	/// swap's own cost.
	function test_theLeastGasThatSucceeds_isSetByTheFloor_notByTheSwap() public {
		uint256 withoutFloor = _leastGas(_data(0));
		uint256 withFloor = _leastGas(_data(FLOOR));
		assertLt(withoutFloor, 200_000, 'the mock swap needs well under the floor');
		assertGe(withFloor, FLOOR, 'an estimate can not come in under the floor');
		assertLt(withFloor, FLOOR + 5_000, 'and it is the floor that sets it');
	}

	function test_v2sFiveFields_areRefused_theFloorMustBeSent() public {
		vm.expectRevert();
		adapter.executeAction(vault, abi.encode(address(usdc), address(tkn), int24(10), uint256(10_000e6), uint256(1)));
	}

	/// @dev The least gas at which executeAction succeeds, as a wallet's estimate finds it: a binary search on one state.
	function _leastGas(bytes memory data) internal returns (uint256 high) {
		uint256 low = 21_000;
		high = 2_000_000;
		while (high - low > 1) {
			uint256 mid = (low + high) / 2;
			uint256 snapshot = vm.snapshotState();
			(bool ok,) = address(adapter).call{gas: mid}(abi.encodeCall(adapter.executeAction, (vault, data)));
			vm.revertToState(snapshot);
			if (ok) high = mid;
			else low = mid;
		}
	}

	function _stripSelector(bytes memory err) internal pure returns (bytes memory out) {
		out = new bytes(err.length - 4);
		for (uint256 i; i < out.length; ++i) {
			out[i] = err[i + 4];
		}
	}
}
