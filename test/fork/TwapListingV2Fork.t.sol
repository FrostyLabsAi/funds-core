// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {IPolicy} from '../../src/interfaces/IPolicy.sol';
import {AggregatorV3Interface} from '../../src/interfaces/AggregatorV3Interface.sol';
import {IUniswapV3SwapRouter} from '../../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {ISlipstreamSwapRouter} from '../../src/interfaces/external/ISlipstreamSwapRouter.sol';
import {IUniswapV3NonfungiblePositionManager} from
	'../../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {TickMath} from '../../src/libraries/TickMath.sol';
import {TwapAggregatorAdapter, IConcentratedPoolOracle} from '../../src/pricing/TwapAggregatorAdapter.sol';
import {IUniswapV3PoolFactory, ISlipstreamPoolFactory} from '../../src/pricing/TwapListingRegistry.sol';
import {TwapAggregatorAdapterV2} from '../../src/pricing/TwapAggregatorAdapterV2.sol';
import {
	TwapListingRegistryV2, IUniswapV2Factory, IAerodromeBasicFactory
} from '../../src/pricing/TwapListingRegistryV2.sol';
import {PriceListingModule} from '../../src/pricing/PriceListingModule.sol';
import {TwapExposurePolicyV2} from '../../src/policies/TwapExposurePolicyV2.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {TwapListingV2} from '../../script/mainnet/TwapListingV2.sol';
import {ITwapPriceAdapter} from '../../src/interfaces/ITwapPriceAdapter.sol';
import {UniswapV2TwapAdapter} from '../../src/pricing/UniswapV2TwapAdapter.sol';
import {UniswapV2ObservationRecorder, IUniswapV2Pair} from '../../src/pricing/UniswapV2ObservationRecorder.sol';
import {AerodromeBasicTwapAdapter, IAerodromeBasicPool} from '../../src/pricing/AerodromeBasicTwapAdapter.sol';
import {IUniswapV2Router02} from '../../src/interfaces/external/IUniswapV2Router02.sol';
import {IAerodromeRouter} from '../../src/interfaces/external/IAerodromeRouter.sol';

/// @notice The Uniswap v3 pool's fee (the NPM keys pools by it).
interface IUniswapV3PoolFee {
	function fee() external view returns (uint24);
}

/// @notice Router02 0x4752…aD24's 0.3%-fee x·y=k quote (verified Basescan source; as in
///         test/fork/V2SwapAdaptersFork.t.sol).
interface IUniswapV2RouterQuote {
	function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) external pure returns (uint256);
}

/// @notice B18 (0xA0c8…25Cb, verified source; test/fork/V2SwapAdaptersFork.t.sol): transfers to or
///         from a listed pair pay buyFeeRate / sellFeeRate of RATE_UNIT.
interface IB18Tax {
	function buyFeeRate() external view returns (uint256);
	function sellFeeRate() external view returns (uint256);
	function RATE_UNIT() external view returns (uint256);
	function swapPairList(address) external view returns (bool);
}

/// @notice The oracle-ring surface a keeper uses on a young pool (Uniswap v3 and Slipstream alike).
interface IOracleRing {
	function factory() external view returns (address);
	function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
	function observations(uint256 index)
		external
		view
		returns (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized);
}

