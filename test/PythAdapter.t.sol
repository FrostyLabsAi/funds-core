// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {PythAggregatorAdapter} from '../src/pricing/PythAggregatorAdapter.sol';
import {IPyth} from '../src/interfaces/external/IPyth.sol';
import {MockERC20, MockPyth} from './utils/Mocks.sol';

contract PythAdapterTest is Test {
	bytes32 internal constant ETH_ID = bytes32(uint256(1));
	bytes32 internal constant TSLA_ID = bytes32(uint256(2));

	MockPyth internal pyth;
	address internal admin = makeAddr('admin');

	function setUp() public {
		vm.warp(30 days);
		pyth = new MockPyth();
	}

	function _adapter(bytes32 id, uint16 confBps) internal returns (PythAggregatorAdapter) {
		// wide maxPushAge here — these tests exercise conversion + the VI heartbeat layer;
		// the adapter's own push-age gate has its own test below
		return new PythAggregatorAdapter(IPyth(address(pyth)), id, confBps, 30 days, 'test (Pyth)');
	}

	// ─── Exponent normalization (live Base reality: crypto -8, equity/FX -5) ─────

	function test_expoMinus8_passesThrough() public {
		pyth.setPrice(ETH_ID, 2500e8, 1e8, -8, block.timestamp);
		(uint80 roundId, int256 answer,, uint256 updatedAt,) = _adapter(ETH_ID, 200).latestRoundData();
		assertEq(answer, 2500e8);
		assertEq(updatedAt, block.timestamp);
		assertEq(uint256(roundId), block.timestamp);
	}

	function test_expoMinus5_scalesUpTo8Decimals() public {
		// TSLA at $393.41724 exactly as the live Base read returned it (expo -5)
		pyth.setPrice(TSLA_ID, 39341724, 26542, -5, block.timestamp);
		(, int256 answer,,,) = _adapter(TSLA_ID, 200).latestRoundData();
		assertEq(answer, 39341724000); // $393.41724 in 8dp
	}

	function test_expoMinus18_scalesDownTo8Decimals() public {
		pyth.setPrice(ETH_ID, 2_500_000_000_000_000_000, 0, -18, block.timestamp);
		(, int256 answer,,,) = _adapter(ETH_ID, 200).latestRoundData();
		assertEq(answer, 25e7); // $2.50
	}

	function test_expoZero_scalesWholeDollars() public {
		pyth.setPrice(ETH_ID, 2500, 1, 0, block.timestamp);
		(, int256 answer,,,) = _adapter(ETH_ID, 200).latestRoundData();
		assertEq(answer, 2500e8);
	}

	function test_positiveExpo_reverts() public {
		pyth.setPrice(ETH_ID, 25, 0, 2, block.timestamp);
		PythAggregatorAdapter adapter = _adapter(ETH_ID, 200);
		vm.expectRevert(abi.encodeWithSelector(PythAggregatorAdapter.UnsupportedExponent.selector, int32(2)));
		adapter.latestRoundData();
	}

	// ─── Guards ──────────────────────────────────────────────────────────────────

	function test_nonPositivePrice_reverts() public {
		pyth.setPrice(ETH_ID, 0, 0, -8, block.timestamp);
		PythAggregatorAdapter adapter = _adapter(ETH_ID, 200);
		vm.expectRevert(abi.encodeWithSelector(PythAggregatorAdapter.NonPositivePrice.selector, int64(0)));
		adapter.latestRoundData();

		pyth.setPrice(ETH_ID, -1, 0, -8, block.timestamp);
		vm.expectRevert(abi.encodeWithSelector(PythAggregatorAdapter.NonPositivePrice.selector, int64(-1)));
		adapter.latestRoundData();
	}

	function test_confidenceTooWide_reverts() public {
		// 2% cap: conf exactly at the cap passes, one unit above reverts
		PythAggregatorAdapter adapter = _adapter(ETH_ID, 200);
		pyth.setPrice(ETH_ID, 100e8, 2e8, -8, block.timestamp);
		(, int256 answer,,,) = adapter.latestRoundData();
		assertEq(answer, 100e8);

		pyth.setPrice(ETH_ID, 100e8, 2e8 + 1, -8, block.timestamp);
		vm.expectRevert(
			abi.encodeWithSelector(PythAggregatorAdapter.ConfidenceTooWide.selector, uint64(2e8 + 1), int64(100e8))
		);
		adapter.latestRoundData();
	}

	function test_unknownId_reverts() public {
		PythAggregatorAdapter adapter = _adapter(bytes32(uint256(999)), 200);
		vm.expectRevert(MockPyth.PriceFeedNotFound.selector);
		adapter.latestRoundData();
	}

	function test_constructorValidation() public {
		vm.expectRevert(PythAggregatorAdapter.ZeroArgument.selector);
		new PythAggregatorAdapter(IPyth(address(0)), ETH_ID, 200, 600, 'x');
		vm.expectRevert(PythAggregatorAdapter.ZeroArgument.selector);
		new PythAggregatorAdapter(IPyth(address(pyth)), bytes32(0), 200, 600, 'x');
		vm.expectRevert(PythAggregatorAdapter.ZeroArgument.selector);
		new PythAggregatorAdapter(IPyth(address(pyth)), ETH_ID, 200, 0, 'x'); // push-age bound required
		vm.expectRevert(abi.encodeWithSelector(PythAggregatorAdapter.BadConfBps.selector, uint16(0)));
		new PythAggregatorAdapter(IPyth(address(pyth)), ETH_ID, 0, 600, 'x');
		vm.expectRevert(abi.encodeWithSelector(PythAggregatorAdapter.BadConfBps.selector, uint16(10001)));
		new PythAggregatorAdapter(IPyth(address(pyth)), ETH_ID, 10001, 600, 'x');
	}

	// ─── ValueInterpreter integration (the actual consumer) ─────────────────────

	function test_valueInterpreter_pricesThroughAdapter_andHeartbeatGatesStaleness() public {
		ValueInterpreter interpreter = new ValueInterpreter(admin);
		MockERC20 usdc = new MockERC20('USD Coin', 'USDC', 6);
		MockERC20 tslax = new MockERC20('TSLA Wrapper', 'TSLAx', 18);
		MockPyth usdcPyth = pyth; // same mock, two ids

		usdcPyth.setPrice(ETH_ID, 1e8, 1e4, -8, block.timestamp); // ETH_ID reused as USDC $1
		pyth.setPrice(TSLA_ID, 39341724, 26542, -5, block.timestamp);

		PythAggregatorAdapter usdcAdapter = _adapter(ETH_ID, 200);
		PythAggregatorAdapter tslaAdapter = _adapter(TSLA_ID, 200);

		vm.startPrank(admin);
		interpreter.addPrimitive(address(usdc), address(usdcAdapter), 1 days);
		// equity: tight heartbeat doubles as the market-hours gate, exactly like Chainlink B20
		interpreter.addPrimitive(address(tslax), address(tslaAdapter), 4 hours);
		vm.stopPrank();

		// 2 TSLAx (18 dec) at $393.41724 = $786.83448 = 786_834480 in 6-dec USDC
		uint256 value = interpreter.calcCanonicalAssetValue(address(tslax), 2e18, address(usdc));
		assertEq(value, 786_834480);

		// market closes / pusher stops → publishTime ages past the heartbeat → GAV reverts
		vm.warp(block.timestamp + 4 hours + 1);
		vm.expectRevert(
			abi.encodeWithSelector(ValueInterpreter.StalePrice.selector, address(tslax), block.timestamp - 4 hours - 1)
		);
		interpreter.calcCanonicalAssetValue(address(tslax), 2e18, address(usdc));
	}

	/// H-3: the adapter itself bounds push age — an actor can no longer cherry-pick any
	/// historical print inside the (wide, market-hours) VI heartbeat around GAV actions.
	function test_maxPushAge_gatesStoredPushesTighterThanHeartbeat() public {
		PythAggregatorAdapter adapter =
			new PythAggregatorAdapter(IPyth(address(pyth)), ETH_ID, 200, 600, 'gated (Pyth)');
		uint256 pushedAt = block.timestamp;
		pyth.setPrice(ETH_ID, 2500e8, 1e8, -8, pushedAt);

		(, int256 answer,,,) = adapter.latestRoundData();
		assertEq(answer, 2500e8);

		vm.warp(pushedAt + 600); // exactly at the bound still reads
		adapter.latestRoundData();

		vm.warp(pushedAt + 601);
		vm.expectRevert(abi.encodeWithSelector(PythAggregatorAdapter.StalePythPush.selector, pushedAt));
		adapter.latestRoundData();
	}

	function test_decimals_is8() public {
		assertEq(_adapter(ETH_ID, 200).decimals(), 8);
	}
}
