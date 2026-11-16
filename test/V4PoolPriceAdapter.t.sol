// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {IValueInterpreter} from '../src/interfaces/IValueInterpreter.sol';
import {IPoolPriceAdapter} from '../src/interfaces/IPoolPriceAdapter.sol';
import {IPoolWatch} from '../src/interfaces/IPoolWatch.sol';
import {ConcentratedPoolPriceAdapter} from '../src/pricing/ConcentratedPoolPriceAdapter.sol';
import {IV4PoolPriceAdapter} from '../src/interfaces/IV4PoolPriceAdapter.sol';
import {V4PoolPriceAdapter} from '../src/pricing/V4PoolPriceAdapter.sol';
import {V4PriceSampler} from '../src/pricing/V4PriceSampler.sol';
import {IV4StateView} from '../src/interfaces/external/IUniswapV4.sol';
import {TickMath} from '../src/libraries/TickMath.sol';
import {PoolPriceMath} from '../src/libraries/PoolPriceMath.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';
import {ScriptedCLPool} from './utils/PoolPriceMocks.sol';
import {MockStateView} from './utils/V4Mocks.sol';

/// @notice V4PoolPriceAdapter (spec 2026-10-08 §4.2): the median of the last hour's keeper samples, at least 4.
contract V4PoolPriceAdapterTest is Test {
	ValueInterpreter internal vi;
	MockERC20 internal usdc;
	MockERC20 internal weth;
	MockERC20 internal asset;
	MockStateView internal stateView;
	V4PriceSampler internal sampler;
	V4PoolPriceAdapter internal impl;
	address internal admin = makeAddr('admin');
	address internal keeper = makeAddr('keeper');
	bytes32 internal constant POOL = keccak256('stfy-like');
	/// @dev ≈ $0.0006 per asset when the asset is token1 against USDC (token0) — the STFY order of magnitude
	int24 internal constant TICK = -350_000;
	uint128 internal constant LIQ = 4e15;

	function setUp() public {
		vm.warp(30 days);
		vi = new ValueInterpreter(admin);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		weth = new MockERC20('Wrapped Ether', 'WETH', 18);
		asset = new MockERC20('Memestock', 'MEME', 18);
		vm.startPrank(admin);
		vi.addPrimitive(address(usdc), address(new MockAggregator(8, 1e8)), 25 hours);
		vi.addPrimitive(address(weth), address(new MockAggregator(8, 2000e8)), 1 hours);
		vm.stopPrank();
		stateView = new MockStateView();
		sampler = new V4PriceSampler(IV4StateView(address(stateView)), address(this));
		sampler.setKeeper(keeper, true);
		impl = new V4PoolPriceAdapter();
		_setPool(TICK, LIQ);
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	function _setPool(int24 tick, uint128 liquidity) internal {
		stateView.setPool(POOL, TickMath.getSqrtRatioAtTick(tick), tick, liquidity);
	}

	function _sampleEvery10Min(uint256 n) internal {
		bytes32[] memory ids = new bytes32[](1);
		ids[0] = POOL;
		for (uint256 i; i < n; ++i) {
			vm.prank(keeper);
			sampler.sample(ids);
			skip(10 minutes);
		}
	}

	/// @dev Asset is token1, quote (USDC or WETH) token0 unless `assetIsToken0`.
	function _adapter(MockERC20 quote, bool assetIsToken0) internal returns (IPoolPriceAdapter) {
		bytes memory args = abi.encode(
			IPoolPriceAdapter.Config({
				valueInterpreter: IValueInterpreter(address(vi)),
				pool: address(0xbeef),
				asset: address(asset),
				quoteAsset: address(quote),
				assetIsToken0: assetIsToken0,
				assetDecimals: 18,
				quoteDecimals: quote.decimals()
			}),
			IV4PoolPriceAdapter.V4Extra({sampler: sampler, stateView: IV4StateView(address(stateView)), poolId: POOL})
		);
		return IPoolPriceAdapter(Clones.cloneWithImmutableArgs(address(impl), args));
	}

	/// @dev The USDC-quoted price of the asset (token1) at `tick`, straight from the shared math.
	function _expectedAt(int24 tick) internal pure returns (uint256) {
		return PoolPriceMath.usdPerAssetAtSqrtP(TickMath.getSqrtRatioAtTick(tick), false, 18, 6, 1e18);
	}

	function _price(IPoolPriceAdapter feed) internal view returns (uint256) {
		(, int256 answer,,,) = feed.latestRoundData();
		return uint256(answer);
	}

	// ─── tests ───────────────────────────────────────────────────────────────────

	/// Same tick and liquidity as a v3 pool priced by the concentrated feed: same price, the same liquidity to 1e-14.
	function test_matchesTheConcentratedFeedAtTheSameTickAndLiquidity() public {
		ScriptedCLPool v3 = new ScriptedCLPool(address(usdc), address(asset), address(this), 3000, 60);
		bool assetIsToken0 = v3.token0() == address(asset);
		v3.setHistory(2 days);
		v3.setOracle(TICK, LIQ);
		usdc.mint(address(v3), type(uint128).max); // the v3 feed also caps by the quote the pool holds: make that not bind
		IPoolPriceAdapter v3Feed = IPoolPriceAdapter(
			Clones.cloneWithImmutableArgs(
				address(new ConcentratedPoolPriceAdapter()),
				abi.encode(
					IPoolPriceAdapter.Config({
						valueInterpreter: IValueInterpreter(address(vi)),
						pool: address(v3),
						asset: address(asset),
						quoteAsset: address(usdc),
						assetIsToken0: assetIsToken0,
						assetDecimals: 18,
						quoteDecimals: 6
					})
				)
			)
		);
		_sampleEvery10Min(6);
		IPoolPriceAdapter v4Feed = _adapter(usdc, assetIsToken0);
		assertEq(_price(v4Feed), _price(v3Feed), 'price');
		// the concentrated feed reads its window's liquidity as a harmonic mean of secondsPerLiquidity, which rounds in
		// the 16th digit; the v4 feed reads the sampled liquidity directly
		assertApproxEqRel(v4Feed.liquidityUsd(), v3Feed.liquidityUsd(), 1e4, 'liquidity');
		assertGt(_price(v4Feed), 1);
	}

	/// Spec Review Focus 1: until 4 samples sit in the last hour, neither a price nor a liquidity reads — the warm-up.
	function test_warmup_refusesPriceAndLiquidity() public {
		IPoolPriceAdapter feed = _adapter(usdc, false);
		_sampleEvery10Min(3);
		vm.expectRevert(V4PoolPriceAdapter.NoPriceHistory.selector);
		feed.latestRoundData();
		vm.expectRevert(V4PoolPriceAdapter.NoPriceHistory.selector);
		feed.liquidityUsd();
		_sampleEvery10Min(1);
		assertGt(_price(feed), 1);
		assertGt(feed.liquidityUsd(), 0);
	}

	/// Samples older than an hour don't count: a stopped keeper ends the price within the hour.
	function test_window_ignoresSamplesOlderThanAnHour() public {
		IPoolPriceAdapter feed = _adapter(usdc, false);
		_sampleEvery10Min(6);
		assertGt(_price(feed), 1);
		skip(30 minutes); // newest sample is now 40 min old, oldest 90: 3 left in the window
		vm.expectRevert(V4PoolPriceAdapter.NoPriceHistory.selector);
		feed.latestRoundData();
	}

	/// Two pumped readings out of six don't move the median: it prices at the unpumped tick.
	function test_median_ignoresTwoOutliersOfSix() public {
		IPoolPriceAdapter feed = _adapter(usdc, false);
		_sampleEvery10Min(4);
		_setPool(TICK + 20_000, LIQ); // a pumped price (≈ ×7)
		_sampleEvery10Min(2);
		// sorted [T,T,T,T,T+20k,T+20k]: both middles are T
		assertEq(_price(feed), _expectedAt(TICK));
	}

	/// Liquidity is the lower of now and the sampled median: adding liquidity right before a check doesn't count,
	/// pulling it does at once.
	function test_liquidity_takesTheLowerOfNowAndTheMedian() public {
		IPoolPriceAdapter feed = _adapter(usdc, false);
		_sampleEvery10Min(6);
		uint256 base = feed.liquidityUsd();
		_setPool(TICK, LIQ * 100); // just-in-time liquidity
		assertEq(feed.liquidityUsd(), base, 'JIT liquidity ignored');
		_setPool(TICK, LIQ / 4); // pulled
		assertApproxEqRel(feed.liquidityUsd(), base / 4, 1e15, 'pulled liquidity counts at once');
	}

	/// The current term reads the pool at its current price, not the median's: the same liquidity moved to a price
	/// where the quote side is worth less shows up in the buy floor at once (final review 2026-10-08, test gap).
	function test_liquidity_readsNowAtTheCurrentPrice() public {
		IPoolPriceAdapter feed = _adapter(usdc, false); // asset token1, USDC token0: quote reserve = L / √P
		_sampleEvery10Min(6);
		uint256 base = feed.liquidityUsd();
		_setPool(TICK + 20_000, LIQ); // same L, √P ×e^1 (≈ ×2.72): L/√P falls to ≈ 37%
		assertApproxEqRel(feed.liquidityUsd(), base * 3_679 / 10_000, 1e15, 'now at the current price');
		_setPool(TICK - 20_000, LIQ); // the other way the reserve grows: the median binds
		assertEq(feed.liquidityUsd(), base, 'never above the sampled median');
	}

	/// The ≈ $0 rule reads the sampled median only: an LP pulling everything for one call (free inside a v4 unlock)
	/// can't make the token read 1 wei for a deposit executed in that call; the buy floor still sees it at once
	/// (final review 2026-10-08, M1).
	function test_valuation_ignoresAFlashPullOfLiquidity() public {
		IPoolPriceAdapter feed = _adapter(usdc, false);
		_sampleEvery10Min(6);
		uint256 price = _price(feed);
		_setPool(TICK, 0); // everything pulled, mid-transaction
		assertEq(feed.liquidityUsd(), 0, 'no buys');
		assertEq(_price(feed), price, 'still valued at the median');
	}

	/// …and a real rug reaches 1 wei once the hour's median shows it (half the readings), not before.
	function test_valuation_aRugReachesOneWeiWithTheMedian() public {
		IPoolPriceAdapter feed = _adapter(usdc, false);
		_sampleEvery10Min(6);
		_setPool(TICK, 1); // rugged: dust left
		_sampleEvery10Min(2); // sorted liquidity [1,1,L,L,L,L]: lower middle still L
		assertGt(_price(feed), 1);
		_sampleEvery10Min(2); // [1,1,1,1,L,L] in the last hour: lower middle 1
		assertEq(_price(feed), 1);
	}

	/// Under $5k of liquidity the token is worth ≈ $0 (1 wei), same rule as today's pool feeds.
	function test_underFiveThousand_valuesAtOneWei() public {
		IPoolPriceAdapter feed = _adapter(usdc, false);
		_setPool(TICK, 1); // dust liquidity
		_sampleEvery10Min(6);
		assertLt(feed.liquidityUsd(), 5_000e18);
		assertEq(_price(feed), 1);
	}

	/// A native-ETH pool is configured with WETH as the quote: it prices with WETH's USD rate.
	function test_nativeEthQuote_pricesWithWeth() public {
		_sampleEvery10Min(6);
		uint256 viaUsdc = _price(_adapter(usdc, false));
		uint256 viaWeth = _price(_adapter(weth, false));
		// same raw ratio: WETH is $2,000 and has 18 decimals, USDC $1 and 6 decimals
		assertApproxEqRel(viaWeth, viaUsdc * 2_000 / 1e12, 1e12);
	}

	/// Four in-window samples (even count): the price is the average of the two middle ticks.
	function test_evenCount_averagesTheMiddleTicks() public {
		IPoolPriceAdapter feed = _adapter(usdc, false);
		_sampleEvery10Min(2);
		_setPool(TICK + 200, LIQ);
		_sampleEvery10Min(2);
		// sorted [T, T, T+200, T+200] → (T + T+200) / 2 = T+100
		assertEq(_price(feed), _expectedAt(TICK + 100));
	}

	/// An odd negative sum rounds toward −∞, as Uniswap's mean tick does.
	function test_evenCount_negativeAverageRoundsDown() public {
		IPoolPriceAdapter feed = _adapter(usdc, false);
		_setPool(-3, LIQ);
		_sampleEvery10Min(2);
		_setPool(-2, LIQ);
		_sampleEvery10Min(2);
		// (−3 + −2) / 2 = −2.5 → −3
		assertEq(_price(feed), _expectedAt(-3));
	}

	function test_v4Extra_isTheCloneArgs() public {
		V4PoolPriceAdapter feed = V4PoolPriceAdapter(address(_adapter(usdc, false)));
		IV4PoolPriceAdapter.V4Extra memory e = feed.v4Extra();
		assertEq(address(e.sampler), address(sampler));
		assertEq(e.poolId, POOL);
		assertEq(feed.config().asset, address(asset));
	}

	/// The pool now under half the sampled median is unsettled at once (review 2026-11-01).
	function test_liquidityUnderHalfNowIsUnsettled() public {
		_setPool(0, 1e18);
		_sampleEvery10Min(6);
		IPoolWatch feed = IPoolWatch(address(_adapter(usdc, true)));
		assertFalse(feed.poolUnsettled(), 'steady');
		_setPool(0, 1e18 / 2);
		assertFalse(feed.poolUnsettled(), 'half is the line');
		_setPool(0, 1e18 / 2 - 1e6);
		assertTrue(feed.poolUnsettled());
	}
}