/// @notice THE TWAP LISTING V2 ACCEPTANCE TEST, on a Base fork against the LIVE genesis: setUp runs
///         TwapListingV2.deploy — the exact wiring DeployTwapListingV2 broadcasts — as the real
///         genesis deployer (read from deployments/base-mainnet.json) with a test keeper, then every
///         test drives real pools, real routers, the real Uniswap NonfungiblePositionManager and
///         real Chainlink feeds. No mocks; `deal` only funds balances.
///         The rule split (v2b): the QUOTE RESERVE (USDC/WETH/cbBTC the pool holds × its feed,
///         ≥ $25k) gates listing and the delist clock; the ±10% quote-side BAND sizes the caps, the
///         recorded depth and the repoint margin. Under-floor scenarios push RESERVES under $25k with
///         real sells (selling the asset pays quote out of the pool).
///         F2 / Ruling 23: the floor is two-part — the band must also hold MIN_BAND_DEPTH_USD
///         ($1,282, what a full-range pool at the $25k reserve floor has within −10%). A real pool
///         with a big balance and no bids (CHECK) is refused, and a real rug that removes the
///         liquidity without collecting it (VIRTUAL's quiet 1% pool) starts the clock.
///         Proven here: keepers list real tokens (strangers and governance can't); one-sided junk
///         is refused on its reserve; WETH-, cbBTC- and Slipstream-3 listings price and trade;
///         Uniswap v2 (after the keeper's recorder snapshot) and Aerodrome basic listings price and
///         the live fund trades them through the new swap adapters; an Aerodrome sAMM pool is never
///         listed; a thin band lists and caps a fund at 10% of it; repoints need a 25% deeper band
///         unless the current reserve is under the floor; flash (same-transaction) liquidity can
///         neither clear a delist clock nor lift a fund's cap; governance keeps every VI admin
///         call; caps bind on quote-side depth; the lens pages and flags real listings on all three
///         pool kinds; a transfer-taxed token lists on-chain (refusing it is keeper policy).
///         Deviations from the task brief, each forced by live state (measured with this
///         registry's own adapter parameters; block 52008523 for the v2 constants, 52014634 for the
///         v2b ones):
///         - TRX's Slipstream-3 ts100 USDC pool 0xf041…7Cb5 holds $5.67M USDC but $36 of it within
///           ±10%; USDL (Slipstream-3 USDC ts50, $345,107; all three of its pools are on Slip3) is used.
///         - The WETH-quoted example stays LCAP: under v2 BRETT's thin band ($32k) could not list.
///           Under the rule split it lists on its reserve, which test_fork_thinBandListsWithTinyCap shows.
///         - Under-floor repoint: MORPHO can no longer show it. Selling into its WETH 0.3% pool until
///           the reserve crosses $25k leaves ~$4k in band, while its only other qualifying pools
///           (USDC 1% $55k band, Slipstream WETH ts200 $68k) are far over 1.25× that, and its
///           Aerodrome / Uniswap v2 pools are empty. LCAP is used: its Slipstream USDC ts200 pool
///           keeps $12.3k in band when its reserve crosses $25k, and its Aerodrome vAMM USDC pool
///           ($101k reserve, $5.2k band) qualifies without being 25% deeper.
///         - VIRTUAL's USDC 0.3% pool keeps ~$24.8k of USDC that sells can't reach (a 130,000-tick
///           push still leaves $24,822), so it can't be put far under the floor; the dump scenarios
///           sell into VIRTUAL's Slipstream WETH ts200 pool instead (20,000 ticks leave $4,006), and
///           the lens test dumps LCAP's Slipstream WETH pool.
///         Run: BASE_MAINNET_RPC=<url> [BASE_FORK_BLOCK=52014634] forge test --match-path test/fork/TwapListingV2Fork.t.sol -j 1 -vv
contract TwapListingV2ForkTest is Test {
	string internal constant GENESIS_FILE = 'deployments/base-mainnet.json';

	TwapListingRegistryV2.Venue internal constant UNI = TwapListingRegistryV2.Venue.UniswapV3;
	TwapListingRegistryV2.Venue internal constant SLIP = TwapListingRegistryV2.Venue.Slipstream;
	TwapListingRegistryV2.Venue internal constant SLIP2 = TwapListingRegistryV2.Venue.Slipstream2;
	TwapListingRegistryV2.Venue internal constant SLIP3 = TwapListingRegistryV2.Venue.Slipstream3;
	TwapListingRegistryV2.Venue internal constant UNIV2 = TwapListingRegistryV2.Venue.UniswapV2;
	TwapListingRegistryV2.Venue internal constant AERO = TwapListingRegistryV2.Venue.AerodromeBasic;

	// ─── Base mainnet, each read with `cast` at block 52008523 ──────────────────
	address internal constant USDC = FundsMainnet.USDC;
	address internal constant WETH = FundsMainnet.WETH;
	address internal constant CL_USDC_USD = FundsMainnet.CL_USDC_USD; // "USDC / USD", 8 dp
	address internal constant CL_ETH_USD = FundsMainnet.CL_ETH_USD; // "ETH / USD" STANDARD proxy, 8 dp
	address internal constant UNI_ROUTER = FundsMainnet.UNI_SWAP_ROUTER02; // factory() = UNI_FACTORY
	address internal constant UNI_NPM = FundsMainnet.UNI_NPM; // factory() = UNI_FACTORY
	/// @dev The live degen fund: fundOwner() = the genesis deployer, allowRiskyAssets() = true,
	///      tracks only USDC (10 USDC in its vault), PostCallOnIntegration = unrestricted mandate + v1 TWAP policy.
	address internal constant LIVE_FUND = 0x833A506d761A4756AF279ABC24183Db407823dE9;

	// Oracle rings (slot0 observationCardinality / next, raw word 4, cast at block 52008523):
	// VIRTUAL_USDC_3000 600/600, VIRTUAL_WETH_SLIP_200 10000/10000, VIRTUAL_WETH_UNI_500 10000/10000,
	// VIRTUAL_WETH_SLIP_100 900/900, VIRTUAL_WETH_SLIP2_50 360/360, LCAP_WETH_SLIP_200 360/360,
	// LCAP_USDC_SLIP_200 360/360, VVV_USDC_3000 360/360, USDT_USDC_UNI_100 1000/1000; at block 52014634:
	// BRETT_WETH_SLIP_200 5000, ZEN_CBBTC_SLIP_200 500 — all over MIN_OBSERVATION_CARDINALITY (300).
	// LUMIA_POOL 1/1 and USDL_USDC_SLIP3_50 1/1: listed only after `_prepareOracle`, as the keeper would.
	uint16 internal constant ORACLE_RING = 300;

	/// @dev symbol "VIRTUAL", 18 dp, unpriced in the live VI. Its pools vs USDC/WETH at listable
	///      spacing, quote-side ±10% depth by this registry's adapter:
	address internal constant VIRTUAL = 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b;
	/// @dev Uniswap getPool(VIRTUAL, USDC, 3000): $237,124 — the deepest; VIRTUAL is token0
	address internal constant VIRTUAL_USDC_3000 = 0x529d2863a1521d0b57db028168fdE2E97120017C;
	/// @dev Slipstream getPool(VIRTUAL, WETH, 200): $129,163 — the second deepest (1.84× under the deepest)
	address internal constant VIRTUAL_WETH_SLIP_200 = 0xC200F21EfE67c7F41B81A854c26F9cdA80593065;
	/// @dev Uniswap getPool(VIRTUAL, WETH, 500), spacing 10: $92,321
	address internal constant VIRTUAL_WETH_UNI_500 = 0x9c087Eb773291e50CF6c6a90ef0F4500e349B903;
	/// @dev Slipstream getPool(VIRTUAL, WETH, 100): $74,744
	address internal constant VIRTUAL_WETH_SLIP_100 = 0x3f0296BF652e19bca772EC3dF08b32732F93014A;
	/// @dev Slipstream-2 getPool(VIRTUAL, WETH, 50): $64,543 (Slip1 ts100 is 1.16× deeper: deeper, short of 1.25×)
	address internal constant VIRTUAL_WETH_SLIP2_50 = 0x9520E1a3BFd86DA6c1E9e5Ee4B9c2F11c413358F;
	/// @dev "VIRTUAL / USD", 8 dp, 24h heartbeat (Chainlink Base directory); answered $0.7938 vs the TWAP's $0.7956
	address internal constant CL_VIRTUAL_USD = 0xEaf310161c9eF7c813A14f8FEF6Fb271434019F7;

	/// @dev symbol "LUMIA"; Uniswap getPool(LUMIA, WETH, 3000) — 0.98 WETH against 150M LUMIA
	address internal constant LUMIA = 0x550161Ae735DebeE90Ba117025db0E83131bf9A6;
	address internal constant LUMIA_POOL = 0x36523a7A21139e0D85D1d3BA69E9F8Aa9A5bD185;

	/// @dev name "CF Large Cap Index", symbol "LCAP", unpriced in the live VI
	address internal constant LCAP = 0x4dA9A0f397dB1397902070f93a4D6ddBC0E0E6e8;
	/// @dev Slipstream getPool(LCAP, WETH, 200): $159,682 of WETH within ±10%; LCAP is token1. At
	///      block 52014634: $305,346 WETH reserve, $158,986 band; UNDER_FLOOR_TICKS of real sells leave $3.
	address internal constant LCAP_WETH_SLIP_200 = 0x3a88eF38879EFb900c2D7b6199d21C139cEf5Fa7;
	/// @dev Slipstream getPool(LCAP, USDC, 200): an independent market (spot $7.368 vs the WETH pool's
	///      $7.379); LCAP is token0. At block 52014634: $98,485 USDC reserve, $44,913 band; real sells
	///      of 2,023 ticks take the reserve just under the floor ($24,985) with $12,346 still in band.
	address internal constant LCAP_USDC_SLIP_200 = 0xC8C15670050541255f9b797C008047682524861F;
	/// @dev Aerodrome basic getPool(LCAP, USDC, false), volatile, at block 52014634: $100,962 USDC
	///      reserve, $5,181 band (5.13% of it) — qualifies, yet thinner than LCAP_USDC_SLIP_200's band
	///      even after that pool slips under the floor
	address internal constant LCAP_USDC_AERO = 0x48D1036b0308884c163cde60AD5fBf87112Ac52f;

	/// @dev name "USDL Stablecoin", 18 dp, unpriced; its only pools are on Slipstream-3 (USDC ts50, WETH ts10, WETH ts500)
	address internal constant USDL = 0x78E8CF657742e10eaC8F64007615AA741fC76414;
	/// @dev Slipstream-3 getPool(USDL, USDC, 50): $345,107 of USDC within ±10%
	address internal constant USDL_USDC_SLIP3_50 = 0xf0d64B4fe5D2619a3aDBE2734AD0584FC54bed88;

	/// @dev symbol "LINK", 18 dp, unpriced; "LINK / USD", 8 dp, 24h heartbeat
	address internal constant LINK = 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196;
	address internal constant CL_LINK_USD = 0x17CAb8FE31E32f08326e5E27412894e49B0f9D65;

	/// @dev symbol "USDT", unpriced; Uniswap getPool(USDT, USDC, 100) has tickSpacing() = 1
	address internal constant USDT = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;
	address internal constant USDT_USDC_UNI_100 = 0xD56da2B74bA826f19015E6B7Dd9Dae1903E85DA1;

	/// @dev Coinbase NVDA stock token: the live VI prices it through Chainlink 0x0468…8513 (heartbeat 432000)
	address internal constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C;
	address internal constant CL_NVDA = 0x04689a41629776563E6822F76f2e57D148d28513;

	/// @dev name "Venice Token", symbol "VVV", 18 dp, unpriced in the live VI
	address internal constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;
	/// @dev Uniswap getPool(VVV, USDC, 3000): $104,538 of USDC within ±10% (v1 two-sided: $235,027);
	///      USDC is token0. Far from the $250k large-pool line, so the 10% cap applies at any nearby
	///      block (VIRTUAL's USDC pool sits at the $250k line). At block 52014634: $285,310 USDC
	///      reserve, $102,358 band; real sells of 8,369 ticks take the reserve just under the floor
	///      ($24,998).
	address internal constant VVV_USDC_3000 = 0x67A11022B7B6ed66f81233F6C8Ed6e48F7826530;

	// ─── v2b: Uniswap v2, Aerodrome basic, cbBTC, taxed (cast + this registry's adapters, block 52014634) ──
	/// @dev symbol "AGNT", 18 dp, unpriced; Uniswap v2 getPair(AGNT, USDC), AGNT token0: $500,857 USDC
	///      reserve (test/UniswapV2TwapAdapterFork.t.sol)
	address internal constant AGNT = 0x7484a9fB40b16c4DFE9195Da399e808aa45E9BB9;
	address internal constant AGNT_USDC_V2 = 0x378551Ab1B395B1E12a49aE3914DD8066860770D;
	/// @dev symbol "AWE", 18 dp, unpriced; Aerodrome basic getPool(AWE, USDC, false), volatile, AWE token0:
	///      $211,473 USDC reserve (test/AerodromeBasicTwapAdapterFork.t.sol)
	address internal constant AWE = 0x1B4617734C43F6159F3a70b7E06d883647512778;
	address internal constant AWE_USDC_AERO = 0xcb7f520d18141E36956fE0b3A6Bc3D4F11245521;
	/// @dev symbol "BRETT", 18 dp, unpriced; Slipstream getPool(BRETT, WETH, 200): $409,694 WETH reserve
	///      but $34,075 within ±10% — a band v2's old $50k band floor refused
	address internal constant BRETT = 0x532f27101965dd16442E59d40670FaF5eBB142E4;
	address internal constant BRETT_WETH_SLIP_200 = 0x4e829F8A5213c42535AB84AA40BD4aDCCE9cBa02;
	/// @dev Uniswap getPool(BRETT, WETH, 10000): 308.9 WETH; the thin-band test buys through it, so the
	///      listed pool's spot (and its TWAP guard) is untouched by the fund's buys
	address internal constant BRETT_WETH_UNI_10000 = 0xBA3F945812a83471d709BCe9C3CA699A19FB46f7;
	/// @dev symbol "crvUSD", 18 dp, unpriced. Aerodrome basic: getPool(crvUSD, USDC, true) is a real sAMM
	///      pool (stable() = true; 19.6 crvUSD / 21.2 USDC); getPool(crvUSD, USDC, false),
	///      getPool(crvUSD, WETH, false) and getPool(crvUSD, WETH, true) are all 0 — its only Aerodrome
	///      pool vs USDC/WETH is stable. (USDe 0x5d3a…ef34 is the same: sAMM USDe/USDC 0x644B…0fE7 only.)
	address internal constant CRVUSD = 0x417Ac0e078398C154EdFadD9Ef675d30Be60Af93;
	address internal constant CRVUSD_USDC_STABLE = 0x7F6095FECb6b67c08F1b8397701d666d71d703e0;
	/// @dev cbBTC (8 dp) and "cbBTC / USD" (8 dp) — the registry's third quote (Ruling 21)
	address internal constant CBBTC = FundsMainnet.CBBTC;
	address internal constant CL_CBBTC_USD = FundsMainnet.CL_CBBTC_USD;
	/// @dev symbol "ZEN", 18 dp, unpriced; Slipstream getPool(ZEN, cbBTC, 200), cbBTC token0: 14.83 cbBTC
	///      ($1,238,789) reserve, $219,349 band (GeckoTerminal's top cbBTC pools, then cast)
	address internal constant ZEN = 0xf43eB8De897Fbc7F2502483B2Bef7Bb9EA179229;
	address internal constant ZEN_CBBTC_SLIP_200 = 0x47f9e291bb766Fc307Ad7BBa4f29f3Eab6A97101;
	/// @dev Slipstream getPool(ZEN, WETH, 100): 706 WETH — ZEN's independent WETH market
	address internal constant ZEN_WETH_SLIP_100 = 0x0392B12a1cEb0cd13af5Ea448CF5586EA609852D;
	/// @dev symbol "EDGE", 18 dp, unpriced; Aerodrome basic getPool(EDGE, cbBTC, false), volatile, cbBTC
	///      token0: 4.147 cbBTC ($346,456) reserve
	address internal constant EDGE = 0xED6E000dEF95780fb89734c07EE2ce9F6dcAf110;
	address internal constant EDGE_CBBTC_AERO = 0x594b83709464A83F37aC77E69DDD447a8A33c0EE;
	/// @dev symbol "B18", 18 dp, unpriced, transfer-TAXED on its pairs (test/fork/V2SwapAdaptersFork.t.sol);
	///      Uniswap v2 getPair(B18, USDC): $625,531 USDC reserve
	address internal constant B18 = 0xA0c8b0C06Ff087d168B79177bab402F8844825Cb;
	address internal constant B18_USDC_V2 = 0x35876a255B24c76a686259943AfCFC455D52Ab53;
	/// @dev Uniswap v2 Router02 and Aerodrome Router: the routers the new swap adapters wrap
	address internal constant UNI_V2_ROUTER = TwapListingV2.UNI_V2_ROUTER;
	address internal constant AERO_ROUTER = TwapListingV2.AERODROME_ROUTER;
	address internal constant AERO_FACTORY = TwapListingV2.AERODROME_POOL_FACTORY;

	// ─── F2 / Ruling 23: the two-part floor (cast, block 52014634) ─────────────────
	/// @dev Uniswap getPool(VIRTUAL, USDC, 10000), spacing 200, VIRTUAL token0: a QUIET pool — 427
	///      USDC and 2,953 VIRTUAL, liquidity 4.15e15, spot tick −278,502 (the 0.3% pool's −278,508),
	///      oracle ring 10 at index 0. A rugger's position becomes most of its liquidity near spot.
	address internal constant VIRTUAL_USDC_10000 = 0xa9991eEaCa10aF662633913106fE4c18EC06E1F8;
	/// @dev symbol "CHECK", 18 dp, unpriced in the live VI; Slipstream-2 getPool(CHECK, USDC, 100),
	///      USDC token0, oracle ring 2000: it holds 300,558 USDC ($300,545), but $512 of it within
	///      −10% of the price (the registry's adapter; the 2026-09-30 scan read $476): the rest sits
	///      far below
	address internal constant CHECK = 0x9126236476eFBA9Ad8aB77855c60eB5BF37586Eb;
	address internal constant CHECK_USDC_SLIP2_100 = 0x3c4384F3664B37A3Cb5A5cB3452B4B4A3Aa1256f;
	/// @dev The USDC the rugger's position puts in VIRTUAL_USDC_10000.
	uint256 internal constant RUG_USDC = 40_000e6;

	// ─── sizing ─────────────────────────────────────────────────────────────────
	/// @dev Real sells moving spot this many ticks against the asset put a pool's QUOTE RESERVE far
	///      under the floor (block 52014634): VIRTUAL_WETH_SLIP_200 $225,424 → $4,006,
	///      LCAP_WETH_SLIP_200 $305,346 → $3, VVV_USDC_3000 $285,310 → $2,601. (VIRTUAL_USDC_3000 can't
	///      be used: it keeps ~$24.8k of USDC no sell reaches.)
	int24 internal constant UNDER_FLOOR_TICKS = 20_000;
	/// @dev Real sells into a v2-style pool of this many times its asset reserve leave ~1/50 of the
	///      quote reserve: AGNT $500,857 → ~$10k, AWE $211,473 → ~$4k.
	uint256 internal constant V2_DUMP_MULTIPLE = 49;
	/// @dev Quote-only liquidity a flash attacker mints just past spot. It lifts VVV_USDC_3000's
	///      live depth to its window leg's ceiling ($102,358 → $117,224 at block 52014634; more does not add).
	uint256 internal constant JIT_USDC = 200_000e6;
	/// @dev The exposure policy's spec (TwapExposurePolicyV2 natspec), kept literal on purpose.
	uint256 internal constant LARGE_POOL_USD18 = 250_000e18;
	uint256 internal constant SMALL_CAP_BPS = 1_000;
	uint256 internal constant LARGE_CAP_BPS = 5_000;
	uint256 internal constant MARGIN_BPS = 12_500;
	/// @dev The registry's listing and delist-clock floor (MIN_QUOTE_RESERVE_USD × 1e18), kept literal
	///      on purpose; test_fork_thinBandListsWithTinyCap pins it to the registry's constant.
	uint256 internal constant RESERVE_FLOOR_USD18 = 25_000e18;
	/// @dev The floor's second part (MIN_BAND_DEPTH_USD × 1e18): floor(25,000 × 51,316 / 1e6) = 1,282,
	///      what a full-range x·y=k pool holding exactly $25k of quote has within −10%. Kept literal on
	///      purpose; test_fork_ruggedConcentratedPoolStartsClock pins it to the registry's constant.
	uint256 internal constant BAND_FLOOR_USD18 = 1_282e18;
	/// @dev v2's retired band floor ($50k within ±10%): the band has no floor now; what it let through is shown.
	uint256 internal constant OLD_BAND_FLOOR_USD18 = 50_000e18;
	/// @dev Uniswap v2 pairs keep no history: the keeper's recorder snapshot must be a window (30 min) old.
	uint256 internal constant V2_WARP = 31 minutes;

	bool internal forked;
	address internal deployer;
	ValueInterpreter internal vi;
	FundFactory internal factory;
	address internal uniAdapter;
	address internal twapPolicyV1;
	address internal keeper = makeAddr('twapKeeper');
	address internal stranger = makeAddr('stranger');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');
	TwapListingV2.Deployed internal d;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		uint256 blockNumber = vm.envOr('BASE_FORK_BLOCK', uint256(0));
		if (blockNumber > 0) vm.createSelectFork(rpc, blockNumber);
		else vm.createSelectFork(rpc);
		forked = true;

		// the genesis address book DeployTwapListingV2 reads
		string memory genesis = vm.readFile(GENESIS_FILE);
		deployer = vm.parseJsonAddress(genesis, '.deployer');
		vi = ValueInterpreter(vm.parseJsonAddress(genesis, '.valueInterpreter'));
		factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		uniAdapter = vm.parseJsonAddress(genesis, '.uniAdapter');
		twapPolicyV1 = vm.parseJsonAddress(genesis, '.twapPolicy');

		vm.startPrank(deployer);
		d = TwapListingV2.deploy(
			TwapListingV2.Config({
				deployer: deployer, valueInterpreter: vi, factory: factory, twapPolicyV1: twapPolicyV1, keeper: keeper
			})
		);
		vm.stopPrank();
	}

	// ─── listing ─────────────────────────────────────────────────────────────────

	function test_fork_keeperListsRealToken() public {
		vm.skip(!forked);
		// only a keeper lists: not a stranger, not governance (the module's owner), not around the module
		vm.prank(stranger);
		vm.expectRevert(PriceListingModule.NotKeeper.selector);
		d.module.list(VIRTUAL, USDC, UNI, 3000);
		vm.prank(deployer);
		vm.expectRevert(PriceListingModule.NotKeeper.selector);
		d.module.list(VIRTUAL, USDC, UNI, 3000);
		vm.prank(stranger);
		vm.expectRevert(TwapListingRegistryV2.NotLister.selector);
		d.registry.list(VIRTUAL, USDC, UNI, 3000);
		assertFalse(vi.isSupportedAsset(VIRTUAL));

		TwapAggregatorAdapterV2 adapter = _list(VIRTUAL, USDC, UNI, 3000);

		assertTrue(vi.isSupportedAsset(VIRTUAL));
		(address aggregator, uint32 heartbeat,,) = vi.getAssetInfo(VIRTUAL);
		assertEq(aggregator, address(adapter), 'the VI prices through the new adapter');
		assertEq(heartbeat, 3600);
		assertEq(uint8(d.registry.venueOf(VIRTUAL)), uint8(UNI));
		assertEq(_poolOf(VIRTUAL), VIRTUAL_USDC_3000);
		assertTrue(d.registry.isTwapPriced(VIRTUAL));
		assertEq(d.registry.listedCount(), 1);

		// the reserve gated the listing; the band is what it records (Ruling 8)
		uint256 reserve = adapter.quoteReserveUsd();
		assertGe(reserve, RESERVE_FLOOR_USD18, 'the USDC reserve holds the floor');
		uint256 recorded = d.registry.recordedDepthUsd18(VIRTUAL);
		assertGe(recorded, 50_000e18, 'Ruling 8: the listing records its quote-side depth');
		assertEq(recorded, adapter.poolDepthUsd());
		assertLt(recorded, reserve, 'the band, not the reserve');

		uint256 rate = vi.calcUsdRate(VIRTUAL);
		uint256 chainlink = _chainlinkUsd18(CL_VIRTUAL_USD);
		assertGt(rate, 0);
		assertApproxEqRel(rate, chainlink, 0.05e18, 'the TWAP agrees with Chainlink VIRTUAL / USD');
		emit log_named_decimal_uint('VIRTUAL USDC reserve (USD)  ', reserve, 18);
		emit log_named_decimal_uint('VIRTUAL recorded depth (USD)', recorded, 18);
		emit log_named_decimal_uint('VIRTUAL TWAP price (USD)    ', rate, 18);
		emit log_named_decimal_uint('VIRTUAL Chainlink (USD)     ', chainlink, 18);
	}

	function test_fork_oneSidedJunkRefused() public {
		vm.skip(!forked);
		// v1 counted LUMIA's own side, priced by the pool itself: the pool looks deep
		TwapAggregatorAdapter v1 = new TwapAggregatorAdapter(
			IConcentratedPoolOracle(LUMIA_POOL), LUMIA, AggregatorV3Interface(CL_ETH_USD), 30 minutes, 50_000, 500, 3600, 'v1'
		);
		uint256 v1Depth = v1.poolDepthUsd();
		assertGt(v1Depth, 1_000_000e18, 'two-sided depth counts the self-priced asset');

		// as it stands, its single-observation oracle is refused first
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.ObservationCardinalityTooLow.selector, uint16(1)));
		d.module.list(LUMIA, WETH, UNI, 3000);

		// with its oracle ring raised the way the keeper would, its WETH reserve is what refuses it:
		// exactly the WETH the pool holds × ETH / USD, the LUMIA side never counted
		_prepareOracle(LUMIA_POOL);
		bytes memory err = _revertData(keeper, address(d.module), abi.encodeCall(PriceListingModule.list, (LUMIA, WETH, UNI, 3000)));
		assertEq(_selector(err), TwapListingRegistryV2.BelowFloorAtListing.selector);
		uint256 quoteReserve = abi.decode(_args(err), (uint256));
		assertEq(quoteReserve, _usd18(IERC20(WETH).balanceOf(LUMIA_POOL), WETH, CL_ETH_USD), 'the WETH the pool holds');
		assertLt(quoteReserve, RESERVE_FLOOR_USD18, 'the WETH reserve is under the floor');
		assertGt(quoteReserve, 1_000e18, 'the real WETH side still counts');
		assertFalse(vi.isSupportedAsset(LUMIA));
		assertEq(d.registry.listedCount(), 0);
		emit log_named_decimal_uint('LUMIA v1 two-sided depth (USD)', v1Depth, 18);
		emit log_named_decimal_uint('LUMIA WETH reserve (USD)      ', quoteReserve, 18);
	}

	function test_fork_wethQuotedListsAndPrices() public {
		vm.skip(!forked);
		TwapAggregatorAdapterV2 adapter = _list(LCAP, WETH, SLIP, 200);

		(, address pool, address quote,,) = d.registry.listings(LCAP);
		assertEq(pool, LCAP_WETH_SLIP_200);
		assertEq(quote, WETH);
		assertEq(uint8(d.registry.venueOf(LCAP)), uint8(SLIP));
		assertEq(address(adapter.quoteFeed()), CL_ETH_USD, 'the STANDARD ETH / USD proxy, never SVR');
		assertEq(adapter.quoteHeartbeat(), 3600);
		assertGe(adapter.quoteReserveUsd(), RESERVE_FLOOR_USD18, 'the WETH reserve holds the floor');
		uint256 recorded = d.registry.recordedDepthUsd18(LCAP);
		assertGe(recorded, OLD_BAND_FLOOR_USD18);
		assertEq(recorded, adapter.poolDepthUsd());

		uint256 rate = vi.calcUsdRate(LCAP);
		// WETH per LCAP at the listed pool's spot × Chainlink ETH / USD: the USD leg is applied
		uint256 viaWeth = _spotUsd18(LCAP_WETH_SLIP_200, LCAP, WETH, CL_ETH_USD);
		// LCAP's own USDC pool: an independent market for the same token
		uint256 viaUsdc = _spotUsd18(LCAP_USDC_SLIP_200, LCAP, USDC, CL_USDC_USD);
		assertApproxEqRel(rate, viaWeth, 0.05e18);
		assertApproxEqRel(rate, viaUsdc, 0.05e18, 'agrees with the USDC market');
		emit log_named_decimal_uint('LCAP recorded depth (USD)  ', recorded, 18);
		emit log_named_decimal_uint('LCAP TWAP price (USD)      ', rate, 18);
		emit log_named_decimal_uint('LCAP USDC-pool spot (USD)  ', viaUsdc, 18);
	}

	function test_fork_slipstream3ListsAndTrades() public {
		vm.skip(!forked);
		_assertNoPoolOffSlipstream3(USDL);
		// its pool has a single-observation oracle: the keeper raises the ring before listing
		_prepareOracle(USDL_USDC_SLIP3_50);
		TwapAggregatorAdapterV2 adapter = _list(USDL, USDC, SLIP3, 50);

		assertEq(_poolOf(USDL), USDL_USDC_SLIP3_50);
		assertEq(uint8(d.registry.venueOf(USDL)), uint8(SLIP3));
		assertGe(adapter.quoteReserveUsd(), RESERVE_FLOOR_USD18, 'the USDC reserve holds the floor');
		uint256 recorded = d.registry.recordedDepthUsd18(USDL);
		assertGe(recorded, OLD_BAND_FLOOR_USD18);
		assertEq(recorded, adapter.poolDepthUsd());
		uint256 rate = vi.calcUsdRate(USDL);
		assertApproxEqRel(rate, 1e18, 0.05e18, 'a USD stablecoin prices near $1');

		// the live fund, as its owner, buys 1 USDC of it through the new Slipstream-3 adapter
		Comptroller live = Comptroller(LIVE_FUND);
		address vault = address(live.vault());
		assertEq(live.fundOwner(), deployer);
		assertTrue(factory.isAdapterRegistered(d.slipstream3Adapter));
		assertGe(IERC20(USDC).balanceOf(vault), 1e6, 'the live fund holds USDC');
		uint256 before = IERC20(USDL).balanceOf(vault);
		uint256 gavBefore = live.calcGav();
		uint256 minOut = Math.mulDiv(0.97e18, 1e18, rate); // 1 USD of USDL at the TWAP, less 3%

		vm.prank(deployer);
		live.callOnIntegration(d.slipstream3Adapter, abi.encode(USDC, USDL, int24(50), uint256(1e6), minOut));

		uint256 bought = IERC20(USDL).balanceOf(vault) - before;
		assertGe(bought, minOut, 'the vault received USDL');
		assertApproxEqRel(live.calcGav(), gavBefore, 0.01e18, 'the fund values its Slip3 holding');
		emit log_named_decimal_uint('USDL recorded depth (USD)', recorded, 18);
		emit log_named_decimal_uint('USDL TWAP price (USD)    ', rate, 18);
		emit log_named_decimal_uint('USDL bought for 1 USDC   ', bought, 18);
	}

	/// @notice A Uniswap v2 pair keeps no price history: the keeper records it on the registry's
	///         recorder and, once that snapshot is a window old, lists the token through the module.
	///         The window spans quiet fork time, so the VI price is the pair's spot within 1%; the
	///         live fund then buys it through the new UniswapV2SwapAdapter.
	function test_fork_uniswapV2ListsPricesTrades() public {
		vm.skip(!forked);
		assertFalse(vi.isSupportedAsset(AGNT));
		assertEq(IUniswapV2Factory(TwapListingV2.UNI_V2_FACTORY).getPair(AGNT, USDC), AGNT_USDC_V2);
		assertEq(address(d.registry.recorder()), address(d.recorder), 'v2 prices from the deployed recorder');

		// no snapshot yet: the listing waits for the keeper's recorder history
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(UniswapV2ObservationRecorder.NoSnapshot.selector, AGNT_USDC_V2));
		d.module.list(AGNT, USDC, UNIV2, 0);

		assertTrue(d.recorder.record(AGNT_USDC_V2));
		_warpRoll(V2_WARP);
		UniswapV2TwapAdapter adapter = UniswapV2TwapAdapter(address(_listAny(AGNT, USDC, UNIV2, 0)));
		assertEq(address(adapter.pair()), AGNT_USDC_V2);
		assertEq(address(adapter.recorder()), address(d.recorder));
		_assertListedOn(AGNT, address(adapter), AGNT_USDC_V2, USDC, UNIV2);
		(uint256 rA, uint256 rQ) = _v2Reserves(AGNT_USDC_V2, AGNT);
		uint256 reserve = adapter.quoteReserveUsd();
		assertEq(reserve, _usd18(rQ, USDC, CL_USDC_USD), 'the USDC reserve x USDC / USD');
		assertGe(reserve, RESERVE_FLOOR_USD18);

		uint256 rate = vi.calcUsdRate(AGNT);
		uint256 spot = _reserveSpotUsd18(rA, rQ, AGNT, USDC, CL_USDC_USD);
		assertApproxEqRel(rate, spot, 0.01e18, 'the VI price is the pair spot within 1%');

		uint256 minOut = _oneUsdLess3Pct(AGNT, rate);
		uint256 bought = _liveFundBuys(d.uniswapV2Adapter, AGNT, abi.encode(USDC, AGNT, uint256(1e6), minOut));
		assertGe(bought, minOut, 'the vault received AGNT');
		emit log_named_decimal_uint('AGNT USDC reserve (USD)', reserve, 18);
		emit log_named_decimal_uint('AGNT band recorded (USD)', d.registry.recordedDepthUsd18(AGNT), 18);
		emit log_named_decimal_uint('AGNT TWAP price (USD)  ', rate, 18);
		emit log_named_decimal_uint('AGNT pair spot (USD)   ', spot, 18);
		emit log_named_decimal_uint('AGNT bought for 1 USDC ', bought, 18);
	}

	/// @notice Aerodrome basic pools keep their own 30-minute observations: the keeper lists AWE on
	///         its VOLATILE USDC pool with no warm-up and the live fund buys it through the new
	///         AerodromeBasicSwapAdapter. The window spans the pool's REAL recent trading, so the
	///         price is pinned exactly to the pool's time-averaged reserves (re-derived here from
	///         its raw observations) and to spot within the adapter's 5% guard — a 1%-of-spot check
	///         would test the market, not the code (at block 52014634 the two are equal: no trade
	///         in the window).
	function test_fork_aerodromeBasicListsPricesTrades() public {
		vm.skip(!forked);
		assertFalse(vi.isSupportedAsset(AWE));
		assertEq(IAerodromeBasicFactory(AERO_FACTORY).getPool(AWE, USDC, false), AWE_USDC_AERO);
		assertFalse(IAerodromeBasicPool(AWE_USDC_AERO).stable());

		AerodromeBasicTwapAdapter adapter = AerodromeBasicTwapAdapter(address(_listAny(AWE, USDC, AERO, 0)));
		assertEq(address(adapter.pool()), AWE_USDC_AERO);
		_assertListedOn(AWE, address(adapter), AWE_USDC_AERO, USDC, AERO);
		(uint256 rA, uint256 rQ) = _aeroReserves(AWE_USDC_AERO, AWE);
		uint256 reserve = adapter.quoteReserveUsd();
		assertEq(reserve, _usd18(rQ, USDC, CL_USDC_USD), 'the USDC reserve x USDC / USD');
		assertGe(reserve, RESERVE_FLOOR_USD18);

		uint256 rate = vi.calcUsdRate(AWE);
		assertEq(rate, _aeroTwapUsd18(AWE_USDC_AERO, AWE, CL_USDC_USD), 'time-averaged reserves x USDC / USD');
		uint256 spot = _reserveSpotUsd18(rA, rQ, AWE, USDC, CL_USDC_USD);
		assertApproxEqRel(rate, spot, 0.05e18, 'within the 5% spot guard');

		uint256 minOut = _oneUsdLess3Pct(AWE, rate);
		uint256 bought = _liveFundBuys(d.aerodromeBasicAdapter, AWE, abi.encode(USDC, AWE, uint256(1e6), minOut));
		assertGe(bought, minOut, 'the vault received AWE');
		emit log_named_decimal_uint('AWE USDC reserve (USD)  ', reserve, 18);
		emit log_named_decimal_uint('AWE band recorded (USD) ', d.registry.recordedDepthUsd18(AWE), 18);
		emit log_named_decimal_uint('AWE TWAP price (USD)    ', rate, 18);
		emit log_named_decimal_uint('AWE pool spot (USD)     ', spot, 18);
		emit log_named_decimal_uint('AWE bought for 1 USDC   ', bought, 18);
	}

	/// @notice Aerodrome basic lists VOLATILE pools only. crvUSD's only Aerodrome pool against USDC
	///         or WETH is a stable (sAMM) one: the registry never resolves it, whatever the fee /
	///         spacing argument, and the adapter itself refuses a stable pool even when deployed
	///         directly (the deployers are permissionless).
	function test_fork_aerodromeStableNeverListed() public {
		vm.skip(!forked);
		IAerodromeBasicFactory aero = IAerodromeBasicFactory(AERO_FACTORY);
		assertFalse(vi.isSupportedAsset(CRVUSD));
		assertEq(aero.getPool(CRVUSD, USDC, true), CRVUSD_USDC_STABLE, 'a real sAMM pool');
		assertTrue(IAerodromeBasicPool(CRVUSD_USDC_STABLE).stable());
		assertEq(aero.getPool(CRVUSD, USDC, false), address(0), 'no volatile pool vs USDC');
		assertEq(aero.getPool(CRVUSD, WETH, false), address(0), 'no volatile pool vs WETH');
		assertEq(aero.getPool(CRVUSD, WETH, true), address(0));

		int24[3] memory args = [int24(0), 1, -1];
		for (uint256 i; i < args.length; ++i) {
			vm.prank(keeper);
			vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.PoolNotFound.selector, CRVUSD, USDC));
			d.module.list(CRVUSD, USDC, AERO, args[i]);
		}
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.PoolNotFound.selector, CRVUSD, WETH));
		d.module.list(CRVUSD, WETH, AERO, 0);

		vm.prank(stranger);
		vm.expectRevert(AerodromeBasicTwapAdapter.StablePool.selector);
		d.aeroDeployer.deploy(
			IAerodromeBasicPool(CRVUSD_USDC_STABLE), CRVUSD, AggregatorV3Interface(CL_USDC_USD), 30 minutes, 25_000, 500, 90_000, 'sAMM'
		);

		assertEq(d.registry.listedCount(), 0);
		assertFalse(vi.isSupportedAsset(CRVUSD));
	}

	/// @notice Ruling 21: cbBTC is the registry's third quote, on the VI's own cbBTC / USD feed and
	///         heartbeat. Real tokens that pair against cbBTC list on it with an 8-decimal quote: ZEN
	///         on its Slipstream pool and EDGE on its Aerodrome basic pool.
	function test_fork_cbBtcQuotedLists() public {
		vm.skip(!forked);
		(AggregatorV3Interface feed, uint32 heartbeat) = d.registry.quotes(CBBTC);
		(address viFeed, uint32 viHeartbeat,,) = vi.getAssetInfo(CBBTC);
		assertEq(address(feed), CL_CBBTC_USD);
		assertEq(viFeed, CL_CBBTC_USD, "the VI's own cbBTC feed");
		assertEq(heartbeat, viHeartbeat, "and the VI's heartbeat");
		assertEq(IERC20Metadata(CBBTC).decimals(), 8);
		_assertZenListsOnCbBtc(heartbeat);
		_assertEdgeListsOnCbBtc();
		assertEq(d.registry.listedCount(), 2);
	}

	/// @dev ZEN on its Slipstream cbBTC pool (cbBTC is token0), priced against its WETH market.
	function _assertZenListsOnCbBtc(uint32 heartbeat) internal {
		assertFalse(vi.isSupportedAsset(ZEN));
		assertEq(ISlipstreamPoolFactory(FundsMainnet.CL_FACTORY).getPool(ZEN, CBBTC, 200), ZEN_CBBTC_SLIP_200);
		TwapAggregatorAdapterV2 zen = _list(ZEN, CBBTC, SLIP, 200);
		_assertListedOn(ZEN, address(zen), ZEN_CBBTC_SLIP_200, CBBTC, SLIP);
		assertEq(address(zen.quoteFeed()), CL_CBBTC_USD);
		assertEq(zen.quoteHeartbeat(), heartbeat);
		uint256 reserve = zen.quoteReserveUsd();
		assertEq(reserve, _usd18(IERC20(CBBTC).balanceOf(ZEN_CBBTC_SLIP_200), CBBTC, CL_CBBTC_USD), 'the cbBTC the pool holds');
		assertGe(reserve, RESERVE_FLOOR_USD18);
		uint256 rate = vi.calcUsdRate(ZEN);
		assertApproxEqRel(rate, _spotUsd18(ZEN_CBBTC_SLIP_200, ZEN, CBBTC, CL_CBBTC_USD), 0.05e18);
		uint256 viaWeth = _spotUsd18(ZEN_WETH_SLIP_100, ZEN, WETH, CL_ETH_USD);
		assertApproxEqRel(rate, viaWeth, 0.05e18, "agrees with ZEN's WETH market");
		emit log_named_decimal_uint('ZEN cbBTC reserve (USD)  ', reserve, 18);
		emit log_named_decimal_uint('ZEN band recorded (USD)  ', d.registry.recordedDepthUsd18(ZEN), 18);
		emit log_named_decimal_uint('ZEN TWAP price (USD)     ', rate, 18);
		emit log_named_decimal_uint('ZEN WETH-market spot     ', viaWeth, 18);
	}

	/// @dev EDGE on its Aerodrome basic cbBTC pool (volatile; cbBTC is token0).
	function _assertEdgeListsOnCbBtc() internal {
		assertFalse(vi.isSupportedAsset(EDGE));
		assertEq(IAerodromeBasicFactory(AERO_FACTORY).getPool(EDGE, CBBTC, false), EDGE_CBBTC_AERO);
		ITwapPriceAdapter edge = _listAny(EDGE, CBBTC, AERO, 0);
		_assertListedOn(EDGE, address(edge), EDGE_CBBTC_AERO, CBBTC, AERO);
		(uint256 rA, uint256 rQ) = _aeroReserves(EDGE_CBBTC_AERO, EDGE);
		uint256 reserve = edge.quoteReserveUsd();
		assertEq(reserve, _usd18(rQ, CBBTC, CL_CBBTC_USD), 'the cbBTC reserve x cbBTC / USD');
		assertGe(reserve, RESERVE_FLOOR_USD18);
		uint256 rate = vi.calcUsdRate(EDGE);
		assertEq(rate, _aeroTwapUsd18(EDGE_CBBTC_AERO, EDGE, CL_CBBTC_USD), 'time-averaged reserves x cbBTC / USD');
		uint256 spot = _reserveSpotUsd18(rA, rQ, EDGE, CBBTC, CL_CBBTC_USD);
		assertApproxEqRel(rate, spot, 0.05e18);
		emit log_named_decimal_uint('EDGE cbBTC reserve (USD) ', reserve, 18);
		emit log_named_decimal_uint('EDGE band recorded (USD) ', d.registry.recordedDepthUsd18(EDGE), 18);
		emit log_named_decimal_uint('EDGE TWAP price (USD)    ', rate, 18);
		emit log_named_decimal_uint('EDGE pool spot (USD)     ', spot, 18);
	}

	/// @notice FOUNDER DECISION 2026-09-30: transfer-taxed tokens are never listed — and that is
	///         KEEPER POLICY, not a contract rule. The keeper's round-trip buy→sell simulation refuses
	///         any token whose transfers cost more than the pool fee; the registry, the module and the
	///         swap adapters do not (and can't: an owner may switch a tax on after listing, and a TWAP
	///         never sees it). This test pins that boundary so nobody assumes the contracts refuse
	///         them: B18 really taxes its pair transfers, yet it lists on-chain and the live fund's
	///         buy really pays the tax. The keeper's simulation is the only guard.
	function test_fork_taxedTokenListsButIsKeeperPolicy() public {
		vm.skip(!forked);
		IB18Tax b18 = IB18Tax(B18);
		assertTrue(b18.swapPairList(B18_USDC_V2), 'B18 taxes transfers to and from its USDC pair');
		assertGt(b18.buyFeeRate(), 0, 'a buy tax');
		assertGt(b18.sellFeeRate(), 0, 'a sell tax');
		assertEq(IUniswapV2Factory(TwapListingV2.UNI_V2_FACTORY).getPair(B18, USDC), B18_USDC_V2);
		assertFalse(vi.isSupportedAsset(B18));

		// the keeper's recorder snapshot, a window, then the listing: nothing on-chain objects
		assertTrue(d.recorder.record(B18_USDC_V2));
		_warpRoll(V2_WARP);
		ITwapPriceAdapter adapter = _listAny(B18, USDC, UNIV2, 0);
		_assertListedOn(B18, address(adapter), B18_USDC_V2, USDC, UNIV2);
		assertGe(adapter.quoteReserveUsd(), RESERVE_FLOOR_USD18);
		(uint256 rA, uint256 rQ) = _v2Reserves(B18_USDC_V2, B18);
		uint256 rate = vi.calcUsdRate(B18);
		assertApproxEqRel(rate, _reserveSpotUsd18(rA, rQ, B18, USDC, CL_USDC_USD), 0.01e18);

		// the live fund buys 1 USDC of it: the pair pays the untaxed quote, the vault gets it less the tax
		uint256 untaxed =
			IUniswapV2RouterQuote(UNI_V2_ROUTER).getAmountOut(IERC20(USDC).balanceOf(B18_USDC_V2) - rQ + 1e6, rQ, rA);
		uint256 bought = _liveFundBuys(d.uniswapV2Adapter, B18, abi.encode(USDC, B18, uint256(1e6), uint256(0)));
		assertEq(bought, untaxed - untaxed * b18.buyFeeRate() / b18.RATE_UNIT(), 'credited net of the buy tax');
		assertLt(bought, untaxed);
		emit log_named_decimal_uint('B18 USDC reserve (USD)      ', adapter.quoteReserveUsd(), 18);
		emit log_named_decimal_uint('B18 TWAP price (USD)        ', rate, 18);
		emit log_named_decimal_uint('B18 untaxed quote for 1 USDC', untaxed, 18);
		emit log_named_decimal_uint('B18 credited (after buy tax)', bought, 18);
	}

	// ─── repoint ─────────────────────────────────────────────────────────────────

	function test_fork_repointNeedsMargin() public {
		vm.skip(!forked);
		// the margin itself: a DEEPER pool that is short of 1.25× is refused
		uint256 snap = vm.snapshotState();
		TwapAggregatorAdapterV2 thin = _list(VIRTUAL, WETH, SLIP2, 50);
		(uint256 cur, uint256 next) =
			_notDeepEnough(_revertData(keeper, address(d.module), abi.encodeCall(PriceListingModule.repoint, (VIRTUAL, WETH, SLIP, 100))));
		assertEq(cur, thin.poolDepthUsd());
		assertGt(next, cur, 'the target is deeper');
		assertLt(next, Math.mulDiv(cur, MARGIN_BPS, 10_000), 'but not 25% deeper');
		emit log_named_decimal_uint('Slip2 ts50 depth  (listed)', cur, 18);
		emit log_named_decimal_uint('Slip1 ts100 depth (refused)', next, 18);
		vm.revertToState(snap);

		// from the second-deepest pool
		TwapAggregatorAdapterV2 second = _list(VIRTUAL, WETH, SLIP, 200);
		uint256 secondDepth = second.poolDepthUsd();
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.SamePool.selector, VIRTUAL_WETH_SLIP_200));
		d.module.repoint(VIRTUAL, WETH, SLIP, 200);

		(cur, next) =
			_notDeepEnough(_revertData(keeper, address(d.module), abi.encodeCall(PriceListingModule.repoint, (VIRTUAL, WETH, UNI, 500))));
		assertEq(cur, secondDepth);
		assertLt(next, cur, 'a shallower pool is refused');

		// the deepest pool is ≥ 1.25× deeper: the listing moves and records the new depth
		TwapAggregatorAdapterV2 deepest = _repoint(VIRTUAL, USDC, UNI, 3000);
		uint256 deepestDepth = deepest.poolDepthUsd();
		assertGe(deepestDepth, Math.mulDiv(secondDepth, MARGIN_BPS, 10_000));
		assertEq(_poolOf(VIRTUAL), VIRTUAL_USDC_3000);
		assertEq(uint8(d.registry.venueOf(VIRTUAL)), uint8(UNI));
		assertEq(d.registry.recordedDepthUsd18(VIRTUAL), deepestDepth, 'Ruling 8: repoint records the new depth');
		assertEq(_clockOf(VIRTUAL), 0);
		(address aggregator,,,) = vi.getAssetInfo(VIRTUAL);
		assertEq(aggregator, address(deepest), 'the VI follows the repoint');
		assertEq(d.registry.listedCount(), 1, 'a repoint adds no listing');

		// and straight back is flapping: refused
		(cur, next) =
			_notDeepEnough(_revertData(keeper, address(d.module), abi.encodeCall(PriceListingModule.repoint, (VIRTUAL, WETH, SLIP, 200))));
		assertEq(cur, deepestDepth);
		assertLt(next, cur);
		emit log_named_decimal_uint('second-deepest depth (USD)', secondDepth, 18);
		emit log_named_decimal_uint('deepest depth (USD)       ', deepestDepth, 18);
	}

	/// @notice Ruling 9: real sells take the listed pool's quote RESERVE just under the floor; anyone
	///         starts the clock; the keeper then moves the listing to a qualifying pool whose band is
	///         NOT 25% deeper than the slipped one's — only the under-floor branch (currentOk = false)
	///         allows that — and the move resets the clock and records the new pool's band.
	///         LCAP, not MORPHO (see the contract natspec): the target must hold the $25k reserve while
	///         its band stays under 1.25× a band that sits in a reserve under $25k.
	function test_fork_underFloorRepointAndClock() public {
		vm.skip(!forked);
		TwapAggregatorAdapterV2 current = _list(LCAP, USDC, SLIP, 200);
		uint256 healthyDepth = current.poolDepthUsd();
		uint256 healthyReserve = current.quoteReserveUsd();
		assertEq(IAerodromeBasicFactory(AERO_FACTORY).getPool(LCAP, USDC, false), LCAP_USDC_AERO);

		// healthy: LCAP's Aerodrome basic USDC pool holds the reserve floor but its band is shallower: refused
		(uint256 cur, uint256 next) =
			_notDeepEnough(_revertData(keeper, address(d.module), abi.encodeCall(PriceListingModule.repoint, (LCAP, USDC, AERO, 0))));
		assertEq(cur, healthyDepth);
		assertLt(next, cur);

		// real sells: the smallest push that takes the USDC reserve under the floor
		int24 push = _sellJustUnderFloor(current);
		uint256 slippedReserve = current.quoteReserveUsd();
		uint256 slipped = current.poolDepthUsd();
		assertLt(slippedReserve, RESERVE_FLOOR_USD18, 'the reserve slipped under the floor');

		// anyone starts the clock
		vm.prank(stranger);
		assertTrue(d.registry.pokeFloor(LCAP));
		assertEq(_clockOf(LCAP), block.timestamp);

		ITwapPriceAdapter moved = _repointAny(LCAP, USDC, AERO, 0);
		uint256 movedDepth = moved.poolDepthUsd();
		assertGe(moved.quoteReserveUsd(), RESERVE_FLOOR_USD18, 'the new pool holds the reserve floor');
		assertLt(movedDepth, Math.mulDiv(slipped, MARGIN_BPS, 10_000), 'the margin alone would have refused this move');
		assertEq(_poolOf(LCAP), LCAP_USDC_AERO);
		assertEq(uint8(d.registry.venueOf(LCAP)), uint8(AERO));
		assertEq(_clockOf(LCAP), 0, 'the repoint resets the clock');
		assertEq(d.registry.recordedDepthUsd18(LCAP), movedDepth, 'Ruling 8: the new depth is recorded');
		(address aggregator,,,) = vi.getAssetInfo(LCAP);
		assertEq(aggregator, address(moved));
		// LCAP has no Chainlink feed: its WETH market, untouched by the sells, is the independent check
		uint256 viaWeth = _spotUsd18(LCAP_WETH_SLIP_200, LCAP, WETH, CL_ETH_USD);
		assertApproxEqRel(vi.calcUsdRate(LCAP), viaWeth, 0.05e18, "agrees with LCAP's WETH market");
		emit log_named_int('real sells pushed spot (ticks)  ', push);
		emit log_named_decimal_uint('USDC-pool reserve healthy (USD) ', healthyReserve, 18);
		emit log_named_decimal_uint('USDC-pool band healthy (USD)    ', healthyDepth, 18);
		emit log_named_decimal_uint('USDC-pool reserve after sells   ', slippedReserve, 18);
		emit log_named_decimal_uint('USDC-pool band after sells      ', slipped, 18);
		emit log_named_decimal_uint('Aerodrome reserve (USD)         ', moved.quoteReserveUsd(), 18);
		emit log_named_decimal_uint('Aerodrome band recorded (USD)   ', movedDepth, 18);
		emit log_named_decimal_uint('LCAP TWAP (USD) / WETH market   ', vi.calcUsdRate(LCAP), 18);
		emit log_named_decimal_uint('                                ', viaWeth, 18);
	}

	/// @notice A pool dumped far under the floor by real sells: the keeper moves the listing to a
	///         pool the margin refused while the dumped one was healthy, and the VI stops pricing
	///         from the dumped pool.
	function test_fork_dumpedPoolRepointsToHealthyPool() public {
		vm.skip(!forked);
		TwapAggregatorAdapterV2 dumped = _list(VIRTUAL, WETH, SLIP, 200);
		uint256 healthyDepth = dumped.poolDepthUsd();

		// healthy: the Uniswap WETH 0.05% pool is not 25% deeper
		(uint256 cur, uint256 next) =
			_notDeepEnough(_revertData(keeper, address(d.module), abi.encodeCall(PriceListingModule.repoint, (VIRTUAL, WETH, UNI, 500))));
		assertEq(cur, healthyDepth);
		assertLt(next, Math.mulDiv(cur, MARGIN_BPS, 10_000));

		// real sells pay the pool's WETH out: its reserve ends far under the floor
		uint256 sold = _sellAsset(dumped, UNDER_FLOOR_TICKS);
		assertTrue(dumped.isBelowFloor());
		uint256 dumpedReserve = dumped.quoteReserveUsd();
		uint256 dumpedDepth = dumped.poolDepthUsd();

		// anyone starts the clock
		vm.prank(stranger);
		assertTrue(d.registry.pokeFloor(VIRTUAL));
		assertEq(_clockOf(VIRTUAL), block.timestamp);

		// the keeper moves the listing with no margin (the current reserve is under the floor)
		TwapAggregatorAdapterV2 moved = _repoint(VIRTUAL, WETH, UNI, 500);
		assertEq(_poolOf(VIRTUAL), VIRTUAL_WETH_UNI_500);
		assertEq(_clockOf(VIRTUAL), 0, 'the repoint resets the clock');
		assertEq(d.registry.recordedDepthUsd18(VIRTUAL), moved.poolDepthUsd(), 'Ruling 8: the new depth is recorded');
		assertLt(moved.poolDepthUsd(), Math.mulDiv(healthyDepth, MARGIN_BPS, 10_000), 'no margin was needed');
		assertGe(moved.quoteReserveUsd(), RESERVE_FLOOR_USD18);
		assertFalse(d.registry.isDelisted(VIRTUAL));
		// the dumped pool no longer prices VIRTUAL
		(address aggregator,,,) = vi.getAssetInfo(VIRTUAL);
		assertEq(aggregator, address(moved));
		assertApproxEqRel(vi.calcUsdRate(VIRTUAL), _chainlinkUsd18(CL_VIRTUAL_USD), 0.05e18);
		emit log_named_decimal_uint('VIRTUAL sold into the pool       ', sold, 18);
		emit log_named_decimal_uint('Slip WETH-pool band healthy (USD)', healthyDepth, 18);
		emit log_named_decimal_uint('Slip WETH-pool reserve after sells', dumpedReserve, 18);
		emit log_named_decimal_uint('Slip WETH-pool band after sells  ', dumpedDepth, 18);
		emit log_named_decimal_uint('Uni WETH-pool band recorded (USD)', moved.poolDepthUsd(), 18);
	}

	/// @notice Ruling 12a: once governance prices a listed token through Chainlink, the keeper can
	///         no longer repoint it back onto a pool.
	function test_fork_governanceChainlinkMoveBlocksRepoint() public {
		vm.skip(!forked);
		TwapAggregatorAdapterV2 listed = _list(VIRTUAL, WETH, SLIP, 200);
		uint256 recorded = d.registry.recordedDepthUsd18(VIRTUAL);

		// before the move this exact repoint goes through (the USDC pool is ≥ 1.25× deeper)
		uint256 snap = vm.snapshotState();
		_repoint(VIRTUAL, USDC, UNI, 3000);
		vm.revertToState(snap);

		vm.prank(deployer);
		d.module.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (VIRTUAL, CL_VIRTUAL_USD, 90_000)));
		(address aggregator, uint32 heartbeat,,) = vi.getAssetInfo(VIRTUAL);
		assertEq(aggregator, CL_VIRTUAL_USD);
		assertEq(heartbeat, 90_000);
		assertFalse(d.registry.isTwapPriced(VIRTUAL));

		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(PriceListingModule.NotTwapPriced.selector, VIRTUAL));
		d.module.repoint(VIRTUAL, USDC, UNI, 3000);
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(PriceListingModule.AlreadyPriced.selector, VIRTUAL));
		d.module.list(VIRTUAL, USDC, UNI, 3000);

		(aggregator,,,) = vi.getAssetInfo(VIRTUAL);
		assertEq(aggregator, CL_VIRTUAL_USD, 'the Chainlink feed stays');
		assertEq(vi.calcUsdRate(VIRTUAL), _chainlinkUsd18(CL_VIRTUAL_USD));
		assertEq(d.registry.adapterOf(VIRTUAL), address(listed), 'the registry record is untouched');
		assertEq(d.registry.recordedDepthUsd18(VIRTUAL), recorded);
	}

	function test_fork_cannotHijackPricedAsset() public {
		vm.skip(!forked);
		// Chainlink-priced (WETH) and derivative (avUSDC) assets: refused before the registry runs
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(PriceListingModule.AlreadyPriced.selector, WETH));
		d.module.list(WETH, USDC, UNI, 500);
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(PriceListingModule.AlreadyPriced.selector, FundsMainnet.AV_USDC));
		d.module.list(FundsMainnet.AV_USDC, USDC, UNI, 500);
		// a Chainlink stock can't be repointed onto a pool
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(PriceListingModule.NotTwapPriced.selector, NVDAC));
		d.module.repoint(NVDAC, USDC, UNI, 3000);

		(address aggregator, uint32 heartbeat,,) = vi.getAssetInfo(WETH);
		assertEq(aggregator, CL_ETH_USD);
		assertEq(heartbeat, 3600);
		(aggregator,,,) = vi.getAssetInfo(NVDAC);
		assertEq(aggregator, CL_NVDA);

		// Uniswap fee ≤ 0 names no pool
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.PoolNotFound.selector, VIRTUAL, USDC));
		d.module.list(VIRTUAL, USDC, UNI, 0);
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.PoolNotFound.selector, VIRTUAL, USDC));
		d.module.list(VIRTUAL, USDC, UNI, -3000);

		// a real spacing-1 pool is refused for its spacing, not for being missing
		assertEq(IUniswapV3PoolFactory(FundsMainnet.UNI_FACTORY).getPool(USDT, USDC, 100), USDT_USDC_UNI_100);
		assertEq(IConcentratedPoolOracle(USDT_USDC_UNI_100).tickSpacing(), 1);
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.TickSpacingTooFine.selector, int24(1)));
		d.module.list(USDT, USDC, UNI, 100);

		assertEq(d.registry.listedCount(), 0);
		assertFalse(vi.isSupportedAsset(VIRTUAL));
		assertFalse(vi.isSupportedAsset(USDT));
	}

	// ─── governance ──────────────────────────────────────────────────────────────

	function test_fork_governancePassthrough() public {
		vm.skip(!forked);
		assertEq(vi.owner(), address(d.module));
		assertFalse(vi.isSupportedAsset(LINK));

		vm.prank(deployer);
		d.module.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (LINK, CL_LINK_USD, 90_000)));
		uint256 rate = vi.calcUsdRate(LINK);
		assertGt(rate, 0);
		assertEq(rate, _chainlinkUsd18(CL_LINK_USD));

		// nobody else reaches the VI: not a stranger, not the keeper, not the deployer directly
		bytes memory remove = abi.encodeCall(ValueInterpreter.removePrimitive, (LINK));
		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		d.module.execute(remove);
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
		d.module.execute(remove);
		vm.prank(deployer);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
		vi.removePrimitive(LINK);

		// the VI's own errors come back unchanged
		vm.prank(deployer);
		vm.expectRevert(abi.encodeWithSelector(ValueInterpreter.HeartbeatAboveMax.selector, uint32(8 days)));
		d.module.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (LINK, CL_LINK_USD, 8 days)));
		assertTrue(vi.isSupportedAsset(LINK));
		emit log_named_decimal_uint('LINK via Chainlink (USD)', rate, 18);
	}

	// ─── exposure caps ───────────────────────────────────────────────────────────

	function test_fork_policyV2CapsQuoteSide() public {
		vm.skip(!forked);
		TwapAggregatorAdapterV2 adapter = _list(VVV, USDC, UNI, 3000);
		uint256 recorded = d.registry.recordedDepthUsd18(VVV);
		assertLt(recorded, LARGE_POOL_USD18, 'the 10% regime');
		uint256 cap = _capUsd18(recorded);
		// v1 measured both sides of the same pool: its cap would be far looser
		TwapAggregatorAdapter v1 = new TwapAggregatorAdapter(
			IConcentratedPoolOracle(VVV_USDC_3000), VVV, AggregatorV3Interface(CL_USDC_USD), 30 minutes, 50_000, 500, 90_000, 'v1'
		);
		uint256 v1Cap = _capUsd18(v1.poolDepthUsd());

		// GAV = 10× the cap, so the 20%-of-GAV rule stays out of the way
		uint256 capUsdc = cap / 1e12;
		Comptroller fund = _fundWithDeposit('TWAP v2 Cap Rehearsal', 'frCAP', manager, capUsdc * 10);
		_assertCarriesPolicyV2(fund);

		// under the cap: the buy goes through
		vm.prank(manager);
		fund.callOnIntegration(uniAdapter, _buy(VVV, capUsdc * 6 / 10));
		uint256 held = _holdingUsd18(fund, VVV);
		assertGt(held, 0);
		assertLt(held, cap);
		// buying added bids: the live depth is over the recorded one, so the recorded one binds
		assertGe(adapter.poolDepthUsd(), recorded);

		// past 10% of the pool's quote-side depth: refused
		bytes memory err = _revertData(
			manager, address(fund), abi.encodeCall(Comptroller.callOnIntegration, (uniAdapter, _buy(VVV, capUsdc * 6 / 10)))
		);
		(uint256 holding, uint256 capHit) = _poolShareExceeded(err, VVV);
		assertEq(capHit, cap, 'the cap is 10% of the recorded quote-side depth');
		assertGt(holding, cap);
		assertLt(Math.mulDiv(holding, 10_000, _gavUsd18(fund)), 2_000, 'under 20% of GAV: only the pool cap binds');
		assertLt(holding, v1Cap, 'two-sided depth would have allowed it');
		emit log_named_decimal_uint('recorded quote-side depth (USD)', recorded, 18);
		emit log_named_decimal_uint('cap (USD)                      ', cap, 18);
		emit log_named_decimal_uint('held after first buy (USD)     ', held, 18);
		emit log_named_decimal_uint('holding refused (USD)          ', holding, 18);
		emit log_named_decimal_uint('v1 two-sided cap (USD)         ', v1Cap, 18);
	}

	/// @notice Amendment A on real pools with real NPM mints: (b) a fund owner that mints
	///         quote-only liquidity in the same transaction as its buy does not lift its cap;
	///         (a) a stranger's flash liquidity can't clear a started delist clock.
	function test_fork_jitCannotClearClockOrLiftCap() public {
		vm.skip(!forked);
		TwapAggregatorAdapterV2 adapter = _list(VVV, USDC, UNI, 3000);
		_jitBuyStaysCapped(adapter);
		_jitPokeCannotClearClock(adapter);
	}

	/// @dev (b) this contract owns the fund: mint → buy → burn, all in one transaction.
	function _jitBuyStaysCapped(TwapAggregatorAdapterV2 adapter) internal {
		uint256 recorded = d.registry.recordedDepthUsd18(VVV);
		uint256 cap = _capUsd18(recorded);
		Comptroller fund = _fundWithDeposit('TWAP v2 JIT Rehearsal', 'frJIT', address(this), cap / 1e12 * 10);
		uint256 liveBefore = adapter.poolDepthUsd();
		(uint256 tokenId, uint128 liquidity,) = _mintQuoteOnly(adapter, JIT_USDC, address(this));
		uint256 liveCap = _capUsd18(adapter.poolDepthUsd());
		assertGt(liveCap, cap, 'the flash mint lifts the live depth, and a live-depth cap with it');
		// a buy sized between the two caps
		bytes memory err = _revertData(
			address(this),
			address(fund),
			abi.encodeCall(Comptroller.callOnIntegration, (uniAdapter, _buy(VVV, (cap + liveCap) / 2 / 1e12)))
		);
		(uint256 holding, uint256 capHit) = _poolShareExceeded(err, VVV);
		assertEq(capHit, cap, 'the cap stays on the recorded depth');
		assertGt(holding, cap);
		assertLt(holding, liveCap, 'a live-depth cap would have let it through');
		_burn(tokenId, liquidity, address(this));
		assertEq(adapter.poolDepthUsd(), liveBefore, 'the burn takes the flash depth back out');
		emit log_named_decimal_uint('recorded depth (USD)          ', recorded, 18);
		emit log_named_decimal_uint('cap held (USD)                ', capHit, 18);
		emit log_named_decimal_uint('live-depth cap w/ flash (USD) ', liveCap, 18);
		emit log_named_decimal_uint('holding refused (USD)         ', holding, 18);
	}

	/// @dev (a) real sells put the pool's quote reserve just under the floor; a stranger starts the
	///      clock, then can't clear it.
	function _jitPokeCannotClearClock(TwapAggregatorAdapterV2 adapter) internal {
		int24 push = _sellJustUnderFloor(adapter);
		uint256 reserveUnder = adapter.quoteReserveUsd();
		vm.prank(stranger);
		assertTrue(d.registry.pokeFloor(VVV));
		uint64 since = _clockOf(VVV);
		assertEq(since, block.timestamp);
		uint256 recordedAtClock = d.registry.recordedDepthUsd18(VVV);

		// the stranger flash-mints quote at the new spot: the live read now says "over the floor" …
		(uint256 tokenId, uint128 liquidity,) = _mintQuoteOnly(adapter, JIT_USDC, stranger);
		assertFalse(adapter.isBelowFloor(), 'the flash liquidity fools a live read');
		uint256 reserveFlash = adapter.quoteReserveUsd();
		uint256 liveFlash = adapter.poolDepthUsd();
		// … but a non-lister's poke neither clears the clock nor records depth
		vm.prank(stranger);
		assertFalse(d.registry.pokeFloor(VVV));
		assertEq(_clockOf(VVV), since, 'the clock keeps running');
		assertEq(d.registry.recordedDepthUsd18(VVV), recordedAtClock);
		_burn(tokenId, liquidity, stranger);
		assertTrue(adapter.isBelowFloor());
		emit log_named_int('sells pushed spot (ticks)     ', push);
		emit log_named_decimal_uint('reserve after sells (USD)     ', reserveUnder, 18);
		emit log_named_decimal_uint('reserve + flash mint (USD)    ', reserveFlash, 18);
		emit log_named_decimal_uint('under-floor depth + flash mint', liveFlash, 18);
	}

	/// @notice The rule split on a real thin pool: BRETT's Slipstream WETH pool holds hundreds of
	///         thousands of dollars of WETH but only ~$34k within −10% of the price. The reserve lists
	///         it (v2's old $50k band floor refused it); the band sizes the cap: a non-degen fund may
	///         hold 10% of the band — far less than 10% of the reserve.
	function test_fork_thinBandListsWithTinyCap() public {
		vm.skip(!forked);
		assertEq(d.registry.MIN_QUOTE_RESERVE_USD() * 1e18, RESERVE_FLOOR_USD18);
		assertFalse(vi.isSupportedAsset(BRETT));
		assertEq(ISlipstreamPoolFactory(FundsMainnet.CL_FACTORY).getPool(BRETT, WETH, 200), BRETT_WETH_SLIP_200);
		TwapAggregatorAdapterV2 adapter = _list(BRETT, WETH, SLIP, 200);
		uint256 reserve = adapter.quoteReserveUsd();
		uint256 band = d.registry.recordedDepthUsd18(BRETT);
		assertGe(reserve, RESERVE_FLOOR_USD18, 'the reserve lists it');
		assertLt(band, OLD_BAND_FLOOR_USD18, "a band v2's old floor refused");
		assertEq(band, adapter.poolDepthUsd(), 'the band is recorded, not the reserve');
		uint256 cap = _capUsd18(band);
		assertEq(cap, band / 10, '10% of the band');

		// a NON-degen fund with GAV 10x the cap
		uint256 capUsdc = cap / 1e12;
		Comptroller fund = _fundWithDeposit('TWAP v2b Thin Band', 'frTHIN', manager, capUsdc * 10);
		_assertCarriesPolicyV2(fund);
		assertFalse(fund.allowRiskyAssets());

		// under the cap: the buy goes through
		_buyBrett(fund, capUsdc * 6 / 10, false);
		uint256 held = _holdingUsd18(fund, BRETT);
		assertGt(held, 0);
		assertLt(held, cap);

		// past 10% of the band: refused, though 10% of the reserve would have allowed it
		(uint256 holding, uint256 capHit) = _poolShareExceeded(_buyBrett(fund, capUsdc * 6 / 10, true), BRETT);
		assertEq(capHit, cap, 'the cap is 10% of the recorded band');
		assertGt(holding, cap);
		assertLt(Math.mulDiv(holding, 10_000, _gavUsd18(fund)), 2_000, 'under 20% of GAV: only the pool cap binds');
		assertLt(holding, Math.mulDiv(reserve, SMALL_CAP_BPS, 10_000), 'a reserve-sized cap would have allowed it');
		emit log_named_decimal_uint('BRETT WETH reserve (USD)      ', reserve, 18);
		emit log_named_decimal_uint('BRETT band recorded (USD)     ', band, 18);
		emit log_named_decimal_uint('cap: 10% of the band (USD)    ', cap, 18);
		emit log_named_decimal_uint('held after first buy (USD)    ', held, 18);
		emit log_named_decimal_uint('holding refused (USD)         ', holding, 18);
	}

	/// @dev The fund owner buys BRETT for `usdcIn`: USDC → WETH on Uniswap's 0.05% pool, then WETH →
	///      BRETT on BRETT's Uniswap 1% pool — a separate market, so the listed Slipstream pool's spot
	///      (and its TWAP guard) stays put. With `expectRevert`, the second leg must revert; its
	///      revert data is returned.
	function _buyBrett(Comptroller fund, uint256 usdcIn, bool expectRevert) internal returns (bytes memory err) {
		address vault = address(fund.vault());
		uint256 wethBefore = IERC20(WETH).balanceOf(vault);
		vm.prank(manager);
		fund.callOnIntegration(uniAdapter, abi.encode(USDC, WETH, uint24(500), usdcIn, uint256(0)));
		uint256 wethIn = IERC20(WETH).balanceOf(vault) - wethBefore;
		assertEq(IUniswapV3PoolFactory(FundsMainnet.UNI_FACTORY).getPool(BRETT, WETH, 10000), BRETT_WETH_UNI_10000);
		bytes memory leg = abi.encode(WETH, BRETT, uint24(10000), wethIn, uint256(0));
		if (expectRevert) {
			return _revertData(manager, address(fund), abi.encodeCall(Comptroller.callOnIntegration, (uniAdapter, leg)));
		}
		vm.prank(manager);
		fund.callOnIntegration(uniAdapter, leg);
	}

	// ─── F2 / Ruling 23: the floor is two-part ───────────────────────────────────

	/// @notice A pool's quote balance is not its bids: CHECK's Slipstream-2 USDC pool holds ~$300k
	///         of USDC, but only ~$512 of it within −10% of the price. It prices, its oracle ring is
	///         long, its reserve clears $25k many times over — and the band floor refuses it, with
	///         the band it read.
	function test_fork_thinBandRefusedAtListing() public {
		vm.skip(!forked);
		assertFalse(vi.isSupportedAsset(CHECK));
		assertEq(ISlipstreamPoolFactory(FundsMainnet.CL2_FACTORY).getPool(CHECK, USDC, 100), CHECK_USDC_SLIP2_100);
		// the registry's own adapter parameters, through its (permissionless) deployer
		(, uint32 heartbeat) = d.registry.quotes(USDC);
		TwapAggregatorAdapterV2 probe = TwapAggregatorAdapterV2(
			d.clDeployer.deploy(
				IConcentratedPoolOracle(CHECK_USDC_SLIP2_100),
				CHECK,
				AggregatorV3Interface(CL_USDC_USD),
				d.registry.WINDOW(),
				d.registry.MIN_QUOTE_RESERVE_USD(),
				d.registry.MAX_DEVIATION_BPS(),
				heartbeat,
				'probe'
			)
		);
		(, int256 price,,,) = probe.latestRoundData();
		assertGt(price, 0, 'it prices: neither the window nor the spot guard refuses it');
		uint256 reserve = probe.quoteReserveUsd();
		uint256 band = probe.poolDepthUsd();
		emit log_named_decimal_uint('CHECK USDC reserve (USD)', reserve, 18);
		emit log_named_decimal_uint('CHECK band (USD)        ', band, 18);
		assertEq(reserve, _usd18(IERC20(USDC).balanceOf(CHECK_USDC_SLIP2_100), USDC, CL_USDC_USD), 'the USDC it holds');
		assertGe(reserve, RESERVE_FLOOR_USD18, 'the reserve alone would list it');
		assertLt(band, BAND_FLOOR_USD18, 'under the band floor');

		bytes memory err = _revertData(keeper, address(d.module), abi.encodeCall(PriceListingModule.list, (CHECK, USDC, SLIP2, 100)));
		assertEq(_selector(err), TwapListingRegistryV2.BandBelowFloorAtListing.selector, 'refused on its band');
		assertEq(abi.decode(_args(err), (uint256)), band, 'with the band it read');
		assertFalse(vi.isSupportedAsset(CHECK));
		assertEq(d.registry.listedCount(), 0);
	}

	/// @notice F2 on a real pool, the way a rugger does it. VIRTUAL's QUIET Uniswap USDC 1% pool
	///         (427 USDC at block 52014634) gets the keeper's oracle-ring prep, then a rugger's
	///         position minted through the real NonfungiblePositionManager — most of the liquidity
	///         near spot. A window later it holds both parts of the floor and the keeper lists it.
	///         The rugger then removes ALL its liquidity WITHOUT collecting: the USDC stays in the
	///         pool as the position's tokensOwed, so the quote reserve (the pool's balance) still
	///         reads over $25k — a reserve-only floor never starts the clock, and a zero-liquidity
	///         pool's TWAP moves with dust — while nothing is left within −10% of the price. The band
	///         floor sees it: isBelowFloor(), the lens and a stranger's poke all report it, and the
	///         clock starts. Collecting then takes the "reserve" with it.
	function test_fork_ruggedConcentratedPoolStartsClock() public {
		vm.skip(!forked);
		assertEq(d.registry.MIN_BAND_DEPTH_USD() * 1e18, BAND_FLOOR_USD18);
		Rug memory g;
		TwapAggregatorAdapterV2 adapter = _listRuggablePool(g);
		assertEq(adapter.minBandDepthUsd(), d.registry.MIN_BAND_DEPTH_USD(), 'the adapter derives the same band floor');
		_rugWithoutCollecting(g);

		g.reserveRugged = adapter.quoteReserveUsd();
		g.bandRugged = adapter.poolDepthUsd();
		bool readsBelow = adapter.isBelowFloor();
		(address[] memory due,) = d.lens.assetsNeedingPoke(d.registry, 0, 10);
		vm.prank(stranger);
		bool pokedBelow = d.registry.pokeFloor(VIRTUAL);
		_logRug(g, readsBelow, due.length, pokedBelow);

		// what a reserve-only floor saw: the uncollected USDC still reads over $25k
		assertGe(g.reserveRugged, RESERVE_FLOOR_USD18, 'the uncollected USDC keeps the reserve over $25k');
		assertApproxEqAbs(
			g.reserveRugged, g.quietReserve + _usd18(g.usdcOwed, USDC, CL_USDC_USD), 0.01e18, 'the quiet pool + the owed USDC'
		);
		// what the band floor sees: no bids
		assertLt(g.bandRugged, BAND_FLOOR_USD18, 'nothing within -10%');
		assertTrue(readsBelow, 'isBelowFloor() sees the rug');
		assertEq(due, _addrs(VIRTUAL), 'the lens flags it');
		assertTrue(pokedBelow, "a stranger's poke reports it");
		assertEq(_clockOf(VIRTUAL), block.timestamp, 'and starts the clock');

		// collecting takes the "reserve" with it: it was the rugger's owed USDC all along
		vm.prank(g.rugger);
		IUniswapV3NonfungiblePositionManager(UNI_NPM).collect(
			IUniswapV3NonfungiblePositionManager.CollectParams({
				tokenId: g.tokenId, recipient: g.rugger, amount0Max: type(uint128).max, amount1Max: type(uint128).max
			})
		);
		uint256 reserveCollected = adapter.quoteReserveUsd();
		emit log_named_decimal_uint('collected: reserve (USD)       ', reserveCollected, 18);
		assertApproxEqAbs(reserveCollected, g.quietReserve, 0.01e18, 'back to the quiet pool');
		skip(d.registry.DELIST_GRACE());
		assertTrue(d.registry.isDelisted(VIRTUAL), '72 hours on: delisted');
	}

	/// @dev The rug scenario's state, in memory (the stack can't hold it).
	struct Rug {
		address rugger;
		uint256 tokenId;
		uint128 liquidity;
		uint256 quietReserve;
		uint256 reserveListed;
		uint256 bandListed;
		uint256 usdcOwed;
		uint256 reserveRugged;
		uint256 bandRugged;
	}

	/// @dev The keeper's ring prep on the quiet pool (its ring holds 10), the rugger's position
	///      around spot, and — a window later, the pool holding the floor on both reads — the
	///      keeper's listing.
	function _listRuggablePool(Rug memory g) internal returns (TwapAggregatorAdapterV2 adapter) {
		address pool = VIRTUAL_USDC_10000;
		assertEq(IUniswapV3PoolFactory(FundsMainnet.UNI_FACTORY).getPool(VIRTUAL, USDC, 10000), pool);
		g.quietReserve = _usd18(IERC20(USDC).balanceOf(pool), USDC, CL_USDC_USD);
		assertLt(g.quietReserve, BAND_FLOOR_USD18, 'a quiet pool');

		_prepareOracle(pool);
		g.rugger = makeAddr('rugger');
		uint256 usdcIn;
		(g.tokenId, g.liquidity, usdcIn) = _mintAroundSpot(pool, USDC, g.rugger, RUG_USDC);
		assertApproxEqAbs(usdcIn, RUG_USDC, 1, 'the USDC side bound the mint');

		_warpRoll(V2_WARP);
		adapter = _list(VIRTUAL, USDC, UNI, 10000);
		g.reserveListed = adapter.quoteReserveUsd();
		g.bandListed = d.registry.recordedDepthUsd18(VIRTUAL);
		assertGe(g.reserveListed, RESERVE_FLOOR_USD18);
		assertGe(g.bandListed, BAND_FLOOR_USD18);
		assertFalse(adapter.isBelowFloor());
	}

	/// @dev The rug: every unit of the rugger's liquidity out through the real NPM, nothing
	///      collected — the USDC stays in the pool as the position's tokensOwed.
	function _rugWithoutCollecting(Rug memory g) internal {
		IUniswapV3NonfungiblePositionManager npm = IUniswapV3NonfungiblePositionManager(UNI_NPM);
		uint256 poolUsdc = IERC20(USDC).balanceOf(VIRTUAL_USDC_10000);
		vm.prank(g.rugger);
		(, uint256 usdcFreed) = npm.decreaseLiquidity(
			IUniswapV3NonfungiblePositionManager.DecreaseLiquidityParams({
				tokenId: g.tokenId, liquidity: g.liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
			})
		);
		(,,,,,,, uint128 left,,,, uint128 owed1) = npm.positions(g.tokenId);
		g.usdcOwed = owed1;
		assertEq(left, 0, 'all liquidity removed');
		assertEq(g.usdcOwed, usdcFreed, 'owed to the rugger, uncollected');
		assertEq(IERC20(USDC).balanceOf(VIRTUAL_USDC_10000), poolUsdc, 'not one USDC left the pool');
	}

	function _logRug(Rug memory g, bool readsBelow, uint256 flagged, bool pokedBelow) internal {
		emit log_named_decimal_uint('quiet pool USDC (USD)          ', g.quietReserve, 18);
		emit log_named_decimal_uint('listed: reserve (USD)          ', g.reserveListed, 18);
		emit log_named_decimal_uint('listed: band recorded (USD)    ', g.bandListed, 18);
		emit log_named_decimal_uint('rugged: USDC owed, uncollected ', _usd18(g.usdcOwed, USDC, CL_USDC_USD), 18);
		emit log_named_decimal_uint('rugged: reserve (USD)          ', g.reserveRugged, 18);
		emit log_named_decimal_uint('rugged: band (USD)             ', g.bandRugged, 18);
		emit log_named_string('rugged: isBelowFloor()         ', readsBelow ? 'true' : 'false');
		emit log_named_uint('rugged: lens flags (count)     ', flagged);
		emit log_named_string("rugged: stranger's pokeFloor   ", pokedBelow ? 'true (clock started)' : 'false (no clock)');
	}

	/// @dev `who` mints a two-sided position of `quoteIn` of `quote` (and as much of the other token
	///      as that needs) on the ten tick spacings either side of spot, through the real Uniswap v3
	///      NonfungiblePositionManager.
	function _mintAroundSpot(address pool, address quote, address who, uint256 quoteIn)
		internal
		returns (uint256 tokenId, uint128 liquidity, uint256 quotePaid)
	{
		IUniswapV3NonfungiblePositionManager.MintParams memory p = _aroundSpot(pool, quote, who, quoteIn);
		vm.startPrank(who);
		IERC20(p.token0).approve(UNI_NPM, p.amount0Desired);
		IERC20(p.token1).approve(UNI_NPM, p.amount1Desired);
		uint256 paid0;
		uint256 paid1;
		(tokenId, liquidity, paid0, paid1) = IUniswapV3NonfungiblePositionManager(UNI_NPM).mint(p);
		vm.stopPrank();
		quotePaid = quote == p.token0 ? paid0 : paid1;
	}

	/// @dev Mint parameters for `who` on `pool`: ten spacings either side of spot, `quoteIn` of
	///      `quote` and 100M of the other token, both dealt to `who`.
	function _aroundSpot(address pool, address quote, address who, uint256 quoteIn)
		internal
		returns (IUniswapV3NonfungiblePositionManager.MintParams memory p)
	{
		p.token0 = IConcentratedPoolOracle(pool).token0();
		p.token1 = IConcentratedPoolOracle(pool).token1();
		p.fee = IUniswapV3PoolFee(pool).fee();
		(, int24 spot) = _slot0(pool);
		int24 spacing = IConcentratedPoolOracle(pool).tickSpacing();
		int24 c = spot / spacing;
		if (spot < 0 && spot % spacing != 0) c--;
		p.tickLower = (c - 10) * spacing;
		p.tickUpper = (c + 11) * spacing;
		address asset = quote == p.token0 ? p.token1 : p.token0;
		uint256 assetIn = 100_000_000 * 10 ** IERC20Metadata(asset).decimals();
		(p.amount0Desired, p.amount1Desired) = quote == p.token0 ? (quoteIn, assetIn) : (assetIn, quoteIn);
		deal(quote, who, quoteIn);
		deal(asset, who, assetIn);
		p.recipient = who;
		p.deadline = block.timestamp;
	}

	// ─── delist clock ────────────────────────────────────────────────────────────

	/// @notice Ruling 12b: the keeper's poke through the module reports `below`, records live
	///         depth, and is the only poke that clears a clock once the pool has really recovered.
	///         VIRTUAL on its Slipstream WETH ts200 pool, which real sells can empty (its USDC 0.3%
	///         pool can't be put under the floor; see the contract natspec).
	function test_fork_keeperPokeClearsAndRecords() public {
		vm.skip(!forked);
		TwapAggregatorAdapterV2 adapter = _list(VIRTUAL, WETH, SLIP, 200);
		vm.prank(stranger);
		vm.expectRevert(PriceListingModule.NotKeeper.selector);
		d.module.pokeFloor(VIRTUAL);

		// healthy
		vm.prank(keeper);
		assertFalse(d.module.pokeFloor(VIRTUAL));
		assertEq(_clockOf(VIRTUAL), 0);
		assertEq(d.registry.recordedDepthUsd18(VIRTUAL), adapter.poolDepthUsd());

		// real sells: under the floor, the keeper's poke starts the clock and records the shortfall
		(uint160 sqrtBefore,) = _slot0(VIRTUAL_WETH_SLIP_200);
		_sellAsset(adapter, UNDER_FLOOR_TICKS);
		vm.prank(keeper);
		assertTrue(d.module.pokeFloor(VIRTUAL));
		uint64 since = _clockOf(VIRTUAL);
		assertEq(since, block.timestamp);
		uint256 shortfall = adapter.poolDepthUsd();
		assertEq(d.registry.recordedDepthUsd18(VIRTUAL), shortfall);
		uint256 reserveUnder = adapter.quoteReserveUsd();
		assertLt(reserveUnder, RESERVE_FLOOR_USD18);

		// a later block buys the price back to where it was, then the window rolls past the dip
		// (1,862 s in all: ETH / USD, last updated 1,150 s before block 52014634, stays inside 3,600 s)
		vm.roll(block.number + 1);
		vm.warp(block.timestamp + 2);
		_buyBack(adapter, sqrtBefore);
		vm.roll(block.number + 930);
		vm.warp(block.timestamp + 31 minutes);
		assertFalse(adapter.isBelowFloor(), 'the pool really recovered');
		uint256 recovered = adapter.poolDepthUsd();

		// a stranger's poke can't clear it (nor record)
		vm.prank(stranger);
		assertFalse(d.registry.pokeFloor(VIRTUAL));
		assertEq(_clockOf(VIRTUAL), since);
		assertEq(d.registry.recordedDepthUsd18(VIRTUAL), shortfall);

		// the keeper's does, and records the live depth
		vm.expectEmit(true, false, false, true, address(d.registry));
		emit TwapListingRegistryV2.FloorRestored(VIRTUAL);
		vm.expectEmit(true, false, false, true, address(d.registry));
		emit TwapListingRegistryV2.DepthRecorded(VIRTUAL, recovered);
		vm.prank(keeper);
		assertFalse(d.module.pokeFloor(VIRTUAL));
		assertEq(_clockOf(VIRTUAL), 0);
		assertEq(d.registry.recordedDepthUsd18(VIRTUAL), recovered);
		assertGe(adapter.quoteReserveUsd(), RESERVE_FLOOR_USD18);
		assertGe(recovered, OLD_BAND_FLOOR_USD18);
		emit log_named_decimal_uint('reserve after sells (USD)   ', reserveUnder, 18);
		emit log_named_decimal_uint('depth after sells (USD)     ', shortfall, 18);
		emit log_named_decimal_uint('reserve after recovery (USD)', adapter.quoteReserveUsd(), 18);
		emit log_named_decimal_uint('depth after recovery (USD)  ', recovered, 18);
	}

	// ─── lens ────────────────────────────────────────────────────────────────────

	function test_fork_lensPagesRealListings() public {
		vm.skip(!forked);
		_list(VIRTUAL, USDC, UNI, 3000);
		TwapAggregatorAdapterV2 lcap = _list(LCAP, WETH, SLIP, 200);
		_prepareOracle(USDL_USDC_SLIP3_50);
		_list(USDL, USDC, SLIP3, 50);
		assertEq(d.registry.listedCount(), 3);

		(address[] memory due, uint256 next) = d.lens.assetsNeedingPoke(d.registry, 0, 2);
		assertEq(next, 2);
		assertEq(due.length, 0);
		(due, next) = d.lens.assetsNeedingPoke(d.registry, 2, 2);
		assertEq(next, 3);
		assertEq(due.length, 0);
		(due, next) = d.lens.assetsNeedingPoke(d.registry, 3, 2);
		assertEq(next, 3, 'past the end: done');
		assertEq(due.length, 0);

		// real sells put LCAP's WETH reserve under the floor: the lens reports it on its page only
		_sellAsset(lcap, UNDER_FLOOR_TICKS);
		uint256 g = gasleft();
		(due, next) = d.lens.assetsNeedingPoke(d.registry, 0, 2);
		uint256 pageGas = g - gasleft();
		assertEq(next, 2);
		assertEq(due.length, 1);
		assertEq(due[0], LCAP);
		(due,) = d.lens.assetsNeedingPoke(d.registry, 2, 2);
		assertEq(due.length, 0);

		// once the clock matches the pool, nothing is due
		vm.prank(stranger);
		d.registry.pokeFloor(LCAP);
		(due,) = d.lens.assetsNeedingPoke(d.registry, 0, 3);
		assertEq(due.length, 0);
		emit log_named_decimal_uint('LCAP WETH reserve after sells', lcap.quoteReserveUsd(), 18);
		emit log_named_uint('lens page (2 real listings) gas', pageGas);
	}

	/// @notice One listing per pool kind — concentrated (VVV, Uniswap v3), Uniswap v2 (AGNT) and
	///         Aerodrome basic (AWE) — paged two at a time. Real sells take each quote reserve under
	///         the floor in turn and the lens flags exactly that asset, on its own page; strangers'
	///         pokes start the clocks and clear the flags; a real buy-back restores the v2 pool, the
	///         lens flags it as clearable, and only the keeper's poke clears it.
	function test_fork_lensPagesAcrossVenues() public {
		vm.skip(!forked);
		assertTrue(d.recorder.record(AGNT_USDC_V2));
		_warpRoll(V2_WARP);
		TwapAggregatorAdapterV2 vvv = _list(VVV, USDC, UNI, 3000);
		ITwapPriceAdapter agnt = _listAny(AGNT, USDC, UNIV2, 0);
		ITwapPriceAdapter awe = _listAny(AWE, USDC, AERO, 0);
		assertEq(d.registry.listedCount(), 3);
		address[] memory none = new address[](0);
		// pages [VVV, AGNT] and [AWE]
		_assertPage(0, none, 2);
		_assertPage(2, none, 3);
		_assertPage(3, none, 3);

		// Aerodrome basic: real sells take AWE's USDC reserve under the floor
		_dumpAerodrome(AWE_USDC_AERO, AWE, USDC);
		assertTrue(awe.isBelowFloor());
		_assertPage(0, none, 2);
		_assertPage(2, _addrs(AWE), 3);
		// Uniswap v2: AGNT
		uint256 usdcOut = _dumpV2(AGNT_USDC_V2, AGNT, USDC);
		assertTrue(agnt.isBelowFloor());
		_assertPage(0, _addrs(AGNT), 2);
		_assertPage(2, _addrs(AWE), 3);
		// concentrated: VVV, flagged in listing order
		_sellAsset(vvv, UNDER_FLOOR_TICKS);
		assertTrue(vvv.isBelowFloor());
		uint256 g = gasleft();
		_assertPage(0, _addrs(VVV, AGNT), 2);
		uint256 pageGas = g - gasleft();
		_assertPage(2, _addrs(AWE), 3);
		emit log_named_decimal_uint('VVV reserve after sells (USD) ', vvv.quoteReserveUsd(), 18);
		emit log_named_decimal_uint('AGNT reserve after sells (USD)', agnt.quoteReserveUsd(), 18);
		emit log_named_decimal_uint('AWE reserve after sells (USD) ', awe.quoteReserveUsd(), 18);

		// a stranger starts every clock: nothing is due
		vm.startPrank(stranger);
		assertTrue(d.registry.pokeFloor(VVV));
		assertTrue(d.registry.pokeFloor(AGNT));
		assertTrue(d.registry.pokeFloor(AWE));
		vm.stopPrank();
		_assertPage(0, none, 2);
		_assertPage(2, none, 3);

		// real buys restore AGNT's reserve: flagged again (a clock to clear), until the keeper pokes
		_buyBackV2(AGNT_USDC_V2, AGNT, USDC, usdcOut);
		assertFalse(agnt.isBelowFloor());
		_assertPage(0, _addrs(AGNT), 2);
		vm.prank(stranger);
		assertFalse(d.registry.pokeFloor(AGNT));
		_assertPage(0, _addrs(AGNT), 2);
		vm.prank(keeper);
		assertFalse(d.module.pokeFloor(AGNT));
		assertEq(_clockOf(AGNT), 0);
		_assertPage(0, none, 2);
		_assertPage(2, none, 3);
		emit log_named_decimal_uint('AGNT reserve after buy-back   ', agnt.quoteReserveUsd(), 18);
		emit log_named_uint('lens page (CL + v2 listings) gas', pageGas);
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	function _list(address asset, address quote, TwapListingRegistryV2.Venue venue, int24 feeOrTickSpacing)
		internal
		returns (TwapAggregatorAdapterV2)
	{
		vm.prank(keeper);
		return TwapAggregatorAdapterV2(d.module.list(asset, quote, venue, feeOrTickSpacing));
	}

	function _repoint(address asset, address quote, TwapListingRegistryV2.Venue venue, int24 feeOrTickSpacing)
		internal
		returns (TwapAggregatorAdapterV2)
	{
		vm.prank(keeper);
		return TwapAggregatorAdapterV2(d.module.repoint(asset, quote, venue, feeOrTickSpacing));
	}

	function _poolOf(address asset) internal view returns (address pool) {
		(, pool,,,) = d.registry.listings(asset);
	}

	function _clockOf(address asset) internal view returns (uint64 since) {
		(,,,, since) = d.registry.listings(asset);
	}

	/// @dev The revert data of `target.call(data)` sent by `sender`; the call must fail.
	function _revertData(address sender, address target, bytes memory data) internal returns (bytes memory) {
		if (sender != address(this)) vm.prank(sender);
		(bool ok, bytes memory ret) = target.call(data);
		assertFalse(ok, 'expected a revert');
		return ret;
	}

	function _selector(bytes memory err) internal pure returns (bytes4 sel) {
		assertGe(err.length, 4, 'revert data carries a selector');
		assembly ('memory-safe') {
			sel := and(mload(add(err, 32)), shl(224, 0xffffffff))
		}
	}

	function _args(bytes memory err) internal pure returns (bytes memory args) {
		args = new bytes(err.length - 4);
		for (uint256 i; i < args.length; ++i) {
			args[i] = err[i + 4];
		}
	}

	function _notDeepEnough(bytes memory err) internal pure returns (uint256 current, uint256 next) {
		assertEq(_selector(err), TwapListingRegistryV2.NotDeepEnough.selector);
		(current, next) = abi.decode(_args(err), (uint256, uint256));
	}

	function _poolShareExceeded(bytes memory err, address expectedAsset)
		internal
		pure
		returns (uint256 holding, uint256 cap)
	{
		assertEq(_selector(err), TwapExposurePolicyV2.PoolShareExceeded.selector);
		address asset;
		(asset, holding, cap) = abi.decode(_args(err), (address, uint256, uint256));
		assertEq(asset, expectedAsset);
	}

	/// @dev The spec: 10% of the depth, 50% once it is ≥ $250k.
	function _capUsd18(uint256 depthUsd18) internal pure returns (uint256) {
		return Math.mulDiv(depthUsd18, depthUsd18 < LARGE_POOL_USD18 ? SMALL_CAP_BPS : LARGE_CAP_BPS, 10_000);
	}

	function _chainlinkUsd18(address feed) internal view returns (uint256) {
		(, int256 answer,,,) = AggregatorV3Interface(feed).latestRoundData();
		return SafeCast.toUint256(answer) * 10 ** (18 - AggregatorV3Interface(feed).decimals());
	}

	/// @dev (sqrtPriceX96, tick) — the first two words of slot0 on Uniswap v3 and Slipstream alike.
	function _slot0(address pool) internal view returns (uint160 sqrtPriceX96, int24 tick) {
		(bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature('slot0()'));
		assertTrue(ok);
		(sqrtPriceX96, tick) = abi.decode(data, (uint160, int24));
	}

	/// @dev What the keeper does before listing a pool whose oracle ring is short: ask for
	///      ORACLE_RING observations, then real observation writes until the ring has grown — a
	///      pool grows its ring only on a write at the ring's last slot, which for cardinality 1 is
	///      the very next write (VIRTUAL_USDC_10000, ring 10 at index 0: the tenth).
	function _prepareOracle(address pool) internal {
		IOracleRing(pool).increaseObservationCardinalityNext(ORACLE_RING);
		uint16 ring = _cardinality(pool);
		for (uint256 i; i < ring && _cardinality(pool) < ORACLE_RING; ++i) {
			_writeObservation(pool);
		}
		assertGe(_cardinality(pool), ORACLE_RING, 'the ring grew');
	}

	/// @dev slot0's observationCardinality (fourth word on Uniswap v3 and Slipstream alike).
	function _cardinality(address pool) internal view returns (uint16 cardinality) {
		(bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature('slot0()'));
		assertTrue(ok);
		(,,, cardinality) = abi.decode(data, (uint160, int24, uint16, uint16));
	}

	/// @dev One real observation write. Pools write at most once a block, so a pool that already
	///      wrote this block is written one block later. On Uniswap v3: a dust position minted
	///      around the current tick through the real NPM (an in-range mint writes without moving the
	///      price — a tick-moving swap into a one-sided pool like LUMIA's would have to buy through
	///      its whole in-range asset side and deepen the quote side it is meant to measure). On
	///      Slipstream: a swap through the venue's router moving the tick down by one.
	function _writeObservation(address pool) internal {
		(bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature('slot0()'));
		assertTrue(ok);
		(, int24 tick, uint16 index) = abi.decode(data, (uint160, int24, uint16));
		(uint32 newest,,,) = IOracleRing(pool).observations(index);
		if (newest == block.timestamp) {
			vm.roll(block.number + 1);
			vm.warp(block.timestamp + 2);
		}
		if (IOracleRing(pool).factory() == FundsMainnet.UNI_FACTORY) {
			_mintInRangeDust(pool, tick);
			(, int24 tickAfter) = _slot0(pool);
			assertEq(tickAfter, tick, 'an in-range mint leaves the price alone');
		} else {
			_swapToken0Down(pool, TickMath.getSqrtRatioAtTick(tick - 1));
			(, int24 tickAfter) = _slot0(pool);
			assertEq(tickAfter, tick - 1, 'the tick moved: the pool wrote an observation');
		}
		(, bytes memory after_) = pool.staticcall(abi.encodeWithSignature('slot0()'));
		(,, uint16 indexAfter) = abi.decode(after_, (uint160, int24, uint16));
		assertTrue(indexAfter != index, 'an observation was written');
	}

	/// @dev A millionth of a token of each side, in the spacing-wide range holding the current tick.
	function _mintInRangeDust(address pool, int24 tick) internal {
		address token0 = IConcentratedPoolOracle(pool).token0();
		address token1 = IConcentratedPoolOracle(pool).token1();
		int24 spacing = IConcentratedPoolOracle(pool).tickSpacing();
		int24 lower = tick / spacing;
		if (tick < 0 && tick % spacing != 0) lower--;
		lower *= spacing;
		uint256 amount0 = 10 ** IERC20Metadata(token0).decimals() / 1e6;
		uint256 amount1 = 10 ** IERC20Metadata(token1).decimals() / 1e6;
		deal(token0, address(this), amount0);
		deal(token1, address(this), amount1);
		IERC20(token0).approve(UNI_NPM, amount0);
		IERC20(token1).approve(UNI_NPM, amount1);
		(, uint128 liquidity,,) = IUniswapV3NonfungiblePositionManager(UNI_NPM).mint(
			IUniswapV3NonfungiblePositionManager.MintParams({
				token0: token0,
				token1: token1,
				fee: IUniswapV3PoolFee(pool).fee(),
				tickLower: lower,
				tickUpper: lower + spacing,
				amount0Desired: amount0,
				amount1Desired: amount1,
				amount0Min: 0,
				amount1Min: 0,
				recipient: address(this),
				deadline: block.timestamp
			})
		);
		assertGt(liquidity, 0);
	}

	/// @dev Real sells of a Slipstream `pool`'s token0 until its price reaches `limit`, through the
	///      router of the pool's own deployment.
	function _swapToken0Down(address pool, uint160 limit) internal {
		address token0 = IConcentratedPoolOracle(pool).token0();
		address token1 = IConcentratedPoolOracle(pool).token1();
		uint256 amount = 1_000_000 * 10 ** IERC20Metadata(token0).decimals();
		deal(token0, address(this), amount);
		address venueFactory = IOracleRing(pool).factory();
		address router = venueFactory == FundsMainnet.CL_FACTORY
			? FundsMainnet.CL_SWAP_ROUTER
			: (venueFactory == FundsMainnet.CL2_FACTORY ? FundsMainnet.CL2_SWAP_ROUTER : TwapListingV2.CL3_SWAP_ROUTER);
		assertTrue(venueFactory == FundsMainnet.CL_FACTORY || venueFactory == FundsMainnet.CL2_FACTORY || venueFactory == TwapListingV2.CL3_FACTORY);
		IERC20(token0).approve(router, amount);
		ISlipstreamSwapRouter(router).exactInputSingle(
			ISlipstreamSwapRouter.ExactInputSingleParams({
				tokenIn: token0,
				tokenOut: token1,
				tickSpacing: IConcentratedPoolOracle(pool).tickSpacing(),
				recipient: address(this),
				deadline: block.timestamp,
				amountIn: amount,
				amountOutMinimum: 0,
				sqrtPriceLimitX96: limit
			})
		);
	}

	/// @dev USD (18 dp) per whole `asset` at `pool`'s CURRENT spot × `quoteFeed`: an independent
	///      path to the adapter's TWAP × feed.
	function _spotUsd18(address pool, address asset, address quote, address quoteFeed) internal view returns (uint256) {
		(uint160 sqrtPriceX96,) = _slot0(pool);
		uint256 unit = 10 ** IERC20Metadata(asset).decimals();
		uint256 ratioX128 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64); // token1 per token0
		uint256 quotePerAsset =
			asset < quote ? Math.mulDiv(ratioX128, unit, 1 << 128) : Math.mulDiv(1 << 128, unit, ratioX128);
		return Math.mulDiv(quotePerAsset, _chainlinkUsd18(quoteFeed), 10 ** IERC20Metadata(quote).decimals());
	}

	/// @dev No pool of `asset` vs USDC/WETH at a listable spacing on Uniswap v3, Slipstream or Slipstream-2.
	function _assertNoPoolOffSlipstream3(address asset) internal view {
		address[2] memory quotes = [USDC, WETH];
		uint24[3] memory fees = [uint24(500), 3000, 10000];
		int24[8] memory spacings = [int24(10), 50, 80, 100, 150, 200, 500, 2000];
		for (uint256 q; q < 2; ++q) {
			for (uint256 f; f < 3; ++f) {
				assertEq(IUniswapV3PoolFactory(FundsMainnet.UNI_FACTORY).getPool(asset, quotes[q], fees[f]), address(0));
			}
			for (uint256 s; s < 8; ++s) {
				assertEq(ISlipstreamPoolFactory(FundsMainnet.CL_FACTORY).getPool(asset, quotes[q], spacings[s]), address(0));
				assertEq(ISlipstreamPoolFactory(FundsMainnet.CL2_FACTORY).getPool(asset, quotes[q], spacings[s]), address(0));
			}
		}
	}

	/// @dev Real sells of `asset` into its Uniswap v3 pool vs `quote` through SwapRouter02 until
	///      spot has moved `ticks` against the asset (a price limit), `deal`ing the asset. Returns
	///      the amount sold.
	function _sellInto(address asset, address quote, uint24 fee, int24 ticks) internal returns (uint256 sold) {
		address pool = IUniswapV3PoolFactory(FundsMainnet.UNI_FACTORY).getPool(asset, quote, fee);
		(, int24 spot) = _slot0(pool);
		// selling token0 lowers the tick, selling token1 raises it
		int24 limitTick = asset < quote ? spot - ticks : spot + ticks;
		uint256 amount = 100_000_000 * 10 ** IERC20Metadata(asset).decimals();
		deal(asset, address(this), amount);
		IERC20(asset).approve(UNI_ROUTER, amount);
		IUniswapV3SwapRouter(UNI_ROUTER).exactInputSingle(
			IUniswapV3SwapRouter.ExactInputSingleParams({
				tokenIn: asset,
				tokenOut: quote,
				fee: fee,
				recipient: address(this),
				amountIn: amount,
				amountOutMinimum: 0,
				sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(limitTick)
			})
		);
		sold = amount - IERC20(asset).balanceOf(address(this));
		(uint160 sqrtAfter,) = _slot0(pool);
		assertEq(sqrtAfter, TickMath.getSqrtRatioAtTick(limitTick), 'the sells reached the limit');
	}

	/// @dev Real sells of `adapter`'s asset into its pool until spot has moved `ticks` against the
	///      asset: Uniswap v3 through SwapRouter02 (`_sellInto`), Slipstream through the router of the
	///      pool's own deployment. Returns the amount sold.
	function _sellAsset(TwapAggregatorAdapterV2 adapter, int24 ticks) internal returns (uint256 sold) {
		address pool = address(adapter.pool());
		address asset = adapter.asset();
		address venueFactory = IOracleRing(pool).factory();
		if (venueFactory == FundsMainnet.UNI_FACTORY) {
			return _sellInto(asset, adapter.quoteAsset(), IUniswapV3PoolFee(pool).fee(), ticks);
		}
		(, int24 spot) = _slot0(pool);
		uint160 limit = TickMath.getSqrtRatioAtTick(adapter.assetIsToken0() ? spot - ticks : spot + ticks);
		uint256 amount = 100_000_000 * 10 ** IERC20Metadata(asset).decimals();
		deal(asset, address(this), amount);
		address router = _slipstreamRouter(venueFactory);
		IERC20(asset).approve(router, amount);
		ISlipstreamSwapRouter(router).exactInputSingle(
			ISlipstreamSwapRouter.ExactInputSingleParams({
				tokenIn: asset,
				tokenOut: adapter.quoteAsset(),
				tickSpacing: IConcentratedPoolOracle(pool).tickSpacing(),
				recipient: address(this),
				deadline: block.timestamp,
				amountIn: amount,
				amountOutMinimum: 0,
				sqrtPriceLimitX96: limit
			})
		);
		sold = amount - IERC20(asset).balanceOf(address(this));
		(uint160 sqrtAfter,) = _slot0(pool);
		assertEq(sqrtAfter, limit, 'the sells reached the limit');
	}

	/// @dev The swap router of a Slipstream deployment, by its pool factory.
	function _slipstreamRouter(address venueFactory) internal pure returns (address) {
		if (venueFactory == FundsMainnet.CL_FACTORY) return FundsMainnet.CL_SWAP_ROUTER;
		if (venueFactory == FundsMainnet.CL2_FACTORY) return FundsMainnet.CL2_SWAP_ROUTER;
		assertEq(venueFactory, TwapListingV2.CL3_FACTORY, 'a Slipstream deployment');
		return TwapListingV2.CL3_SWAP_ROUTER;
	}

	/// @dev Whether real sells moving spot `ticks` against the asset leave the pool under the floor
	///      (two-part since Ruling 23; on the pools used here the QUOTE RESERVE crosses first — the
	///      pushes found are the same as under the reserve-only floor); the state is rolled back.
	function _belowAfterSells(TwapAggregatorAdapterV2 adapter, int24 ticks) internal returns (bool below) {
		uint256 snap = vm.snapshotState();
		_sellAsset(adapter, ticks);
		below = adapter.isBelowFloor();
		vm.revertToState(snap);
	}

	/// @dev Real sells that leave `adapter`'s pool JUST under the floor: the smallest push (to the
	///      tick) whose quote reserve reads under $25k. Selling the asset pays quote out of the pool,
	///      so the push is bracketed by doubling, then binary-searched over snapshots.
	function _sellJustUnderFloor(TwapAggregatorAdapterV2 adapter) internal returns (int24 push) {
		assertFalse(adapter.isBelowFloor());
		int24 over;
		int24 under = 1_000;
		while (!_belowAfterSells(adapter, under)) {
			over = under;
			under *= 2;
			assertLe(under, 256_000, 'real sells reach the floor');
		}
		while (under - over > 1) {
			int24 mid = (over + under) / 2;
			if (_belowAfterSells(adapter, mid)) under = mid;
			else over = mid;
		}
		_sellAsset(adapter, under);
		assertTrue(adapter.isBelowFloor());
		push = under;
	}

	/// @dev Real buys of `adapter`'s asset with its quote token, through the router of the pool's
	///      own Slipstream deployment, until the pool is back at `sqrtTarget` exactly.
	function _buyBack(TwapAggregatorAdapterV2 adapter, uint160 sqrtTarget) internal {
		address pool = address(adapter.pool());
		address quote = adapter.quoteAsset();
		address router = _slipstreamRouter(IOracleRing(pool).factory());
		uint256 amount = 100_000_000 * 10 ** IERC20Metadata(quote).decimals();
		deal(quote, address(this), amount);
		IERC20(quote).approve(router, amount);
		ISlipstreamSwapRouter(router).exactInputSingle(
			ISlipstreamSwapRouter.ExactInputSingleParams({
				tokenIn: quote,
				tokenOut: adapter.asset(),
				tickSpacing: IConcentratedPoolOracle(pool).tickSpacing(),
				recipient: address(this),
				deadline: block.timestamp,
				amountIn: amount,
				amountOutMinimum: 0,
				sqrtPriceLimitX96: sqrtTarget
			})
		);
		(uint160 sqrtNow,) = _slot0(pool);
		assertEq(sqrtNow, sqrtTarget);
	}

	/// @dev Ten tick spacings just past spot on the quote side: above spot holds only token0,
	///      below only token1 (test/TwapAggregatorAdapterV2Fork.t.sol).
	function _quoteOnlyRange(TwapAggregatorAdapterV2 adapter) internal view returns (int24 lo, int24 hi) {
		address pool = address(adapter.pool());
		(, int24 spot) = _slot0(pool);
		int24 spacing = IConcentratedPoolOracle(pool).tickSpacing();
		int24 c = spot / spacing;
		if (spot < 0 && spot % spacing != 0) c--;
		if (adapter.assetIsToken0()) {
			hi = c * spacing;
			lo = hi - 10 * spacing;
		} else {
			lo = (c + 1) * spacing;
			hi = lo + 10 * spacing;
		}
	}

	/// @dev `who` mints `quoteIn` of the quote token as a quote-only position through the real
	///      Uniswap v3 NonfungiblePositionManager.
	function _mintQuoteOnly(TwapAggregatorAdapterV2 adapter, uint256 quoteIn, address who)
		internal
		returns (uint256 tokenId, uint128 liquidity, uint256 quotePaid)
	{
		(int24 lo, int24 hi) = _quoteOnlyRange(adapter);
		address quote = adapter.quoteAsset();
		bool quoteIsToken0 = !adapter.assetIsToken0();
		deal(quote, who, quoteIn);
		vm.startPrank(who);
		IERC20(quote).approve(UNI_NPM, quoteIn);
		uint256 paid0;
		uint256 paid1;
		(tokenId, liquidity, paid0, paid1) = IUniswapV3NonfungiblePositionManager(UNI_NPM).mint(
			IUniswapV3NonfungiblePositionManager.MintParams({
				token0: quoteIsToken0 ? quote : adapter.asset(),
				token1: quoteIsToken0 ? adapter.asset() : quote,
				fee: IUniswapV3PoolFee(address(adapter.pool())).fee(),
				tickLower: lo,
				tickUpper: hi,
				amount0Desired: quoteIsToken0 ? quoteIn : 0,
				amount1Desired: quoteIsToken0 ? 0 : quoteIn,
				amount0Min: 0,
				amount1Min: 0,
				recipient: who,
				deadline: block.timestamp
			})
		);
		vm.stopPrank();
		assertEq(quoteIsToken0 ? paid1 : paid0, 0, 'quote-only position');
		quotePaid = quoteIsToken0 ? paid0 : paid1;
	}

	function _burn(uint256 tokenId, uint128 liquidity, address who) internal {
		IUniswapV3NonfungiblePositionManager npm = IUniswapV3NonfungiblePositionManager(UNI_NPM);
		vm.startPrank(who);
		npm.decreaseLiquidity(
			IUniswapV3NonfungiblePositionManager.DecreaseLiquidityParams({
				tokenId: tokenId, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
			})
		);
		npm.collect(
			IUniswapV3NonfungiblePositionManager.CollectParams({
				tokenId: tokenId, recipient: who, amount0Max: type(uint128).max, amount1Max: type(uint128).max
			})
		);
		npm.burn(tokenId);
		vm.stopPrank();
	}

	/// @dev A fresh NON-degen USDC fund on the live factory, owned by `owner`, with `amount` deposited.
	function _fundWithDeposit(string memory name, string memory symbol, address owner, uint256 amount)
		internal
		returns (Comptroller fund)
	{
		fund = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: name,
					symbol: symbol,
					denominationAsset: IERC20(USDC),
					fundOwner: owner,
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: 0,
					sharesActionTimelock: 0,
					minRequestDuration: 1 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				})
			)
		);
		deal(USDC, alice, amount);
		vm.startPrank(alice);
		IERC20(USDC).approve(address(fund), amount);
		fund.requestDeposit(amount);
		vm.stopPrank();
		skip(1 minutes);
		fund.executeDepositRequest(alice);
	}

	/// @dev The factory attached TwapExposurePolicyV2 — not v1 — on every mandatory hook.
	function _assertCarriesPolicyV2(Comptroller fund) internal view {
		IPolicy.PolicyHook[4] memory hooks = [
			IPolicy.PolicyHook.PostCallOnIntegration,
			IPolicy.PolicyHook.PostDepositRequest,
			IPolicy.PolicyHook.CreateExternalPosition,
			IPolicy.PolicyHook.PostCallOnExternalPosition
		];
		for (uint256 h; h < 4; ++h) {
			address[] memory policies = fund.getPolicies(hooks[h]);
			bool v2;
			for (uint256 i; i < policies.length; ++i) {
				assertTrue(policies[i] != twapPolicyV1, 'no v1 policy');
				if (policies[i] == address(d.policy)) v2 = true;
			}
			assertTrue(v2, 'policy V2 attached');
		}
	}

	/// @dev UniswapV3SwapAdapter data: `usdcIn` USDC → `asset` through its USDC 0.3% pool.
	function _buy(address asset, uint256 usdcIn) internal pure returns (bytes memory) {
		return abi.encode(USDC, asset, uint24(3000), usdcIn, uint256(0));
	}

	function _holdingUsd18(Comptroller fund, address asset) internal view returns (uint256) {
		return Math.mulDiv(
			IERC20(asset).balanceOf(address(fund.vault())), vi.calcUsdRate(asset), 10 ** IERC20Metadata(asset).decimals()
		);
	}

	function _gavUsd18(Comptroller fund) internal returns (uint256) {
		return Math.mulDiv(fund.calcGav(), vi.calcUsdRate(USDC), 1e6);
	}

	function _listAny(address asset, address quote, TwapListingRegistryV2.Venue venue, int24 feeOrTickSpacing)
		internal
		returns (ITwapPriceAdapter)
	{
		vm.prank(keeper);
		return ITwapPriceAdapter(d.module.list(asset, quote, venue, feeOrTickSpacing));
	}

	function _repointAny(address asset, address quote, TwapListingRegistryV2.Venue venue, int24 feeOrTickSpacing)
		internal
		returns (ITwapPriceAdapter)
	{
		vm.prank(keeper);
		return ITwapPriceAdapter(d.module.repoint(asset, quote, venue, feeOrTickSpacing));
	}

	/// @dev The listing is live: the registry's record, the venue, the VI primitive (TWAP heartbeat)
	///      and the band the lister recorded.
	function _assertListedOn(address asset, address adapter, address pool, address quote, TwapListingRegistryV2.Venue venue)
		internal
		view
	{
		(ITwapPriceAdapter stored, address storedPool, address storedQuote,, uint64 since) = d.registry.listings(asset);
		assertEq(address(stored), adapter);
		assertEq(storedPool, pool);
		assertEq(storedQuote, quote);
		assertEq(since, 0);
		assertEq(uint8(d.registry.venueOf(asset)), uint8(venue));
		assertTrue(d.registry.isTwapPriced(asset));
		(address aggregator, uint32 heartbeat,,) = vi.getAssetInfo(asset);
		assertEq(aggregator, adapter, 'the VI prices through the new adapter');
		assertEq(heartbeat, d.module.TWAP_HEARTBEAT());
		assertEq(d.registry.recordedDepthUsd18(asset), ITwapPriceAdapter(adapter).poolDepthUsd(), 'the band is recorded');
	}

	/// @dev The live degen fund, as its owner, trades through `swapAdapter`; returns the `asset` its
	///      vault received, after checking the fund still values itself within 1%.
	function _liveFundBuys(address swapAdapter, address asset, bytes memory data) internal returns (uint256 bought) {
		Comptroller live = Comptroller(LIVE_FUND);
		address vault = address(live.vault());
		assertEq(live.fundOwner(), deployer);
		assertTrue(factory.isAdapterRegistered(swapAdapter), 'the deploy registered the swap adapter');
		assertGe(IERC20(USDC).balanceOf(vault), 1e6, 'the live fund holds USDC');
		uint256 before = IERC20(asset).balanceOf(vault);
		uint256 gavBefore = live.calcGav();
		vm.prank(deployer);
		live.callOnIntegration(swapAdapter, data);
		bought = IERC20(asset).balanceOf(vault) - before;
		assertGt(bought, 0);
		assertApproxEqRel(live.calcGav(), gavBefore, 0.01e18, 'the fund values its new holding');
	}

	/// @dev One USD of `asset` at `rate` (USD per whole asset, 18 dp), less 3%.
	function _oneUsdLess3Pct(address asset, uint256 rate) internal view returns (uint256) {
		return Math.mulDiv(0.97e18, 10 ** IERC20Metadata(asset).decimals(), rate);
	}

	/// @dev Time passes on Base: ~2-second blocks.
	function _warpRoll(uint256 secs) internal {
		vm.warp(block.timestamp + secs);
		vm.roll(block.number + secs / 2);
	}

	/// @dev USD (18 dp) of `amount` raw units of `token` at `feed`.
	function _usd18(uint256 amount, address token, address feed) internal view returns (uint256) {
		return Math.mulDiv(amount, _chainlinkUsd18(feed), 10 ** IERC20Metadata(token).decimals());
	}

	/// @dev USD (18 dp) per whole asset at the reserves' spot: rQ / rA × the quote feed.
	function _reserveSpotUsd18(uint256 rA, uint256 rQ, address asset, address quote, address feed)
		internal
		view
		returns (uint256)
	{
		return Math.mulDiv(_usd18(rQ, quote, feed), 10 ** IERC20Metadata(asset).decimals(), rA);
	}

	/// @dev (asset reserve, quote reserve) of a Uniswap v2 pair.
	function _v2Reserves(address pair, address asset) internal view returns (uint256 rA, uint256 rQ) {
		(uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
		(rA, rQ) = IUniswapV2Pair(pair).token0() == asset ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
	}

	/// @dev (asset reserve, quote reserve) of an Aerodrome basic pool.
	function _aeroReserves(address pool, address asset) internal view returns (uint256 rA, uint256 rQ) {
		(uint256 r0, uint256 r1,) = IAerodromeBasicPool(pool).getReserves();
		(rA, rQ) = IAerodromeBasicPool(pool).token0() == asset ? (r0, r1) : (r1, r0);
	}

	/// @dev The pool's own time-averaged reserves (asset, quote), read from the raw pool, × `feed`,
	///      rounded once: USD (18 dp) per whole asset.
	function _aeroTwapUsd18(address pool, address asset, address feed) internal view returns (uint256) {
		(uint256 avgA, uint256 avgQ) = _aeroTwar(IAerodromeBasicPool(pool), asset);
		address quote = IAerodromeBasicPool(pool).token0() == asset ? IAerodromeBasicPool(pool).token1() : IAerodromeBasicPool(pool).token0();
		return Math.mulDiv(avgQ, 10 ** IERC20Metadata(asset).decimals() * _chainlinkUsd18(feed), avgA)
			/ 10 ** IERC20Metadata(quote).decimals();
	}

	/// @dev Average reserves from the newest observation at least 30 minutes old (the last one, else
	///      the one before it) to now.
	function _aeroTwar(IAerodromeBasicPool p, address asset) internal view returns (uint256 avgA, uint256 avgQ) {
		(uint256 t, uint256 c0, uint256 c1) = p.lastObservation();
		if (block.timestamp - t < 30 minutes) (t, c0, c1) = p.observations(p.observationLength() - 2);
		(uint256 n0, uint256 n1, uint256 tNow) = p.currentCumulativePrices();
		(uint256 avg0, uint256 avg1) = ((n0 - c0) / (tNow - t), (n1 - c1) / (tNow - t));
		(avgA, avgQ) = p.token0() == asset ? (avg0, avg1) : (avg1, avg0);
	}

	/// @dev Real sells of V2_DUMP_MULTIPLE × the pair's `asset` reserve through Uniswap v2 Router02;
	///      returns the `quote` paid out.
	function _dumpV2(address pair, address asset, address quote) internal returns (uint256 quoteOut) {
		(uint256 rA,) = _v2Reserves(pair, asset);
		uint256 amount = rA * V2_DUMP_MULTIPLE;
		deal(asset, address(this), amount);
		IERC20(asset).approve(UNI_V2_ROUTER, amount);
		uint256 before = IERC20(quote).balanceOf(address(this));
		IUniswapV2Router02(UNI_V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
			amount, 0, _path(asset, quote), address(this), block.timestamp
		);
		quoteOut = IERC20(quote).balanceOf(address(this)) - before;
	}

	/// @dev Real buys of `asset` with `quoteIn` of `quote` through Uniswap v2 Router02.
	function _buyBackV2(address pair, address asset, address quote, uint256 quoteIn) internal {
		(uint256 rABefore,) = _v2Reserves(pair, asset);
		IERC20(quote).approve(UNI_V2_ROUTER, quoteIn);
		IUniswapV2Router02(UNI_V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
			quoteIn, 0, _path(quote, asset), address(this), block.timestamp
		);
		(uint256 rAAfter,) = _v2Reserves(pair, asset);
		assertLt(rAAfter, rABefore, 'the buys took the asset back out');
	}

	/// @dev Real sells of V2_DUMP_MULTIPLE × the pool's `asset` reserve through the Aerodrome Router,
	///      on the volatile route.
	function _dumpAerodrome(address pool, address asset, address quote) internal {
		(uint256 rA,) = _aeroReserves(pool, asset);
		uint256 amount = rA * V2_DUMP_MULTIPLE;
		deal(asset, address(this), amount);
		IERC20(asset).approve(AERO_ROUTER, amount);
		IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
		routes[0] = IAerodromeRouter.Route({from: asset, to: quote, stable: false, factory: AERO_FACTORY});
		IAerodromeRouter(AERO_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
			amount, 0, routes, address(this), block.timestamp
		);
	}

	function _path(address from, address to) internal pure returns (address[] memory path) {
		path = new address[](2);
		path[0] = from;
		path[1] = to;
	}

	/// @dev The lens page [offset, offset + 2) flags exactly `expected`, in listing order.
	function _assertPage(uint256 offset, address[] memory expected, uint256 expectedNext) internal view {
		(address[] memory due, uint256 next) = d.lens.assetsNeedingPoke(d.registry, offset, 2);
		assertEq(next, expectedNext);
		assertEq(due, expected);
	}

	function _addrs(address a) internal pure returns (address[] memory list) {
		list = new address[](1);
		list[0] = a;
	}

	function _addrs(address a, address b) internal pure returns (address[] memory list) {
		list = new address[](2);
		list[0] = a;
		list[1] = b;
	}
}
