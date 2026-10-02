// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {UniswapV2TwapAdapter} from '../src/pricing/UniswapV2TwapAdapter.sol';
import {UniswapV2ObservationRecorder, IUniswapV2Pair} from '../src/pricing/UniswapV2ObservationRecorder.sol';
import {AggregatorV3Interface} from '../src/interfaces/AggregatorV3Interface.sol';
import {ITwapPriceAdapter} from '../src/interfaces/ITwapPriceAdapter.sol';
import {IValueInterpreter} from '../src/interfaces/IValueInterpreter.sol';

/// @notice UniswapV2Pair functions the test needs beyond the adapter's read surface (verified
///         source on Basescan, Solidity 0.5.16).
interface IUniswapV2PairExtras {
	function factory() external view returns (address);
	function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
	function mint(address to) external returns (uint256 liquidity);
	function skim(address to) external;
	function sync() external;
}

/// @notice Uniswap v2 factory 0x8909…8eC6 (= router02.factory()).
interface IUniswapV2Factory {
	function getPair(address tokenA, address tokenB) external view returns (address);
	function createPair(address tokenA, address tokenB) external returns (address);
}

/// @notice Uniswap v2 Router02 0x4752…aD24: the 0.3%-fee amount-out formula.
interface IUniswapV2Router02 {
	function factory() external view returns (address);
	function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) external pure returns (uint256);
}

