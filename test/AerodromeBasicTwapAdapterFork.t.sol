// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {AerodromeBasicTwapAdapter, IAerodromeBasicPool} from '../src/pricing/AerodromeBasicTwapAdapter.sol';
import {AggregatorV3Interface} from '../src/interfaces/AggregatorV3Interface.sol';
import {ITwapPriceAdapter} from '../src/interfaces/ITwapPriceAdapter.sol';
import {IValueInterpreter} from '../src/interfaces/IValueInterpreter.sol';

/// @notice Aerodrome basic pool functions the test needs beyond the adapter's read surface
///         (verified source of the clone implementation 0xA4e4…D6d7, Solidity 0.8.19).
interface IAerodromeBasicPoolExtras {
	function reserve0CumulativeLast() external view returns (uint256);
	function reserve1CumulativeLast() external view returns (uint256);
	function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
	function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
	function mint(address to) external returns (uint256 liquidity);
	function skim(address to) external;
}

/// @notice Aerodrome PoolFactory (verified source of 0x420D…40Da).
interface IAerodromePoolFactory {
	function getPool(address tokenA, address tokenB, bool stable) external view returns (address);
	function getFee(address pool, bool stable) external view returns (uint256);
	function createPool(address tokenA, address tokenB, bool stable) external returns (address);
}

