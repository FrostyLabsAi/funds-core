// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {TwapAggregatorAdapter, IConcentratedPoolOracle} from '../src/pricing/TwapAggregatorAdapter.sol';
import {AggregatorV3Interface} from '../src/interfaces/AggregatorV3Interface.sol';
import {TickMath} from '../src/libraries/TickMath.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';

/// @dev A pool whose oracle is scripted: cumulatives are built from a constant tick and
///      liquidity over the window, exactly as Uniswap v3 accumulates them.
contract ScriptedPool {
	address public token0;
	address public token1;
	int24 public spotTick;
	int24 public meanTick;
	uint128 public meanLiquidity;
	bool public young; // cannot serve the window

	constructor(address a, address b) {
		(token0, token1) = a < b ? (a, b) : (b, a);
	}

	function set(int24 spot, int24 mean, uint128 liquidity) external {
		spotTick = spot;
		meanTick = mean;
		meanLiquidity = liquidity;
	}

	function setYoung(bool y) external {
		young = y;
	}

	function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory tc, uint160[] memory spl) {
		require(!young, 'OLD');
		tc = new int56[](2);
		spl = new uint160[](2);
		uint32 span = secondsAgos[0] - secondsAgos[1];
		tc[0] = 1_000_000;
		tc[1] = 1_000_000 + int56(meanTick) * int56(uint56(span));
		spl[0] = 7;
		spl[1] = 7 + uint160((uint256(span) << 128) / meanLiquidity);
	}

	function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool) {
		return (TickMath.getSqrtRatioAtTick(spotTick), spotTick, 0, 900, 900, true);
	}

	// Flat liquidity profile (no initialized ticks): the band minimum equals the current
	// in-range liquidity, which is scripted equal to the window's harmonic mean.
	function tickSpacing() external pure returns (int24) {
		return 60;
	}

	function liquidity() external view returns (uint128) {
		return meanLiquidity;
	}

	function tickBitmap(int16) external pure returns (uint256) {
		return 0;
	}
}

