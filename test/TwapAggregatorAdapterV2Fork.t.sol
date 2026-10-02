// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {TwapAggregatorAdapterV2} from '../src/pricing/TwapAggregatorAdapterV2.sol';
import {TwapAggregatorAdapter, IConcentratedPoolOracle} from '../src/pricing/TwapAggregatorAdapter.sol';
import {AggregatorV3Interface} from '../src/interfaces/AggregatorV3Interface.sol';
import {ITwapPriceAdapter} from '../src/interfaces/ITwapPriceAdapter.sol';
import {IUniswapV3NonfungiblePositionManager} from
	'../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {TickMath} from '../src/libraries/TickMath.sol';

/// @notice The Uniswap v3 pool reads the test needs beyond the adapter's oracle surface.
interface IUniswapV3PoolState {
	function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
	function fee() external view returns (uint24);
}

/// @notice Quote-side depth on real Base pools: a two-sided pool keeps a real depth; LUMIA's
///         one-sided pool (0.98 WETH vs 150M LUMIA) collapses to its ~$2.6k of WETH. A quote-only
///         position minted through the real NonfungiblePositionManager moves the depth by exactly
///         its USD value in both orientations (asset = token1 and asset = token0). The floor is
///         two-part (Ruling 23): the quote RESERVE (USDC/WETH the pool holds × Chainlink) — LUMIA's
///         ~$2.6k stays under the $25k listing floor, VIRTUAL's pool clears it — AND the band (CHECK's
///         pool holds ~$300k of USDC but ~$500 of it within −10%: under the $1,282 band floor).
///         Run: BASE_MAINNET_RPC=<url> [BASE_FORK_BLOCK=<n>] forge test --match-path test/TwapAggregatorAdapterV2Fork.t.sol -vv
contract TwapAggregatorAdapterV2ForkTest is Test {
	address internal constant WETH = 0x4200000000000000000000000000000000000006;
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant ETH_USD = 0x50015f8b17fb2C290Dde41fDc246ed0dcEE93a8b; // standard proxy
	address internal constant USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
	address internal constant LUMIA = 0x550161Ae735DebeE90Ba117025db0E83131bf9A6;
	address internal constant LUMIA_POOL = 0x36523a7A21139e0D85D1d3BA69E9F8Aa9A5bD185; // UniV3 0.3% vs WETH
	address internal constant VIRTUAL = 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b;
	address internal constant VIRTUAL_POOL = 0x529d2863a1521d0b57db028168fdE2E97120017C; // UniV3 0.3% vs USDC
	// Uniswap v3 NPM on Base: factory() = both pools' factory 0x33128a8f…F6FDfD, WETH9() = WETH (cast, 2026-09-30)
	address internal constant NPM = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
	// Quote-token wei the depth delta may differ from the minted amount by. Only rounding separates
	// them: the pool rounds the paid amount up (≤ 1 wei), the band walk rounds each segment down
	// (≤ 1 wei each), and the position's two new ticks split two existing segments. At spacing 60
	// the 2007-tick band holds at most 34 initialized ticks, so the error is < 40 wei; 100 wei is
	// $0.0001 of USDC and ~$3e-13 of WETH.
	uint256 internal constant ROUNDING_WEI = 100;
	/// @dev The registry's listing / delist-clock floor (MIN_QUOTE_RESERVE_USD), whole USD.
	uint256 internal constant MIN_QUOTE_RESERVE_USD = 25_000;
	// Real USDC pools pricing a token below $0.0001 (cast over DefiLlama Base USDC pools, 2026-09-30;
	// each = UniV3 factory 0x3312…FDfD getPool(asset, USDC, fee), HTEA = Slipstream CL2 factory
	// 0xf8f2…61Ef getPool(asset, USDC, 200)); none is VI-priced
	address internal constant GILD = 0xA6C3b8Dcb7C31132Dcef64eF099f68B731db1e73;
	address internal constant GILD_POOL = 0x85DF35277A271F8217380735D8cDa2F604907589; // 0.3%, USDC token0
	address internal constant BONSAI = 0xA0aeBd4Ae5F256B72B7D43f67eD934237Adb1AeE;
	address internal constant BONSAI_POOL = 0x4fe87203b27a105a772f195D3F30dea714d1ECf0; // 1%, USDC token0
	address internal constant X8004 = 0x8004c039F2c7AC2Df4C54836de452161fF248004;
	address internal constant X8004_POOL = 0xDC1BA8D332BFd3D954Ca472eD9e1634c5c9d39F5; // 1%, USDC token1
	address internal constant HTEA = 0xa1A0B2E02B0E6830aD5A4A7211691200945d8919;
	address internal constant HTEA_POOL = 0xAbe1f289107C20081F591BB3972b8289aDd64f6C; // CL200, USDC token0
	// Slipstream-2 getPool(CHECK, USDC, 100), USDC token0 (2026-09-30 scan, cast at block 52014634):
	// 300,558 USDC held, $512 of it within −10% of the price (this adapter, block 52014634)
	address internal constant CHECK = 0x9126236476eFBA9Ad8aB77855c60eB5BF37586Eb;
	address internal constant CHECK_POOL = 0x3c4384F3664B37A3Cb5A5cB3452B4B4A3Aa1256f;
	/// @dev floor((1 − √0.9) · 1e6): the band floor is minLiquidityUsd × this / 1e6 (Ruling 23)
	uint256 internal constant BAND_QUOTE_PPM = 51_316;

	bool internal forked;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		uint256 blockNumber = vm.envOr('BASE_FORK_BLOCK', uint256(0));
		if (blockNumber > 0) vm.createSelectFork(rpc, blockNumber);
		else vm.createSelectFork(rpc);
		forked = true;
	}

	function _pair(address pool, address asset, address feed, uint32 hb)
		internal
		returns (TwapAggregatorAdapter v1, TwapAggregatorAdapterV2 v2)
	{
		v1 = new TwapAggregatorAdapter(IConcentratedPoolOracle(pool), asset, AggregatorV3Interface(feed), 30 minutes, 50_000, 500, hb, 'v1');
		v2 = new TwapAggregatorAdapterV2(IConcentratedPoolOracle(pool), asset, AggregatorV3Interface(feed), 30 minutes, 50_000, 500, hb, 'v2');
	}

	function _v2(address pool, address asset, address feed, uint32 hb, uint256 minLiquidityUsd)
		internal
		returns (TwapAggregatorAdapterV2)
	{
		return new TwapAggregatorAdapterV2(
			IConcentratedPoolOracle(pool), asset, AggregatorV3Interface(feed), 30 minutes, minLiquidityUsd, 500, hb, 'v2'
		);
	}

	function test_fork_oneSidedPoolIsShallow() public {
		vm.skip(!forked);
		(TwapAggregatorAdapter v1, TwapAggregatorAdapterV2 v2) = _pair(LUMIA_POOL, LUMIA, ETH_USD, 3600);
		_assertMatchesOldFormula(v1, v2, ETH_USD);
		assertGt(v1.poolDepthUsd(), 1_000_000e18, 'v1 counts the self-priced asset side');
		assertLt(v2.poolDepthUsd(), 10_000e18, 'v2 counts only the WETH side');
		assertGt(v2.poolDepthUsd(), 1_000e18, 'the real WETH side still counts');
		assertTrue(v2.isBelowFloor());
	}

	function test_fork_twoSidedPoolKeepsDepth() public {
		vm.skip(!forked);
		(TwapAggregatorAdapter v1, TwapAggregatorAdapterV2 v2) = _pair(VIRTUAL_POOL, VIRTUAL, USDC_USD, 90_000);
		assertGt(v2.poolDepthUsd(), 50_000e18, 'real USDC bids within 10%');
		assertFalse(v2.isBelowFloor());
		(, int256 answer,,,) = v2.latestRoundData();
		assertGt(answer, 0);
		_assertMatchesOldFormula(v1, v2, USDC_USD);
	}

	function test_fork_quoteSideNeverExceedsTwoSided() public {
		vm.skip(!forked);
		(TwapAggregatorAdapter v1, TwapAggregatorAdapterV2 v2) = _pair(VIRTUAL_POOL, VIRTUAL, USDC_USD, 90_000);
		assertLt(v2.poolDepthUsd(), v1.poolDepthUsd(), 'the VIRTUAL side is not counted');
		_assertMatchesOldFormula(v1, v2, USDC_USD);
	}

	/// @notice asset = token1 (LUMIA; WETH is token0): a WETH-only position above spot.
	function test_fork_quotePositionMovesDepth_assetToken1() public {
		vm.skip(!forked);
		(TwapAggregatorAdapter v1, TwapAggregatorAdapterV2 v2) = _pair(LUMIA_POOL, LUMIA, ETH_USD, 3600);
		assertFalse(v2.assetIsToken0());
		_assertMatchesOldFormula(v1, v2, ETH_USD);
		_assertDepthTracksQuotePosition(v2, ETH_USD, 1 ether);
	}

	/// @notice asset = token0 (VIRTUAL; USDC is token1): a USDC-only position below spot.
	function test_fork_quotePositionMovesDepth_assetToken0() public {
		vm.skip(!forked);
		(TwapAggregatorAdapter v1, TwapAggregatorAdapterV2 v2) = _pair(VIRTUAL_POOL, VIRTUAL, USDC_USD, 90_000);
		assertTrue(v2.assetIsToken0());
		_assertMatchesOldFormula(v1, v2, USDC_USD);
		_assertDepthTracksQuotePosition(v2, USDC_USD, 10_000e6);
	}

	// ─── quote reserve floor ─────────────────────────────────────────────────────

	/// @notice VIRTUAL/USDC 0.3%: the reserve is the pool's USDC balance × the USDC feed, to the
	///         wei, read through ITwapPriceAdapter; it clears the $25k floor.
	function test_fork_quoteReserveIsQuoteBalanceTimesFeed() public {
		vm.skip(!forked);
		ITwapPriceAdapter a = _v2(VIRTUAL_POOL, VIRTUAL, USDC_USD, 90_000, MIN_QUOTE_RESERVE_USD);
		assertEq(a.quoteAsset(), USDC);
		uint256 expected = Math.mulDiv(IERC20(USDC).balanceOf(VIRTUAL_POOL), _quoteUsd18(USDC_USD), 1e6);
		uint256 reserve = a.quoteReserveUsd();
		emit log_named_decimal_uint('VIRTUAL pool USDC reserve (USD)', reserve, 18);
		emit log_named_decimal_uint('VIRTUAL pool band depth (USD)  ', a.poolDepthUsd(), 18);
		assertEq(reserve, expected, 'USDC.balanceOf(pool) x the feed, exactly');
		assertGe(reserve, MIN_QUOTE_RESERVE_USD * 1e18);
		assertFalse(a.isBelowFloor());
	}

	/// @notice LUMIA's one-sided pool holds ~$2.6k of real WETH: under the $25k floor.
	function test_fork_oneSidedPoolReserveUnderFloor() public {
		vm.skip(!forked);
		TwapAggregatorAdapterV2 v2 = _v2(LUMIA_POOL, LUMIA, ETH_USD, 3600, MIN_QUOTE_RESERVE_USD);
		assertEq(v2.quoteAsset(), WETH);
		uint256 reserve = v2.quoteReserveUsd();
		emit log_named_decimal_uint('LUMIA pool WETH reserve (USD)  ', reserve, 18);
		emit log_named_decimal_uint('LUMIA pool band depth (USD)    ', v2.poolDepthUsd(), 18);
		assertEq(reserve, Math.mulDiv(IERC20(WETH).balanceOf(LUMIA_POOL), _quoteUsd18(ETH_USD), 1e18));
		assertLt(reserve, MIN_QUOTE_RESERVE_USD * 1e18, 'under the floor');
		assertGt(reserve, 1_000e18, 'the real WETH still counts');
		assertTrue(v2.isBelowFloor());
	}

	/// @notice isBelowFloor()'s reserve part is exactly quoteReserveUsd() < minLiquidityUsd·1e18: a
	///         floor at the reserve's whole dollars reads over, one dollar more reads under. VIRTUAL's
	///         band depth sits under that floor's NUMBER, but over its band floor (5.13% of it), so a
	///         band-depth floor at the reserve's number would read under at both.
	function test_fork_isBelowFloorIsTheReserveFloor() public {
		vm.skip(!forked);
		uint256 whole = _v2(VIRTUAL_POOL, VIRTUAL, USDC_USD, 90_000, 1).quoteReserveUsd() / 1e18;
		TwapAggregatorAdapterV2 atReserve = _v2(VIRTUAL_POOL, VIRTUAL, USDC_USD, 90_000, whole);
		TwapAggregatorAdapterV2 overReserve = _v2(VIRTUAL_POOL, VIRTUAL, USDC_USD, 90_000, whole + 1);
		assertLt(atReserve.poolDepthUsd(), whole * 1e18, 'the band reads under this floor');
		assertGe(atReserve.poolDepthUsd(), atReserve.minBandDepthUsd() * 1e18, 'and over its band floor');
		assertFalse(atReserve.isBelowFloor(), 'reserve >= floor');
		assertTrue(overReserve.isBelowFloor(), 'reserve < floor + $1');
		_assertTwoPartFloor(atReserve);
		_assertTwoPartFloor(overReserve);

		// LUMIA, on the registry's floor
		TwapAggregatorAdapterV2 lumia = _v2(LUMIA_POOL, LUMIA, ETH_USD, 3600, MIN_QUOTE_RESERVE_USD);
		_assertTwoPartFloor(lumia);
		assertTrue(lumia.isBelowFloor());
	}

	/// @dev isBelowFloor() = reserve < minLiquidityUsd·1e18 || band < minBandDepthUsd·1e18, with the
	///      band floor derived from the reserve floor (1,282 for 25,000).
	function _assertTwoPartFloor(TwapAggregatorAdapterV2 a) internal view {
		assertEq(a.minBandDepthUsd(), a.minLiquidityUsd() * BAND_QUOTE_PPM / 1e6, 'band floor = reserve floor x PPM');
		assertEq(
			a.isBelowFloor(),
			a.quoteReserveUsd() < a.minLiquidityUsd() * 1e18 || a.poolDepthUsd() < a.minBandDepthUsd() * 1e18
		);
	}

	/// @notice Ruling 23: isBelowFloor() is two-part — the quote reserve under minLiquidityUsd OR the
	///         band under minLiquidityUsd × BAND_QUOTE_PPM / 1e6 (what a full-range pool holding the
	///         reserve floor has within −10%). CHECK's pool holds ~$300k of USDC but ~$512 within
	///         −10%: under the registry's $25k floor (band floor $1,282) it reads under. The band floor
	///         follows minLiquidityUsd exactly: at the largest floor whose band floor is still ≤ the
	///         band it reads over, one band-floor dollar more and it reads under — far below the
	///         reserve both times.
	function test_fork_isBelowFloorNeedsTheBand() public {
		vm.skip(!forked);
		TwapAggregatorAdapterV2 a = _v2(CHECK_POOL, CHECK, USDC_USD, 90_000, MIN_QUOTE_RESERVE_USD);
		assertFalse(a.assetIsToken0());
		uint256 reserve = a.quoteReserveUsd();
		uint256 band = a.poolDepthUsd();
		emit log_named_decimal_uint('CHECK pool USDC reserve (USD)  ', reserve, 18);
		emit log_named_decimal_uint('CHECK pool band depth (USD)    ', band, 18);
		assertEq(reserve, Math.mulDiv(IERC20(USDC).balanceOf(CHECK_POOL), _quoteUsd18(USDC_USD), 1e6));
		assertGe(reserve, MIN_QUOTE_RESERVE_USD * 1e18, 'the reserve holds the floor');
		assertLt(band, (MIN_QUOTE_RESERVE_USD * BAND_QUOTE_PPM / 1e6) * 1e18, 'the band does not');
		assertTrue(a.isBelowFloor(), 'reserve over, band under: under the floor');
		assertEq(a.minBandDepthUsd(), 1_282, "the registry's band floor");
		_assertTwoPartFloor(a);

		// the band floor is minLiquidityUsd's: the largest floor whose band floor (whole USD) is ≤ the band ...
		uint256 bandWhole = band / 1e18;
		uint256 over = ((bandWhole + 1) * 1e6 - 1) / BAND_QUOTE_PPM; // over × PPM < (bandWhole + 1) × 1e6 ≤ (over + 1) × PPM
		TwapAggregatorAdapterV2 atBand = _v2(CHECK_POOL, CHECK, USDC_USD, 90_000, over);
		assertLe(atBand.minBandDepthUsd(), bandWhole);
		assertFalse(atBand.isBelowFloor(), 'band floor <= the band: over');
		// ... and one more dollar of floor lifts the band floor past it
		TwapAggregatorAdapterV2 pastBand = _v2(CHECK_POOL, CHECK, USDC_USD, 90_000, over + 1);
		assertGt(pastBand.minBandDepthUsd() * 1e18, band);
		assertGe(reserve, (over + 1) * 1e18, 'the reserve holds that floor too');
		assertTrue(pastBand.isBelowFloor(), 'band floor > the band: under');
	}

	/// @notice No reserve reading from a pool that can't serve the window: a year-long window
	///         outruns VIRTUAL's observations, so quoteReserveUsd() and isBelowFloor() revert.
	function test_fork_quoteReserveRevertsWhenWindowUnserved() public {
		vm.skip(!forked);
		TwapAggregatorAdapterV2 v2 = new TwapAggregatorAdapterV2(
			IConcentratedPoolOracle(VIRTUAL_POOL), VIRTUAL, AggregatorV3Interface(USDC_USD), 365 days, 25_000, 500, 90_000, 'v2'
		);
		vm.expectRevert(TwapAggregatorAdapterV2.ObservationWindowUnavailable.selector);
		v2.quoteReserveUsd();
		vm.expectRevert(TwapAggregatorAdapterV2.ObservationWindowUnavailable.selector);
		v2.isBelowFloor();
	}

	// ─── price precision (Ruling 19) ─────────────────────────────────────────────

	/// @notice Both existing pools, both orientations: v2's single-rounded price stays within one
	///         old rounding unit of v1's (WETH-quoted LUMIA: unchanged to ~1e-15 USD) and within 1e-6
	///         of the independent full-precision reference.
	function test_fork_priceMatchesOldFormulaAndReference() public {
		vm.skip(!forked);
		(TwapAggregatorAdapter lumiaV1, TwapAggregatorAdapterV2 lumiaV2) = _pair(LUMIA_POOL, LUMIA, ETH_USD, 3600);
		(TwapAggregatorAdapter virtualV1, TwapAggregatorAdapterV2 virtualV2) = _pair(VIRTUAL_POOL, VIRTUAL, USDC_USD, 90_000);
		(uint256 lumiaPrice,) = _assertMatchesOldFormula(lumiaV1, lumiaV2, ETH_USD);
		(uint256 virtualPrice,) = _assertMatchesOldFormula(virtualV1, virtualV2, USDC_USD);
		assertApproxEqRel(lumiaPrice, _referencePrice(lumiaV2, ETH_USD), 1e12, 'LUMIA within 1e-6 of the reference');
		assertApproxEqRel(virtualPrice, _referencePrice(virtualV2, USDC_USD), 1e12, 'VIRTUAL within 1e-6 of the reference');
	}

	/// @notice $GILD/USDC 0.3% (asset = token1, sqrtP ≤ 2^128), ~$0.0000007: the old formula floored
	///         to zero raw USDC units (v1 reverts PriceRoundsToZero); v2 prices it.
	function test_fork_subCentUsdc_gild() public {
		vm.skip(!forked);
		_assertSubCentPricedInFull(GILD_POOL, GILD, false, false);
	}

	/// @notice BONSAICOIN/USDC 1% (asset = token1, sqrtP > 2^128), ~$0.00000001.
	function test_fork_subCentUsdc_bonsai() public {
		vm.skip(!forked);
		_assertSubCentPricedInFull(BONSAI_POOL, BONSAI, false, true);
	}

	/// @notice X8004/USDC 1% (asset = token0), ~$0.00001: the old formula read ~4% low.
	function test_fork_subCentUsdc_x8004() public {
		vm.skip(!forked);
		_assertSubCentPricedInFull(X8004_POOL, X8004, true, false);
	}

	/// @notice hTEA/USDC Slipstream CL200 (asset = token1), ~$0.00004.
	function test_fork_subCentUsdc_htea() public {
		vm.skip(!forked);
		_assertSubCentPricedInFull(HTEA_POOL, HTEA, false, false);
	}

	function _assertSubCentPricedInFull(address pool, address asset, bool assetIsToken0, bool sqrtAbove128) internal {
		(TwapAggregatorAdapter v1, TwapAggregatorAdapterV2 v2) = _pair(pool, asset, USDC_USD, 90_000);
		assertEq(v2.quoteAsset(), USDC);
		assertEq(v2.assetIsToken0(), assetIsToken0);
		(int24 meanTick,) = v2.consult();
		assertEq(TickMath.getSqrtRatioAtTick(meanTick) > type(uint128).max, sqrtAbove128, 'sqrtP branch');
		(uint256 price, uint256 old) = _assertMatchesOldFormula(v1, v2, USDC_USD);
		uint256 expected = _referencePrice(v2, USDC_USD);
		emit log_named_decimal_uint('reference price (USD)  ', expected, 18);
		emit log_named_decimal_uint('old / new              ', Math.mulDiv(old, 1e18, price), 18);
		assertLt(price, 0.0001e18, 'below $0.0001');
		assertApproxEqRel(price, expected, 1e12, 'within 1e-6 of the full-precision reference');
	}

	/// @dev Equality guard (Ruling 19): v1 still runs the old formula (quote floored to whole raw
	///      units per whole asset, then x the feed). floor(Q) <= Q < floor(Q) + 1, so v2's price is
	///      never below v1's and exceeds it by at most the USD of one raw quote unit (+1 wei). Where
	///      the old quote floors to zero, v1 reverts PriceRoundsToZero (old = 0) and v2 still prices.
	function _assertMatchesOldFormula(TwapAggregatorAdapter v1, TwapAggregatorAdapterV2 v2, address feed)
		internal
		returns (uint256 price, uint256 old)
	{
		(, int256 answer,,,) = v2.latestRoundData();
		price = SafeCast.toUint256(answer);
		try v1.latestRoundData() returns (uint80, int256 oldAnswer, uint256, uint256, uint80) {
			old = SafeCast.toUint256(oldAnswer);
		} catch (bytes memory reason) {
			assertEq(bytes4(reason), TwapAggregatorAdapter.PriceRoundsToZero.selector, 'v1 fails only by rounding to zero');
		}
		uint256 unit = _quoteUsd18(feed) / 10 ** IERC20Metadata(v2.quoteAsset()).decimals();
		emit log_named_decimal_uint('v2 price (USD)         ', price, 18);
		emit log_named_decimal_uint('v1 old-formula (USD)   ', old, 18);
		assertGe(price, old, 'never below the truncated price');
		assertLe(price - old, unit + 1, 'within one old rounding unit');
	}

	/// @dev Independent full-precision reference: Uniswap OracleLibrary.getQuoteAtTick for 10^38 raw
	///      asset units (10^(38 - ad) whole assets), so its own floor costs < 1e-18 relative on these
	///      pools, then per whole asset and x the feed.
	function _referencePrice(TwapAggregatorAdapterV2 v2, address feed) internal view returns (uint256) {
		(int24 meanTick,) = v2.consult();
		uint256 assetDecimals = IERC20Metadata(v2.asset()).decimals();
		uint256 quoteOut = _getQuoteAtTick(meanTick, uint128(1e38), v2.assetIsToken0());
		uint256 denominator = 10 ** (38 - assetDecimals) * 10 ** IERC20Metadata(v2.quoteAsset()).decimals();
		return Math.mulDiv(quoteOut, _quoteUsd18(feed), denominator);
	}

	/// @dev Uniswap v3-periphery OracleLibrary.getQuoteAtTick.
	function _getQuoteAtTick(int24 tick, uint128 baseAmount, bool baseIsToken0) internal pure returns (uint256) {
		uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
		if (sqrtRatioX96 <= type(uint128).max) {
			uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
			return baseIsToken0 ? Math.mulDiv(ratioX192, baseAmount, 1 << 192) : Math.mulDiv(1 << 192, baseAmount, ratioX192);
		}
		uint256 ratioX128 = Math.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
		return baseIsToken0 ? Math.mulDiv(ratioX128, baseAmount, 1 << 128) : Math.mulDiv(1 << 128, baseAmount, ratioX128);
	}

	/// @dev Mints `quoteIn` of the quote token as an out-of-range position inside the band, checks
	///      the depth rises by its USD value, burns it, and checks the depth returns exactly. The
	///      position is out of range, so the TWAP and harmonic-mean legs cannot move; the current
	///      band leg must bind before and after, or the delta would not show.
	function _assertDepthTracksQuotePosition(TwapAggregatorAdapterV2 v2, address feed, uint256 quoteIn) internal {
		uint256 before = v2.poolDepthUsd();
		assertEq(before, v2.spotBandDepthUsd(), 'current band leg binds before');

		(uint256 tokenId, uint128 liquidity, uint256 quotePaid) = _mintQuoteOnly(v2, quoteIn);
		uint256 quoteUsd18 = _quoteUsd18(feed);
		uint256 unit = 10 ** IERC20Metadata(v2.quoteAsset()).decimals();
		uint256 positionUsd = Math.mulDiv(quotePaid, quoteUsd18, unit);
		uint256 during = v2.poolDepthUsd();
		assertEq(during, v2.spotBandDepthUsd(), 'current band leg binds during');

		emit log_named_decimal_uint('depth before      ', before, 18);
		emit log_named_decimal_uint('position USD      ', positionUsd, 18);
		emit log_named_decimal_uint('depth delta       ', during - before, 18);
		assertApproxEqAbs(during - before, positionUsd, Math.mulDiv(ROUNDING_WEI, quoteUsd18, unit) + 1);

		_burn(tokenId, liquidity);
		emit log_named_decimal_uint('depth after burn  ', v2.poolDepthUsd(), 18);
		assertEq(v2.poolDepthUsd(), before, 'depth returns after burn');
	}

	/// @dev Ten tick spacings just past spot on the quote side: above spot holds only token0,
	///      below only token1. With spacing 60 the range stays within +660 / −660 ticks of spot,
	///      inside the +953 / −1054 band.
	function _quoteOnlyRange(TwapAggregatorAdapterV2 v2) internal view returns (int24 lo, int24 hi) {
		address pool = address(v2.pool());
		(, int24 spot,,,,,) = IUniswapV3PoolState(pool).slot0();
		int24 spacing = IConcentratedPoolOracle(pool).tickSpacing();
		int24 c = spot / spacing;
		if (spot < 0 && spot % spacing != 0) c--;
		if (v2.assetIsToken0()) {
			hi = c * spacing;
			lo = hi - 10 * spacing;
		} else {
			lo = (c + 1) * spacing;
			hi = lo + 10 * spacing;
		}
	}

	function _mintQuoteOnly(TwapAggregatorAdapterV2 v2, uint256 quoteIn)
		internal
		returns (uint256 tokenId, uint128 liquidity, uint256 quotePaid)
	{
		(int24 lo, int24 hi) = _quoteOnlyRange(v2);
		bool quoteIsToken0 = !v2.assetIsToken0();
		deal(v2.quoteAsset(), address(this), quoteIn);
		IERC20(v2.quoteAsset()).approve(NPM, quoteIn);
		uint256 paid0;
		uint256 paid1;
		(tokenId, liquidity, paid0, paid1) = IUniswapV3NonfungiblePositionManager(NPM).mint(
			IUniswapV3NonfungiblePositionManager.MintParams({
				token0: quoteIsToken0 ? v2.quoteAsset() : v2.asset(),
				token1: quoteIsToken0 ? v2.asset() : v2.quoteAsset(),
				fee: IUniswapV3PoolState(address(v2.pool())).fee(),
				tickLower: lo,
				tickUpper: hi,
				amount0Desired: quoteIsToken0 ? quoteIn : 0,
				amount1Desired: quoteIsToken0 ? 0 : quoteIn,
				amount0Min: 0,
				amount1Min: 0,
				recipient: address(this),
				deadline: block.timestamp
			})
		);
		assertEq(quoteIsToken0 ? paid1 : paid0, 0, 'quote-only position');
		quotePaid = quoteIsToken0 ? paid0 : paid1;
	}

	function _burn(uint256 tokenId, uint128 liquidity) internal {
		IUniswapV3NonfungiblePositionManager npm = IUniswapV3NonfungiblePositionManager(NPM);
		npm.decreaseLiquidity(
			IUniswapV3NonfungiblePositionManager.DecreaseLiquidityParams({
				tokenId: tokenId, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
			})
		);
		npm.collect(
			IUniswapV3NonfungiblePositionManager.CollectParams({
				tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
			})
		);
		npm.burn(tokenId);
	}

	function _quoteUsd18(address feed) internal view returns (uint256) {
		(, int256 answer,,,) = AggregatorV3Interface(feed).latestRoundData();
		return SafeCast.toUint256(answer) * 10 ** (18 - AggregatorV3Interface(feed).decimals());
	}
}
