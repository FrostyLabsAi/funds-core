// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IPoolPriceAdapter} from '../src/interfaces/IPoolPriceAdapter.sol';
import {IPoolWatch} from '../src/interfaces/IPoolWatch.sol';
import {BasicPoolPriceAdapter} from '../src/pricing/BasicPoolPriceAdapter.sol';
import {BasicPoolPriceAdapterV2} from '../src/pricing/BasicPoolPriceAdapterV2.sol';
import {ScriptedBasicPool} from './utils/PoolPriceMocks.sol';
import {BasicPoolPriceAdapterTest} from './BasicPoolPriceAdapter.t.sol';

/// @notice Every BasicPoolPriceAdapter test, run on V2, plus V2's one change: the ≈ $0 rule reads the window's average
///         quote reserve only, so a quote reserve emptied inside one transaction (a large sale, an LP's own burn) no
///         longer zeroes the price (red-team PRICING-POOL-01, second pass, 2026-10-27). The buy floor still counts it.
contract BasicPoolPriceAdapterV2Test is BasicPoolPriceAdapterTest {
	function _implementation() internal override returns (address) {
		return address(new BasicPoolPriceAdapterV2());
	}

	function _v1(ScriptedBasicPool pool) internal returns (IPoolPriceAdapter adapter) {
		address v2 = impl;
		impl = address(new BasicPoolPriceAdapter());
		adapter = _adapter(pool, tkn);
		impl = v2;
	}

	/// The current quote reserve emptied, the window's average unchanged: V2 prices at the window, V1 at 1 wei.
	function test_aDrainedReserveLeavesThePriceAtTheWindow() public {
		ScriptedBasicPool pool = _usdcPool();
		_script(pool, tkn, HALF_M_TKN, ONE_M_USDC, 2 hours); // $2 per TKN, $1M average
		IPoolPriceAdapter adapter = _adapter(pool, tkn);
		IPoolPriceAdapter v1 = _v1(pool);

		_setReserves(pool, tkn, 2 * HALF_M_TKN, 1);
		assertEq(_answer(adapter), 2e18, 'V2: still the window price');
		assertEq(_answer(v1), 1, 'V1 (the control): 1 wei');
	}

	/// The buy floor still sees the reserve now.
	function test_theBuyFloorStillCountsTheReserveNow() public {
		ScriptedBasicPool pool = _usdcPool();
		_script(pool, tkn, HALF_M_TKN, ONE_M_USDC, 2 hours);
		_setReserves(pool, tkn, 2 * HALF_M_TKN, 4_000e6);

		assertEq(_adapter(pool, tkn).liquidityUsd(), 4_000e18);
	}

	/// Where the reserve is untouched, V2 answers exactly what V1 does.
	function test_answersAsV1DoesWhenNothingIsDrained() public {
		ScriptedBasicPool pool = _usdcPool();
		_script(pool, tkn, HALF_M_TKN, ONE_M_USDC, 2 hours);
		_setReserves(pool, tkn, HALF_M_TKN, 900_000e6);
		IPoolPriceAdapter adapter = _adapter(pool, tkn);
		IPoolPriceAdapter v1 = _v1(pool);

		assertEq(_answer(adapter), _answer(v1));
		assertEq(adapter.liquidityUsd(), v1.liquidityUsd());
	}

	/// The reserve under half the window's average is unsettled the block it happens, however quiet the pool (review 2026-11-01).
	function test_aReserveUnderHalfIsUnsettled() public {
		ScriptedBasicPool pool = _usdcPool();
		_script(pool, tkn, HALF_M_TKN, ONE_M_USDC, 2 hours);
		IPoolWatch adapter = IPoolWatch(address(_adapter(pool, tkn)));
		assertFalse(adapter.poolUnsettled(), 'steady');
		_setReserves(pool, tkn, HALF_M_TKN, ONE_M_USDC / 2);
		assertFalse(adapter.poolUnsettled(), 'half is the line');
		_setReserves(pool, tkn, HALF_M_TKN, ONE_M_USDC / 2 - 1);
		assertTrue(adapter.poolUnsettled());
	}
}