/// @notice The Aerodrome basic adapter on real Base volatile pools: KTA/WETH and FAI/WETH (asset =
///         token1, 18-decimal quote) and AWE/USDC (asset = token0, 6-decimal quote). The TWAP is the
///         ratio of the pool's own time-averaged reserves, re-derived here from raw pool storage; the
///         reserve is `getReserves()` (a donation is skimmable, so it never counts); the depth is the
///         quote a real −10% sell pulls out of x·y=k (1 − √0.9 of the reserve). Real swaps trip the
///         spot guard, a fresh observation falls back to the one before it, and a pool with no
///         window of history (a real pool created on the fork) does not price.
///         Run: BASE_MAINNET_RPC=<url> [BASE_FORK_BLOCK=<n>] forge test --match-path test/AerodromeBasicTwapAdapterFork.t.sol -vv
contract AerodromeBasicTwapAdapterForkTest is Test {
	address internal constant WETH = 0x4200000000000000000000000000000000000006;
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	// FundsMainnet.CL_ETH_USD / CL_USDC_USD and the registry's quote heartbeats
	address internal constant ETH_USD = 0x50015f8b17fb2C290Dde41fDc246ed0dcEE93a8b;
	address internal constant USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
	uint32 internal constant WETH_HEARTBEAT = 1 hours;
	uint32 internal constant USDC_HEARTBEAT = 90_000;
	address internal constant FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
	address internal constant VALUE_INTERPRETER = 0x3CDbaBE5Bf4E6cfE10A2A326E0ad31b2d16398D4;
	// Long-tail tokens with Aerodrome basic pools (DefiLlama aerodrome-v1, 2026-09-30); none VI-priced
	address internal constant KTA = 0xc0634090F2Fe6c6d75e61Be2b949464aBB498973;
	address internal constant FAI = 0xb33Ff54b9F7242EF1593d2C9Bcd8f9df46c77935;
	address internal constant AWE = 0x1B4617734C43F6159F3a70b7E06d883647512778;
	// No LUMIA/USDC volatile pool exists; the single-observation test creates one
	address internal constant LUMIA = 0x550161Ae735DebeE90Ba117025db0E83131bf9A6;
	// factory.getPool(asset, quote, false) (cast, 2026-09-30)
	address internal constant KTA_WETH = 0xd9eDC75a3a797Ec92Ca370F19051BAbebfb2edEe; // WETH token0, fee 30 bps
	address internal constant FAI_WETH = 0x5447F7FE76894d98753A0A6d69B9cb840037c13D; // WETH token0, fee 100 bps
	address internal constant AWE_USDC = 0xcb7f520d18141E36956fE0b3A6Bc3D4F11245521; // AWE token0, fee 30 bps
	// factory.getPool(KTA, quote, true): KTA's sAMM pools
	address internal constant KTA_USDC_STABLE = 0x8358462C5805592c35E4143BC769B3383B5e768f;
	address internal constant KTA_WETH_STABLE = 0x52f58Bc927230aa1b3895979a7DB55809Ac2cd63;

	uint32 internal constant WINDOW = 30 minutes;
	uint16 internal constant MAX_DEVIATION_BPS = 500;
	/// @dev The registry's listing / delist-clock floor (MIN_QUOTE_RESERVE_USD), whole USD.
	uint256 internal constant MIN_QUOTE_RESERVE_USD = 25_000;
	/// @dev Pool.periodSize: an observation is written only when the last is > 1800 s old.
	uint256 internal constant PERIOD_SIZE = 1800;
	uint256 internal constant BPS = 10_000;
	/// @dev floor((1 − √0.9) · 1e6), pinned independently by test_bandQuotePpmIsOneMinusSqrtPoint9
	uint256 internal constant BAND_QUOTE_PPM = 51_316;
	/// @dev The registry's band floor (MIN_BAND_DEPTH_USD, Ruling 23): MIN_QUOTE_RESERVE_USD × PPM / 1e6.
	uint256 internal constant MIN_BAND_DEPTH_USD = 1_282;
	/// @dev √0.9 · 1e18 = sqrt(0.9e36)
	uint256 internal constant SQRT_POINT9_E18 = 948_683_298_050_513_799;

	bool internal forked;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		uint256 blockNumber = vm.envOr('BASE_FORK_BLOCK', uint256(0));
		if (blockNumber > 0) vm.createSelectFork(rpc, blockNumber);
		else vm.createSelectFork(rpc);
		forked = true;
	}

	// ─── constants and premises ──────────────────────────────────────────────────

	/// @notice BAND_QUOTE_PPM = floor((1 − √0.9) · 1e6): (1e6 − PPM − 1)² < 0.9e12 ≤ (1e6 − PPM)².
	///         test_fork_constructorChecks pins the adapter's constant to this one.
	function test_bandQuotePpmIsOneMinusSqrtPoint9() public pure {
		uint256 ppm = BAND_QUOTE_PPM;
		assertLt((1e6 - ppm - 1) ** 2, 0.9e12, 'rounded down');
		assertGe((1e6 - ppm) ** 2, 0.9e12, 'by less than one ppm');
		assertEq(SQRT_POINT9_E18, Math.sqrt(0.9e36));
	}

	/// @notice The three pools are the factory's VOLATILE pools for their pair, their asset is not
	///         priced by the ValueInterpreter, and each holds more than the $25k quote floor.
	function test_fork_candidatePoolsAreVolatileUnpricedAndFunded() public {
		vm.skip(!forked);
		_assertCandidate(KTA_WETH, KTA, WETH, false);
		_assertCandidate(FAI_WETH, FAI, WETH, false);
		_assertCandidate(AWE_USDC, AWE, USDC, true);
	}

	/// @notice The pool writes an observation only when the last is more than periodSize old, so
	///         consecutive observations are > 1800 s apart (checked over the last 48, ~1 day).
	function test_fork_observationsAreMoreThanAPeriodApart() public {
		vm.skip(!forked);
		address[3] memory pools = [KTA_WETH, FAI_WETH, AWE_USDC];
		for (uint256 k; k < pools.length; k++) {
			IAerodromeBasicPool p = IAerodromeBasicPool(pools[k]);
			assertEq(p.periodSize(), PERIOD_SIZE);
			uint256 len = p.observationLength();
			(uint256 tLast, uint256 c0Last, uint256 c1Last) = p.lastObservation();
			(uint256 t, uint256 c0, uint256 c1) = p.observations(len - 1);
			assertEq(abi.encode(tLast, c0Last, c1Last), abi.encode(t, c0, c1), 'lastObservation = observations(len - 1)');
			for (uint256 i = len - 1; i > len - 49; i--) {
				(uint256 tPrev,,) = p.observations(i - 1);
				(uint256 tNext,,) = p.observations(i);
				assertGt(tNext - tPrev, PERIOD_SIZE, 'observations more than periodSize apart');
			}
		}
	}

	/// @notice currentCumulativePrices() returns cumulative RESERVES: the stored cumulative plus the
	///         current reserves × the seconds since the last update, and it grows by reserves × dt.
	function test_fork_cumulativesAreReservesTimesSeconds() public {
		vm.skip(!forked);
		address[3] memory pools = [KTA_WETH, FAI_WETH, AWE_USDC];
		for (uint256 k; k < pools.length; k++) {
			IAerodromeBasicPool p = IAerodromeBasicPool(pools[k]);
			(uint256 r0, uint256 r1, uint256 tLast) = p.getReserves();
			(uint256 n0, uint256 n1, uint256 tNow) = p.currentCumulativePrices();
			assertEq(tNow, block.timestamp);
			assertEq(n0, IAerodromeBasicPoolExtras(pools[k]).reserve0CumulativeLast() + r0 * (tNow - tLast), 'reserve0 x seconds');
			assertEq(n1, IAerodromeBasicPoolExtras(pools[k]).reserve1CumulativeLast() + r1 * (tNow - tLast), 'reserve1 x seconds');
		}
		IAerodromeBasicPool kta = IAerodromeBasicPool(KTA_WETH);
		(uint256 a0, uint256 a1,) = kta.currentCumulativePrices();
		(uint256 s0, uint256 s1,) = kta.getReserves();
		vm.warp(block.timestamp + 600);
		(uint256 b0, uint256 b1,) = kta.currentCumulativePrices();
		assertEq(b0 - a0, s0 * 600, 'grows by reserve0 x dt');
		assertEq(b1 - a1, s1 * 600, 'grows by reserve1 x dt');
	}

	// ─── (a) prices real pools, both orientations ────────────────────────────────

	/// @notice asset = token1, WETH quote: TWAP within 2% of spot, reserve = getReserves × feed,
	///         depth = 5.13% of the window-floored reserve.
	function test_fork_pricesKtaWeth_assetToken1() public {
		vm.skip(!forked);
		_assertPricesRealPool(KTA_WETH, KTA, ETH_USD, WETH_HEARTBEAT, false);
	}

	function test_fork_pricesFaiWeth_assetToken1() public {
		vm.skip(!forked);
		_assertPricesRealPool(FAI_WETH, FAI, ETH_USD, WETH_HEARTBEAT, false);
	}

	/// @notice asset = token0, USDC (6 decimals) quote.
	function test_fork_pricesAweUsdc_assetToken0() public {
		vm.skip(!forked);
		_assertPricesRealPool(AWE_USDC, AWE, USDC_USD, USDC_HEARTBEAT, true);
	}

	/// @notice The interface surface: the adapter is read through ITwapPriceAdapter.
	function test_fork_readsThroughITwapPriceAdapter() public {
		vm.skip(!forked);
		ITwapPriceAdapter a = _adapter(AWE_USDC, AWE, USDC_USD, USDC_HEARTBEAT);
		assertEq(a.asset(), AWE);
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

	// ─── depth = the quote a real −10% sell pays out ─────────────────────────────

	/// @notice Selling the asset into KTA/WETH until spot is −10% pays out (1 − √0.9) of the WETH
	///         reserve: BAND_QUOTE_PPM of it, and never less than the adapter's depth.
	function test_fork_minus10PctSellPaysBandQuote_kta() public {
		vm.skip(!forked);
		_assertMinus10PctSellPaysBandQuote(KTA_WETH, KTA, ETH_USD, WETH_HEARTBEAT);
	}

	function test_fork_minus10PctSellPaysBandQuote_awe() public {
		vm.skip(!forked);
		_assertMinus10PctSellPaysBandQuote(AWE_USDC, AWE, USDC_USD, USDC_HEARTBEAT);
	}

	// ─── quote reserve ───────────────────────────────────────────────────────────

	/// @notice A donation raises balanceOf(pool) but not the reserve, and skim() hands it to anyone:
	///         the reserve is getReserves(), so a donation never lifts the floor or the depth.
	function test_fork_donationIsNotReserve() public {
		vm.skip(!forked);
		AerodromeBasicTwapAdapter a = _adapter(KTA_WETH, KTA, ETH_USD, WETH_HEARTBEAT);
		uint256 reserve = a.quoteReserveUsd();
		uint256 depth = a.poolDepthUsd();
		uint256 balance = IERC20(WETH).balanceOf(KTA_WETH);

		deal(WETH, address(this), 1_000 ether);
		assertTrue(IERC20(WETH).transfer(KTA_WETH, 1_000 ether));
		assertEq(IERC20(WETH).balanceOf(KTA_WETH), balance + 1_000 ether);
		emit log_named_decimal_uint('reserve USD after a 1000 WETH donation', a.quoteReserveUsd(), 18);
		assertEq(a.quoteReserveUsd(), reserve, 'donation not counted');
		assertEq(a.poolDepthUsd(), depth, 'depth unchanged');

		address taker = makeAddr('taker');
		IAerodromeBasicPoolExtras(KTA_WETH).skim(taker);
		assertGe(IERC20(WETH).balanceOf(taker), 1_000 ether, 'anyone skims the donation back');
	}

	/// @notice A same-block liquidity add doubles the quote reserve but not the depth, which takes
	///         the window-average reserve; liquidity that stays a full window counts.
	function test_fork_jitLiquidityCannotLiftDepth() public {
		vm.skip(!forked);
		AerodromeBasicTwapAdapter a = _adapter(AWE_USDC, AWE, USDC_USD, USDC_HEARTBEAT);
		(, int256 priceBefore,,,) = a.latestRoundData();
		uint256 depthBefore = a.poolDepthUsd();
		uint256 reserveBefore = a.quoteReserveUsd();
		(uint256 r0, uint256 r1,) = IAerodromeBasicPool(AWE_USDC).getReserves();
		_addLiquidity(AWE_USDC, r0, r1);

		uint256 depthAfter = a.poolDepthUsd();
		emit log_named_decimal_uint('reserve before / after JIT (USD)', reserveBefore, 18);
		emit log_named_decimal_uint('                                ', a.quoteReserveUsd(), 18);
		emit log_named_decimal_uint('depth before / after JIT (USD)  ', depthBefore, 18);
		emit log_named_decimal_uint('                                ', depthAfter, 18);
		assertApproxEqRel(a.quoteReserveUsd(), 2 * reserveBefore, 0.000001e18, 'the reserve doubles');
		(, uint256 avgQ) = _expectedTwar(AWE_USDC, true, WINDOW);
		uint256 expected = Math.mulDiv(Math.mulDiv(avgQ, BAND_QUOTE_PPM, 1e6), _quoteUsd18(USDC_USD), 1e6);
		assertEq(depthAfter, expected, 'depth on the window-average reserve');
		assertApproxEqRel(depthAfter, depthBefore, 0.001e18, 'depth not lifted');
		(, int256 priceAfter,,,) = a.latestRoundData();
		assertEq(priceAfter, priceBefore, 'a proportional add leaves the TWAP');

		vm.warp(block.timestamp + WINDOW);
		_assertQuoteFresh(USDC_USD, USDC_HEARTBEAT);
		assertGe(a.poolDepthUsd(), depthBefore * 3 / 2, 'liquidity held a full window counts');
	}

	/// @notice Ruling 23 on Aerodrome basic: the floor is two-part, and the band is (1 − √0.9) of the
	///         LOWER of the window-average and current quote reserves. Liquidity added this block (a
	///         real mint doubling AWE/USDC's reserves) lifts the live reserve, not the window average:
	///         at a floor of the doubled reserve's whole dollars the reserve reads over it, but the
	///         band — still 5.13% of the old reserve — is under that floor's band floor (5.13% of it),
	///         so the pool reads under. At the pre-mint reserve's floor it reads over on both.
	function test_fork_jitLiquidityCannotLiftTheFloor() public {
		vm.skip(!forked);
		AerodromeBasicTwapAdapter a = _adapter(AWE_USDC, AWE, USDC_USD, USDC_HEARTBEAT);
		uint256 wholeBefore = a.quoteReserveUsd() / 1e18;
		AerodromeBasicTwapAdapter atOld = new AerodromeBasicTwapAdapter(
			IAerodromeBasicPool(AWE_USDC), AWE, AggregatorV3Interface(USDC_USD), WINDOW, wholeBefore, MAX_DEVIATION_BPS, USDC_HEARTBEAT, ''
		);
		assertFalse(atOld.isBelowFloor(), 'before the mint: over both parts at its own reserve');

		(uint256 r0, uint256 r1,) = IAerodromeBasicPool(AWE_USDC).getReserves();
		_addLiquidity(AWE_USDC, r0, r1);
		uint256 whole = a.quoteReserveUsd() / 1e18;
		AerodromeBasicTwapAdapter atJit = new AerodromeBasicTwapAdapter(
			IAerodromeBasicPool(AWE_USDC), AWE, AggregatorV3Interface(USDC_USD), WINDOW, whole, MAX_DEVIATION_BPS, USDC_HEARTBEAT, ''
		);
		uint256 depth = atJit.poolDepthUsd();
		uint256 bandFloor = whole * BAND_QUOTE_PPM / 1e6;
		assertEq(atJit.minBandDepthUsd(), bandFloor, "the adapter's band floor");
		emit log_named_decimal_uint('reserve before / after the mint (USD)', wholeBefore * 1e18, 18);
		emit log_named_decimal_uint('                                     ', atJit.quoteReserveUsd(), 18);
		emit log_named_decimal_uint('band after the mint (USD)            ', depth, 18);
		emit log_named_uint('band floor at the doubled reserve    ', bandFloor);
		assertGe(atJit.quoteReserveUsd(), whole * 1e18, 'the live reserve holds this floor');
		assertLt(depth, bandFloor * 1e18, 'the window-average band does not');
		assertTrue(atJit.isBelowFloor(), 'so the pool reads under it');
		assertFalse(atOld.isBelowFloor(), 'the pre-mint floor still reads over');
	}

	/// @notice isBelowFloor()'s reserve part is exactly quoteReserveUsd() < minLiquidityUsd·1e18: a
	///         floor at the reserve's whole dollars reads over, one dollar more reads under; both
	///         orientations (the band part follows: 5.13% of the reserve vs 5.13% of the floor).
	function test_fork_isBelowFloorIsTheQuoteReserveFloor() public {
		vm.skip(!forked);
		_assertFloorBoundary(KTA_WETH, KTA, ETH_USD, WETH_HEARTBEAT);
		_assertFloorBoundary(AWE_USDC, AWE, USDC_USD, USDC_HEARTBEAT);
	}

	// ─── (b) stable pools are refused ────────────────────────────────────────────

	function test_fork_stablePoolRefused() public {
		vm.skip(!forked);
		IAerodromePoolFactory f = IAerodromePoolFactory(FACTORY);
		assertEq(f.getPool(KTA, USDC, true), KTA_USDC_STABLE);
		assertEq(f.getPool(KTA, WETH, true), KTA_WETH_STABLE);
		assertTrue(IAerodromeBasicPool(KTA_USDC_STABLE).stable());
		assertTrue(IAerodromeBasicPool(KTA_WETH_STABLE).stable());

		vm.expectRevert(AerodromeBasicTwapAdapter.StablePool.selector);
		_adapter(KTA_USDC_STABLE, KTA, USDC_USD, USDC_HEARTBEAT);
		vm.expectRevert(AerodromeBasicTwapAdapter.StablePool.selector);
		_adapter(KTA_WETH_STABLE, KTA, ETH_USD, WETH_HEARTBEAT);
	}

	function test_fork_constructorChecks() public {
		vm.skip(!forked);
		IAerodromeBasicPool p = IAerodromeBasicPool(KTA_WETH);
		AggregatorV3Interface feed = AggregatorV3Interface(ETH_USD);

		vm.expectRevert(AerodromeBasicTwapAdapter.ZeroArgument.selector);
		new AerodromeBasicTwapAdapter(IAerodromeBasicPool(address(0)), KTA, feed, WINDOW, 1, 500, 3600, '');
		vm.expectRevert(AerodromeBasicTwapAdapter.ZeroArgument.selector);
		new AerodromeBasicTwapAdapter(p, address(0), feed, WINDOW, 1, 500, 3600, '');
		vm.expectRevert(AerodromeBasicTwapAdapter.ZeroArgument.selector);
		new AerodromeBasicTwapAdapter(p, KTA, AggregatorV3Interface(address(0)), WINDOW, 1, 500, 3600, '');
		vm.expectRevert(AerodromeBasicTwapAdapter.ZeroArgument.selector);
		new AerodromeBasicTwapAdapter(p, KTA, feed, WINDOW, 0, 500, 3600, '');
		vm.expectRevert(AerodromeBasicTwapAdapter.ZeroArgument.selector);
		new AerodromeBasicTwapAdapter(p, KTA, feed, WINDOW, 1, 500, 0, '');

		vm.expectRevert(abi.encodeWithSelector(AerodromeBasicTwapAdapter.WindowTooShort.selector, uint32(WINDOW - 1)));
		new AerodromeBasicTwapAdapter(p, KTA, feed, WINDOW - 1, 1, 500, 3600, '');
		vm.expectRevert(abi.encodeWithSelector(AerodromeBasicTwapAdapter.BadDeviation.selector, uint16(0)));
		new AerodromeBasicTwapAdapter(p, KTA, feed, WINDOW, 1, 0, 3600, '');
		vm.expectRevert(abi.encodeWithSelector(AerodromeBasicTwapAdapter.BadDeviation.selector, uint16(2_001)));
		new AerodromeBasicTwapAdapter(p, KTA, feed, WINDOW, 1, 2_001, 3600, '');
		vm.expectRevert(abi.encodeWithSelector(AerodromeBasicTwapAdapter.AssetNotInPool.selector, USDC));
		new AerodromeBasicTwapAdapter(p, USDC, feed, WINDOW, 1, 500, 3600, '');

		AerodromeBasicTwapAdapter a = new AerodromeBasicTwapAdapter(p, KTA, feed, WINDOW, 25_000, 2_000, 3600, 'KTA / USD');
		assertEq(address(a.pool()), KTA_WETH);
		assertEq(a.asset(), KTA);
		assertEq(a.quoteAsset(), WETH);
		assertFalse(a.assetIsToken0());
		assertEq(address(a.quoteFeed()), ETH_USD);
		assertEq(a.window(), WINDOW);
		assertEq(a.minLiquidityUsd(), 25_000);
		assertEq(a.minBandDepthUsd(), MIN_BAND_DEPTH_USD, 'the band floor: 25,000 x PPM / 1e6');
		assertEq(MIN_BAND_DEPTH_USD, MIN_QUOTE_RESERVE_USD * BAND_QUOTE_PPM / 1e6);
		assertEq(a.maxDeviationBps(), 2_000);
		assertEq(a.quoteHeartbeat(), 3600);
		assertEq(a.description(), 'KTA / USD');
		assertEq(a.BAND_QUOTE_PPM(), BAND_QUOTE_PPM, 'floor((1 - sqrt 0.9) x 1e6)');
	}

	// ─── (c) observation choice ──────────────────────────────────────────────────

	/// @notice A real swap writes a fresh observation; 60 s later the last observation is < 30 min
	///         old, so the adapter prices from the one before it (len − 2), not from the fresh one.
	function test_fork_freshLastObservationFallsBackToPrevious() public {
		vm.skip(!forked);
		IAerodromeBasicPool p = IAerodromeBasicPool(AWE_USDC);
		_writeFreshObservation(AWE_USDC, USDC);
		vm.warp(block.timestamp + 60);
		_assertQuoteFresh(USDC_USD, USDC_HEARTBEAT);

		uint256 len = p.observationLength();
		(uint256 tFresh,,) = p.observations(len - 1);
		(uint256 tPrev,,) = p.observations(len - 2);
		assertLt(block.timestamp - tFresh, WINDOW, 'last observation younger than the window');
		assertGe(block.timestamp - tPrev, WINDOW, 'previous observation old enough');

		AerodromeBasicTwapAdapter a = _adapter(AWE_USDC, AWE, USDC_USD, USDC_HEARTBEAT);
		(, int256 answer,,,) = a.latestRoundData();
		uint256 fromPrev = _priceFrom(AWE_USDC, true, USDC_USD, len - 2);
		uint256 fromFresh = _priceFrom(AWE_USDC, true, USDC_USD, len - 1);
		emit log_named_decimal_uint('price from len-2 (used)   ', fromPrev, 18);
		emit log_named_decimal_uint('price from len-1 (skipped)', fromFresh, 18);
		assertEq(SafeCast.toUint256(answer), fromPrev, 'priced from len - 2');
		assertTrue(fromPrev != fromFresh, 'the two observations price differently');
		assertEq(fromPrev, _expectedPrice(AWE_USDC, true, USDC_USD), 'the newest observation at least a window old');
	}

	/// @notice With the last observation fresh, the window is served exactly up to len − 2's age:
	///         a window of that age prices, one second more reverts on every read.
	function test_fork_windowBoundaryAtPreviousObservation() public {
		vm.skip(!forked);
		IAerodromeBasicPool p = IAerodromeBasicPool(AWE_USDC);
		_writeFreshObservation(AWE_USDC, USDC);
		vm.warp(block.timestamp + 60);
		_assertQuoteFresh(USDC_USD, USDC_HEARTBEAT);
		(uint256 tPrev,,) = p.observations(p.observationLength() - 2);
		uint32 served = SafeCast.toUint32(block.timestamp - tPrev);

		AerodromeBasicTwapAdapter ok = _adapterWindow(AWE_USDC, AWE, USDC_USD, USDC_HEARTBEAT, served);
		(, int256 answer,,,) = ok.latestRoundData();
		assertGt(answer, 0);

		AerodromeBasicTwapAdapter tooLong = _adapterWindow(AWE_USDC, AWE, USDC_USD, USDC_HEARTBEAT, served + 1);
		_assertWindowUnavailable(tooLong);
	}

	/// @notice A real pool created on the fork has one observation (its creation): it can't price
	///         until that observation is a window old, then prices exactly at its reserves.
	function test_fork_newPoolNeedsAWindowOfHistory() public {
		vm.skip(!forked);
		uint256 usdcIn = 30_000e6;
		uint256 lumiaIn = 100_000e18;
		address pool = _newLumiaUsdcPool(usdcIn, lumiaIn);
		assertEq(IAerodromeBasicPool(pool).observationLength(), 1);

		AerodromeBasicTwapAdapter a = _adapter(pool, LUMIA, USDC_USD, USDC_HEARTBEAT);
		assertTrue(a.assetIsToken0());
		_assertWindowUnavailable(a);

		vm.warp(block.timestamp + WINDOW - 1);
		_assertWindowUnavailable(a);

		vm.warp(block.timestamp + 1);
		_assertQuoteFresh(USDC_USD, USDC_HEARTBEAT);
		assertEq(IAerodromeBasicPool(pool).observationLength(), 1, 'still one observation');
		(, int256 answer,,,) = a.latestRoundData();
		uint256 expected = Math.mulDiv(usdcIn * 1e18, _quoteUsd18(USDC_USD), lumiaIn * 1e6);
		assertEq(SafeCast.toUint256(answer), expected, 'the minted reserves, exactly');
		assertEq(a.quoteReserveUsd(), Math.mulDiv(usdcIn, _quoteUsd18(USDC_USD), 1e6));
	}

	/// @notice A real pool that never held liquidity has zero cumulative reserves: it never prices.
	function test_fork_emptyPoolNeverPrices() public {
		vm.skip(!forked);
		address pool = IAerodromePoolFactory(FACTORY).createPool(LUMIA, USDC, false);
		AerodromeBasicTwapAdapter a = _adapter(pool, LUMIA, USDC_USD, USDC_HEARTBEAT);
		vm.warp(block.timestamp + WINDOW);
		_assertQuoteFresh(USDC_USD, USDC_HEARTBEAT);
		_assertWindowUnavailable(a);
	}

	// ─── sub-cent prices (Ruling 19) ─────────────────────────────────────────────
	// No Aerodrome basic USDC pool prices a token below $0.0001 (cast over every DefiLlama
	// aerodrome-v1 Base USDC pool ≥ $50k, 2026-09-30: cheapest BET $0.0075, AUKI $0.0077), so these
	// create a real LUMIA/USDC volatile pool through the real factory and mint it at the price.

	/// @notice $0.0000123456789: the answer equals the full-precision reference to the wei; the old
	///         whole-raw-unit formula read 12 raw USDC units per LUMIA, $0.000012 (−2.8%).
	function test_fork_subCentPriceKeepsItsDigits() public {
		vm.skip(!forked);
		uint256 usdcIn = 12_345_678_901; // 12,345.678901 USDC
		uint256 lumiaIn = 1e27; // 1e9 LUMIA
		AerodromeBasicTwapAdapter a = _adapter(_newLumiaUsdcPool(usdcIn, lumiaIn), LUMIA, USDC_USD, USDC_HEARTBEAT);
		vm.warp(block.timestamp + WINDOW);
		_assertQuoteFresh(USDC_USD, USDC_HEARTBEAT);

		(, int256 answer,,,) = a.latestRoundData();
		uint256 price = SafeCast.toUint256(answer);
		uint256 expected = Math.mulDiv(usdcIn * 1e18, _quoteUsd18(USDC_USD), lumiaIn * 1e6);
		uint256 old = Math.mulDiv(Math.mulDiv(usdcIn, 1e18, lumiaIn), _quoteUsd18(USDC_USD), 1e6);
		emit log_named_decimal_uint('price (USD)               ', price, 18);
		emit log_named_decimal_uint('old / new                 ', Math.mulDiv(old, 1e18, price), 18);
		assertEq(price, expected, 'rounded once');
		assertEq(Math.mulDiv(usdcIn, 1e18, lumiaIn), 12, 'the old formula kept 12 raw USDC units per LUMIA');
		assertLt(Math.mulDiv(old, 1e18, price), 0.975e18, 'the old formula read > 2.5% low');
		_assertWithinOldRounding(price, old, USDC_USD, USDC);
	}

	/// @notice $0.00000001: the old formula floored to zero raw USDC units (PriceRoundsToZero);
	///         the adapter prices it to the wei.
	function test_fork_nanoPriceIsPriced() public {
		vm.skip(!forked);
		uint256 usdcIn = 10_000e6;
		uint256 lumiaIn = 1e30; // 1e12 LUMIA
		AerodromeBasicTwapAdapter a = _adapter(_newLumiaUsdcPool(usdcIn, lumiaIn), LUMIA, USDC_USD, USDC_HEARTBEAT);
		vm.warp(block.timestamp + WINDOW);
		_assertQuoteFresh(USDC_USD, USDC_HEARTBEAT);

		(, int256 answer,,,) = a.latestRoundData();
		emit log_named_decimal_uint('price (USD)               ', SafeCast.toUint256(answer), 18);
		assertEq(Math.mulDiv(usdcIn, 1e18, lumiaIn), 0, 'the old formula floored to zero');
		assertEq(SafeCast.toUint256(answer), Math.mulDiv(usdcIn * 1e18, _quoteUsd18(USDC_USD), lumiaIn * 1e6), 'rounded once');
		assertGt(answer, 0);
	}

	/// @notice At $0.00000001 the old guard compared 0 raw units with 0 and always passed; the
	///         cross-product guard still trips on a real ~8% swap, with the exact USD prices.
	function test_fork_nanoPriceSpotGuardStillTrips() public {
		vm.skip(!forked);
		address pool = _newLumiaUsdcPool(10_000e6, 1e30);
		AerodromeBasicTwapAdapter a = _adapter(pool, LUMIA, USDC_USD, USDC_HEARTBEAT);
		vm.warp(block.timestamp + WINDOW);
		_assertQuoteFresh(USDC_USD, USDC_HEARTBEAT);
		(, int256 before,,,) = a.latestRoundData();
		uint256 twapUsd = SafeCast.toUint256(before);

		(, uint256 rQ) = _reserves(pool, true);
		_swapIn(pool, USDC, rQ * 4 / 100);
		(uint256 rA, uint256 rQAfter) = _reserves(pool, true);
		assertEq(Math.mulDiv(rQAfter, 1e18, rA), 0, 'the old spot floored to zero too');
		uint256 spotUsd = _spotUsd(pool, true, USDC_USD);
		emit log_named_decimal_uint('spot / TWAP after the swap', Math.mulDiv(spotUsd, 1e18, twapUsd), 18);
		assertGt(spotUsd * BPS, twapUsd * (BPS + MAX_DEVIATION_BPS), 'spot more than 5% over');

		vm.expectRevert(abi.encodeWithSelector(AerodromeBasicTwapAdapter.SpotDeviatesFromTwap.selector, spotUsd, twapUsd));
		a.latestRoundData();
	}

	// ─── (d) spot guard on real swaps ────────────────────────────────────────────

	/// @notice A same-block swap moves spot but not the TWAP: the answer is unchanged to the wei.
	function test_fork_sameBlockSwapCannotMoveTwap() public {
		vm.skip(!forked);
		AerodromeBasicTwapAdapter a = _adapter(KTA_WETH, KTA, ETH_USD, WETH_HEARTBEAT);
		(, int256 before,,,) = a.latestRoundData();
		uint256 spotBefore = _spotUsd(KTA_WETH, false, ETH_USD);
		(, uint256 rQ) = _reserves(KTA_WETH, false);
		_swapIn(KTA_WETH, WETH, rQ / 200); // ~ +1% spot
		assertGt(_spotUsd(KTA_WETH, false, ETH_USD), spotBefore, 'spot moved up');
		(, int256 afterSwap,,,) = a.latestRoundData();
		assertEq(afterSwap, before, 'TWAP unmoved');
	}

	function test_fork_spotGuardTripsOnSell_kta() public {
		vm.skip(!forked);
		_assertSwapTripsGuard(KTA_WETH, KTA, ETH_USD, WETH_HEARTBEAT, true);
	}

	function test_fork_spotGuardTripsOnBuy_kta() public {
		vm.skip(!forked);
		_assertSwapTripsGuard(KTA_WETH, KTA, ETH_USD, WETH_HEARTBEAT, false);
	}

	function test_fork_spotGuardTripsOnSell_awe() public {
		vm.skip(!forked);
		_assertSwapTripsGuard(AWE_USDC, AWE, USDC_USD, USDC_HEARTBEAT, true);
	}

	function test_fork_spotGuardTripsOnBuy_awe() public {
		vm.skip(!forked);
		_assertSwapTripsGuard(AWE_USDC, AWE, USDC_USD, USDC_HEARTBEAT, false);
	}

	// ─── quote feed ──────────────────────────────────────────────────────────────

	/// @notice The quote feed is fresh up to updatedAt + heartbeat and stale one second later.
	function test_fork_staleQuoteFeedReverts() public {
		vm.skip(!forked);
		AerodromeBasicTwapAdapter a = _adapter(KTA_WETH, KTA, ETH_USD, WETH_HEARTBEAT);
		(,,, uint256 updatedAt,) = AggregatorV3Interface(ETH_USD).latestRoundData();
		vm.warp(updatedAt + WETH_HEARTBEAT);
		a.latestRoundData();
		vm.warp(updatedAt + WETH_HEARTBEAT + 1);
		bytes memory stale = abi.encodeWithSelector(AerodromeBasicTwapAdapter.QuoteStale.selector, updatedAt);
		vm.expectRevert(stale);
		a.latestRoundData();
		vm.expectRevert(stale);
		a.quoteReserveUsd();
		vm.expectRevert(stale);
		a.poolDepthUsd();
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	function _adapter(address pool, address asset, address feed, uint32 heartbeat)
		internal
		returns (AerodromeBasicTwapAdapter)
	{
		return _adapterWindow(pool, asset, feed, heartbeat, WINDOW);
	}

	function _adapterWindow(address pool, address asset, address feed, uint32 heartbeat, uint32 window)
		internal
		returns (AerodromeBasicTwapAdapter)
	{
		return new AerodromeBasicTwapAdapter(
			IAerodromeBasicPool(pool),
			asset,
			AggregatorV3Interface(feed),
			window,
			MIN_QUOTE_RESERVE_USD,
			MAX_DEVIATION_BPS,
			heartbeat,
			'aerodrome basic'
		);
	}

	function _assertCandidate(address pool, address asset, address quote, bool assetIsToken0) internal view {
		assertEq(IAerodromePoolFactory(FACTORY).getPool(asset, quote, false), pool, 'the factory volatile pool');
		IAerodromeBasicPool p = IAerodromeBasicPool(pool);
		assertFalse(p.stable());
		assertEq(p.token0(), assetIsToken0 ? asset : quote);
		assertEq(p.token1(), assetIsToken0 ? quote : asset);
		assertFalse(IValueInterpreter(VALUE_INTERPRETER).isSupportedAsset(asset), 'not VI-priced');
		(, uint256 rQ) = _reserves(pool, assetIsToken0);
		address feed = quote == WETH ? ETH_USD : USDC_USD;
		uint256 reserveUsd = Math.mulDiv(rQ, _quoteUsd18(feed), 10 ** IERC20Metadata(quote).decimals());
		assertGe(reserveUsd, MIN_QUOTE_RESERVE_USD * 1e18, 'above the quote floor');
	}

	function _assertPricesRealPool(address pool, address asset, address feed, uint32 heartbeat, bool assetIsToken0)
		internal
	{
		AerodromeBasicTwapAdapter a = _adapter(pool, asset, feed, heartbeat);
		assertEq(a.assetIsToken0(), assetIsToken0);
		emit log_named_address('pool', pool);
		_assertPriceNearSpot(a, feed);
		uint256 reserve = _assertReserveIsGetReserves(a, feed);
		_assertDepthIsBandOfReserve(a, feed, reserve);
		assertFalse(a.isBelowFloor());
	}

	function _assertPriceNearSpot(AerodromeBasicTwapAdapter a, address feed) internal {
		address pool = address(a.pool());
		(, int256 answer,, uint256 updatedAt,) = a.latestRoundData();
		uint256 price = SafeCast.toUint256(answer);
		assertEq(updatedAt, block.timestamp);
		assertEq(price, _expectedPrice(pool, a.assetIsToken0(), feed), 'time-averaged reserves x the feed, rounded once');
		(uint256 avgA, uint256 avgQ) = _expectedTwar(pool, a.assetIsToken0(), WINDOW);
		_assertWithinOldRounding(price, _oldPrice(pool, a.assetIsToken0(), feed, avgA, avgQ), feed, a.quoteAsset());
		uint256 spotUsd = _spotUsd(pool, a.assetIsToken0(), feed);
		emit log_named_decimal_uint('TWAP price (USD)          ', price, 18);
		emit log_named_decimal_uint('spot price (USD)          ', spotUsd, 18);
		assertApproxEqRel(price, spotUsd, 0.02e18, 'TWAP within 2% of spot');
	}

	/// @dev quoteReserveUsd = getReserves' quote × the feed exactly; balanceOf only adds dust.
	function _assertReserveIsGetReserves(AerodromeBasicTwapAdapter a, address feed) internal returns (uint256 reserve) {
		address pool = address(a.pool());
		uint256 qUnit = 10 ** IERC20Metadata(a.quoteAsset()).decimals();
		(, uint256 rQ) = _reserves(pool, a.assetIsToken0());
		reserve = a.quoteReserveUsd();
		uint256 balanceUsd = Math.mulDiv(IERC20(a.quoteAsset()).balanceOf(pool), _quoteUsd18(feed), qUnit);
		emit log_named_decimal_uint('quote reserve (USD)       ', reserve, 18);
		emit log_named_decimal_uint('quote balanceOf (USD)     ', balanceUsd, 18);
		assertEq(reserve, Math.mulDiv(rQ, _quoteUsd18(feed), qUnit), 'getReserves quote x the feed, exactly');
		assertLe(reserve, balanceUsd, 'balance = reserve + unskimmed donations');
		assertApproxEqRel(reserve, balanceUsd, 0.001e18, 'within 0.1% of balanceOf');
	}

	/// @dev depth = (1 − √0.9) × min(window-average, current) quote reserve × the feed.
	function _assertDepthIsBandOfReserve(AerodromeBasicTwapAdapter a, address feed, uint256 reserve) internal {
		address pool = address(a.pool());
		(, uint256 avgQ) = _expectedTwar(pool, a.assetIsToken0(), WINDOW);
		(, uint256 rQ) = _reserves(pool, a.assetIsToken0());
		uint256 depth = a.poolDepthUsd();
		uint256 bandOfReserve = Math.mulDiv(reserve, BAND_QUOTE_PPM, 1e6);
		emit log_named_decimal_uint('band depth (USD)          ', depth, 18);
		emit log_named_decimal_uint('5.1316% of reserve (USD)  ', bandOfReserve, 18);
		emit log_named_decimal_uint('window-avg quote / reserve', Math.mulDiv(avgQ, 1e18, rQ), 18);
		uint256 quoteOut = Math.mulDiv(Math.min(avgQ, rQ), BAND_QUOTE_PPM, 1e6);
		uint256 expected = Math.mulDiv(quoteOut, _quoteUsd18(feed), 10 ** IERC20Metadata(a.quoteAsset()).decimals());
		assertEq(depth, expected, 'min(window-avg, current) quote x (1 - sqrt 0.9) x the feed');
		assertLe(depth, bandOfReserve, 'never above 5.13% of the current reserve');
		assertApproxEqRel(depth, bandOfReserve, 0.05e18, '~5.13% of the reserve');
	}

	/// @dev Sells the asset into the pool until spot is −10% (x·y=k: the net input takes the asset
	///      reserve to A/√0.9) and checks the quote paid out is (1 − √0.9) of the quote reserve.
	function _assertMinus10PctSellPaysBandQuote(address pool, address asset, address feed, uint32 heartbeat) internal {
		AerodromeBasicTwapAdapter a = _adapter(pool, asset, feed, heartbeat);
		bool t0 = a.assetIsToken0();
		uint256 depth = a.poolDepthUsd();
		(uint256 rA, uint256 rQ) = _reserves(pool, t0);
		uint256 spotBefore = _spotUsd(pool, t0, feed);

		uint256 quoteOut = _swapIn(pool, asset, _grossInForMinus10Pct(pool, rA));

		uint256 qUnit = 10 ** IERC20Metadata(a.quoteAsset()).decimals();
		uint256 outUsd = Math.mulDiv(quoteOut, _quoteUsd18(feed), qUnit);
		emit log_named_decimal_uint('spot after / before         ', Math.mulDiv(_spotUsd(pool, t0, feed), 1e18, spotBefore), 18);
		emit log_named_decimal_uint('quote out / quote reserve   ', Math.mulDiv(quoteOut, 1e18, rQ), 18);
		emit log_named_decimal_uint('quote out (USD)             ', outUsd, 18);
		emit log_named_decimal_uint('adapter depth before (USD)  ', depth, 18);
		assertApproxEqRel(_spotUsd(pool, t0, feed), Math.mulDiv(spotBefore, 9, 10), 0.0001e18, 'spot -10%');
		assertApproxEqRel(quoteOut, Math.mulDiv(rQ, BAND_QUOTE_PPM, 1e6), 0.0001e18, '(1 - sqrt 0.9) of the quote reserve');
		assertLe(depth, outUsd, 'the depth never overstates the real bids');
	}

	/// @dev Gross asset input whose post-fee part takes the asset reserve to rA/√0.9 (spot × 0.9).
	function _grossInForMinus10Pct(address pool, uint256 rA) internal view returns (uint256) {
		uint256 netIn = Math.mulDiv(rA, 1e18, SQRT_POINT9_E18, Math.Rounding.Ceil) - rA;
		uint256 fee = IAerodromePoolFactory(FACTORY).getFee(pool, false);
		return Math.mulDiv(netIn, BPS, BPS - fee, Math.Rounding.Ceil);
	}

	function _assertFloorBoundary(address pool, address asset, address feed, uint32 heartbeat) internal {
		uint256 whole = _adapter(pool, asset, feed, heartbeat).quoteReserveUsd() / 1e18;
		AerodromeBasicTwapAdapter atReserve = new AerodromeBasicTwapAdapter(
			IAerodromeBasicPool(pool), asset, AggregatorV3Interface(feed), WINDOW, whole, MAX_DEVIATION_BPS, heartbeat, ''
		);
		AerodromeBasicTwapAdapter overReserve = new AerodromeBasicTwapAdapter(
			IAerodromeBasicPool(pool), asset, AggregatorV3Interface(feed), WINDOW, whole + 1, MAX_DEVIATION_BPS, heartbeat, ''
		);
		assertFalse(atReserve.isBelowFloor(), 'reserve >= floor');
		assertTrue(overReserve.isBelowFloor(), 'reserve < floor + $1');
		assertEq(atReserve.minBandDepthUsd(), whole * BAND_QUOTE_PPM / 1e6, 'the band floor follows the reserve floor');
		assertGe(atReserve.poolDepthUsd(), atReserve.minBandDepthUsd() * 1e18);
	}

	/// @dev Real swaps of 4% of the input reserve move spot ~8% (> 5%): the guard reverts with the
	///      new spot and the unmoved TWAP. The reserve and depth reads skip the guard; a 20% guard
	///      still prices at the same TWAP.
	function _assertSwapTripsGuard(address pool, address asset, address feed, uint32 heartbeat, bool sellAsset) internal {
		AerodromeBasicTwapAdapter a = _adapter(pool, asset, feed, heartbeat);
		AerodromeBasicTwapAdapter wide = new AerodromeBasicTwapAdapter(
			IAerodromeBasicPool(pool), asset, AggregatorV3Interface(feed), WINDOW, MIN_QUOTE_RESERVE_USD, 2_000, heartbeat, ''
		);
		(, int256 before,,,) = a.latestRoundData(); // within the guard before the swap
		uint256 twapUsd = SafeCast.toUint256(before); // a same-block swap leaves the TWAP

		(uint256 rA, uint256 rQ) = _reserves(pool, a.assetIsToken0());
		if (sellAsset) _swapIn(pool, asset, rA * 4 / 100);
		else _swapIn(pool, a.quoteAsset(), rQ * 4 / 100);

		uint256 spotUsd = _spotUsd(pool, a.assetIsToken0(), feed);
		emit log_named_decimal_uint('spot / TWAP after the swap', Math.mulDiv(spotUsd, 1e18, twapUsd), 18);
		if (sellAsset) assertGt(twapUsd * BPS, spotUsd * (BPS + MAX_DEVIATION_BPS), 'spot more than 5% under');
		else assertGt(spotUsd * BPS, twapUsd * (BPS + MAX_DEVIATION_BPS), 'spot more than 5% over');

		vm.expectRevert(abi.encodeWithSelector(AerodromeBasicTwapAdapter.SpotDeviatesFromTwap.selector, spotUsd, twapUsd));
		a.latestRoundData();

		(, int256 wideAnswer,,,) = wide.latestRoundData();
		assertEq(wideAnswer, before, 'a 20% guard prices at the unmoved TWAP');
		_assertReadsSkipGuard(a, feed);
	}

	/// @dev The reserve and depth reads still serve while spot is off the TWAP.
	function _assertReadsSkipGuard(AerodromeBasicTwapAdapter a, address feed) internal view {
		(, uint256 rQ) = _reserves(address(a.pool()), a.assetIsToken0());
		uint256 qUnit = 10 ** IERC20Metadata(a.quoteAsset()).decimals();
		assertEq(a.quoteReserveUsd(), Math.mulDiv(rQ, _quoteUsd18(feed), qUnit), 'reserve read skips the guard');
		assertGt(a.poolDepthUsd(), 0, 'depth read skips the guard');
	}

	function _assertWindowUnavailable(AerodromeBasicTwapAdapter a) internal {
		bytes4 err = AerodromeBasicTwapAdapter.ObservationWindowUnavailable.selector;
		vm.expectRevert(err);
		a.latestRoundData();
		vm.expectRevert(err);
		a.quoteReserveUsd();
		vm.expectRevert(err);
		a.poolDepthUsd();
		vm.expectRevert(err);
		a.isBelowFloor();
	}

	/// @dev Makes the last observation older than periodSize (warping at most 1801 s) and swaps
	///      0.5% of the quote reserve in, which writes a new observation at block.timestamp.
	function _writeFreshObservation(address pool, address quote) internal {
		IAerodromeBasicPool p = IAerodromeBasicPool(pool);
		(uint256 tLast,,) = p.lastObservation();
		if (block.timestamp - tLast <= PERIOD_SIZE) vm.warp(tLast + PERIOD_SIZE + 1);
		uint256 len = p.observationLength();
		(uint256 r0, uint256 r1,) = p.getReserves();
		_swapIn(pool, quote, (quote == p.token0() ? r0 : r1) / 200);
		assertEq(p.observationLength(), len + 1, 'the swap wrote an observation');
		(uint256 tNew,,) = p.lastObservation();
		assertEq(tNew, block.timestamp);
	}

	/// @dev A real LUMIA/USDC volatile pool (none exists on Base) created by the real factory and
	///      minted at `usdcIn` per `lumiaIn`; LUMIA sorts first, so the asset is token0.
	function _newLumiaUsdcPool(uint256 usdcIn, uint256 lumiaIn) internal returns (address pool) {
		IAerodromePoolFactory f = IAerodromePoolFactory(FACTORY);
		assertEq(f.getPool(LUMIA, USDC, false), address(0), 'no LUMIA/USDC volatile pool yet');
		pool = f.createPool(LUMIA, USDC, false);
		assertEq(IAerodromeBasicPool(pool).token0(), LUMIA);
		_addLiquidity(pool, lumiaIn, usdcIn);
	}

	/// @dev Real liquidity add straight through the pool: pay both tokens in, mint.
	function _addLiquidity(address pool, uint256 amount0, uint256 amount1) internal {
		IAerodromeBasicPool p = IAerodromeBasicPool(pool);
		deal(p.token0(), address(this), amount0);
		deal(p.token1(), address(this), amount1);
		assertTrue(IERC20(p.token0()).transfer(pool, amount0));
		assertTrue(IERC20(p.token1()).transfer(pool, amount1));
		assertGt(IAerodromeBasicPoolExtras(pool).mint(address(this)), 0);
	}

	/// @dev Real swap straight through the pool: pay in, take getAmountOut of what arrived.
	function _swapIn(address pool, address tokenIn, uint256 amountIn) internal returns (uint256 out) {
		IAerodromeBasicPool p = IAerodromeBasicPool(pool);
		bool zeroIn = tokenIn == p.token0();
		deal(tokenIn, address(this), amountIn);
		assertTrue(IERC20(tokenIn).transfer(pool, amountIn));
		(uint256 r0, uint256 r1,) = p.getReserves();
		uint256 received = IERC20(tokenIn).balanceOf(pool) - (zeroIn ? r0 : r1);
		out = IAerodromeBasicPoolExtras(pool).getAmountOut(received, tokenIn);
		IAerodromeBasicPoolExtras(pool).swap(zeroIn ? 0 : out, zeroIn ? out : 0, address(this), '');
	}

	/// @dev Independent re-derivation from raw pool storage: scan back to the newest observation at
	///      least `window` old, then reserve{0,1}CumulativeLast + reserves × (now − last update).
	function _expectedTwar(address pool, bool assetIsToken0, uint32 window)
		internal
		view
		returns (uint256 avgA, uint256 avgQ)
	{
		IAerodromeBasicPool p = IAerodromeBasicPool(pool);
		uint256 i = p.observationLength() - 1;
		(uint256 t,,) = p.observations(i);
		while (block.timestamp - t < window) {
			(t,,) = p.observations(--i);
		}
		return _twarFrom(pool, assetIsToken0, i);
	}

	function _twarFrom(address pool, bool assetIsToken0, uint256 index) internal view returns (uint256 avgA, uint256 avgQ) {
		IAerodromeBasicPool p = IAerodromeBasicPool(pool);
		(uint256 t, uint256 c0, uint256 c1) = p.observations(index);
		(uint256 r0, uint256 r1, uint256 tLast) = p.getReserves();
		uint256 n0 = IAerodromeBasicPoolExtras(pool).reserve0CumulativeLast() + r0 * (block.timestamp - tLast);
		uint256 n1 = IAerodromeBasicPoolExtras(pool).reserve1CumulativeLast() + r1 * (block.timestamp - tLast);
		uint256 dt = block.timestamp - t;
		(uint256 a0, uint256 a1) = ((n0 - c0) / dt, (n1 - c1) / dt);
		(avgA, avgQ) = assetIsToken0 ? (a0, a1) : (a1, a0);
	}

	function _expectedPrice(address pool, bool assetIsToken0, address feed) internal view returns (uint256) {
		(uint256 avgA, uint256 avgQ) = _expectedTwar(pool, assetIsToken0, WINDOW);
		return _price(pool, assetIsToken0, feed, avgA, avgQ);
	}

	function _priceFrom(address pool, bool assetIsToken0, address feed, uint256 index) internal view returns (uint256) {
		(uint256 avgA, uint256 avgQ) = _twarFrom(pool, assetIsToken0, index);
		return _price(pool, assetIsToken0, feed, avgA, avgQ);
	}

	/// @dev Full-precision reference, decomposed differently from the adapter (both products
	///      formed first, one mulDiv): floor(quote × 10^ad × feed / (asset × 10^qd)).
	function _price(address pool, bool assetIsToken0, address feed, uint256 assetAmount, uint256 quoteAmount)
		internal
		view
		returns (uint256)
	{
		(uint256 aUnit, uint256 qUnit) = _units(pool, assetIsToken0);
		return Math.mulDiv(quoteAmount * aUnit, _quoteUsd18(feed), assetAmount * qUnit);
	}

	/// @dev The pre-Ruling-19 formula: quote truncated to whole raw units per whole asset first.
	function _oldPrice(address pool, bool assetIsToken0, address feed, uint256 assetAmount, uint256 quoteAmount)
		internal
		view
		returns (uint256)
	{
		(uint256 aUnit, uint256 qUnit) = _units(pool, assetIsToken0);
		return Math.mulDiv(Math.mulDiv(quoteAmount, aUnit, assetAmount), _quoteUsd18(feed), qUnit);
	}

	function _units(address pool, bool assetIsToken0) internal view returns (uint256 aUnit, uint256 qUnit) {
		IAerodromeBasicPool p = IAerodromeBasicPool(pool);
		(address asset, address quote) = assetIsToken0 ? (p.token0(), p.token1()) : (p.token1(), p.token0());
		aUnit = 10 ** IERC20Metadata(asset).decimals();
		qUnit = 10 ** IERC20Metadata(quote).decimals();
	}

	/// @dev Equality guard: the old formula floored the quote Q to whole raw units, floor(Q) ≤ Q <
	///      floor(Q) + 1, so the exact price is never below it and exceeds it by at most the USD of one
	///      raw quote unit (+1 wei for the final floor).
	function _assertWithinOldRounding(uint256 price, uint256 oldPrice, address feed, address quote) internal {
		uint256 unit = _quoteUsd18(feed) / 10 ** IERC20Metadata(quote).decimals();
		emit log_named_decimal_uint('old-formula price (USD)   ', oldPrice, 18);
		assertGe(price, oldPrice, 'never below the truncated price');
		assertLe(price - oldPrice, unit + 1, 'within one old rounding unit');
	}

	function _reserves(address pool, bool assetIsToken0) internal view returns (uint256 rA, uint256 rQ) {
		(uint256 r0, uint256 r1,) = IAerodromeBasicPool(pool).getReserves();
		(rA, rQ) = assetIsToken0 ? (r0, r1) : (r1, r0);
	}

	/// @dev Spot USD per whole asset from the current reserves, full precision.
	function _spotUsd(address pool, bool assetIsToken0, address feed) internal view returns (uint256) {
		(uint256 rA, uint256 rQ) = _reserves(pool, assetIsToken0);
		return _price(pool, assetIsToken0, feed, rA, rQ);
	}

	function _assertQuoteFresh(address feed, uint32 heartbeat) internal view {
		(,,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
		assertLe(block.timestamp, updatedAt + heartbeat, 'quote feed fresh after the warp (pin BASE_FORK_BLOCK if not)');
	}

	function _quoteUsd18(address feed) internal view returns (uint256) {
		(, int256 answer,,,) = AggregatorV3Interface(feed).latestRoundData();
		return SafeCast.toUint256(answer) * 10 ** (18 - AggregatorV3Interface(feed).decimals());
	}
}
