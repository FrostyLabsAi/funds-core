// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {IValueInterpreter} from '../src/interfaces/IValueInterpreter.sol';
import {IPoolPriceAdapter} from '../src/interfaces/IPoolPriceAdapter.sol';
import {BasicPoolPriceAdapter} from '../src/pricing/BasicPoolPriceAdapter.sol';
import {PoolPriceAdapterBase} from '../src/pricing/PoolPriceAdapterBase.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';
import {ScriptedBasicPool} from './utils/PoolPriceMocks.sol';

contract BasicPoolPriceAdapterTest is Test {
	ValueInterpreter internal vi;
	BasicPoolPriceAdapter internal impl;
	MockERC20 internal usdc;
	MockERC20 internal weth;
	MockERC20 internal tkn;
	MockAggregator internal wethFeed;
	address internal admin = makeAddr('admin');

	uint256 internal constant HALF_M_TKN = 500_000e18;
	uint256 internal constant ONE_M_USDC = 1_000_000e6;

	function setUp() public {
		vm.warp(30 days);
		vi = new ValueInterpreter(admin);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		weth = new MockERC20('Wrapped Ether', 'WETH', 18);
		tkn = new MockERC20('Token', 'TKN', 18);
		wethFeed = new MockAggregator(8, 2000e8);
		vm.startPrank(admin);
		vi.addPrimitive(address(usdc), address(new MockAggregator(8, 1e8)), 25 hours);
		vi.addPrimitive(address(weth), address(wethFeed), 1 hours);
		vm.stopPrank();
		impl = new BasicPoolPriceAdapter();
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	function _adapter(ScriptedBasicPool pool, MockERC20 asset) internal returns (IPoolPriceAdapter) {
		bool assetIsToken0 = pool.token0() == address(asset);
		address quote = assetIsToken0 ? pool.token1() : pool.token0();
		bytes memory args = abi.encode(
			IPoolPriceAdapter.Config({
				valueInterpreter: IValueInterpreter(address(vi)),
				pool: address(pool),
				asset: address(asset),
				quoteAsset: quote,
				assetIsToken0: assetIsToken0,
				assetDecimals: asset.decimals(),
				quoteDecimals: MockERC20(quote).decimals()
			})
		);
		return IPoolPriceAdapter(Clones.cloneWithImmutableArgs(address(impl), args));
	}

	/// @dev (asset, quote) amounts in the pool's token order
	function _ordered(ScriptedBasicPool pool, MockERC20 asset, uint256 a, uint256 q) internal view returns (uint256, uint256) {
		return pool.token0() == address(asset) ? (a, q) : (q, a);
	}

	/// @dev One observation `age` ago, averaging (avgA, avgQ) from it to now; current reserves equal.
	function _script(ScriptedBasicPool pool, MockERC20 asset, uint256 avgA, uint256 avgQ, uint256 age) internal {
		pool.addObservation(age, 0, 0);
		(uint256 c0, uint256 c1) = _ordered(pool, asset, avgA * age, avgQ * age);
		pool.setCurrentCumulatives(c0, c1);
		_setReserves(pool, asset, avgA, avgQ);
	}

	function _setReserves(ScriptedBasicPool pool, MockERC20 asset, uint256 a, uint256 q) internal {
		(uint256 r0, uint256 r1) = _ordered(pool, asset, a, q);
		pool.setReserves(r0, r1);
	}

	function _usdcPool() internal returns (ScriptedBasicPool) {
		return new ScriptedBasicPool(address(tkn), address(usdc), address(this), false);
	}

	function _answer(IPoolPriceAdapter adapter) internal view returns (int256 answer) {
		(, answer,,,) = adapter.latestRoundData();
	}

	// ─── price ───────────────────────────────────────────────────────────────────

	function test_pricesFromTheWindowsAverageReserves() public {
		ScriptedBasicPool pool = _usdcPool();
		_script(pool, tkn, HALF_M_TKN, ONE_M_USDC, 2 hours); // 1M USDC per 500k TKN = $2

		assertEq(_answer(_adapter(pool, tkn)), 2e18);
	}

	function test_pricesInUsdThroughTheQuoteTokensValueInterpreterPrice() public {
		ScriptedBasicPool pool = new ScriptedBasicPool(address(tkn), address(weth), address(this), false);
		_script(pool, tkn, 1_000e18, 1_000e18, 2 hours); // 1 WETH per TKN
		IPoolPriceAdapter adapter = _adapter(pool, tkn);

		assertEq(_answer(adapter), 2000e18);
		wethFeed.setAnswer(3000e8);
		assertEq(_answer(adapter), 3000e18);
	}

	function test_usesTheNewestObservationAtLeastThirtyMinutesOld() public {
		ScriptedBasicPool pool = _usdcPool();
		// from 3 h ago the average is $3; from 45 min ago (the newest old enough) it is $2
		(uint256 n0, uint256 n1) = _ordered(pool, tkn, HALF_M_TKN * 3 hours, 1_500_000e6 * 3 hours);
		(uint256 d0, uint256 d1) = _ordered(pool, tkn, HALF_M_TKN * 45 minutes, ONE_M_USDC * 45 minutes);
		pool.addObservation(3 hours, 0, 0);
		pool.addObservation(45 minutes, n0 - d0, n1 - d1);
		pool.setCurrentCumulatives(n0, n1);
		_setReserves(pool, tkn, HALF_M_TKN, ONE_M_USDC);

		assertEq(_answer(_adapter(pool, tkn)), 2e18);
	}

	function test_usesTheObservationBeforeWhenTheNewestIsUnderThirtyMinutesOld() public {
		ScriptedBasicPool pool = _usdcPool();
		// from 50 min ago the average is $2; from 10 min ago (too young) it is $3
		(uint256 n0, uint256 n1) = _ordered(pool, tkn, HALF_M_TKN * 50 minutes, ONE_M_USDC * 50 minutes);
		(uint256 d0, uint256 d1) = _ordered(pool, tkn, HALF_M_TKN * 10 minutes, 1_500_000e6 * 10 minutes);
		pool.addObservation(50 minutes, 0, 0);
		pool.addObservation(10 minutes, n0 - d0, n1 - d1);
		pool.setCurrentCumulatives(n0, n1);
		_setReserves(pool, tkn, HALF_M_TKN, ONE_M_USDC);

		assertEq(_answer(_adapter(pool, tkn)), 2e18);
	}

	function test_usesWhatHistoryThePoolHasWhenUnderThirtyMinutes() public {
		ScriptedBasicPool pool = _usdcPool();
		_script(pool, tkn, HALF_M_TKN, ONE_M_USDC, 10 minutes); // the pool's only observation

		assertEq(_answer(_adapter(pool, tkn)), 2e18);
	}

	function test_revertsWhenThePoolHasNoHistoryBeforeThisBlock() public {
		ScriptedBasicPool pool = _usdcPool();
		_script(pool, tkn, HALF_M_TKN, ONE_M_USDC, 0);
		IPoolPriceAdapter adapter = _adapter(pool, tkn);

		vm.expectRevert(PoolPriceAdapterBase.NoPriceHistory.selector);
		adapter.latestRoundData();
	}

	function test_doesNotRevertWhenSpotIsFarFromTheWindowPrice() public {
		ScriptedBasicPool pool = _usdcPool();
		_script(pool, tkn, HALF_M_TKN, ONE_M_USDC, 2 hours);
		_setReserves(pool, tkn, 100_000e18, ONE_M_USDC); // spot $10

		assertEq(_answer(_adapter(pool, tkn)), 2e18);
	}

	function test_neverAnswersZero() public {
		MockERC20 dust = new MockERC20('Dust', 'DUST', 0);
		ScriptedBasicPool pool = new ScriptedBasicPool(address(dust), address(usdc), address(this), false);
		// 10k USDC per 1e40 whole DUST = $1e-36 per DUST: rounds to 0 at 18 decimals
		_script(pool, dust, 1e40, 10_000e6, 2 hours);

		assertEq(_answer(_adapter(pool, dust)), 1);
	}

	function test_anEmptyAssetSideAnswersOneInsteadOfDividingByZero() public {
		ScriptedBasicPool pool = _usdcPool();
		_script(pool, tkn, 0, ONE_M_USDC, 2 hours);

		assertEq(_answer(_adapter(pool, tkn)), 1);
	}

	// ─── liquidity ───────────────────────────────────────────────────────────────

	function test_liquidityIsTheCurrentReserveWhenTheWindowHadMore() public {
		ScriptedBasicPool pool = _usdcPool();
		_script(pool, tkn, HALF_M_TKN, ONE_M_USDC, 2 hours);
		_setReserves(pool, tkn, 20_000e18, 40_000e6);

		assertEq(_adapter(pool, tkn).liquidityUsd(), 40_000e18);
	}

	function test_liquidityIsTheWindowAverageWhenTheReserveIsHigher() public {
		ScriptedBasicPool pool = _usdcPool();
		_script(pool, tkn, HALF_M_TKN, ONE_M_USDC, 2 hours);
		_setReserves(pool, tkn, HALF_M_TKN * 2, ONE_M_USDC * 2); // liquidity just added

		assertEq(_adapter(pool, tkn).liquidityUsd(), 1_000_000e18);
	}

	function test_liquidityIsCountedInUsdAtTheQuotePrice() public {
		ScriptedBasicPool pool = new ScriptedBasicPool(address(tkn), address(weth), address(this), false);
		_script(pool, tkn, 10e18, 10e18, 2 hours); // 10 WETH at $2000

		assertEq(_adapter(pool, tkn).liquidityUsd(), 20_000e18);
	}

	function test_pricesNearZeroWhenThePoolWasDrained() public {
		ScriptedBasicPool pool = _usdcPool();
		_script(pool, tkn, HALF_M_TKN, ONE_M_USDC, 2 hours);
		_setReserves(pool, tkn, 2_000e18, 4_999e6); // under the $5,000 valuation minimum

		assertEq(_answer(_adapter(pool, tkn)), 1);
	}

	function test_pricesNearZeroWhenTheWindowAveragedUnderTheMinimum() public {
		ScriptedBasicPool pool = _usdcPool();
		_script(pool, tkn, 2_000e18, 4_000e6, 2 hours);
		_setReserves(pool, tkn, HALF_M_TKN, ONE_M_USDC); // liquidity added in the last moments

		assertEq(_answer(_adapter(pool, tkn)), 1);
	}

	function test_pricesNormallyAtExactlyTheValuationMinimum() public {
		ScriptedBasicPool pool = _usdcPool();
		_script(pool, tkn, HALF_M_TKN, ONE_M_USDC, 2 hours);
		_setReserves(pool, tkn, 2_500e18, 5_000e6);

		assertEq(_answer(_adapter(pool, tkn)), 2e18);
	}

	// ─── feed shape ──────────────────────────────────────────────────────────────

	function test_valueInterpreterPricesAHoldingThroughTheAdapter() public {
		ScriptedBasicPool pool = _usdcPool();
		_script(pool, tkn, HALF_M_TKN, ONE_M_USDC, 2 hours);
		IPoolPriceAdapter adapter = _adapter(pool, tkn);
		vm.prank(admin);
		vi.addPrimitive(address(tkn), address(adapter), 1 hours);

		// 3 TKN at $2 = 6 USDC
		assertEq(vi.calcCanonicalAssetValue(address(tkn), 3e18, address(usdc)), 6e6);
	}
}
