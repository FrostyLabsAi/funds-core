// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {IPoolPriceAdapter} from '../src/interfaces/IPoolPriceAdapter.sol';
import {PoolPriceRegistrar} from '../src/pricing/PoolPriceRegistrar.sol';
import {V4PoolPriceAdapter} from '../src/pricing/V4PoolPriceAdapter.sol';
import {V4PriceSampler} from '../src/pricing/V4PriceSampler.sol';
import {IValueInterpreterAdmin} from '../src/interfaces/IValueInterpreterAdmin.sol';
import {IV4StateView, PoolKey, PoolKeyId} from '../src/interfaces/external/IUniswapV4.sol';
import {TickMath} from '../src/libraries/TickMath.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';
import {
	ScriptedCLPool,
	ScriptedBasicPool,
	MockUniswapV3Factory,
	MockSlipstreamFactory,
	MockAerodromeBasicFactory
} from './utils/PoolPriceMocks.sol';
import {MockStateView} from './utils/V4Mocks.sol';

/// @notice PoolPriceRegistrar: anyone prices a token from its own Uniswap v3, Slipstream, Aerodrome basic or Aero CL pool,
///         or from an approved Uniswap v4 pool (spec 2026-10-08 §4.3), against the approved quotes (USDC, WETH and
///         Chainlink-priced stock tokens); the owner corrects pools, sets quotes, v4 approvals and hooks, and passes any
///         other call through to the ValueInterpreter it owns.
contract PoolPriceRegistrarTest is Test {
	ValueInterpreter internal vi;
	PoolPriceRegistrar internal registrar;
	MockUniswapV3Factory internal uniswap;
	MockSlipstreamFactory[3] internal slipstreams;
	MockAerodromeBasicFactory internal aerodrome;
	MockSlipstreamFactory internal aero;
	MockStateView internal stateView;
	V4PriceSampler internal sampler;
	MockERC20 internal usdc;
	MockERC20 internal weth;
	MockERC20 internal stock; // a Chainlink-priced stock token (NVDAc-like), $180
	MockERC20 internal tkn;
	address internal admin = makeAddr('admin');
	address internal manager = makeAddr('manager');
	address internal anyone = makeAddr('anyone');
	address internal keeper = makeAddr('keeper');
	address internal constant POOL_MANAGER = address(0x4444);
	address internal constant HOOK = address(0x47Ec48C74f3069e9Ae69406197821996d80200cC);

	/// @dev USDC liquidity L at tick 0 is L raw USDC as a full-range reserve.
	uint128 internal constant PLENTY = 1_000_000e6;

	function setUp() public {
		vm.warp(30 days);
		vi = new ValueInterpreter(admin);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		weth = new MockERC20('Wrapped Ether', 'WETH', 18);
		stock = new MockERC20('NVIDIA', 'NVDAc', 6);
		tkn = new MockERC20('Token', 'TKN', 6);
		vm.startPrank(admin);
		vi.addPrimitive(address(usdc), address(new MockAggregator(8, 1e8)), 25 hours);
		vi.addPrimitive(address(weth), address(new MockAggregator(8, 2000e8)), 1 hours);
		vi.addPrimitive(address(stock), address(new MockAggregator(8, 180e8)), 5 days);
		vm.stopPrank();

		uniswap = new MockUniswapV3Factory();
		aerodrome = new MockAerodromeBasicFactory();
		aero = new MockSlipstreamFactory();
		for (uint256 i; i < 3; ++i) slipstreams[i] = new MockSlipstreamFactory();
		stateView = new MockStateView();
		sampler = new V4PriceSampler(IV4StateView(address(stateView)), admin);
		vm.prank(admin);
		sampler.setKeeper(keeper, true);
		registrar = new PoolPriceRegistrar(_wiring(), admin);

		// the deploy's hand-over: the VI's owner proposes the registrar, which accepts
		vm.startPrank(admin);
		vi.transferOwnership(address(registrar));
		registrar.acceptValueInterpreter();
		vm.stopPrank();
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	function _wiring() internal view returns (PoolPriceRegistrar.Wiring memory w) {
		address[] memory quotes = new address[](3);
		quotes[0] = address(usdc);
		quotes[1] = address(weth);
		quotes[2] = address(stock);
		w = PoolPriceRegistrar.Wiring({
			valueInterpreter: IValueInterpreterAdmin(address(vi)),
			uniswapV3Factory: address(uniswap),
			slipstreamFactories: [address(slipstreams[0]), address(slipstreams[1]), address(slipstreams[2])],
			aerodromeBasicFactory: address(aerodrome),
			aeroFactory: address(aero),
			stateView: IV4StateView(address(stateView)),
			poolManager: POOL_MANAGER,
			sampler: sampler,
			weth: address(weth),
			quotes: quotes
		});
	}

	/// @dev A canonical Uniswap v3 TKN/USDC pool at $1 (6-decimal TKN, tick 0) with `usdcHeld`.
	function _uniswapPool(MockERC20 asset, uint256 usdcHeld) internal returns (ScriptedCLPool pool) {
		pool = new ScriptedCLPool(address(asset), address(usdc), address(uniswap), 3000, 60);
		pool.setHistory(2 days);
		pool.setOracle(0, PLENTY);
		usdc.mint(address(pool), usdcHeld);
		uniswap.setPool(address(asset), address(usdc), 3000, address(pool));
	}

	function _usdRate(address asset) internal view returns (uint256) {
		return vi.calcUsdRate(asset);
	}

	/// @dev A v4 key for `asset` against `quote` (address(0) = native ETH) at tick 0, sorted like the PoolManager.
	function _key(address asset, address quote, address hooks) internal pure returns (PoolKey memory key) {
		(address c0, address c1) = asset < quote ? (asset, quote) : (quote, asset);
		key = PoolKey({currency0: c0, currency1: c1, fee: 10_000, tickSpacing: 200, hooks: hooks});
	}

	/// @dev An initialized pool the owner has approved (registration's gate); `_initUnapprovedPool` for one it hasn't.
	function _initPool(PoolKey memory key, uint128 liquidity) internal returns (bytes32 id) {
		id = _initUnapprovedPool(key, liquidity);
		vm.prank(admin);
		registrar.setPoolApproved(id, true);
	}

	function _initUnapprovedPool(PoolKey memory key, uint128 liquidity) internal returns (bytes32 id) {
		id = PoolKeyId.toId(key);
		stateView.setPool(id, TickMath.getSqrtRatioAtTick(0), 0, liquidity);
	}

	function _sample(bytes32 id, uint256 n) internal {
		bytes32[] memory ids = new bytes32[](1);
		ids[0] = id;
		for (uint256 i; i < n; ++i) {
			vm.prank(keeper);
			sampler.sample(ids);
			skip(10 minutes);
		}
	}

	function _pool(MockERC20 asset, MockERC20 quote, address factory, uint128 liquidity) internal returns (ScriptedCLPool pool) {
		pool = new ScriptedCLPool(address(asset), address(quote), factory, 0, 10);
		pool.setHistory(2 days);
		pool.setOracle(0, liquidity);
		quote.mint(address(pool), liquidity);
	}

	function _aeroPool(MockERC20 asset, MockERC20 quote, uint128 liquidity) internal returns (ScriptedCLPool pool) {
		pool = _pool(asset, quote, address(aero), liquidity);
		aero.setPool(address(asset), address(quote), 10, address(pool));
	}

	function _uniswapPoolIn(MockERC20 asset, MockERC20 quote, uint256 quoteHeld) internal returns (ScriptedCLPool pool) {
		pool = new ScriptedCLPool(address(asset), address(quote), address(uniswap), 3000, 60);
		pool.setHistory(2 days);
		pool.setOracle(0, PLENTY);
		quote.mint(address(pool), quoteHeld);
		uniswap.setPool(address(asset), address(quote), 3000, address(pool));
	}

	// ─── register ────────────────────────────────────────────────────────────────

	function test_anyoneRegistersATokenWithADeepEnoughPool() public {
		ScriptedCLPool pool = _uniswapPool(tkn, 1_000_000e6);

		vm.prank(manager);
		address adapter = registrar.register(address(tkn), address(pool));

		assertEq(_usdRate(address(tkn)), 1e18);
		(address aggregator,,,) = vi.getAssetInfo(address(tkn));
		assertEq(aggregator, adapter);
		assertEq(registrar.poolPricedAdapter(address(tkn)), adapter);
		assertEq(IPoolPriceAdapter(adapter).config().pool, address(pool));
	}

	function test_registersOnEachSlipstreamFactory() public {
		for (uint256 i; i < 3; ++i) {
			MockERC20 asset = new MockERC20('Token', 'TKN', 6);
			ScriptedCLPool pool = new ScriptedCLPool(address(asset), address(usdc), address(slipstreams[i]), 0, 200);
			pool.setHistory(2 days);
			pool.setOracle(0, PLENTY);
			usdc.mint(address(pool), 1_000_000e6);
			slipstreams[i].setPool(address(asset), address(usdc), 200, address(pool));

			registrar.register(address(asset), address(pool));
			assertEq(_usdRate(address(asset)), 1e18);
		}
	}

	function test_registersOnAnAerodromeBasicVolatilePool() public {
		ScriptedBasicPool pool = new ScriptedBasicPool(address(tkn), address(usdc), address(aerodrome), false);
		aerodrome.setPool(address(tkn), address(usdc), false, address(pool));
		// 1M USDC per 500k TKN over the last 2 hours = $2 (both tokens 6 decimals)
		pool.addObservation(2 hours, 0, 0);
		(uint256 c0, uint256 c1) =
			pool.token0() == address(tkn) ? (500_000e6 * 2 hours, 1_000_000e6 * 2 hours) : (1_000_000e6 * 2 hours, 500_000e6 * 2 hours);
		pool.setCurrentCumulatives(c0, c1);
		(uint256 r0, uint256 r1) = pool.token0() == address(tkn) ? (500_000e6, 1_000_000e6) : (1_000_000e6, 500_000e6);
		pool.setReserves(r0, r1);

		registrar.register(address(tkn), address(pool));

		assertEq(_usdRate(address(tkn)), 2e18);
	}

	function test_registeringGrowsAConcentratedPoolsPriceHistory() public {
		ScriptedCLPool pool = _uniswapPool(tkn, 1_000_000e6);

		registrar.register(address(tkn), address(pool));

		assertEq(pool.observationCardinalityNext(), registrar.OBSERVATION_SLOTS());
		assertGt(registrar.OBSERVATION_SLOTS(), 2);
	}

	function test_registersAtExactlyTheLiquidityMinimum() public {
		ScriptedCLPool pool = _uniswapPool(tkn, 25_000e6);

		registrar.register(address(tkn), address(pool));

		assertTrue(vi.isSupportedAsset(address(tkn)));
	}

	function test_refusesAPoolUnderTheLiquidityMinimum() public {
		ScriptedCLPool pool = _uniswapPool(tkn, 24_999e6);

		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.NotEnoughLiquidity.selector, 24_999e18));
		registrar.register(address(tkn), address(pool));
	}

	function test_refusesATokenTheValueInterpreterAlreadyPrices() public {
		ScriptedCLPool pool = _uniswapPool(tkn, 1_000_000e6);
		registrar.register(address(tkn), address(pool));

		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.AlreadyPriced.selector, address(tkn)));
		registrar.register(address(tkn), address(pool));
	}

	function test_refusesAPoolFromAnUnknownFactory() public {
		ScriptedCLPool pool = new ScriptedCLPool(address(tkn), address(usdc), makeAddr('fork-dex'), 3000, 60);
		pool.setHistory(2 days);
		pool.setOracle(0, PLENTY);
		usdc.mint(address(pool), 1_000_000e6);

		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.UnknownVenue.selector, makeAddr('fork-dex')));
		registrar.register(address(tkn), address(pool));
	}

	function test_refusesAPoolThatClaimsAKnownFactoryWhichNeverMadeIt() public {
		// names Uniswap's factory, but the factory's canonical TKN/USDC pool is someone else
		ScriptedCLPool impostor = new ScriptedCLPool(address(tkn), address(usdc), address(uniswap), 3000, 60);
		impostor.setHistory(2 days);
		impostor.setOracle(0, PLENTY);
		usdc.mint(address(impostor), 1_000_000e6);
		_uniswapPool(tkn, 1_000_000e6);

		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.NotCanonicalPool.selector, address(impostor)));
		registrar.register(address(tkn), address(impostor));
	}

	function test_refusesAnAerodromeStablePool() public {
		ScriptedBasicPool pool = new ScriptedBasicPool(address(tkn), address(usdc), address(aerodrome), true);
		aerodrome.setPool(address(tkn), address(usdc), true, address(pool));

		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.NotCanonicalPool.selector, address(pool)));
		registrar.register(address(tkn), address(pool));
	}

	function test_refusesAQuoteTokenThatIsNotAllowed() public {
		MockERC20 dai = new MockERC20('Dai', 'DAI', 18);
		ScriptedCLPool pool = new ScriptedCLPool(address(tkn), address(dai), address(uniswap), 3000, 60);
		uniswap.setPool(address(tkn), address(dai), 3000, address(pool));

		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.QuoteNotAllowed.selector, address(dai)));
		registrar.register(address(tkn), address(pool));
	}

	function test_refusesAnAssetThatIsNotInThePool() public {
		ScriptedCLPool pool = _uniswapPool(tkn, 1_000_000e6);
		MockERC20 other = new MockERC20('Other', 'OTH', 6);

		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.AssetNotInPool.selector, address(other)));
		registrar.register(address(other), address(pool));
	}

	function test_refusesAnAssetWithMoreThan38Decimals() public {
		MockERC20 wide = new MockERC20('Wide', 'WIDE', 39);
		ScriptedCLPool pool = _uniswapPool(wide, 1_000_000e6);

		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.UnsupportedDecimals.selector, uint8(39)));
		registrar.register(address(wide), address(pool));
	}

	// ─── owner ───────────────────────────────────────────────────────────────────

	function test_ownerMovesAnAlreadyPricedTokenOntoAPool() public {
		// priced elsewhere first (e.g. an old TWAP adapter): the migration overwrites it
		MockAggregator oldFeed = new MockAggregator(8, 7e8);
		vm.prank(admin);
		registrar.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (address(tkn), address(oldFeed), 1 hours)));
		ScriptedCLPool pool = _uniswapPool(tkn, 1_000_000e6);

		vm.prank(admin);
		address adapter = registrar.setPool(address(tkn), address(pool));

		assertEq(_usdRate(address(tkn)), 1e18);
		assertEq(registrar.poolPricedAdapter(address(tkn)), adapter);
	}

	function test_ownerMayKeepAPoolUnderTheMinimumPriced() public {
		// a listing being migrated may have thinned out; it keeps a price (≈ $0 under $5k)
		ScriptedCLPool pool = _uniswapPool(tkn, 10_000e6);

		vm.prank(admin);
		registrar.setPool(address(tkn), address(pool));

		assertEq(_usdRate(address(tkn)), 1e18);
	}

	function test_setPoolStillRefusesAPoolNoKnownFactoryMade() public {
		ScriptedCLPool pool = new ScriptedCLPool(address(tkn), address(usdc), makeAddr('fork-dex'), 3000, 60);

		vm.prank(admin);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.UnknownVenue.selector, makeAddr('fork-dex')));
		registrar.setPool(address(tkn), address(pool));
	}

	function test_onlyTheOwnerSetsPools() public {
		ScriptedCLPool pool = _uniswapPool(tkn, 1_000_000e6);

		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
		registrar.setPool(address(tkn), address(pool));
	}

	function test_ownerExecutesAnyValueInterpreterCall() public {
		MockAggregator feed = new MockAggregator(8, 42e8);

		vm.prank(admin);
		registrar.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (address(tkn), address(feed), 1 hours)));

		assertEq(_usdRate(address(tkn)), 42e18);
	}

	/// The owner records a v4 pool's sale tax for the keeper's cap, up to the bytecode cap of 5%; no one else can.
	function test_setPoolSaleTax_ownerOnly_cappedAtFivePercent() public {
		bytes32 pool = keccak256('a taxed v4 pool');
		vm.expectEmit(address(registrar));
		emit PoolPriceRegistrar.PoolSaleTaxSet(pool, 290);
		vm.prank(admin);
		registrar.setPoolSaleTax(pool, 290);
		assertEq(registrar.poolSaleTaxBps(pool), 290);
		assertEq(registrar.poolSaleTaxBps(keccak256('another pool')), 0, 'per pool');

		vm.prank(admin);
		registrar.setPoolSaleTax(pool, 500);
		assertEq(registrar.poolSaleTaxBps(pool), 500, 'the cap itself is allowed');
		vm.prank(admin);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.SaleTaxTooHigh.selector, uint16(501)));
		registrar.setPoolSaleTax(pool, 501);
		vm.prank(admin);
		vm.expectRevert(PoolPriceRegistrar.ZeroAddress.selector);
		registrar.setPoolSaleTax(bytes32(0), 290);

		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
		registrar.setPoolSaleTax(pool, 0);
		assertEq(registrar.poolSaleTaxBps(pool), 500);
	}

	function test_onlyTheOwnerExecutes() public {
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
		registrar.execute(abi.encodeCall(ValueInterpreter.removePrimitive, (address(usdc))));
	}

	function test_executeBubblesTheValueInterpretersRevert() public {
		vm.prank(admin);
		vm.expectRevert(abi.encodeWithSelector(ValueInterpreter.UnsupportedAsset.selector, address(tkn)));
		registrar.execute(abi.encodeCall(ValueInterpreter.removePrimitive, (address(tkn))));
	}

	function test_aTokenMovedToAChainlinkFeedIsNoLongerPoolPriced() public {
		ScriptedCLPool pool = _uniswapPool(tkn, 1_000_000e6);
		registrar.register(address(tkn), address(pool));
		MockAggregator chainlink = new MockAggregator(8, 1e8);

		vm.prank(admin);
		registrar.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (address(tkn), address(chainlink), 25 hours)));

		assertEq(registrar.poolPricedAdapter(address(tkn)), address(0));
	}

	function test_listsEachRegisteredOrMovedTokenOnce() public {
		ScriptedCLPool pool = _uniswapPool(tkn, 1_000_000e6);
		registrar.register(address(tkn), address(pool));
		MockERC20 other = new MockERC20('Other', 'OTH', 6);
		ScriptedCLPool otherPool = _uniswapPool(other, 1_000_000e6);
		vm.startPrank(admin);
		registrar.setPool(address(other), address(otherPool));
		registrar.setPool(address(tkn), address(pool)); // moved again: still listed once
		vm.stopPrank();

		address[] memory listed = registrar.getRegisteredAssets();
		assertEq(listed.length, 2);
		assertEq(listed[0], address(tkn));
		assertEq(listed[1], address(other));
	}

	function test_aTokenNeverRegisteredIsNotPoolPriced() public view {
		assertEq(registrar.poolPricedAdapter(address(usdc)), address(0));
	}

	// ─── construction ────────────────────────────────────────────────────────────

	function test_refusesAQuoteTheValueInterpreterDoesNotPrice() public {
		PoolPriceRegistrar.Wiring memory w = _wiring();
		w.quotes[1] = address(tkn);

		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.QuoteNotPriced.selector, address(tkn)));
		new PoolPriceRegistrar(w, admin);
	}

	function test_refusesAMissingVenue() public {
		PoolPriceRegistrar.Wiring memory w = _wiring();
		w.slipstreamFactories[2] = address(0);

		vm.expectRevert(PoolPriceRegistrar.ZeroAddress.selector);
		new PoolPriceRegistrar(w, admin);
	}

	// ─── Uniswap v4 ──────────────────────────────────────────────────────────────

