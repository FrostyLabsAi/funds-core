// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {TickMath} from '../src/libraries/TickMath.sol';
import {PoolPriceMath} from '../src/libraries/PoolPriceMath.sol';
import {PoolKey, PoolKeyId, V4Delta} from '../src/interfaces/external/IUniswapV4.sol';

/// @notice The v4 key/delta helpers and the pool price math (spec 2026-10-08 §4.2).
contract PoolPriceMathTest is Test {
	/// The STFY pool's real key → its real PoolId (Initialize event, block 50186379).
	function test_toId_matchesTheStfyPool() public pure {
		PoolKey memory key = PoolKey({
			currency0: address(0),
			currency1: 0xC6405D7a226e1C18E559Be2F335F74C01Ad07bF5,
			fee: 10_000,
			tickSpacing: 200,
			hooks: 0x47Ec48C74f3069e9Ae69406197821996d80200cC
		});
		assertEq(PoolKeyId.toId(key), 0xa6979745954ea4976d4c94a5957c225801de74b4ef6ab22d122854fb09405e06);
	}

	function test_delta_unpacksBothAmounts() public pure {
		int256 delta = (int256(-5) << 128) | int256(uint256(uint128(7)));
		assertEq(V4Delta.amount0(delta), -5);
		assertEq(V4Delta.amount1(delta), 7);
		int256 negOne = (int256(3) << 128) | int256(uint256(uint128(type(uint128).max))); // amount1 = -1
		assertEq(V4Delta.amount0(negOne), 3);
		assertEq(V4Delta.amount1(negOne), -1);
	}

	/// tick 0 = a 1:1 raw ratio: 1 whole 18-dec asset = 1e18 units of a 6-dec quote at $1 = $1e12.
	function test_price_tickZero() public pure {
		uint256 sqrtP = TickMath.getSqrtRatioAtTick(0);
		assertEq(PoolPriceMath.usdPerAssetAtSqrtP(sqrtP, true, 18, 6, 1e18), 1e30);
		assertEq(PoolPriceMath.usdPerAssetAtSqrtP(sqrtP, false, 18, 6, 1e18), 1e30);
	}

	/// Against an independent computation of quote-per-asset from the tick, both orientations.
	function test_price_matchesTheRatio(int24 tick) public pure {
		tick = int24(bound(tick, -400_000, 400_000));
		uint256 sqrtP = TickMath.getSqrtRatioAtTick(tick);
		uint256 viaLib0 = PoolPriceMath.usdPerAssetAtSqrtP(sqrtP, true, 18, 6, 2_000e18);
		uint256 viaLib1 = PoolPriceMath.usdPerAssetAtSqrtP(sqrtP, false, 18, 6, 2_000e18);
		// asset token0: quote/asset = P = sqrtP²/2^192; asset token1: 1/P
		uint256 expect0 = Math.mulDiv(Math.mulDiv(sqrtP, sqrtP, 1 << 96), 1e18 * 2_000e18, (1 << 96) * 1e6);
		uint256 expect1 = Math.mulDiv(1e18 * 2_000e18, 1 << 96, Math.mulDiv(sqrtP, sqrtP, 1 << 96) * 1e6);
		assertApproxEqRel(viaLib0, expect0, 1e12); // 1e-6 relative: different rounding paths
		assertApproxEqRel(viaLib1, expect1, 1e12);
	}

	/// Full-range-equivalent quote reserve: L·√P/2^96 of token1 when the asset is token0, L·2^96/√P of token0 otherwise.
	function test_quoteReserve() public pure {
		uint256 sqrtP = TickMath.getSqrtRatioAtTick(0);
		assertEq(PoolPriceMath.quoteReserve(1e18, sqrtP, true), 1e18);
		assertEq(PoolPriceMath.quoteReserve(1e18, sqrtP, false), 1e18);
		uint256 sqrt4 = 2 * (uint256(1) << 96); // P = 4
		assertEq(PoolPriceMath.quoteReserve(1e18, sqrt4, true), 2e18);
		assertEq(PoolPriceMath.quoteReserve(1e18, sqrt4, false), 0.5e18);
	}
}
