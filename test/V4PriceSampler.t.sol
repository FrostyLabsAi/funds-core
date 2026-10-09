// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {V4PriceSampler} from '../src/pricing/V4PriceSampler.sol';
import {IV4StateView} from '../src/interfaces/external/IUniswapV4.sol';
import {TickMath} from '../src/libraries/TickMath.sol';
import {MockStateView} from './utils/V4Mocks.sol';

/// @notice V4PriceSampler (spec 2026-10-08 §4.1): keeper-only samples of v4 pools into a 12-slot history.
contract V4PriceSamplerTest is Test {
	V4PriceSampler internal sampler;
	MockStateView internal stateView;
	address internal owner = makeAddr('owner');
	address internal keeper = makeAddr('keeper');
	bytes32 internal constant POOL = keccak256('pool');

	function setUp() public {
		vm.warp(1_000_000);
		stateView = new MockStateView();
		sampler = new V4PriceSampler(IV4StateView(address(stateView)), owner);
		vm.prank(owner);
		sampler.setKeeper(keeper, true);
		stateView.setPool(POOL, TickMath.getSqrtRatioAtTick(100), 100, 5e18);
	}

	function _ids() internal pure returns (bytes32[] memory ids) {
		ids = new bytes32[](1);
		ids[0] = POOL;
	}

	function _sample() internal {
		vm.prank(keeper);
		sampler.sample(_ids());
	}

	function test_sample_recordsTimeTickAndLiquidity() public {
		_sample();
		V4PriceSampler.Sample[] memory s = sampler.samples(POOL);
		assertEq(s.length, 1);
		assertEq(s[0].time, block.timestamp);
		assertEq(s[0].tick, 100);
		assertEq(s[0].liquidity, 5e18);
		assertEq(sampler.sampleCount(POOL), 1);
	}

	function test_sample_keeperOnly() public {
		vm.expectRevert(abi.encodeWithSelector(V4PriceSampler.NotKeeper.selector, address(this)));
		sampler.sample(_ids());
	}

	function test_setKeeper_ownerOnly() public {
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
		sampler.setKeeper(address(this), true);
	}

	/// A keeper bug can't flood a pool's history: a sample within 9 minutes of the last is skipped.
	function test_sample_skipsWithinNineMinutes() public {
		_sample();
		skip(9 minutes - 1);
		stateView.setPool(POOL, TickMath.getSqrtRatioAtTick(200), 200, 5e18);
		_sample();
		assertEq(sampler.sampleCount(POOL), 1, 'skipped');
		skip(1);
		_sample();
		assertEq(sampler.sampleCount(POOL), 2);
		assertEq(sampler.samples(POOL)[0].tick, 200, 'newest first');
	}

	function test_sample_skipsAnUninitializedPool() public {
		bytes32[] memory ids = new bytes32[](1);
		ids[0] = keccak256('nothing');
		vm.prank(keeper);
		sampler.sample(ids);
		assertEq(sampler.sampleCount(ids[0]), 0);
	}

	function test_ring_keepsTheLastTwelve() public {
		for (uint256 i; i < 15; ++i) {
			stateView.setPool(POOL, TickMath.getSqrtRatioAtTick(int24(int256(i))), int24(int256(i)), 5e18);
			_sample();
			skip(10 minutes);
		}
		V4PriceSampler.Sample[] memory s = sampler.samples(POOL);
		assertEq(s.length, 12);
		assertEq(s[0].tick, 14, 'newest');
		assertEq(s[11].tick, 3, 'oldest kept');
		assertEq(sampler.sampleCount(POOL), 15);
	}
}