function test_registerV4_pricesTheTokenFromItsPoolAfterWarmup() public {
		PoolKey memory key = _key(address(tkn), address(usdc), address(0));
		bytes32 id = _initPool(key, PLENTY);
		vm.prank(anyone);
		address adapter = registrar.registerV4(address(tkn), key);

		(address aggregator,,,) = vi.getAssetInfo(address(tkn));
		assertEq(aggregator, adapter, 'the VI primitive is the clone');
		assertEq(registrar.poolPricedAdapter(address(tkn)), adapter, 'long-tail for new funds');
		assertEq(V4PoolPriceAdapter(adapter).v4Extra().poolId, id);
		assertEq(IPoolPriceAdapter(adapter).config().quoteAsset, address(usdc));
		(address c0, address c1,,,) = registrar.v4KeyOf(address(tkn));
		assertEq(c0, key.currency0);
		assertEq(c1, key.currency1);

		vm.expectRevert(V4PoolPriceAdapter.NoPriceHistory.selector);
		vi.calcUsdRate(address(tkn));
		_sample(id, 4);
		assertEq(vi.calcUsdRate(address(tkn)), 1e18, '$1 at tick 0 (6-decimal token vs USDC)');
	}

	/// An unapproved pool can't be registered however deep it reads: a v4 pool's liquidity figure can be met by a
	/// position holding no quote token, or liquidity added for one call (final review 2026-10-08, H1; founder
	/// 2026-10-08: approve each v4 pool).
	function test_registerV4_refusesAnUnapprovedPool() public {
		PoolKey memory key = _key(address(tkn), address(usdc), address(0));
		bytes32 id = _initUnapprovedPool(key, PLENTY);
		vm.prank(anyone);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.PoolNotApproved.selector, id));
		registrar.registerV4(address(tkn), key);
	}

	/// The owner and pool approvers (the Admin Safe) approve and revoke pools; nobody else can, and an approver can do
	/// nothing else.
	function test_setPoolApproved_ownerOrApproverOnly() public {
		PoolKey memory key = _key(address(tkn), address(usdc), address(0));
		bytes32 id = _initUnapprovedPool(key, PLENTY);
		address safe = makeAddr('safe');
		vm.prank(safe);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.NotPoolApprover.selector, safe));
		registrar.setPoolApproved(id, true);

		vm.prank(admin);
		registrar.setPoolApprover(safe, true);
		vm.prank(safe);
		registrar.setPoolApproved(id, true);
		assertTrue(registrar.isPoolApproved(id));
		vm.prank(safe);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, safe));
		registrar.setHook(HOOK, true, '');

		vm.prank(safe);
		registrar.setPoolApproved(id, false);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.PoolNotApproved.selector, id));
		registrar.registerV4(address(tkn), key);
		vm.prank(admin);
		registrar.setPoolApprover(safe, false);
		vm.prank(safe);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.NotPoolApprover.selector, safe));
		registrar.setPoolApproved(id, true);
	}

	function test_registerV4_refusesAnUninitializedPool() public {
		PoolKey memory key = _key(address(tkn), address(usdc), address(0));
		vm.prank(admin);
		registrar.setPoolApproved(PoolKeyId.toId(key), true);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.PoolNotInitialized.selector, PoolKeyId.toId(key)));
		registrar.registerV4(address(tkn), key);
	}

	function test_registerV4_refusesAnAssetOutsideTheKey() public {
		PoolKey memory key = _key(address(tkn), address(usdc), address(0));
		_initPool(key, PLENTY);
		MockERC20 outsider = new MockERC20('Outsider', 'OUT', 18);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.AssetNotInPool.selector, address(outsider)));
		registrar.registerV4(address(outsider), key);
	}

	function test_registerV4_refusesAnUnapprovedQuote() public {
		MockERC20 dai = new MockERC20('Dai', 'DAI', 18);
		PoolKey memory key = _key(address(tkn), address(dai), address(0));
		_initPool(key, PLENTY);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.QuoteNotAllowed.selector, address(dai)));
		registrar.registerV4(address(tkn), key);
	}

	function test_registerV4_refusesAnUnapprovedHook() public {
		PoolKey memory key = _key(address(tkn), address(usdc), HOOK);
		_initPool(key, PLENTY);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.HookNotApproved.selector, HOOK));
		registrar.registerV4(address(tkn), key);

		vm.prank(admin);
		registrar.setHook(HOOK, true, abi.encode(admin));
		registrar.registerV4(address(tkn), key);
		(bool approved, bytes memory data) = registrar.hookOf(HOOK);
		assertTrue(approved);
		assertEq(data, abi.encode(admin));
		assertTrue(registrar.isHookAllowed(HOOK));
		assertTrue(registrar.isHookAllowed(address(0)), 'no hook is always allowed');
	}

	function test_registerV4_refusesAThinPool() public {
		PoolKey memory key = _key(address(tkn), address(usdc), address(0));
		_initPool(key, 24_999e6); // $24,999 of USDC as a full-range reserve at tick 0
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.NotEnoughLiquidity.selector, uint256(24_999e18)));
		registrar.registerV4(address(tkn), key);
	}

	function test_registerV4_refusesAnAlreadyPricedToken() public {
		PoolKey memory key = _key(address(weth), address(usdc), address(0));
		_initPool(key, PLENTY);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.AlreadyPriced.selector, address(weth)));
		registrar.registerV4(address(weth), key);
	}

	/// A native-ETH pool counts WETH as its quote (WETH must be approved; it prices native ETH).
	function test_registerV4_nativeEthCountsAsWeth() public {
		PoolKey memory key = _key(address(tkn), address(0), address(0));
		assertEq(key.currency0, address(0));
		_initPool(key, 1e18); // L·√P at tick 0 for a token1 asset: the token0 (ETH) reserve is L·Q96/√P = 1e18 wei
		// 1 ETH at $2,000 is below the floor: refused, measured in WETH's price
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.NotEnoughLiquidity.selector, uint256(2_000e18)));
		registrar.registerV4(address(tkn), key);
		_initPool(key, 20e18); // 20 ETH = $40k
		address adapter = registrar.registerV4(address(tkn), key);
		assertEq(IPoolPriceAdapter(adapter).config().quoteAsset, address(weth));
	}

	/// A memestock paired against a stock token on Uniswap v3: the stock is an approved quote.
	function test_register_v3PoolQuotedInAStockToken() public {
		ScriptedCLPool pool = _uniswapPoolIn(tkn, stock, 1_000_000e6);
		address adapter = registrar.register(address(tkn), address(pool));
		assertEq(registrar.poolPricedAdapter(address(tkn)), adapter);
		assertEq(vi.calcUsdRate(address(tkn)), 180e18, 'one stock per token at tick 0');
		assertEq(pool.observationCardinalityNext(), 450, 'its price history grown');
	}

	/// Review Focus 5: a pool-priced (long-tail) token can't become a quote for another.
	function test_setQuote_refusesPoolPricedTokens() public {
		ScriptedCLPool pool = _uniswapPoolIn(tkn, usdc, 1_000_000e6);
		registrar.register(address(tkn), address(pool));
		vm.prank(admin);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.QuoteIsPoolPriced.selector, address(tkn)));
		registrar.setQuote(address(tkn), true);

		MockERC20 unpriced = new MockERC20('Nope', 'NOPE', 18);
		vm.prank(admin);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.QuoteNotPriced.selector, address(unpriced)));
		registrar.setQuote(address(unpriced), true);
	}

	/// A token registered on a v3 pool, moved to a v4 pool by the owner, is listed once (final review 2026-10-08, I2).
	function test_getRegisteredAssets_listsATokenMovedToV4Once() public {
		ScriptedCLPool pool = _uniswapPoolIn(tkn, usdc, 1_000_000e6);
		registrar.register(address(tkn), address(pool));
		PoolKey memory key = _key(address(tkn), address(usdc), address(0));
		_initPool(key, PLENTY);
		vm.prank(admin);
		registrar.setPoolV4(address(tkn), key);
		address[] memory all = registrar.getRegisteredAssets();
		assertEq(all.length, 1);
		assertEq(all[0], address(tkn));
		assertEq(registrar.poolPricedAdapter(address(tkn)), registrar.adapterOf(address(tkn)), 'priced from its v4 pool now');
	}

	function test_setPoolV4_correctsWithoutALiquidityCheck() public {
		PoolKey memory key = _key(address(tkn), address(usdc), address(0));
		_initPool(key, PLENTY);
		address first = registrar.registerV4(address(tkn), key);
		PoolKey memory thin = PoolKey({currency0: key.currency0, currency1: key.currency1, fee: 3000, tickSpacing: 60, hooks: address(0)});
		bytes32 thinId = _initUnapprovedPool(thin, 1);
		vm.prank(admin);
		address second = registrar.setPoolV4(address(tkn), thin);
		assertTrue(registrar.isPoolApproved(thinId), 'the owner choosing a pool approves it');
		assertTrue(second != first);
		assertEq(registrar.poolPricedAdapter(address(tkn)), second);
		assertEq(registrar.getRegisteredAssets().length, 1, 'listed once');
	}

	function test_ownerOnly() public {
		bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone);
		vm.startPrank(anyone);
		vm.expectRevert(unauthorized);
		registrar.setHook(HOOK, true, '');
		vm.expectRevert(unauthorized);
		registrar.setQuote(address(usdc), false);
		vm.expectRevert(unauthorized);
		registrar.execute('');
		vm.expectRevert(unauthorized);
		registrar.acceptValueInterpreter();
		vm.expectRevert(unauthorized);
		registrar.setPoolV4(address(tkn), _key(address(tkn), address(usdc), address(0)));
		vm.expectRevert(unauthorized);
		registrar.setPoolApprover(anyone, true);
		vm.expectRevert(unauthorized);
		registrar.setPool(address(tkn), address(1));
		vm.stopPrank();
		assertEq(vi.owner(), address(registrar), 'the registrar owns the VI');
	}

	// ─── Aero ────────────────────────────────────────────────────────────────────