contract TwapAggregatorAdapterTest is Test {
	MockERC20 internal weth;
	MockERC20 internal usdc;
	MockAggregator internal usdcFeed;
	ScriptedPool internal pool;
	TwapAggregatorAdapter internal adapter;

	// 1 WETH (18) = 2,500 USDC (6): raw price 2500e6/1e18 = 2.5e-9 → tick ≈ ln(2.5e-9)/ln(1.0001)
	int24 internal constant TICK_2500 = -198_080; // 1.0001^-198080 × 1e12 ≈ 2,499.8

	function setUp() public {
		vm.warp(10 days);
		// fixed addresses: WETH is token0, like the real Base pools (0x4200… < 0x8335…)
		deployCodeTo('Mocks.sol:MockERC20', abi.encode('Wrapped Ether', 'WETH', uint8(18)), address(0x1111));
		deployCodeTo('Mocks.sol:MockERC20', abi.encode('USD Coin', 'USDC', uint8(6)), address(0x2222));
		weth = MockERC20(address(0x1111));
		usdc = MockERC20(address(0x2222));
		usdcFeed = new MockAggregator(8, 1e8);
		pool = new ScriptedPool(address(weth), address(usdc));
		pool.set(TICK_2500, TICK_2500, 1e18);
		adapter = _adapter(address(weth), 50_000, 500);
	}

	function _adapter(address asset, uint256 floorUsd, uint16 devBps) internal returns (TwapAggregatorAdapter) {
		return new TwapAggregatorAdapter(
			IConcentratedPoolOracle(address(pool)), asset, AggregatorV3Interface(address(usdcFeed)), 30 minutes, floorUsd, devBps, 1 days, 'WETH / USD (TWAP)'
		);
	}

	function _price() internal view returns (uint256) {
		(, int256 answer,,,) = adapter.latestRoundData();
		return uint256(answer);
	}

	function _expectedUsd18(int24 tick, bool assetIsToken0) internal pure returns (uint256) {
		// 1.0001^tick as raw quote/asset, rescaled 1e18 asset → 1e6 quote → 18-dp USD
		uint256 sqrt = TickMath.getSqrtRatioAtTick(tick);
		uint256 raw = assetIsToken0 ? (sqrt * sqrt * 1e18) >> 192 : (uint256(1) << 192) * 1e6 / (sqrt * sqrt);
		return raw * 1e12;
	}

	// ─── price ──────────────────────────────────────────────────────────────────

	function test_pricesTheMeanTick_18Decimals() public view {
		assertEq(adapter.decimals(), 18);
		uint256 p = _price();
		assertApproxEqRel(p, 2_500e18, 0.001e18); // tick chosen for ≈$2,500
		assertEq(p, _expectedUsd18(TICK_2500, true));
	}

	function test_quoteFeedScalesThePrice() public {
		usdcFeed.setAnswer(0.99e8);
		assertApproxEqRel(_price(), 2_475e18, 0.001e18);
	}

	function test_assetAsToken1_pricesTheInverse() public {
		// price USDC in WETH-terms against a $2,500 WETH feed → ≈ $1
		MockAggregator ethFeed = new MockAggregator(8, 2_500e8);
		TwapAggregatorAdapter usdcAdapter = new TwapAggregatorAdapter(
			IConcentratedPoolOracle(address(pool)), address(usdc), AggregatorV3Interface(address(ethFeed)), 30 minutes, 50_000, 500, 1 days, 'USDC / USD (TWAP)'
		);
		(, int256 answer,,,) = usdcAdapter.latestRoundData();
		assertApproxEqRel(uint256(answer), 1e18, 0.001e18);
	}

	function test_meanTickRoundsTowardNegativeInfinity() public {
		// a cumulative delta not divisible by the window: OracleLibrary floors, never truncates toward 0
		ScriptedPoolOdd odd = new ScriptedPoolOdd(address(weth), address(usdc));
		TwapAggregatorAdapter a = new TwapAggregatorAdapter(
			IConcentratedPoolOracle(address(odd)), address(weth), AggregatorV3Interface(address(usdcFeed)), 30 minutes, 1, 500, 1 days, ''
		);
		(int24 meanTick,) = a.consult();
		assertEq(meanTick, -198_081); // −198080.5 floors to −198081
	}

	// ─── guards ─────────────────────────────────────────────────────────────────

	function test_spotAwayFromTwap_reverts_bothDirections() public {
		// the 5% cap lands between ticks: 1.0001^487 = 1.04990 (inside), 1.0001^488 = 1.05001 (outside)
		pool.set(TICK_2500 + 487, TICK_2500, 1e18);
		assertGt(_price(), 0, '+4.99% still prices');
		pool.set(TICK_2500 - 487, TICK_2500, 1e18);
		assertGt(_price(), 0, '-4.75% still prices');
		pool.set(TICK_2500 + 488, TICK_2500, 1e18);
		vm.expectRevert(abi.encodeWithSelector(TwapAggregatorAdapter.SpotDeviatesFromTwap.selector, TICK_2500 + 488, TICK_2500));
		adapter.latestRoundData();
		pool.set(TICK_2500 - 488, TICK_2500, 1e18); // symmetric in ratio: TWAP is 5.001% above spot
		vm.expectRevert(abi.encodeWithSelector(TwapAggregatorAdapter.SpotDeviatesFromTwap.selector, TICK_2500 - 488, TICK_2500));
		adapter.latestRoundData();
	}

	/// Under the floor the price keeps flowing (founder decision 2026-09-24) — the floor is
	/// REPORTED, and the registry's 72h clock acts on it.
	function test_liquidityFloor_isReportedNotEnforced() public {
		uint256 depth = adapter.poolDepthUsd();
		assertGt(depth, 0);
		TwapAggregatorAdapter strict = _adapter(address(weth), depth / 1e18 + 1, 500);
		assertTrue(strict.isBelowFloor());
		(, int256 answer,,,) = strict.latestRoundData();
		assertEq(uint256(answer), _price(), 'same market price under the floor');
		assertFalse(_adapter(address(weth), depth / 1e18, 500).isBelowFloor());
	}

	/// Depth = what the liquidity holds within ±10% of the mean price. Closed form, evaluated
	/// off-chain at 60-digit precision for tick −198080, L = 1e18:
	///   USDC side L·(√P − √P_lower) = $2,566,602 · WETH side L·(1/√P − 1/√P_upper)·P = $2,326,474
	function test_depthIsTheTenPercentBand() public view {
		assertApproxEqRel(adapter.poolDepthUsd(), 4_893_076e18, 0.0001e18);
	}

	function test_liquidityPullInsideTheWindow_dragsTheHarmonicMeanUnderTheFloor() public {
		// 29 min at L, 1 min at L/1000 → harmonic mean ≈ L/33.3, the arithmetic mean would be ≈ 0.97 L
		// the unpulled pool clears a $1M floor ($4.89M depth) …
		assertGt(_adapter(address(weth), 1_000_000, 500).poolDepthUsd(), 1_000_000e18);
		ScriptedPoolPulled pulled = new ScriptedPoolPulled(address(weth), address(usdc), TICK_2500, 1e18, 1e15, 60);
		TwapAggregatorAdapter a = new TwapAggregatorAdapter(
			IConcentratedPoolOracle(address(pulled)), address(weth), AggregatorV3Interface(address(usdcFeed)), 30 minutes, 1_000_000, 500, 1 days, ''
		);
		(, uint128 meanLiquidity) = a.consult();
		assertApproxEqRel(meanLiquidity, uint256(1e18) * 1800 / (1740 + 60_000), 0.001e18);
		// … one minute at 1/1000th of the liquidity leaves ≈ $142,655 of harmonic-mean depth
		assertApproxEqRel(a.poolDepthUsd(), 142_655e18, 0.001e18);
		assertTrue(a.isBelowFloor());
	}

	function test_youngPool_reverts() public {
		pool.setYoung(true);
		vm.expectRevert(TwapAggregatorAdapter.ObservationWindowUnavailable.selector);
		adapter.latestRoundData();
	}

	function test_quoteLeg_staleOrNonPositive_reverts() public {
		usdcFeed.setUpdatedAt(block.timestamp - 1 days - 1);
		vm.expectRevert(abi.encodeWithSelector(TwapAggregatorAdapter.QuoteStale.selector, block.timestamp - 1 days - 1));
		adapter.latestRoundData();
		usdcFeed.setAnswer(0);
		vm.expectRevert(abi.encodeWithSelector(TwapAggregatorAdapter.QuoteNonPositive.selector, int256(0)));
		adapter.latestRoundData();
	}

	function test_updatedAtIsNow() public {
		skip(3 hours);
		usdcFeed.setAnswer(1e8);
		(,,, uint256 updatedAt,) = adapter.latestRoundData();
		assertEq(updatedAt, block.timestamp);
	}

	// ─── constructor ────────────────────────────────────────────────────────────

	function test_constructor_rejectsBadParameters() public {
		IConcentratedPoolOracle p = IConcentratedPoolOracle(address(pool));
		AggregatorV3Interface f = AggregatorV3Interface(address(usdcFeed));
		vm.expectRevert(abi.encodeWithSelector(TwapAggregatorAdapter.WindowTooShort.selector, uint32(29 minutes)));
		new TwapAggregatorAdapter(p, address(weth), f, 29 minutes, 50_000, 500, 1 days, '');
		vm.expectRevert(abi.encodeWithSelector(TwapAggregatorAdapter.BadDeviation.selector, uint16(2_001)));
		new TwapAggregatorAdapter(p, address(weth), f, 30 minutes, 50_000, 2_001, 1 days, '');
		vm.expectRevert(abi.encodeWithSelector(TwapAggregatorAdapter.BadDeviation.selector, uint16(0)));
		new TwapAggregatorAdapter(p, address(weth), f, 30 minutes, 50_000, 0, 1 days, '');
		vm.expectRevert(TwapAggregatorAdapter.ZeroArgument.selector);
		new TwapAggregatorAdapter(p, address(weth), f, 30 minutes, 0, 500, 1 days, '');
		address stranger = address(new MockERC20('X', 'X', 18));
		vm.expectRevert(abi.encodeWithSelector(TwapAggregatorAdapter.AssetNotInPool.selector, stranger));
		new TwapAggregatorAdapter(p, stranger, f, 30 minutes, 50_000, 500, 1 days, '');
	}

	function test_constructor_resolvesTheQuoteSide() public view {
		assertEq(adapter.asset(), address(weth));
		assertEq(adapter.quoteAsset(), address(usdc));
		assertEq(adapter.assetIsToken0(), address(weth) < address(usdc));
	}
}

