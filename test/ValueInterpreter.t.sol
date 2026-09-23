// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';

contract ValueInterpreterTest is Test {
	ValueInterpreter internal interpreter;
	MockERC20 internal usdc; // 6 decimals, $1
	MockERC20 internal weth; // 18 decimals, $2500
	MockERC20 internal nvdax; // 18 decimals, $180 (tokenized stock)
	MockAggregator internal usdcFeed;
	MockAggregator internal wethFeed;
	MockAggregator internal nvdaxFeed;

	address internal admin = makeAddr('admin');

	function setUp() public {
		vm.warp(30 days);
		interpreter = new ValueInterpreter(admin);

		usdc = new MockERC20('USD Coin', 'USDC', 6);
		weth = new MockERC20('Wrapped Ether', 'WETH', 18);
		nvdax = new MockERC20('NVDA Wrapper', 'NVDAx', 18);

		usdcFeed = new MockAggregator(8, 1e8);
		wethFeed = new MockAggregator(8, 2500e8);
		nvdaxFeed = new MockAggregator(8, 180e8);

		vm.startPrank(admin);
		interpreter.addPrimitive(address(usdc), address(usdcFeed), 1 days);
		interpreter.addPrimitive(address(weth), address(wethFeed), 1 days);
		// Equity wrapper: tight heartbeat = market-hours gate.
		interpreter.addPrimitive(address(nvdax), address(nvdaxFeed), 4 hours);
		vm.stopPrank();
	}

	function test_crossDecimalPricing() public {
		// 2 WETH (18 dec) at $2500 = $5000 = 5000e6 USDC (6 dec)
		assertEq(interpreter.calcCanonicalAssetValue(address(weth), 2e18, address(usdc)), 5000e6);

		// 5000 USDC in WETH = 2 WETH
		assertEq(interpreter.calcCanonicalAssetValue(address(usdc), 5000e6, address(weth)), 2e18);

		// 10 NVDAx at $180 = 1800e6 USDC
		assertEq(interpreter.calcCanonicalAssetValue(address(nvdax), 10e18, address(usdc)), 1800e6);

		// Same asset short-circuits without touching feeds
		assertEq(interpreter.calcCanonicalAssetValue(address(weth), 7e18, address(weth)), 7e18);
	}

	function test_staleEquityFeed_reverts_marketHoursGate() public {
		// Friday close: feed stops updating. 5 hours later (heartbeat 4h) pricing reverts.
		skip(5 hours);
		vm.expectRevert(abi.encodeWithSelector(ValueInterpreter.StalePrice.selector, address(nvdax), nvdaxFeed.updatedAt()));
		interpreter.calcCanonicalAssetValue(address(nvdax), 1e18, address(usdc));

		// Crypto feed (1 day heartbeat) still fine at 5 hours.
		assertEq(interpreter.calcCanonicalAssetValue(address(weth), 1e18, address(usdc)), 2500e6);

		// Monday open: feed updates, pricing resumes.
		nvdaxFeed.setAnswer(185e8);
		assertEq(interpreter.calcCanonicalAssetValue(address(nvdax), 1e18, address(usdc)), 185e6);
	}

	function test_invalidAnswer_reverts() public {
		nvdaxFeed.setAnswer(0);
		vm.expectRevert(abi.encodeWithSelector(ValueInterpreter.InvalidPrice.selector, address(nvdax), int256(0)));
		interpreter.calcCanonicalAssetValue(address(nvdax), 1e18, address(usdc));
	}

	function test_unsupportedAsset_reverts() public {
		MockERC20 rogue = new MockERC20('Rogue', 'RGE', 18);
		vm.expectRevert(abi.encodeWithSelector(ValueInterpreter.UnsupportedAsset.selector, address(rogue)));
		interpreter.calcCanonicalAssetValue(address(rogue), 1e18, address(usdc));
		assertFalse(interpreter.isSupportedAsset(address(rogue)));
	}

	function test_adminGates() public {
		MockERC20 token = new MockERC20('T', 'T', 18);
		MockAggregator feed = new MockAggregator(8, 1e8);

		vm.expectRevert();
		interpreter.addPrimitive(address(token), address(feed), 1 days);

		vm.prank(admin);
		vm.expectRevert(abi.encodeWithSelector(ValueInterpreter.HeartbeatAboveMax.selector, uint32(8 days)));
		interpreter.addPrimitive(address(token), address(feed), 8 days);

		vm.prank(admin);
		interpreter.addPrimitive(address(token), address(feed), 1 days);
		assertTrue(interpreter.isSupportedAsset(address(token)));

		vm.prank(admin);
		interpreter.removePrimitive(address(token));
		assertFalse(interpreter.isSupportedAsset(address(token)));
	}
}