function test_aero_registersAnAeroPool() public {
		ScriptedCLPool pool = _aeroPool(tkn, usdc, PLENTY);
		vm.prank(anyone);
		address adapter = registrar.register(address(tkn), address(pool));

		assertEq(registrar.adapterOf(address(tkn)), adapter);
		assertEq(registrar.poolPricedAdapter(address(tkn)), adapter, 'long-tail');
		(address aggregator, uint32 heartbeat,,) = vi.getAssetInfo(address(tkn));
		assertEq(aggregator, adapter, 'the VI prices it from its Aero pool');
		assertEq(heartbeat, registrar.HEARTBEAT());
		assertEq(pool.observationCardinalityNext(), registrar.OBSERVATION_SLOTS(), 'price history grown');
		assertApproxEqRel(vi.calcUsdRate(address(tkn)), 1e18, 1e15, 'tick 0, 6/6 decimals: $1');
		address[] memory all = registrar.getRegisteredAssets();
		assertEq(all[all.length - 1], address(tkn), 'listed');
	}

	function test_aero_refusesUnderMinLiquidity() public {
		ScriptedCLPool pool = _aeroPool(tkn, usdc, 20_000e6); // $20k of USDC
		// 20,000 less the five slices' rounding of the harmonic mean
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.NotEnoughLiquidity.selector, 19_999_999_999_000_000_000_000));
		registrar.register(address(tkn), address(pool));
	}

	function test_aero_refusesUnapprovedQuote() public {
		MockERC20 other = new MockERC20('Other', 'OTH', 6);
		ScriptedCLPool pool = _aeroPool(tkn, other, PLENTY);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.QuoteNotAllowed.selector, address(other)));
		registrar.register(address(tkn), address(pool));
	}

	function test_aero_refusesANonCanonicalPool() public {
		ScriptedCLPool pool = _pool(tkn, usdc, address(aero), PLENTY); // claims Aero's factory, which doesn't know it
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.NotCanonicalPool.selector, address(pool)));
		registrar.register(address(tkn), address(pool));
	}

	/// A registrar that doesn't own the VI yet can't register: nothing is half-registered.
	function test_registerRevertsBeforeItOwnsTheVi() public {
		PoolPriceRegistrar early = new PoolPriceRegistrar(_wiring(), admin); // the VI belongs to `registrar`
		ScriptedCLPool pool = _aeroPool(tkn, usdc, PLENTY);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(early)));
		early.register(address(tkn), address(pool));
		assertFalse(vi.isSupportedAsset(address(tkn)), 'nothing half-registered');
		assertEq(early.adapterOf(address(tkn)), address(0));
	}

	/// The owner moves an Aero-priced token to a Uniswap v3 pool (a correction): the new adapter is the one named.
	function test_poolPricedAdapter_followsTheVi() public {
		ScriptedCLPool aeroPool = _aeroPool(tkn, usdc, PLENTY);
		address aeroAdapter = registrar.register(address(tkn), address(aeroPool));
		ScriptedCLPool uniPool = _uniswapPoolIn(tkn, usdc, PLENTY);
		vm.prank(admin);
		address uniAdapter = registrar.setPool(address(tkn), address(uniPool));
		assertTrue(uniAdapter != aeroAdapter);
		assertEq(registrar.poolPricedAdapter(address(tkn)), uniAdapter);
	}

	/// funds-keeper's USDC exit reads these off a fund's registrar (src/protect/usdc-exit.ts).
	function test_exposesTheKeepersVenueReads() public view {
		assertEq(registrar.uniswapV3Factory(), address(uniswap));
		assertEq(registrar.slipstreamFactory1(), address(slipstreams[0]));
		assertEq(registrar.slipstreamFactory2(), address(slipstreams[1]));
		assertEq(registrar.slipstreamFactory3(), address(slipstreams[2]));
		assertEq(registrar.aerodromeBasicFactory(), address(aerodrome));
		assertEq(registrar.aeroFactory(), address(aero));
		assertEq(registrar.weth(), address(weth));
	}

	/// A v4-priced token re-pointed by the owner to its Aero pool has no v4 key left: the keeper doesn't sell it on v4.
	function test_v4KeyOf_clearedWhenRepointedOffV4() public {
		PoolKey memory key = _key(address(tkn), address(usdc), address(0));
		_initPool(key, PLENTY);
		registrar.registerV4(address(tkn), key);
		(address c0,,,,) = registrar.v4KeyOf(address(tkn));
		assertEq(c0, key.currency0);
		ScriptedCLPool pool = _aeroPool(tkn, usdc, PLENTY);
		vm.prank(admin);
		registrar.setPool(address(tkn), address(pool));
		(c0,,,,) = registrar.v4KeyOf(address(tkn));
		assertEq(c0, address(0), 'no v4 sale for a token priced on Aero');
	}

	/// The open path too (review 2026-11-16): the owner delists a v4-priced token, then anyone registers it on its Aero
	/// pool. The key left behind would send the keeper's sale of it to the v4 pool it is no longer priced on.
	function test_v4KeyOf_clearedWhenAnyoneRegistersItOffV4() public {
		PoolKey memory key = _key(address(tkn), address(usdc), address(0));
		_initPool(key, PLENTY);
		registrar.registerV4(address(tkn), key);
		vm.prank(admin);
		registrar.execute(abi.encodeCall(ValueInterpreter.removePrimitive, (address(tkn))));
		ScriptedCLPool pool = _aeroPool(tkn, usdc, PLENTY);

		vm.prank(anyone);
		registrar.register(address(tkn), address(pool));

		(address c0, address c1,,,) = registrar.v4KeyOf(address(tkn));
		assertEq(c0, address(0), 'no v4 sale for a token priced on Aero');
		assertEq(c1, address(0), 'an empty key (the keeper reads currency1)');
	}

	/// A revoked hook takes no new registrations (review 2026-11-16: nothing tested the revocation).
	function test_setHook_revokingStopsRegistrationsThroughIt() public {
		PoolKey memory key = _key(address(tkn), address(usdc), HOOK);
		_initPool(key, PLENTY);
		vm.prank(admin);
		registrar.setHook(HOOK, true, abi.encode(admin));
		vm.prank(admin);
		registrar.setHook(HOOK, false, '');

		assertFalse(registrar.isHookAllowed(HOOK));
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.HookNotApproved.selector, HOOK));
		registrar.registerV4(address(tkn), key);
	}

	/// Review 2026-10-25: a token priced from its Aero pool can't become a quote; revoking a quote needs no check.
	function test_aPoolPricedAeroTokenCantBecomeAQuote() public {
		registrar.register(address(tkn), address(_aeroPool(tkn, usdc, PLENTY)));
		vm.startPrank(admin);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.QuoteIsPoolPriced.selector, address(tkn)));
		registrar.setQuote(address(tkn), true);
		registrar.setQuote(address(usdc), false); // revoking needs no check
		vm.stopPrank();
		assertFalse(registrar.isQuote(address(usdc)));
	}

	function test_ownerSetPoolRepointsWithoutTheLiquidityCheck() public {
		ScriptedCLPool thin = _aeroPool(tkn, usdc, 1_000e6);
		vm.prank(admin);
		address adapter = registrar.setPool(address(tkn), address(thin));
		assertEq(registrar.poolPricedAdapter(address(tkn)), adapter);
	}
}