/// @notice The Uniswap v2 TWAP adapter on real Base pairs, every orientation:
///         AGNT/USDC (asset = token0, 6-decimal quote), OPAL/WETH (asset = token0, WETH quote),
///         DINO/WETH (asset = token1, WETH quote), RFG/USDC (asset = token1, sub-$0.0001) and
///         SPN/USDC (asset = token0, sub-$0.0001). The recorder's counterfactual cumulatives are pinned
///         to the pair's own accrual (`sync()`), each price to an independent full-precision
///         computation from the cumulatives, and the wrap handling (cumulatives mod 2^256, time mod
///         2^32) to the pair's own unchecked 0.5.16 arithmetic.
///         Feeds: ETH/USD updates at most ~1232 s apart on Base (cast, 2026-09-30) against the
///         registry's 3600 s heartbeat, so WETH-quoted tests warp at most 31 min; USDC-quoted tests
///         warp at most 40 min against 90_000 s (feed heartbeat 86_400 s). Every warp that reads a
///         feed asserts it is still fresh; the two time-wrap tests (year 2106) read consult() only.
///         Run: BASE_MAINNET_RPC=<url> [BASE_FORK_BLOCK=<n>] forge test --match-path test/UniswapV2TwapAdapterFork.t.sol -vv
contract UniswapV2TwapAdapterForkTest is Test {
	using SafeERC20 for IERC20;

	address internal constant WETH = 0x4200000000000000000000000000000000000006;
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	// FundsMainnet.CL_ETH_USD / CL_USDC_USD and the registry's quote heartbeats
	address internal constant ETH_USD = 0x50015f8b17fb2C290Dde41fDc246ed0dcEE93a8b;
	address internal constant USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
	uint32 internal constant WETH_HEARTBEAT = 1 hours;
	uint32 internal constant USDC_HEARTBEAT = 90_000;
	address internal constant FACTORY = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
	address internal constant ROUTER = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
	address internal constant VALUE_INTERPRETER = 0x3CDbaBE5Bf4E6cfE10A2A326E0ad31b2d16398D4;
	// Long-tail tokens with Uniswap v2 pairs (DefiLlama uniswap-v2, 2026-09-30); none VI-priced
	address internal constant AGNT = 0x7484a9fB40b16c4DFE9195Da399e808aa45E9BB9;
	address internal constant OPAL = 0x119B63B1605Be3A8ff4543c7F76f7f1f79eECd1f;
	address internal constant DINO = 0x85E90a5430AF45776548ADB82eE4cD9E33B08077;
	address internal constant RFG = 0xA5053C346f4759198bd6B64171db1Eff4CBA6331;
	address internal constant SPN = 0x035098c2A3bEa5e03b1E08e7140a5369D47Bd349;
	// factory.getPair(asset, quote) (cast, 2026-09-30)
	address internal constant AGNT_USDC = 0x378551Ab1B395B1E12a49aE3914DD8066860770D; // AGNT token0
	address internal constant OPAL_WETH = 0x3F2Bb479C96227805DD98d862f564AFC0131478c; // OPAL token0
	address internal constant DINO_WETH = 0x6a77CDeC82EFf6A6A5D273F18C1c27CD3d71A588; // DINO token1
	address internal constant RFG_USDC = 0x26D4Bb0EDb8f505eE25228a633040034b19ac4a9; // RFG token1
	address internal constant SPN_USDC = 0x51597f069B3A8CaD5c49C055aE7f4f80B70e36Db; // SPN token0

	uint32 internal constant WINDOW = 30 minutes;
	uint32 internal constant WARP = 31 minutes;
	uint16 internal constant MAX_DEVIATION_BPS = 500;
	/// @dev The registry's listing / delist-clock floor (MIN_QUOTE_RESERVE_USD), whole USD.
	uint256 internal constant MIN_QUOTE_RESERVE_USD = 25_000;
	uint256 internal constant BPS = 10_000;
	/// @dev floor((1 − √0.9) · 1e6), pinned independently by test_bandQuotePpmIsOneMinusSqrtPoint9
	uint256 internal constant BAND_QUOTE_PPM = 51_316;
	/// @dev The registry's band floor (MIN_BAND_DEPTH_USD, Ruling 23): MIN_QUOTE_RESERVE_USD × PPM / 1e6.
	uint256 internal constant MIN_BAND_DEPTH_USD = 1_282;
	/// @dev √0.9 · 1e18 = sqrt(0.9e36)
	uint256 internal constant SQRT_POINT9_E18 = 948_683_298_050_513_799;
	uint256 internal constant Q112 = 2 ** 112;
	/// @dev 1e-6 relative, for assertApproxEqRel
	uint256 internal constant PPM_REL = 1e12;
	// UniswapV2Pair storage: slot 8 packs (reserve0, reserve1, blockTimestampLast); 9 and 10 are the
	// cumulatives (cast storage == the getters on all five pairs)
	bytes32 internal constant SLOT_PRICE0_CUMULATIVE = bytes32(uint256(9));
	bytes32 internal constant SLOT_PRICE1_CUMULATIVE = bytes32(uint256(10));

	bool internal forked;
	UniswapV2ObservationRecorder internal recorder;

	/// @dev A pair's asset-side cumulative price and the time it was read, taken by the test itself.
	struct Mark {
		uint256 cumulative;
		uint256 time;
	}

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		uint256 blockNumber = vm.envOr('BASE_FORK_BLOCK', uint256(0));
		if (blockNumber > 0) vm.createSelectFork(rpc, blockNumber);
		else vm.createSelectFork(rpc);
		forked = true;
		recorder = new UniswapV2ObservationRecorder();
	}

	// ─── constants and premises ──────────────────────────────────────────────────

	/// @notice BAND_QUOTE_PPM = floor((1 − √0.9) · 1e6): (1e6 − PPM − 1)² < 0.9e12 ≤ (1e6 − PPM)².
	function test_bandQuotePpmIsOneMinusSqrtPoint9() public pure {
		uint256 ppm = BAND_QUOTE_PPM;
		assertLt((1e6 - ppm - 1) ** 2, 0.9e12, 'rounded down');
		assertGe((1e6 - ppm) ** 2, 0.9e12, 'by less than one ppm');
		assertEq(SQRT_POINT9_E18, Math.sqrt(0.9e36));
	}

	/// @notice Every pair is the factory's pair for its tokens, its asset is not ValueInterpreter-
	///         priced, and its sides are as the orientation tests assume.
	function test_fork_candidatePairsAreFactoryPairsAndUnpriced() public {
		vm.skip(!forked);
		assertEq(IUniswapV2Router02(ROUTER).factory(), FACTORY, 'router02.factory()');
		_assertCandidate(AGNT_USDC, AGNT, USDC, true);
		_assertCandidate(OPAL_WETH, OPAL, WETH, true);
		_assertCandidate(DINO_WETH, DINO, WETH, false);
		_assertCandidate(RFG_USDC, RFG, USDC, false);
		_assertCandidate(SPN_USDC, SPN, USDC, true);
	}

	/// @notice The recorder's counterfactual is UniswapV2OracleLibrary's: stored cumulative + the
	///         current UQ112x112 price × (now − blockTimestampLast). After record() and a 31-minute
	///         warp with no swap, it equals what the pair itself accrues when sync() runs then.
	function test_fork_counterfactualEqualsThePairsOwnAccrual() public {
		vm.skip(!forked);
		address[5] memory pairs = [AGNT_USDC, OPAL_WETH, DINO_WETH, RFG_USDC, SPN_USDC];
		for (uint256 k; k < pairs.length; k++) {
			_assertCounterfactualIsLibraryFormula(pairs[k]);
			assertTrue(recorder.record(pairs[k]));
			UniswapV2ObservationRecorder.Snapshot memory s = recorder.snapshotAtLeast(pairs[k], 0);
			assertEq(s.price0Cumulative, _pairCumulative(pairs[k], true), 'snapshot price0');
			assertEq(s.price1Cumulative, _pairCumulative(pairs[k], false), 'snapshot price1');
			assertEq(s.timestamp, uint32(block.timestamp));
		}
		_warpRoll(WARP);
		for (uint256 k; k < pairs.length; k++) {
			_assertCounterfactualIsLibraryFormula(pairs[k]);
			(uint256 c0, uint256 c1,) = recorder.currentCumulativePrices(pairs[k]);
			IUniswapV2PairExtras(pairs[k]).sync();
			assertEq(IUniswapV2Pair(pairs[k]).price0CumulativeLast(), c0, 'pair accrues price0 to the counterfactual');
			assertEq(IUniswapV2Pair(pairs[k]).price1CumulativeLast(), c1, 'pair accrues price1 to the counterfactual');
		}
	}

	// ─── (a)+(d) prices real pairs, both orientations ────────────────────────────

	/// @notice asset = token0, USDC (6 decimals) quote.
	function test_fork_pricesAgntUsdc_assetToken0() public {
		vm.skip(!forked);
		_assertPricesRealPair(AGNT_USDC, AGNT, USDC_USD, USDC_HEARTBEAT, true);
	}

	/// @notice asset = token0, WETH quote (OPAL sorts below WETH).
	function test_fork_pricesOpalWeth_assetToken0() public {
		vm.skip(!forked);
		_assertPricesRealPair(OPAL_WETH, OPAL, ETH_USD, WETH_HEARTBEAT, true);
	}

	/// @notice asset = token1, WETH quote.
	function test_fork_pricesDinoWeth_assetToken1() public {
		vm.skip(!forked);
		_assertPricesRealPair(DINO_WETH, DINO, ETH_USD, WETH_HEARTBEAT, false);
	}

	/// @notice The interface surface: the adapter is read through ITwapPriceAdapter.
	function test_fork_readsThroughITwapPriceAdapter() public {
		vm.skip(!forked);
		(UniswapV2TwapAdapter adapter,) = _primed(AGNT_USDC, AGNT, USDC_USD, USDC_HEARTBEAT);
		ITwapPriceAdapter a = adapter;
		assertEq(a.asset(), AGNT);
		assertEq(a.quoteAsset(), USDC);
		assertEq(a.decimals(), 18);
		(uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = a.latestRoundData();
		assertGt(answer, 0);
		assertEq(updatedAt, block.timestamp, "the read's own timestamp");
		assertEq(startedAt, block.timestamp);
		assertEq(roundId, uint80(block.timestamp));
		assertEq(answeredInRound, roundId);
		assertEq(
			a.isBelowFloor(),
			a.quoteReserveUsd() < MIN_QUOTE_RESERVE_USD * 1e18 || a.poolDepthUsd() < MIN_BAND_DEPTH_USD * 1e18,
			'the two-part floor'
		);
		assertGt(a.poolDepthUsd(), 0);
	}

	// ─── sub-$0.0001 USDC-quoted (Ruling 19) ─────────────────────────────────────

	/// @notice RFG (~$0.0000122, asset = token1): within 1e-6 of the full-precision reference; the
	///         old whole-raw-unit formula kept 12 raw USDC units per RFG (> 1% low).
	function test_fork_subCentUsdc_rfg_assetToken1() public {
		vm.skip(!forked);
		_assertSubCent(RFG_USDC, RFG, false);
	}

	/// @notice SPN (~$0.0000206, asset = token0).
	function test_fork_subCentUsdc_spn_assetToken0() public {
		vm.skip(!forked);
		_assertSubCent(SPN_USDC, SPN, true);
	}

	// ─── the window: which snapshot, time weighting ──────────────────────────────

	/// @notice A real swap 10 minutes into a 31-minute span: the average weights each price by its
	///         seconds, exactly, and the answer is that average × the feed, rounded once.
	function test_fork_twapWeightsEachPriceByItsSeconds_agnt() public {
		vm.skip(!forked);
		_assertTimeWeighted(AGNT_USDC, AGNT, USDC_USD, USDC_HEARTBEAT);
	}

	function test_fork_twapWeightsEachPriceByItsSeconds_dino() public {
		vm.skip(!forked);
		_assertTimeWeighted(DINO_WETH, DINO, ETH_USD, WETH_HEARTBEAT);
	}

	/// @notice Snapshots every 10 minutes with real swaps between: the adapter averages from the
	///         NEWEST snapshot at least 30 minutes old, at both the 30- and 40-minute marks.
	function test_fork_newestOldEnoughSnapshotIsUsed() public {
		vm.skip(!forked);
		UniswapV2TwapAdapter a = _adapter(AGNT_USDC, AGNT, USDC_USD, USDC_HEARTBEAT);
		Mark memory first = _record(AGNT_USDC, true);
		_warpRoll(10 minutes);
		_swapIn(AGNT_USDC, USDC, _quoteReserve(AGNT_USDC, true) / 100);
		Mark memory second = _record(AGNT_USDC, true);
		_warpRoll(10 minutes);
		_swapIn(AGNT_USDC, USDC, _quoteReserve(AGNT_USDC, true) / 100);
		_record(AGNT_USDC, true);
		_warpRoll(10 minutes); // first is exactly 30 minutes old
		assertEq(a.consult(), _average(first, _mark(AGNT_USDC, true)), 'from the 30-minute-old snapshot');

		_warpRoll(10 minutes); // second is now 30 minutes old, first 40
		Mark memory now_ = _mark(AGNT_USDC, true);
		uint256 fromSecond = _average(second, now_);
		assertEq(a.consult(), fromSecond, 'from the newest snapshot at least 30 minutes old');
		assertTrue(fromSecond != _average(first, now_), 'the older snapshot averages differently');
		_assertQuoteFresh(USDC_USD, USDC_HEARTBEAT);
		(, int256 answer,,,) = a.latestRoundData();
		assertEq(SafeCast.toUint256(answer), _priceFromAverage(a, fromSecond, USDC_USD));
	}

	// ─── (b) no window, no price ─────────────────────────────────────────────────

	/// @notice With no snapshot every read reverts NoSnapshot(pair); a snapshot serves only once it
	///         is a window old (WINDOW − 1 still reverts), then the pair prices.
	function test_fork_noSnapshotRevertsEveryRead() public {
		vm.skip(!forked);
		UniswapV2TwapAdapter a = _adapter(AGNT_USDC, AGNT, USDC_USD, USDC_HEARTBEAT);
		_assertNoSnapshot(a);
		assertTrue(recorder.record(AGNT_USDC));
		_assertNoSnapshot(a);
		_warpRoll(WINDOW - 1);
		_assertNoSnapshot(a);
		_warpRoll(1);
		_assertQuoteFresh(USDC_USD, USDC_HEARTBEAT);
		(, int256 answer,,,) = a.latestRoundData();
		(uint256 rA, uint256 rQ) = _reserves(AGNT_USDC, true);
		assertEq(SafeCast.toUint256(answer), _priceFromAverage(a, rQ * Q112 / rA, USDC_USD), 'priced at the idle reserves');
	}

	/// @notice A real pair created on the fork has zero reserves: record() and the counterfactual
	///         revert ZeroReserves. Once minted it records, and a window later prices at the minted
	///         reserves (asset = token0: OPAL sorts below USDC).
	function test_fork_newPairNeedsReservesAndAWindow() public {
		vm.skip(!forked);
		IUniswapV2Factory f = IUniswapV2Factory(FACTORY);
		assertEq(f.getPair(OPAL, USDC), address(0), 'no OPAL/USDC pair yet');
		address pair = f.createPair(OPAL, USDC);
		assertEq(IUniswapV2Pair(pair).token0(), OPAL);
		bytes memory zero = abi.encodeWithSelector(UniswapV2ObservationRecorder.ZeroReserves.selector, pair);
		vm.expectRevert(zero);
		recorder.record(pair);
		vm.expectRevert(zero);
		recorder.currentCumulativePrices(pair);

		UniswapV2TwapAdapter a = _adapter(pair, OPAL, USDC_USD, USDC_HEARTBEAT);
		_assertNoSnapshot(a);
		uint256 opalIn = 1_000_000e18;
		uint256 usdcIn = 40_000e6;
		_addLiquidity(pair, opalIn, usdcIn);
		assertTrue(recorder.record(pair));
		_warpRoll(WINDOW);
		_assertQuoteFresh(USDC_USD, USDC_HEARTBEAT);
		assertEq(a.consult(), usdcIn * Q112 / opalIn, 'the minted price, UQ112x112');
		(, int256 answer,,,) = a.latestRoundData();
		uint256 exact = Math.mulDiv(usdcIn * 1e18, _quoteUsd18(USDC_USD), opalIn * 1e6);
		assertLe(SafeCast.toUint256(answer), exact);
		assertApproxEqRel(SafeCast.toUint256(answer), exact, PPM_REL, 'the minted reserves x the feed');
		assertEq(a.quoteReserveUsd(), Math.mulDiv(usdcIn, _quoteUsd18(USDC_USD), 1e6));
	}

	/// @notice A real pair minted at 1 raw USDC per 1e30 raw OPAL (1e12 OPAL): ~0.9999e-18 USD per
	///         OPAL, just under one wei of the answer. Spot equals the TWAP, so the guard passes, and the
	///         read reverts PriceRoundsToZero rather than answer 0.
	function test_fork_priceBelowOneWeiRevertsPriceRoundsToZero() public {
		vm.skip(!forked);
		address pair = IUniswapV2Factory(FACTORY).createPair(OPAL, USDC);
		_addLiquidity(pair, 1e30, 1);
		UniswapV2TwapAdapter a = _adapter(pair, OPAL, USDC_USD, USDC_HEARTBEAT);
		assertTrue(recorder.record(pair));
		_warpRoll(WINDOW);
		_assertQuoteFresh(USDC_USD, USDC_HEARTBEAT);
		assertEq(a.consult(), Q112 / 1e30, 'one raw USDC per 1e30 raw OPAL');
		assertEq(_priceFromAverage(a, a.consult(), USDC_USD), 0, 'under one wei of USD');
		vm.expectRevert(UniswapV2TwapAdapter.PriceRoundsToZero.selector);
		a.latestRoundData();
	}

	// ─── (c) spot guard on real swaps ────────────────────────────────────────────

	/// @notice A same-block swap moves spot but not the TWAP: the answer is unchanged to the wei.
	function test_fork_sameBlockSwapCannotMoveTwap() public {
		vm.skip(!forked);
		(UniswapV2TwapAdapter a,) = _primed(DINO_WETH, DINO, ETH_USD, WETH_HEARTBEAT);
		(, int256 before,,,) = a.latestRoundData();
		uint256 spotBefore = _spotUsd(a);
		_swapIn(DINO_WETH, WETH, _quoteReserve(DINO_WETH, false) / 200); // ~ +1% spot
		assertGt(_spotUsd(a), spotBefore, 'spot moved up');
		(, int256 afterSwap,,,) = a.latestRoundData();
		assertEq(afterSwap, before, 'TWAP unmoved');
	}

	function test_fork_spotGuardTripsOnSell_agnt() public {
		vm.skip(!forked);
		_assertSwapTripsGuard(AGNT_USDC, AGNT, USDC_USD, USDC_HEARTBEAT, true);
	}

	function test_fork_spotGuardTripsOnBuy_agnt() public {
		vm.skip(!forked);
		_assertSwapTripsGuard(AGNT_USDC, AGNT, USDC_USD, USDC_HEARTBEAT, false);
	}

	function test_fork_spotGuardTripsOnSell_dino() public {
		vm.skip(!forked);
		_assertSwapTripsGuard(DINO_WETH, DINO, ETH_USD, WETH_HEARTBEAT, true);
	}

	function test_fork_spotGuardTripsOnBuy_dino() public {
		vm.skip(!forked);
		_assertSwapTripsGuard(DINO_WETH, DINO, ETH_USD, WETH_HEARTBEAT, false);
	}

	/// @notice At ~$0.0000122 the guard still trips on a real ~8% swap with the exact USD prices.
	function test_fork_spotGuardTripsOnBuy_rfgSubCent() public {
		vm.skip(!forked);
		_assertSwapTripsGuard(RFG_USDC, RFG, USDC_USD, USDC_HEARTBEAT, false);
	}

	// ─── wrap handling ───────────────────────────────────────────────────────────

	/// @notice The pair's cumulatives set (vm.store on the real pair) 15 minutes of accrual below
	///         2^256: both wrap inside the window. The recorder's counterfactual wraps, the average is
	///         still exactly the idle price, the answer prices at spot, and the pair's own unchecked
	///         accrual (sync) wraps to the same values.
	function test_fork_cumulativeWrapIsExact() public {
		vm.skip(!forked);
		IUniswapV2PairExtras(DINO_WETH).sync(); // last update = now; balances == reserves, price unchanged
		(uint112 r0, uint112 r1,) = IUniswapV2Pair(DINO_WETH).getReserves();
		uint256 p0 = (uint256(r1) << 112) / r0;
		uint256 p1 = (uint256(r0) << 112) / r1;
		vm.store(DINO_WETH, SLOT_PRICE0_CUMULATIVE, bytes32(type(uint256).max - p0 * 900 + 1));
		vm.store(DINO_WETH, SLOT_PRICE1_CUMULATIVE, bytes32(type(uint256).max - p1 * 900 + 1));
		assertEq(IUniswapV2Pair(DINO_WETH).price0CumulativeLast(), type(uint256).max - p0 * 900 + 1, 'slot 9');
		assertEq(IUniswapV2Pair(DINO_WETH).price1CumulativeLast(), type(uint256).max - p1 * 900 + 1, 'slot 10');

		UniswapV2TwapAdapter a = _adapter(DINO_WETH, DINO, ETH_USD, WETH_HEARTBEAT);
		assertTrue(recorder.record(DINO_WETH));
		UniswapV2ObservationRecorder.Snapshot memory s = recorder.snapshotAtLeast(DINO_WETH, 0);
		_warpRoll(WARP);
		_assertQuoteFresh(ETH_USD, WETH_HEARTBEAT);

		(uint256 c0, uint256 c1,) = recorder.currentCumulativePrices(DINO_WETH);
		assertEq(c0, p0 * (WARP - 900), 'price0 wrapped past 2^256');
		assertEq(c1, p1 * (WARP - 900), 'price1 wrapped past 2^256');
		assertLt(c1, s.price1Cumulative, 'now < snapshot: the delta wraps');
		assertEq(a.consult(), p1, 'the wrapped delta / seconds = the idle price');
		(, int256 answer,,,) = a.latestRoundData();
		assertEq(SafeCast.toUint256(answer), _priceFromAverage(a, p1, ETH_USD));
		assertApproxEqRel(SafeCast.toUint256(answer), _spotUsd(a), 0.01e18, 'TWAP within 1% of spot');

		IUniswapV2PairExtras(DINO_WETH).sync();
		assertEq(IUniswapV2Pair(DINO_WETH).price0CumulativeLast(), c0, "the pair's own wrap agrees (price0)");
		assertEq(IUniswapV2Pair(DINO_WETH).price1CumulativeLast(), c1, "the pair's own wrap agrees (price1)");
	}

	/// @notice block.timestamp crosses 2^32 (Feb 2106) between a snapshot and the read: the pair's
	///         uint32 blockTimestampLast, the recorder's spacing, ages and counterfactual, and the
	///         adapter's Δt all wrap, and the average is still exactly the idle price over 1860 s.
	///         The feeds are decades stale there, so this reads consult() (the price path's average).
	function test_fork_timestampWrapIsExact() public {
		vm.skip(!forked);
		uint256 wrap = 2 ** 32;
		vm.warp(wrap - 900);
		vm.roll(block.number + 1);
		IUniswapV2PairExtras(AGNT_USDC).sync();
		(,, uint32 tLast) = IUniswapV2Pair(AGNT_USDC).getReserves();
		assertEq(tLast, uint32(wrap - 900));
		(uint256 rA, uint256 rQ) = _reserves(AGNT_USDC, true);
		uint256 p = rQ * Q112 / rA;

		UniswapV2TwapAdapter a = _adapter(AGNT_USDC, AGNT, USDC_USD, USDC_HEARTBEAT);
		assertTrue(recorder.record(AGNT_USDC));
		UniswapV2ObservationRecorder.Snapshot memory s = recorder.snapshotAtLeast(AGNT_USDC, 0);
		assertEq(s.timestamp, uint32(wrap - 900));

		vm.warp(wrap + 100); // 1000 s later, past the wrap
		vm.roll(block.number + 1);
		assertTrue(recorder.record(AGNT_USDC), 'spacing measured across the wrap');
		vm.warp(wrap + 960); // 1860 s after s
		vm.roll(block.number + 1);
		(uint256 c0,, uint32 t) = recorder.currentCumulativePrices(AGNT_USDC);
		assertEq(t, 960);
		assertEq(c0, s.price0Cumulative + p * 1860, 'counterfactual across the uint32 wrap');
		assertEq(recorder.snapshotAtLeast(AGNT_USDC, WINDOW).timestamp, s.timestamp, 'age across the wrap');
		assertEq(a.consult(), p, 'average across the uint32 wrap');

		IUniswapV2PairExtras(AGNT_USDC).sync();
		assertEq(IUniswapV2Pair(AGNT_USDC).price0CumulativeLast(), c0, "the pair's own uint32 accrual agrees");
	}

	// ─── liquidity reads ─────────────────────────────────────────────────────────

	/// @notice Selling the asset until spot is −10%: Uniswap v2 keeps the 0.3% LP fee in the
	///         reserves, so the real payout is ~5.1244% of the quote reserve, and BAND_QUOTE_PPM
	///         (the fee-free x·y=k figure, 5.1316%) overstates it by under 0.15%.
	function test_fork_minus10PctSellPaysAboutBandQuote_agnt() public {
		vm.skip(!forked);
		_assertMinus10PctSell(AGNT_USDC, AGNT, USDC_USD, USDC_HEARTBEAT);
	}

	function test_fork_minus10PctSellPaysAboutBandQuote_dino() public {
		vm.skip(!forked);
		_assertMinus10PctSell(DINO_WETH, DINO, ETH_USD, WETH_HEARTBEAT);
	}

	/// @notice A donation raises balanceOf(pair) but not the reserve, and skim() hands it to anyone:
	///         the reserve is getReserves(), so a donation never lifts the floor or the depth.
	function test_fork_donationIsNotReserve() public {
		vm.skip(!forked);
		(UniswapV2TwapAdapter a,) = _primed(AGNT_USDC, AGNT, USDC_USD, USDC_HEARTBEAT);
		uint256 reserve = a.quoteReserveUsd();
		uint256 depth = a.poolDepthUsd();
		uint256 balance = IERC20(USDC).balanceOf(AGNT_USDC);

		deal(USDC, address(this), 1_000_000e6);
		IERC20(USDC).safeTransfer(AGNT_USDC, 1_000_000e6);
		assertEq(IERC20(USDC).balanceOf(AGNT_USDC), balance + 1_000_000e6);
		assertEq(a.quoteReserveUsd(), reserve, 'donation not counted');
		assertEq(a.poolDepthUsd(), depth, 'depth unchanged');

		address taker = makeAddr('taker');
		IUniswapV2PairExtras(AGNT_USDC).skim(taker);
		assertEq(IERC20(USDC).balanceOf(taker), 1_000_000e6, 'anyone skims the donation back');
	}

	/// @notice v2 keeps no time-weighted reserves: a same-block proportional add doubles the live
	///         reserve and depth (the policy's min(live, recorded) bounds that) but leaves the TWAP.
	function test_fork_proportionalAddLiftsLiveReadsNotTheTwap() public {
		vm.skip(!forked);
		(UniswapV2TwapAdapter a,) = _primed(AGNT_USDC, AGNT, USDC_USD, USDC_HEARTBEAT);
		(, int256 before,,,) = a.latestRoundData();
		uint256 reserveBefore = a.quoteReserveUsd();
		uint256 depthBefore = a.poolDepthUsd();
		(uint256 rA, uint256 rQ) = _reserves(AGNT_USDC, true);
		_addLiquidity(AGNT_USDC, rA, rQ);
		emit log_named_decimal_uint('reserve before / after add (USD)', reserveBefore, 18);
		emit log_named_decimal_uint('                                ', a.quoteReserveUsd(), 18);
		assertApproxEqRel(a.quoteReserveUsd(), 2 * reserveBefore, 0.000001e18, 'the live reserve doubles');
		assertApproxEqRel(a.poolDepthUsd(), 2 * depthBefore, 0.000001e18, 'the live depth doubles');
		(, int256 afterAdd,,,) = a.latestRoundData();
		assertEq(afterAdd, before, 'the TWAP is unmoved');
	}

	/// @notice isBelowFloor()'s reserve part is exactly quoteReserveUsd() < minLiquidityUsd·1e18: a
	///         floor at the reserve's whole dollars reads over, one dollar more reads under; both
	///         orientations (the band part follows: 5.13% of the reserve vs 5.13% of the floor).
	function test_fork_isBelowFloorIsTheQuoteReserveFloor() public {
		vm.skip(!forked);
		assertTrue(recorder.record(AGNT_USDC));
		assertTrue(recorder.record(DINO_WETH));
		_warpRoll(WARP); // one warp for both pairs keeps the ETH/USD feed fresh
		_assertQuoteFresh(USDC_USD, USDC_HEARTBEAT);
		_assertQuoteFresh(ETH_USD, WETH_HEARTBEAT);
		_assertFloorBoundary(AGNT_USDC, AGNT, USDC_USD, USDC_HEARTBEAT);
		_assertFloorBoundary(DINO_WETH, DINO, ETH_USD, WETH_HEARTBEAT);
	}

	// ─── constructor and feed ────────────────────────────────────────────────────

	function test_fork_constructorChecks() public {
		vm.skip(!forked);
		IUniswapV2Pair p = IUniswapV2Pair(DINO_WETH);
		AggregatorV3Interface feed = AggregatorV3Interface(ETH_USD);
		UniswapV2ObservationRecorder r = recorder;

		vm.expectRevert(UniswapV2TwapAdapter.ZeroArgument.selector);
		new UniswapV2TwapAdapter(IUniswapV2Pair(address(0)), DINO, feed, r, WINDOW, 1, 500, 3600, '');
		vm.expectRevert(UniswapV2TwapAdapter.ZeroArgument.selector);
		new UniswapV2TwapAdapter(p, address(0), feed, r, WINDOW, 1, 500, 3600, '');
		vm.expectRevert(UniswapV2TwapAdapter.ZeroArgument.selector);
		new UniswapV2TwapAdapter(p, DINO, AggregatorV3Interface(address(0)), r, WINDOW, 1, 500, 3600, '');
		vm.expectRevert(UniswapV2TwapAdapter.ZeroArgument.selector);
		new UniswapV2TwapAdapter(p, DINO, feed, UniswapV2ObservationRecorder(address(0)), WINDOW, 1, 500, 3600, '');
		vm.expectRevert(UniswapV2TwapAdapter.ZeroArgument.selector);
		new UniswapV2TwapAdapter(p, DINO, feed, r, WINDOW, 0, 500, 3600, '');
		vm.expectRevert(UniswapV2TwapAdapter.ZeroArgument.selector);
		new UniswapV2TwapAdapter(p, DINO, feed, r, WINDOW, 1, 500, 0, '');

		vm.expectRevert(abi.encodeWithSelector(UniswapV2TwapAdapter.WindowTooShort.selector, uint32(WINDOW - 1)));
		new UniswapV2TwapAdapter(p, DINO, feed, r, WINDOW - 1, 1, 500, 3600, '');
		vm.expectRevert(abi.encodeWithSelector(UniswapV2TwapAdapter.BadDeviation.selector, uint16(0)));
		new UniswapV2TwapAdapter(p, DINO, feed, r, WINDOW, 1, 0, 3600, '');
		vm.expectRevert(abi.encodeWithSelector(UniswapV2TwapAdapter.BadDeviation.selector, uint16(2_001)));
		new UniswapV2TwapAdapter(p, DINO, feed, r, WINDOW, 1, 2_001, 3600, '');
		vm.expectRevert(abi.encodeWithSelector(UniswapV2TwapAdapter.AssetNotInPool.selector, USDC));
		new UniswapV2TwapAdapter(p, USDC, feed, r, WINDOW, 1, 500, 3600, '');

		UniswapV2TwapAdapter a = new UniswapV2TwapAdapter(p, DINO, feed, r, WINDOW, 25_000, 2_000, 3600, 'DINO / USD');
		assertEq(address(a.pair()), DINO_WETH);
		assertEq(address(a.recorder()), address(recorder));
		assertEq(a.asset(), DINO);
		assertEq(a.quoteAsset(), WETH);
		assertFalse(a.assetIsToken0());
		assertEq(address(a.quoteFeed()), ETH_USD);
		assertEq(a.window(), WINDOW);
		assertEq(a.minLiquidityUsd(), 25_000);
		assertEq(a.minBandDepthUsd(), MIN_BAND_DEPTH_USD, 'the band floor: 25,000 x PPM / 1e6');
		assertEq(MIN_BAND_DEPTH_USD, MIN_QUOTE_RESERVE_USD * BAND_QUOTE_PPM / 1e6);
		assertEq(a.maxDeviationBps(), 2_000);
		assertEq(a.quoteHeartbeat(), 3600);
		assertEq(a.description(), 'DINO / USD');
		assertEq(a.decimals(), 18);
		assertEq(a.MIN_WINDOW(), 30 minutes);
		assertEq(a.MAX_DEVIATION_BPS(), 2_000);
		assertEq(a.BAND_QUOTE_PPM(), BAND_QUOTE_PPM, 'floor((1 - sqrt 0.9) x 1e6)');
	}

	/// @notice The quote feed is fresh up to updatedAt + heartbeat and stale one second later, on
	///         every read that prices.
	function test_fork_staleQuoteFeedReverts() public {
		vm.skip(!forked);
		UniswapV2TwapAdapter a = _adapter(AGNT_USDC, AGNT, USDC_USD, USDC_HEARTBEAT);
		assertTrue(recorder.record(AGNT_USDC));
		(,,, uint256 updatedAt,) = AggregatorV3Interface(USDC_USD).latestRoundData();
		assertGe(updatedAt + USDC_HEARTBEAT, block.timestamp + WINDOW, 'stale point is after the window');
		vm.warp(updatedAt + USDC_HEARTBEAT);
		a.latestRoundData();
		vm.warp(updatedAt + USDC_HEARTBEAT + 1);
		bytes memory stale = abi.encodeWithSelector(UniswapV2TwapAdapter.QuoteStale.selector, updatedAt);
		vm.expectRevert(stale);
		a.latestRoundData();
		vm.expectRevert(stale);
		a.quoteReserveUsd();
		vm.expectRevert(stale);
		a.poolDepthUsd();
	}

	/// @notice The feed is read before the spot guard (as in the Aerodrome adapter): with spot
	///         ~8% off the TWAP AND the feed stale, the read reverts QuoteStale.
	function test_fork_staleFeedRevertsBeforeTheSpotGuard() public {
		vm.skip(!forked);
		UniswapV2TwapAdapter a = _adapter(AGNT_USDC, AGNT, USDC_USD, USDC_HEARTBEAT);
		assertTrue(recorder.record(AGNT_USDC));
		(,,, uint256 updatedAt,) = AggregatorV3Interface(USDC_USD).latestRoundData();
		vm.warp(updatedAt + USDC_HEARTBEAT + 1);
		vm.roll(block.number + 1);
		uint256 twapX112 = a.consult();
		_swapIn(AGNT_USDC, USDC, _quoteReserve(AGNT_USDC, true) * 4 / 100);
		assertGt(_priceX112(AGNT_USDC, true) * BPS, twapX112 * (BPS + MAX_DEVIATION_BPS), 'spot more than 5% over');
		vm.expectRevert(abi.encodeWithSelector(UniswapV2TwapAdapter.QuoteStale.selector, updatedAt));
		a.latestRoundData();
	}

	// ─── helpers: setup ──────────────────────────────────────────────────────────

	function _adapter(address pair, address asset, address feed, uint32 heartbeat) internal returns (UniswapV2TwapAdapter) {
		return _adapterDev(pair, asset, feed, heartbeat, MAX_DEVIATION_BPS, MIN_QUOTE_RESERVE_USD);
	}

	function _adapterDev(address pair, address asset, address feed, uint32 heartbeat, uint16 bps, uint256 floorUsd)
		internal
		returns (UniswapV2TwapAdapter)
	{
		return new UniswapV2TwapAdapter(
			IUniswapV2Pair(pair), asset, AggregatorV3Interface(feed), recorder, WINDOW, floorUsd, bps, heartbeat, 'uniswap v2'
		);
	}

	/// @dev Adapter + a snapshot now + a 31-minute warp with no swap; the feed checked fresh.
	function _primed(address pair, address asset, address feed, uint32 heartbeat)
		internal
		returns (UniswapV2TwapAdapter a, Mark memory then_)
	{
		a = _adapter(pair, asset, feed, heartbeat);
		then_ = _record(pair, a.assetIsToken0());
		_warpRoll(WARP);
		_assertQuoteFresh(feed, heartbeat);
	}

	function _warpRoll(uint256 dt) internal {
		vm.warp(block.timestamp + dt);
		vm.roll(block.number + dt / 2);
	}

	function _assertCandidate(address pair, address asset, address quote, bool assetIsToken0) internal view {
		assertEq(IUniswapV2Factory(FACTORY).getPair(asset, quote), pair, 'the factory pair');
		assertEq(IUniswapV2PairExtras(pair).factory(), FACTORY);
		assertEq(IUniswapV2Pair(pair).token0(), assetIsToken0 ? asset : quote);
		assertEq(IUniswapV2Pair(pair).token1(), assetIsToken0 ? quote : asset);
		assertFalse(IValueInterpreter(VALUE_INTERPRETER).isSupportedAsset(asset), 'not VI-priced');
	}

	// ─── helpers: assertions ─────────────────────────────────────────────────────

	function _assertPricesRealPair(address pair, address asset, address feed, uint32 heartbeat, bool assetIsToken0)
		internal
	{
		(UniswapV2TwapAdapter a, Mark memory then_) = _primed(pair, asset, feed, heartbeat);
		assertEq(a.assetIsToken0(), assetIsToken0, 'orientation');
		emit log_named_address('pair', pair);
		uint256 price = _assertPriceIsReference(a, then_, feed);
		uint256 spotUsd = _spotUsd(a);
		emit log_named_decimal_uint('spot price (USD)          ', spotUsd, 18);
		assertApproxEqRel(price, spotUsd, 0.01e18, 'TWAP within 1% of spot');
		uint256 reserve = _assertReserveIsGetReserves(a, feed);
		_assertDepthIsBandOfReserve(a, feed, reserve);
		assertEq(a.isBelowFloor(), reserve < MIN_QUOTE_RESERVE_USD * 1e18 || a.poolDepthUsd() < MIN_BAND_DEPTH_USD * 1e18);
	}

	/// @dev The answer vs an independent full-precision computation from the pair's own cumulatives:
	///      Δcumulative × 10^ad × feed / (Δt × 2^112 × 10^qd), rounded once. The adapter floors the
	///      average first, so it is never above it and within 1e-6 of it. With no swap since the
	///      snapshot the average is the pair's current UQ112x112 price.
	function _assertPriceIsReference(UniswapV2TwapAdapter a, Mark memory then_, address feed)
		internal
		returns (uint256 price)
	{
		uint256 avg = _average(then_, _mark(address(a.pair()), a.assetIsToken0()));
		assertEq(a.consult(), avg, 'consult = the cumulative delta / seconds');
		assertEq(avg, _priceX112(address(a.pair()), a.assetIsToken0()), 'no swap: the average is the current price');
		price = _assertPriceIsReferenceOf(a, then_, feed);
		assertEq(price, _priceFromAverage(a, avg, feed), 'the average x the feed, rounded once');
	}

	/// @dev quoteReserveUsd = getReserves' quote × the feed exactly; balanceOf only adds donations.
	function _assertReserveIsGetReserves(UniswapV2TwapAdapter a, address feed) internal returns (uint256 reserve) {
		address pair = address(a.pair());
		uint256 qUnit = 10 ** IERC20Metadata(a.quoteAsset()).decimals();
		uint256 rQ = _quoteReserve(pair, a.assetIsToken0());
		reserve = a.quoteReserveUsd();
		uint256 balanceUsd = Math.mulDiv(IERC20(a.quoteAsset()).balanceOf(pair), _quoteUsd18(feed), qUnit);
		emit log_named_decimal_uint('quote reserve (USD)       ', reserve, 18);
		emit log_named_decimal_uint('quote balanceOf (USD)     ', balanceUsd, 18);
		assertEq(reserve, Math.mulDiv(rQ, _quoteUsd18(feed), qUnit), 'getReserves quote x the feed, exactly');
		assertLe(reserve, balanceUsd, 'balance = reserve + unskimmed donations');
	}

	/// @dev depth = floor(rQ × 51_316 / 1e6) quote × the feed: 5.1316% of the reserve.
	function _assertDepthIsBandOfReserve(UniswapV2TwapAdapter a, address feed, uint256 reserve) internal {
		uint256 rQ = _quoteReserve(address(a.pair()), a.assetIsToken0());
		uint256 depth = a.poolDepthUsd();
		uint256 qUnit = 10 ** IERC20Metadata(a.quoteAsset()).decimals();
		emit log_named_decimal_uint('band depth (USD)          ', depth, 18);
		emit log_named_decimal_uint('depth / reserve           ', Math.mulDiv(depth, 1e18, reserve), 18);
		assertEq(depth, Math.mulDiv(Math.mulDiv(rQ, BAND_QUOTE_PPM, 1e6), _quoteUsd18(feed), qUnit), 'exact');
		assertLe(depth, Math.mulDiv(reserve, BAND_QUOTE_PPM, 1e6), 'never above 5.1316% of the reserve');
		assertApproxEqRel(depth, Math.mulDiv(reserve, BAND_QUOTE_PPM, 1e6), PPM_REL, '5.1316% of the reserve');
	}

	/// @dev Sub-$0.0001: exact against the reference; the old formula (whole raw quote units per
	///      whole asset first) read > 1% low, and the new price is within one old rounding unit.
	function _assertSubCent(address pair, address asset, bool assetIsToken0) internal {
		(UniswapV2TwapAdapter a, Mark memory then_) = _primed(pair, asset, USDC_USD, USDC_HEARTBEAT);
		assertEq(a.assetIsToken0(), assetIsToken0, 'orientation');
		uint256 price = _assertPriceIsReference(a, then_, USDC_USD);
		assertLt(price, 0.0001e18, 'below $0.0001');
		uint256 avg = a.consult();
		uint256 rawPerWhole = Math.mulDiv(avg, 1e18, Q112);
		uint256 old = Math.mulDiv(rawPerWhole, _quoteUsd18(USDC_USD), 1e6);
		emit log_named_uint('old: raw USDC units per whole asset', rawPerWhole);
		emit log_named_decimal_uint('old-formula price (USD)   ', old, 18);
		emit log_named_decimal_uint('old / new                 ', Math.mulDiv(old, 1e18, price), 18);
		assertLt(Math.mulDiv(old, 1e18, price), 0.99e18, 'the old formula read > 1% low');
		uint256 unit = _quoteUsd18(USDC_USD) / 1e6;
		assertGe(price, old, 'never below the truncated price');
		assertLe(price - old, unit + 1, 'within one old rounding unit');
		assertApproxEqRel(price, _spotUsd(a), 0.01e18, 'TWAP within 1% of spot');
	}

	/// @dev A snapshot, 600 s at the old price, a real ~+2% swap, 1260 s at the new price.
	function _assertTimeWeighted(address pair, address asset, address feed, uint32 heartbeat) internal {
		UniswapV2TwapAdapter a = _adapter(pair, asset, feed, heartbeat);
		Mark memory then_ = _record(pair, a.assetIsToken0());
		uint256 pOld = _priceX112(pair, a.assetIsToken0());
		_warpRoll(600);
		_swapIn(pair, a.quoteAsset(), _quoteReserve(pair, a.assetIsToken0()) / 100);
		uint256 pNew = _priceX112(pair, a.assetIsToken0());
		_warpRoll(1260);
		_assertQuoteFresh(feed, heartbeat);

		uint256 expected = (pOld * 600 + pNew * 1260) / 1860;
		assertEq(a.consult(), expected, 'each price weighted by its seconds');
		assertGt(pNew, pOld);
		assertGt(expected, pOld);
		assertLt(expected, pNew);
		emit log_named_decimal_uint('price before / after the swap (USD)', _priceFromAverage(a, pOld, feed), 18);
		emit log_named_decimal_uint('                                   ', _priceFromAverage(a, pNew, feed), 18);
		uint256 price = _assertPriceIsReferenceOf(a, then_, feed);
		assertEq(price, _priceFromAverage(a, expected, feed), 'rounded once from the average');
	}

	/// @dev The answer within 1e-6 of (and never above) the full-precision reference from `then_`.
	function _assertPriceIsReferenceOf(UniswapV2TwapAdapter a, Mark memory then_, address feed)
		internal
		returns (uint256 price)
	{
		Mark memory now_ = _mark(address(a.pair()), a.assetIsToken0());
		(, int256 answer,,,) = a.latestRoundData();
		price = SafeCast.toUint256(answer);
		uint256 reference_ = _referencePrice(a, then_, now_, feed);
		emit log_named_decimal_uint('TWAP price (USD)          ', price, 18);
		emit log_named_decimal_uint('full-precision reference  ', reference_, 18);
		assertLe(price, reference_, 'never above the reference');
		assertApproxEqRel(price, reference_, PPM_REL, 'within 1e-6 of the reference');
	}

	/// @dev The pair's current price on the asset side, UQ112x112 (quote raw per asset raw × 2^112).
	function _priceX112(address pair, bool assetIsToken0) internal view returns (uint256) {
		(uint256 rA, uint256 rQ) = _reserves(pair, assetIsToken0);
		return rQ * Q112 / rA;
	}

	/// @dev Real swaps of 4% of the input reserve move spot ~8% (> 5%): the guard reverts with the
	///      exact new spot and the unmoved TWAP. A 20% guard still prices at the same TWAP, and the
	///      reserve and depth reads skip the guard.
	function _assertSwapTripsGuard(address pair, address asset, address feed, uint32 heartbeat, bool sellAsset) internal {
		(UniswapV2TwapAdapter a,) = _primed(pair, asset, feed, heartbeat);
		UniswapV2TwapAdapter wide = _adapterDev(pair, asset, feed, heartbeat, 2_000, MIN_QUOTE_RESERVE_USD);
		(, int256 before,,,) = a.latestRoundData(); // within the guard before the swap
		uint256 twapUsd = SafeCast.toUint256(before); // a same-block swap leaves the TWAP

		(uint256 rA, uint256 rQ) = _reserves(pair, a.assetIsToken0());
		if (sellAsset) _swapIn(pair, asset, rA * 4 / 100);
		else _swapIn(pair, a.quoteAsset(), rQ * 4 / 100);

		uint256 spotUsd = _spotUsd(a);
		emit log_named_decimal_uint('spot / TWAP after the swap', Math.mulDiv(spotUsd, 1e18, twapUsd), 18);
		if (sellAsset) assertGt(twapUsd * BPS, spotUsd * (BPS + MAX_DEVIATION_BPS), 'spot more than 5% under');
		else assertGt(spotUsd * BPS, twapUsd * (BPS + MAX_DEVIATION_BPS), 'spot more than 5% over');

		vm.expectRevert(abi.encodeWithSelector(UniswapV2TwapAdapter.SpotDeviatesFromTwap.selector, spotUsd, twapUsd));
		a.latestRoundData();

		(, int256 wideAnswer,,,) = wide.latestRoundData();
		assertEq(wideAnswer, before, 'a 20% guard prices at the unmoved TWAP');
		_assertReadsSkipGuard(a, feed);
	}

	/// @dev The reserve and depth reads still serve while spot is off the TWAP.
	function _assertReadsSkipGuard(UniswapV2TwapAdapter a, address feed) internal view {
		uint256 qUnit = 10 ** IERC20Metadata(a.quoteAsset()).decimals();
		uint256 rQ = _quoteReserve(address(a.pair()), a.assetIsToken0());
		assertEq(a.quoteReserveUsd(), Math.mulDiv(rQ, _quoteUsd18(feed), qUnit), 'reserve read skips the guard');
		assertGt(a.poolDepthUsd(), 0, 'depth read skips the guard');
	}

	/// @dev Sells the asset into the pair until spot is −10% and compares the quote paid out with
	///      the adapter's depth. With the 0.3% fee kept in the pair, spot × 0.9 needs gross g with
	///      8973·g² + 17973·A·g − 1000·A² = 0, and pays out Q·(1 − 1000·A / (1000·A + 997·g)).
	function _assertMinus10PctSell(address pair, address asset, address feed, uint32 heartbeat) internal {
		(UniswapV2TwapAdapter a,) = _primed(pair, asset, feed, heartbeat);
		bool t0 = a.assetIsToken0();
		uint256 depth = a.poolDepthUsd();
		(uint256 rA, uint256 rQ) = _reserves(pair, t0);
		uint256 spotBefore = _spotUsd(a);

		uint256 quoteOut = _swapIn(pair, asset, _grossInForMinus10Pct(rA));

		uint256 qUnit = 10 ** IERC20Metadata(a.quoteAsset()).decimals();
		uint256 outUsd = Math.mulDiv(quoteOut, _quoteUsd18(feed), qUnit);
		emit log_named_decimal_uint('spot after / before         ', Math.mulDiv(_spotUsd(a), 1e18, spotBefore), 18);
		emit log_named_decimal_uint('quote out / quote reserve   ', Math.mulDiv(quoteOut, 1e18, rQ), 18);
		emit log_named_decimal_uint('quote out (USD)             ', outUsd, 18);
		emit log_named_decimal_uint('adapter depth before (USD)  ', depth, 18);
		emit log_named_decimal_uint('depth / real payout         ', Math.mulDiv(depth, 1e18, outUsd), 18);
		assertApproxEqRel(_spotUsd(a), Math.mulDiv(spotBefore, 9, 10), 0.0001e18, 'spot -10%');
		assertApproxEqRel(quoteOut, Math.mulDiv(rQ, 51_244, 1e6), 0.0001e18, '~5.1244% of the quote reserve');
		assertGt(depth, outUsd, 'the fee-free figure overstates the fee-kept payout');
		assertApproxEqRel(depth, outUsd, 0.0015e18, 'by under 0.15%');
	}

	/// @dev Gross asset input taking spot to 0.9× with the 0.3% fee kept in the pair (see above):
	///      g = A·(√358_920_729 − 17_973) / 17_946 = 0.0541747·A, rounded up.
	function _grossInForMinus10Pct(uint256 rA) internal pure returns (uint256) {
		uint256 root = Math.sqrt(358_920_729e36);
		return Math.mulDiv(rA, root - 17_973e18, 17_946e18, Math.Rounding.Ceil);
	}

	function _assertFloorBoundary(address pair, address asset, address feed, uint32 heartbeat) internal {
		uint256 whole = _adapter(pair, asset, feed, heartbeat).quoteReserveUsd() / 1e18;
		UniswapV2TwapAdapter atReserve = _adapterDev(pair, asset, feed, heartbeat, MAX_DEVIATION_BPS, whole);
		UniswapV2TwapAdapter overReserve = _adapterDev(pair, asset, feed, heartbeat, MAX_DEVIATION_BPS, whole + 1);
		assertFalse(atReserve.isBelowFloor(), 'reserve >= floor');
		assertTrue(overReserve.isBelowFloor(), 'reserve < floor + $1');
		assertEq(atReserve.minBandDepthUsd(), whole * BAND_QUOTE_PPM / 1e6, 'the band floor follows the reserve floor');
		assertGe(atReserve.poolDepthUsd(), atReserve.minBandDepthUsd() * 1e18);
	}

	function _assertNoSnapshot(UniswapV2TwapAdapter a) internal {
		bytes memory err = abi.encodeWithSelector(UniswapV2ObservationRecorder.NoSnapshot.selector, address(a.pair()));
		vm.expectRevert(err);
		a.latestRoundData();
		vm.expectRevert(err);
		a.quoteReserveUsd();
		vm.expectRevert(err);
		a.poolDepthUsd();
		vm.expectRevert(err);
		a.isBelowFloor();
		vm.expectRevert(err);
		a.consult();
	}

	/// @dev The recorder's counterfactual now equals the library formula read from the pair's raw
	///      state, on both sides.
	function _assertCounterfactualIsLibraryFormula(address pair) internal view {
		(uint256 c0, uint256 c1, uint32 t) = recorder.currentCumulativePrices(pair);
		assertEq(t, uint32(block.timestamp));
		assertEq(c0, _pairCumulative(pair, true), 'price0CumulativeLast + price0 x elapsed');
		assertEq(c1, _pairCumulative(pair, false), 'price1CumulativeLast + price1 x elapsed');
	}

	// ─── helpers: independent arithmetic ─────────────────────────────────────────

	/// @dev Independent of the recorder: the pair's stored cumulative for one side plus its current
	///      UQ112x112 price × the seconds since its last update, in plain checked uint256 (block time
	///      is below 2^32 until 2106 and the live cumulatives are far below 2^256).
	function _pairCumulative(address pair, bool side0) internal view returns (uint256) {
		(uint112 r0, uint112 r1, uint32 tLast) = IUniswapV2Pair(pair).getReserves();
		uint256 elapsed = block.timestamp - tLast;
		return side0
			? IUniswapV2Pair(pair).price0CumulativeLast() + (uint256(r1) * Q112 / r0) * elapsed
			: IUniswapV2Pair(pair).price1CumulativeLast() + (uint256(r0) * Q112 / r1) * elapsed;
	}

	function _mark(address pair, bool assetIsToken0) internal view returns (Mark memory) {
		return Mark(_pairCumulative(pair, assetIsToken0), block.timestamp);
	}

	function _record(address pair, bool assetIsToken0) internal returns (Mark memory m) {
		assertTrue(recorder.record(pair), 'recorded');
		m = _mark(pair, assetIsToken0);
		UniswapV2ObservationRecorder.Snapshot memory s = recorder.snapshotAtLeast(pair, 0);
		assertEq(assetIsToken0 ? s.price0Cumulative : s.price1Cumulative, m.cumulative, 'snapshot = the pair formula');
	}

	function _average(Mark memory then_, Mark memory now_) internal pure returns (uint256) {
		return (now_.cumulative - then_.cumulative) / (now_.time - then_.time);
	}

	/// @dev Full precision, decomposed differently from the adapter (no floor of the average):
	///      floor(Δcumulative × 10^ad × feed / (Δt × 2^112 × 10^qd)).
	function _referencePrice(UniswapV2TwapAdapter a, Mark memory then_, Mark memory now_, address feed)
		internal
		view
		returns (uint256)
	{
		(uint256 aUnit, uint256 qUnit) = _units(a);
		return Math.mulDiv(
			now_.cumulative - then_.cumulative, aUnit * _quoteUsd18(feed), (now_.time - then_.time) * Q112 * qUnit
		);
	}

	/// @dev floor(avgX112 × 10^ad × feed / (2^112 × 10^qd)) in one mulDiv.
	function _priceFromAverage(UniswapV2TwapAdapter a, uint256 avgX112, address feed) internal view returns (uint256) {
		(uint256 aUnit, uint256 qUnit) = _units(a);
		return Math.mulDiv(avgX112, aUnit * _quoteUsd18(feed), Q112 * qUnit);
	}

	/// @dev Spot USD per whole asset from the current reserves, full precision.
	function _spotUsd(UniswapV2TwapAdapter a) internal view returns (uint256) {
		(uint256 rA, uint256 rQ) = _reserves(address(a.pair()), a.assetIsToken0());
		(uint256 aUnit, uint256 qUnit) = _units(a);
		address feed = address(a.quoteFeed());
		return Math.mulDiv(rQ * aUnit, _quoteUsd18(feed), rA * qUnit);
	}

	function _units(UniswapV2TwapAdapter a) internal view returns (uint256 aUnit, uint256 qUnit) {
		aUnit = 10 ** IERC20Metadata(a.asset()).decimals();
		qUnit = 10 ** IERC20Metadata(a.quoteAsset()).decimals();
	}

	function _reserves(address pair, bool assetIsToken0) internal view returns (uint256 rA, uint256 rQ) {
		(uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
		(rA, rQ) = assetIsToken0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
	}

	function _quoteReserve(address pair, bool assetIsToken0) internal view returns (uint256 rQ) {
		(, rQ) = _reserves(pair, assetIsToken0);
	}

	// ─── helpers: real pair actions ──────────────────────────────────────────────

	/// @dev Real swap straight through the pair: pay in, take Router02.getAmountOut of what arrived.
	function _swapIn(address pair, address tokenIn, uint256 amountIn) internal returns (uint256 out) {
		bool zeroIn = tokenIn == IUniswapV2Pair(pair).token0();
		deal(tokenIn, address(this), amountIn);
		IERC20(tokenIn).safeTransfer(pair, amountIn);
		(uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
		(uint256 rIn, uint256 rOut) = zeroIn ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
		uint256 received = IERC20(tokenIn).balanceOf(pair) - rIn;
		out = IUniswapV2Router02(ROUTER).getAmountOut(received, rIn, rOut);
		IUniswapV2PairExtras(pair).swap(zeroIn ? 0 : out, zeroIn ? out : 0, address(this), '');
	}

	/// @dev Real liquidity add straight through the pair: pay both tokens in, mint.
	function _addLiquidity(address pair, uint256 amount0, uint256 amount1) internal {
		address t0 = IUniswapV2Pair(pair).token0();
		address t1 = IUniswapV2Pair(pair).token1();
		deal(t0, address(this), amount0);
		deal(t1, address(this), amount1);
		IERC20(t0).safeTransfer(pair, amount0);
		IERC20(t1).safeTransfer(pair, amount1);
		assertGt(IUniswapV2PairExtras(pair).mint(address(this)), 0);
	}

	// ─── helpers: feeds ──────────────────────────────────────────────────────────

	function _assertQuoteFresh(address feed, uint32 heartbeat) internal view {
		(,,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
		assertLe(block.timestamp, updatedAt + heartbeat, 'quote feed fresh after the warp (pin BASE_FORK_BLOCK if not)');
	}

	function _quoteUsd18(address feed) internal view returns (uint256) {
		(, int256 answer,,,) = AggregatorV3Interface(feed).latestRoundData();
		return SafeCast.toUint256(answer) * 10 ** (18 - AggregatorV3Interface(feed).decimals());
	}
}