/// @dev Tick cumulative delta −198080.5 × window: forces the floor rounding path.
contract ScriptedPoolOdd {
	address public token0;
	address public token1;

	constructor(address a, address b) {
		(token0, token1) = a < b ? (a, b) : (b, a);
	}

	function observe(uint32[] calldata secondsAgos) external pure returns (int56[] memory tc, uint160[] memory spl) {
		tc = new int56[](2);
		spl = new uint160[](2);
		tc[1] = -int56(198_080) * int56(uint56(secondsAgos[0])) - int56(uint56(secondsAgos[0] / 2));
		spl[1] = uint160((uint256(secondsAgos[0]) << 128) / 1e18);
	}
}

/// @dev Liquidity L for the window except the last `pulledSeconds`, which run at L_pulled.
contract ScriptedPoolPulled {
	address public token0;
	address public token1;
	int24 internal tick;
	uint128 internal l;
	uint128 internal lPulled;
	uint32 internal pulledSeconds;

	constructor(address a, address b, int24 tick_, uint128 l_, uint128 lPulled_, uint32 pulledSeconds_) {
		(token0, token1) = a < b ? (a, b) : (b, a);
		(tick, l, lPulled, pulledSeconds) = (tick_, l_, lPulled_, pulledSeconds_);
	}

	function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory tc, uint160[] memory spl) {
		tc = new int56[](2);
		spl = new uint160[](2);
		uint32 span = secondsAgos[0];
		tc[1] = int56(tick) * int56(uint56(span));
		spl[1] = uint160(((uint256(span - pulledSeconds) << 128) / l) + ((uint256(pulledSeconds) << 128) / lPulled));
	}

	function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool) {
		return (TickMath.getSqrtRatioAtTick(tick), tick, 0, 1, 1, true);
	}
	// Liquidity is back to L now (flat profile) — only the window's harmonic mean remembers the pull
	function tickSpacing() external pure returns (int24) {
		return 60;
	}

	function liquidity() external view returns (uint128) {
		return l;
	}

	function tickBitmap(int16) external pure returns (uint256) {
		return 0;
	}
}
