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
import {TwapListingRegistryV2} from '../../src/pricing/TwapListingRegistryV2.sol';
import {PriceListingModule} from '../../src/pricing/PriceListingModule.sol';
import {TwapExposurePolicyV2} from '../../src/policies/TwapExposurePolicyV2.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {TwapListingV2} from '../../script/mainnet/TwapListingV2.sol';

/// @notice The Uniswap v3 pool's fee (the NPM keys pools by it).
interface IUniswapV3PoolFee {
	function fee() external view returns (uint24);
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
///         Proven here: keepers list real tokens (strangers and governance can't); one-sided junk
///         is refused; WETH-quoted and Slipstream-3 listings price and trade; repoints need a 25%
///         deeper pool unless the current one is under the floor; flash (same-transaction)
///         liquidity can neither clear a delist clock nor lift a fund's cap; governance keeps
///         every VI admin call; caps bind on quote-side depth; the lens pages real listings.
///         Deviations from the task brief, both forced by live state (block 52008523, measured
///         with this registry's own adapter parameters):
///         - BRETT's Slipstream ts200 WETH pool 0x4e82…Ba02 holds $32,294 of WETH within ±10%, under
///           the $50k floor, so it cannot list; LCAP on the same venue and spacing ($159,682) is used.
///         - TRX's Slipstream-3 ts100 USDC pool 0xf041…7Cb5 holds $5.67M USDC but $36 of it within
///           ±10%; USDL (Slipstream-3 USDC ts50, $345,107; all three of its pools are on Slip3) is used.
///         Run: BASE_MAINNET_RPC=<url> [BASE_FORK_BLOCK=52008523] forge test --match-path test/fork/TwapListingV2Fork.t.sol -j 1 -vv
contract TwapListingV2ForkTest is Test {
	string internal constant GENESIS_FILE = 'deployments/base-mainnet.json';

	TwapListingRegistryV2.Venue internal constant UNI = TwapListingRegistryV2.Venue.UniswapV3;
	TwapListingRegistryV2.Venue internal constant SLIP = TwapListingRegistryV2.Venue.Slipstream;
	TwapListingRegistryV2.Venue internal constant SLIP2 = TwapListingRegistryV2.Venue.Slipstream2;
	TwapListingRegistryV2.Venue internal constant SLIP3 = TwapListingRegistryV2.Venue.Slipstream3;

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
	// LCAP_USDC_SLIP_200 360/360, MORPHO_WETH_3000 301/301, MORPHO_USDC_10000 360/360,
	// VVV_USDC_3000 360/360, USDT_USDC_UNI_100 1000/1000 — all over MIN_OBSERVATION_CARDINALITY (300).
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
	/// @dev Slipstream getPool(LCAP, WETH, 200): $159,682 of WETH within ±10%
	address internal constant LCAP_WETH_SLIP_200 = 0x3a88eF38879EFb900c2D7b6199d21C139cEf5Fa7;
	/// @dev Slipstream getPool(LCAP, USDC, 200): an independent market (spot $7.368 vs the WETH pool's $7.379)
	address internal constant LCAP_USDC_SLIP_200 = 0xC8C15670050541255f9b797C008047682524861F;

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

	/// @dev symbol "MORPHO", 18 dp, unpriced in the live VI
	address internal constant MORPHO = 0xBAa5CC21fd487B8Fcc2F632f3F4E8D37262a0842;
	/// @dev Uniswap getPool(MORPHO, WETH, 3000): $90,138 of WETH within ±10%; MORPHO is token1.
	///      Real sells of +99 ticks leave it just under the floor ($49,722).
	address internal constant MORPHO_WETH_3000 = 0x2F42Df4aF5312B492E9d7F7b2110D9c7bf2D9e4F;
	/// @dev Uniswap getPool(MORPHO, USDC, 10000), spacing 200: $55,440 — qualifies, yet under
	///      1.25× a pool that just slipped under $50k
	address internal constant MORPHO_USDC_10000 = 0x2043B296fFC6b2d3bf4A3F3167d2Afb3B0FBdbEE;
	/// @dev "MORPHO / USD", 8 dp; answered $2.4791 vs the USDC pool's TWAP $2.4963
	address internal constant CL_MORPHO_USD = 0xe95e258bb6615d47515Fc849f8542dA651f12bF6;

	/// @dev name "Venice Token", symbol "VVV", 18 dp, unpriced in the live VI
	address internal constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;
	/// @dev Uniswap getPool(VVV, USDC, 3000): $104,538 of USDC within ±10% (v1 two-sided: $235,027);
	///      USDC is token0. Far from both the $50k floor and the $250k large-pool line, so the
	///      10% cap applies at any nearby block (VIRTUAL's USDC pool sits at the $250k line).
	address internal constant VVV_USDC_3000 = 0x67A11022B7B6ed66f81233F6C8Ed6e48F7826530;

	// ─── sizing, measured at block 52008523 ─────────────────────────────────────
	/// @dev Real sells that move VIRTUAL_USDC_3000's spot this many ticks down (~977k VIRTUAL)
	///      leave $102 of USDC within ±10% (5,000 ticks still leave $13,975).
	int24 internal constant UNDER_FLOOR_TICKS = 10_000;
	/// @dev Quote-only liquidity a flash attacker mints just past spot. It lifts VVV_USDC_3000's
	///      live depth to its window leg's ceiling ($104,538 → $118,585; more does not add).
	uint256 internal constant JIT_USDC = 200_000e6;
	/// @dev The exposure policy's spec (TwapExposurePolicyV2 natspec), kept literal on purpose.
	uint256 internal constant LARGE_POOL_USD18 = 250_000e18;
	uint256 internal constant SMALL_CAP_BPS = 1_000;
	uint256 internal constant LARGE_CAP_BPS = 5_000;
	uint256 internal constant MARGIN_BPS = 12_500;
	uint256 internal constant FLOOR_USD18 = 50_000e18;

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

		uint256 recorded = d.registry.recordedDepthUsd18(VIRTUAL);
		assertGe(recorded, 50_000e18, 'Ruling 8: the listing records its quote-side depth');
		assertEq(recorded, adapter.poolDepthUsd());

		uint256 rate = vi.calcUsdRate(VIRTUAL);
		uint256 chainlink = _chainlinkUsd18(CL_VIRTUAL_USD);
		assertGt(rate, 0);
		assertApproxEqRel(rate, chainlink, 0.05e18, 'the TWAP agrees with Chainlink VIRTUAL / USD');
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

		// with its oracle ring raised the way the keeper would, the one-sided depth is what refuses it
		_prepareOracle(LUMIA_POOL);
		bytes memory err = _revertData(keeper, address(d.module), abi.encodeCall(PriceListingModule.list, (LUMIA, WETH, UNI, 3000)));
		assertEq(_selector(err), TwapListingRegistryV2.BelowFloorAtListing.selector);
		uint256 quoteDepth = abi.decode(_args(err), (uint256));
		assertLt(quoteDepth, FLOOR_USD18, 'the WETH bids are under the floor');
		assertGt(quoteDepth, 1_000e18, 'the real WETH side still counts');
		assertFalse(vi.isSupportedAsset(LUMIA));
		assertEq(d.registry.listedCount(), 0);
		emit log_named_decimal_uint('LUMIA v1 two-sided depth (USD)', v1Depth, 18);
		emit log_named_decimal_uint('LUMIA quote-side depth (USD)  ', quoteDepth, 18);
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
		uint256 recorded = d.registry.recordedDepthUsd18(LCAP);
		assertGe(recorded, FLOOR_USD18);
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
		uint256 recorded = d.registry.recordedDepthUsd18(USDL);
		assertGe(recorded, FLOOR_USD18);
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

	/// @notice Ruling 9: real sells take the listed pool JUST under the floor; anyone starts the
	///         clock; the keeper then moves the listing to a qualifying pool that is NOT 25% deeper
	///         than the slipped one — only the under-floor branch (currentOk = false) allows that —
	///         and the move resets the clock and records the new pool's depth.
	function test_fork_underFloorRepointAndClock() public {
		vm.skip(!forked);
		TwapAggregatorAdapterV2 current = _list(MORPHO, WETH, UNI, 3000);
		uint256 healthyDepth = current.poolDepthUsd();

		// healthy: the USDC 1% pool is shallower, refused
		(uint256 cur, uint256 next) = _notDeepEnough(
			_revertData(keeper, address(d.module), abi.encodeCall(PriceListingModule.repoint, (MORPHO, USDC, UNI, 10000)))
		);
		assertEq(cur, healthyDepth);
		assertLt(next, cur);

		// real sells: the smallest push that takes the WETH bids under the floor
		int24 push = _sellJustUnderFloor(current, 3000);
		uint256 slipped = current.poolDepthUsd();
		assertLt(slipped, FLOOR_USD18);

		// anyone starts the clock
		vm.prank(stranger);
		assertTrue(d.registry.pokeFloor(MORPHO));
		assertEq(_clockOf(MORPHO), block.timestamp);

		TwapAggregatorAdapterV2 moved = _repoint(MORPHO, USDC, UNI, 10000);
		uint256 movedDepth = moved.poolDepthUsd();
		assertGe(movedDepth, FLOOR_USD18);
		assertLt(movedDepth, Math.mulDiv(slipped, MARGIN_BPS, 10_000), 'the margin alone would have refused this move');
		assertEq(_poolOf(MORPHO), MORPHO_USDC_10000);
		assertEq(_clockOf(MORPHO), 0, 'the repoint resets the clock');
		assertEq(d.registry.recordedDepthUsd18(MORPHO), movedDepth, 'Ruling 8: the new depth is recorded');
		(address aggregator,,,) = vi.getAssetInfo(MORPHO);
		assertEq(aggregator, address(moved));
		assertApproxEqRel(vi.calcUsdRate(MORPHO), _chainlinkUsd18(CL_MORPHO_USD), 0.05e18, 'agrees with Chainlink MORPHO / USD');
		emit log_named_int('real sells pushed spot (ticks)', push);
		emit log_named_decimal_uint('WETH-pool depth healthy (USD) ', healthyDepth, 18);
		emit log_named_decimal_uint('WETH-pool depth after sells   ', slipped, 18);
		emit log_named_decimal_uint('USDC-pool depth recorded (USD)', movedDepth, 18);
	}

	/// @notice A pool dumped far under the floor by real sells: the keeper moves the listing to a
	///         pool the margin refused while the dumped one was healthy, and the VI stops pricing
	///         from the dumped pool.
	function test_fork_dumpedPoolRepointsToHealthyPool() public {
		vm.skip(!forked);
		TwapAggregatorAdapterV2 dumped = _list(VIRTUAL, USDC, UNI, 3000);
		uint256 healthyDepth = dumped.poolDepthUsd();

		// healthy: the WETH pool is not 25% deeper
		(uint256 cur, uint256 next) =
			_notDeepEnough(_revertData(keeper, address(d.module), abi.encodeCall(PriceListingModule.repoint, (VIRTUAL, WETH, SLIP, 200))));
		assertEq(cur, healthyDepth);
		assertLt(next, Math.mulDiv(cur, MARGIN_BPS, 10_000));

		// real sells take the pool's USDC bids out of the band
		uint256 sold = _dumpVirtual(UNDER_FLOOR_TICKS);
		assertTrue(dumped.isBelowFloor());
		uint256 dumpedDepth = dumped.poolDepthUsd();

		// anyone starts the clock
		vm.prank(stranger);
		assertTrue(d.registry.pokeFloor(VIRTUAL));
		assertEq(_clockOf(VIRTUAL), block.timestamp);

		// the keeper moves the listing to the WETH pool with no margin (the current one is not answerable)
		TwapAggregatorAdapterV2 moved = _repoint(VIRTUAL, WETH, SLIP, 200);
		assertEq(_poolOf(VIRTUAL), VIRTUAL_WETH_SLIP_200);
		assertEq(_clockOf(VIRTUAL), 0, 'the repoint resets the clock');
		assertEq(d.registry.recordedDepthUsd18(VIRTUAL), moved.poolDepthUsd(), 'Ruling 8: the new depth is recorded');
		assertLt(moved.poolDepthUsd(), Math.mulDiv(healthyDepth, MARGIN_BPS, 10_000), 'no margin was needed');
		assertFalse(d.registry.isDelisted(VIRTUAL));
		// the dumped pool no longer prices VIRTUAL
		(address aggregator,,,) = vi.getAssetInfo(VIRTUAL);
		assertEq(aggregator, address(moved));
		assertApproxEqRel(vi.calcUsdRate(VIRTUAL), _chainlinkUsd18(CL_VIRTUAL_USD), 0.05e18);
		emit log_named_decimal_uint('VIRTUAL sold into the pool     ', sold, 18);
		emit log_named_decimal_uint('USDC-pool depth healthy (USD)  ', healthyDepth, 18);
		emit log_named_decimal_uint('USDC-pool depth after sells    ', dumpedDepth, 18);
		emit log_named_decimal_uint('WETH-pool depth recorded (USD) ', moved.poolDepthUsd(), 18);
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

	/// @dev (a) real sells put the pool under the floor; a stranger starts the clock, then can't clear it.
	function _jitPokeCannotClearClock(TwapAggregatorAdapterV2 adapter) internal {
		int24 push = _sellJustUnderFloor(adapter, 3000);
		vm.prank(stranger);
		assertTrue(d.registry.pokeFloor(VVV));
		uint64 since = _clockOf(VVV);
		assertEq(since, block.timestamp);
		uint256 recordedAtClock = d.registry.recordedDepthUsd18(VVV);

		// the stranger flash-mints quote at the new spot: the live read now says "over the floor" …
		(uint256 tokenId, uint128 liquidity,) = _mintQuoteOnly(adapter, JIT_USDC, stranger);
		assertFalse(adapter.isBelowFloor(), 'the flash liquidity fools a live read');
		uint256 liveFlash = adapter.poolDepthUsd();
		// … but a non-lister's poke neither clears the clock nor records depth
		vm.prank(stranger);
		assertFalse(d.registry.pokeFloor(VVV));
		assertEq(_clockOf(VVV), since, 'the clock keeps running');
		assertEq(d.registry.recordedDepthUsd18(VVV), recordedAtClock);
		_burn(tokenId, liquidity, stranger);
		assertTrue(adapter.isBelowFloor());
		emit log_named_int('sells pushed spot (ticks)     ', push);
		emit log_named_decimal_uint('under-floor depth + flash mint', liveFlash, 18);
	}

	// ─── delist clock ────────────────────────────────────────────────────────────

	/// @notice Ruling 12b: the keeper's poke through the module reports `below`, records live
	///         depth, and is the only poke that clears a clock once the pool has really recovered.
	function test_fork_keeperPokeClearsAndRecords() public {
		vm.skip(!forked);
		TwapAggregatorAdapterV2 adapter = _list(VIRTUAL, USDC, UNI, 3000);
		vm.prank(stranger);
		vm.expectRevert(PriceListingModule.NotKeeper.selector);
		d.module.pokeFloor(VIRTUAL);

		// healthy
		vm.prank(keeper);
		assertFalse(d.module.pokeFloor(VIRTUAL));
		assertEq(_clockOf(VIRTUAL), 0);
		assertEq(d.registry.recordedDepthUsd18(VIRTUAL), adapter.poolDepthUsd());

		// real sells: under the floor, the keeper's poke starts the clock and records the shortfall
		(uint160 sqrtBefore,) = _slot0(VIRTUAL_USDC_3000);
		_dumpVirtual(UNDER_FLOOR_TICKS);
		vm.prank(keeper);
		assertTrue(d.module.pokeFloor(VIRTUAL));
		uint64 since = _clockOf(VIRTUAL);
		assertEq(since, block.timestamp);
		uint256 shortfall = adapter.poolDepthUsd();
		assertEq(d.registry.recordedDepthUsd18(VIRTUAL), shortfall);
		assertLt(shortfall, FLOOR_USD18);

		// a later block buys the price back to where it was, then the window rolls past the dip
		vm.roll(block.number + 1);
		vm.warp(block.timestamp + 2);
		_restoreVirtual(sqrtBefore);
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
		assertGe(recovered, FLOOR_USD18);
		emit log_named_decimal_uint('depth after sells (USD)  ', shortfall, 18);
		emit log_named_decimal_uint('depth after recovery (USD)', recovered, 18);
	}

	// ─── lens ────────────────────────────────────────────────────────────────────

	function test_fork_lensPagesRealListings() public {
		vm.skip(!forked);
		_list(VIRTUAL, USDC, UNI, 3000);
		_list(LCAP, WETH, SLIP, 200);
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

		// real sells put VIRTUAL under the floor: the lens reports it on its page only
		_dumpVirtual(UNDER_FLOOR_TICKS);
		uint256 g = gasleft();
		(due, next) = d.lens.assetsNeedingPoke(d.registry, 0, 2);
		uint256 pageGas = g - gasleft();
		assertEq(next, 2);
		assertEq(due.length, 1);
		assertEq(due[0], VIRTUAL);
		(due,) = d.lens.assetsNeedingPoke(d.registry, 2, 2);
		assertEq(due.length, 0);

		// once the clock matches the pool, nothing is due
		vm.prank(stranger);
		d.registry.pokeFloor(VIRTUAL);
		(due,) = d.lens.assetsNeedingPoke(d.registry, 0, 3);
		assertEq(due.length, 0);
		emit log_named_uint('lens page (2 real listings) gas', pageGas);
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
	///      ORACLE_RING observations, then one real observation write if the ring hasn't grown — a
	///      pool grows its ring only on a write at the ring's last slot, which for cardinality 1 is
	///      the very next write.
	function _prepareOracle(address pool) internal {
		IOracleRing(pool).increaseObservationCardinalityNext(ORACLE_RING);
		if (_cardinality(pool) < ORACLE_RING) _writeObservation(pool);
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

	/// @dev Real sells of VIRTUAL into its USDC 0.3% pool until spot is `ticks` lower.
	function _dumpVirtual(int24 ticks) internal returns (uint256 sold) {
		return _sellInto(VIRTUAL, USDC, 3000, ticks);
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

	/// @dev Real sells that leave `adapter`'s Uniswap pool JUST under the floor: the smallest push
	///      (binary search over snapshots) whose quote-side depth reads under $50k.
	function _sellJustUnderFloor(TwapAggregatorAdapterV2 adapter, uint24 fee) internal returns (int24 push) {
		address asset = adapter.asset();
		address quote = adapter.quoteAsset();
		assertFalse(adapter.isBelowFloor());
		int24 over;
		int24 under = 5_000;
		while (under - over > 1) {
			int24 mid = (over + under) / 2;
			uint256 snap = vm.snapshotState();
			_sellInto(asset, quote, fee, mid);
			bool below = adapter.isBelowFloor();
			vm.revertToState(snap);
			if (below) under = mid;
			else over = mid;
		}
		_sellInto(asset, quote, fee, under);
		assertTrue(adapter.isBelowFloor());
		push = under;
	}

	/// @dev Real buys of VIRTUAL with USDC until the pool is back at `sqrtTarget` exactly.
	function _restoreVirtual(uint160 sqrtTarget) internal {
		uint256 amount = 100_000_000e6;
		deal(USDC, address(this), amount);
		IERC20(USDC).approve(UNI_ROUTER, amount);
		IUniswapV3SwapRouter(UNI_ROUTER).exactInputSingle(
			IUniswapV3SwapRouter.ExactInputSingleParams({
				tokenIn: USDC,
				tokenOut: VIRTUAL,
				fee: 3000,
				recipient: address(this),
				amountIn: amount,
				amountOutMinimum: 0,
				sqrtPriceLimitX96: sqrtTarget
			})
		);
		(uint160 sqrtNow,) = _slot0(VIRTUAL_USDC_3000);
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
}
