// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {IPoolPriceAdapter} from '../src/interfaces/IPoolPriceAdapter.sol';
import {PoolPriceRegistrar} from '../src/pricing/PoolPriceRegistrar.sol';
import {PoolPriceRegistrarWindowed} from '../src/pricing/PoolPriceRegistrarWindowed.sol';
import {PoolPriceRegistrarV2} from '../src/pricing/PoolPriceRegistrarV2.sol';
import {V4PoolPriceAdapter} from '../src/pricing/V4PoolPriceAdapter.sol';
import {V4PriceSampler} from '../src/pricing/V4PriceSampler.sol';
import {IV4StateView, PoolKey, PoolKeyId} from '../src/interfaces/external/IUniswapV4.sol';
import {TickMath} from '../src/libraries/TickMath.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';
import {
	ScriptedCLPool,
	MockUniswapV3Factory,
	MockSlipstreamFactory,
	MockAerodromeBasicFactory
} from './utils/PoolPriceMocks.sol';
import {MockStateView} from './utils/V4Mocks.sol';

/// @notice PoolPriceRegistrarV2 (spec 2026-10-08 §4.3): v4 + v3/Aerodrome registrations against an extended quote
///         list, owning today's registrar (which keeps owning the VI), answering long-tail status for both.
contract PoolPriceRegistrarV2Test is Test {
	ValueInterpreter internal vi;
	PoolPriceRegistrar internal old;
	PoolPriceRegistrarV2 internal v2;
	V4PriceSampler internal sampler;
	MockStateView internal stateView;
	MockUniswapV3Factory internal uniswap;
	MockSlipstreamFactory[3] internal slipstreams;
	MockAerodromeBasicFactory internal aerodrome;
	MockERC20 internal usdc;
	MockERC20 internal weth;
	MockERC20 internal stock; // a Chainlink-priced stock token (NVDAc-like), $180
	MockERC20 internal tkn;
	address internal admin = makeAddr('admin');
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
		tkn = new MockERC20('Memestock', 'MEME', 6);
		vm.startPrank(admin);
		vi.addPrimitive(address(usdc), address(new MockAggregator(8, 1e8)), 25 hours);
		vi.addPrimitive(address(weth), address(new MockAggregator(8, 2000e8)), 1 hours);
		vi.addPrimitive(address(stock), address(new MockAggregator(8, 180e8)), 5 days);
		vm.stopPrank();

		uniswap = new MockUniswapV3Factory();
		aerodrome = new MockAerodromeBasicFactory();
		for (uint256 i; i < 3; ++i) slipstreams[i] = new MockSlipstreamFactory();
		address[] memory oldQuotes = new address[](2);
		oldQuotes[0] = address(usdc);
		oldQuotes[1] = address(weth);
		old = PoolPriceRegistrar(address(new PoolPriceRegistrarWindowed(
			PoolPriceRegistrarWindowed.Wiring({
				valueInterpreter: vi,
				uniswapV3Factory: address(uniswap),
				slipstreamFactories: [address(slipstreams[0]), address(slipstreams[1]), address(slipstreams[2])],
				aerodromeBasicFactory: address(aerodrome),
				quotes: oldQuotes
			}),
			admin
		)));
		vm.startPrank(admin);
		vi.transferOwnership(address(old));
		old.execute(abi.encodeCall(Ownable2Step.acceptOwnership, ()));
		vm.stopPrank();

		stateView = new MockStateView();
		sampler = new V4PriceSampler(IV4StateView(address(stateView)), admin);
		vm.prank(admin);
		sampler.setKeeper(keeper, true);
		address[] memory quotes = new address[](3);
		quotes[0] = address(usdc);
		quotes[1] = address(weth);
		quotes[2] = address(stock);
		v2 = new PoolPriceRegistrarV2(old, IV4StateView(address(stateView)), POOL_MANAGER, sampler, address(weth), quotes, admin);
		// the hand-over the owner steps do
		vm.startPrank(admin);
		old.transferOwnership(address(v2));
		v2.acceptOldRegistrar();
		vm.stopPrank();
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	/// @dev A v4 key for `asset` against `quote` (address(0) = native ETH) at tick 0, sorted like the PoolManager.
	function _key(address asset, address quote, address hooks) internal pure returns (PoolKey memory key) {
		(address c0, address c1) = asset < quote ? (asset, quote) : (quote, asset);
		key = PoolKey({currency0: c0, currency1: c1, fee: 10_000, tickSpacing: 200, hooks: hooks});
	}

	/// @dev An initialized pool the owner has approved (registration's gate); `_initUnapprovedPool` for one it hasn't.
	function _initPool(PoolKey memory key, uint128 liquidity) internal returns (bytes32 id) {
		id = _initUnapprovedPool(key, liquidity);
		vm.prank(admin);
		v2.setPoolApproved(id, true);
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

	function _uniswapPool(MockERC20 asset, MockERC20 quote, uint256 quoteHeld) internal returns (ScriptedCLPool pool) {
		pool = new ScriptedCLPool(address(asset), address(quote), address(uniswap), 3000, 60);
		pool.setHistory(2 days);
		pool.setOracle(0, PLENTY);
		quote.mint(address(pool), quoteHeld);
		uniswap.setPool(address(asset), address(quote), 3000, address(pool));
	}

	// ─── registerV4 ──────────────────────────────────────────────────────────────

	function test_registerV4_pricesTheTokenFromItsPoolAfterWarmup() public {
		PoolKey memory key = _key(address(tkn), address(usdc), address(0));
		bytes32 id = _initPool(key, PLENTY);
		vm.prank(anyone);
		address adapter = v2.registerV4(address(tkn), key);

		(address aggregator,,,) = vi.getAssetInfo(address(tkn));
		assertEq(aggregator, adapter, 'the VI primitive is the clone');
		assertEq(v2.poolPricedAdapter(address(tkn)), adapter, 'long-tail for new funds');
		assertEq(V4PoolPriceAdapter(adapter).v4Extra().poolId, id);
		assertEq(IPoolPriceAdapter(adapter).config().quoteAsset, address(usdc));
		(address c0, address c1,,,) = v2.v4KeyOf(address(tkn));
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
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrarV2.PoolNotApproved.selector, id));
		v2.registerV4(address(tkn), key);
	}

	/// The owner and pool approvers (the Admin Safe) approve and revoke pools; nobody else can, and an approver can do
	/// nothing else.
	function test_setPoolApproved_ownerOrApproverOnly() public {
		PoolKey memory key = _key(address(tkn), address(usdc), address(0));
		bytes32 id = _initUnapprovedPool(key, PLENTY);
		address safe = makeAddr('safe');
		vm.prank(safe);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrarV2.NotPoolApprover.selector, safe));
		v2.setPoolApproved(id, true);

		vm.prank(admin);
		v2.setPoolApprover(safe, true);
		vm.prank(safe);
		v2.setPoolApproved(id, true);
		assertTrue(v2.isPoolApproved(id));
		vm.prank(safe);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, safe));
		v2.setHook(HOOK, true, '');

		vm.prank(safe);
		v2.setPoolApproved(id, false);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrarV2.PoolNotApproved.selector, id));
		v2.registerV4(address(tkn), key);
		vm.prank(admin);
		v2.setPoolApprover(safe, false);
		vm.prank(safe);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrarV2.NotPoolApprover.selector, safe));
		v2.setPoolApproved(id, true);
	}

	function test_registerV4_refusesAnUninitializedPool() public {
		PoolKey memory key = _key(address(tkn), address(usdc), address(0));
		vm.prank(admin);
		v2.setPoolApproved(PoolKeyId.toId(key), true);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrarV2.PoolNotInitialized.selector, PoolKeyId.toId(key)));
		v2.registerV4(address(tkn), key);
	}

	function test_registerV4_refusesAnAssetOutsideTheKey() public {
		PoolKey memory key = _key(address(tkn), address(usdc), address(0));
		_initPool(key, PLENTY);
		MockERC20 outsider = new MockERC20('Outsider', 'OUT', 18);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrarV2.AssetNotInPool.selector, address(outsider)));
		v2.registerV4(address(outsider), key);
	}

	function test_registerV4_refusesAnUnapprovedQuote() public {
		MockERC20 dai = new MockERC20('Dai', 'DAI', 18);
		PoolKey memory key = _key(address(tkn), address(dai), address(0));
		_initPool(key, PLENTY);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrarV2.QuoteNotAllowed.selector, address(dai)));
		v2.registerV4(address(tkn), key);
	}

	function test_registerV4_refusesAnUnapprovedHook() public {
		PoolKey memory key = _key(address(tkn), address(usdc), HOOK);
		_initPool(key, PLENTY);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrarV2.HookNotApproved.selector, HOOK));
		v2.registerV4(address(tkn), key);

		vm.prank(admin);
		v2.setHook(HOOK, true, abi.encode(admin));
		v2.registerV4(address(tkn), key);
		(bool approved, bytes memory data) = v2.hookOf(HOOK);
		assertTrue(approved);
		assertEq(data, abi.encode(admin));
		assertTrue(v2.isHookAllowed(HOOK));
		assertTrue(v2.isHookAllowed(address(0)), 'no hook is always allowed');
	}

	function test_registerV4_refusesAThinPool() public {
		PoolKey memory key = _key(address(tkn), address(usdc), address(0));
		_initPool(key, 24_999e6); // $24,999 of USDC as a full-range reserve at tick 0
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrarV2.NotEnoughLiquidity.selector, uint256(24_999e18)));
		v2.registerV4(address(tkn), key);
	}

	function test_registerV4_refusesAnAlreadyPricedToken() public {
		PoolKey memory key = _key(address(weth), address(usdc), address(0));
		_initPool(key, PLENTY);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrarV2.AlreadyPriced.selector, address(weth)));
		v2.registerV4(address(weth), key);
	}

	/// A native-ETH pool counts WETH as its quote (WETH must be approved; it prices native ETH).
	function test_registerV4_nativeEthCountsAsWeth() public {
		PoolKey memory key = _key(address(tkn), address(0), address(0));
		assertEq(key.currency0, address(0));
		_initPool(key, 1e18); // L·√P at tick 0 for a token1 asset: the token0 (ETH) reserve is L·Q96/√P = 1e18 wei
		// 1 ETH at $2,000 is below the floor: refused, measured in WETH's price
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrarV2.NotEnoughLiquidity.selector, uint256(2_000e18)));
		v2.registerV4(address(tkn), key);
		_initPool(key, 20e18); // 20 ETH = $40k
		address adapter = v2.registerV4(address(tkn), key);
		assertEq(IPoolPriceAdapter(adapter).config().quoteAsset, address(weth));
	}

	// ─── register (v3 / Aerodrome) with the extended quotes ──────────────────────

	/// A memestock paired against a stock token on Uniswap v3: today's registrar refuses the quote, V2 takes it.
	function test_register_v3PoolQuotedInAStockToken() public {
		ScriptedCLPool pool = _uniswapPool(tkn, stock, 1_000_000e6);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.QuoteNotAllowed.selector, address(stock)));
		old.register(address(tkn), address(pool));
		address adapter = v2.register(address(tkn), address(pool));
		assertEq(v2.poolPricedAdapter(address(tkn)), adapter);
		assertEq(vi.calcUsdRate(address(tkn)), 180e18, 'one stock per token at tick 0');
		assertEq(pool.observationCardinalityNext(), 450, 'its price history grown, as today');
	}

	// ─── quotes, fallback, listings ──────────────────────────────────────────────

	/// Review Focus 5: a pool-priced (long-tail) token can't become a quote for another.
	function test_setQuote_refusesPoolPricedTokens() public {
		ScriptedCLPool pool = _uniswapPool(tkn, usdc, 1_000_000e6);
		old.register(address(tkn), address(pool));
		vm.prank(admin);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrarV2.QuoteIsPoolPriced.selector, address(tkn)));
		v2.setQuote(address(tkn), true);

		MockERC20 unpriced = new MockERC20('Nope', 'NOPE', 18);
		vm.prank(admin);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrarV2.QuoteNotPriced.selector, address(unpriced)));
		v2.setQuote(address(unpriced), true);
	}

	function test_poolPricedAdapter_fallsBackToTodaysRegistrar() public {
		ScriptedCLPool pool = _uniswapPool(tkn, usdc, 1_000_000e6);
		address adapter = old.register(address(tkn), address(pool));
		assertEq(v2.poolPricedAdapter(address(tkn)), adapter);
		assertEq(v2.poolPricedAdapter(address(usdc)), address(0), 'Chainlink-priced: not long-tail');
		assertEq(v2.MIN_LIQUIDITY_USD(), 25_000);
	}

	function test_getRegisteredAssets_concatenatesBoth() public {
		ScriptedCLPool pool = _uniswapPool(tkn, usdc, 1_000_000e6);
		old.register(address(tkn), address(pool));
		MockERC20 other = new MockERC20('Other', 'OTH', 6);
		PoolKey memory key = _key(address(other), address(usdc), address(0));
		_initPool(key, PLENTY);
		v2.registerV4(address(other), key);
		address[] memory all = v2.getRegisteredAssets();
		assertEq(all.length, 2);
		assertEq(all[0], address(tkn));
		assertEq(all[1], address(other));
	}

	/// A token today's registrar registered, moved here by the owner, is listed once (final review 2026-10-08, I2).
	function test_getRegisteredAssets_listsAMovedTokenOnce() public {
		ScriptedCLPool pool = _uniswapPool(tkn, usdc, 1_000_000e6);
		old.register(address(tkn), address(pool));
		PoolKey memory key = _key(address(tkn), address(usdc), address(0));
		_initPool(key, PLENTY);
		vm.prank(admin);
		v2.setPoolV4(address(tkn), key);
		address[] memory all = v2.getRegisteredAssets();
		assertEq(all.length, 1);
		assertEq(all[0], address(tkn));
		assertEq(v2.poolPricedAdapter(address(tkn)), v2.adapterOf(address(tkn)), 'priced from its v4 pool now');
	}

	/// The owner's passthrough keeps Chainlink listings and corrections working through today's registrar.
	function test_callOldRegistrar_listsAChainlinkToken() public {
		MockERC20 listed = new MockERC20('Listed', 'LST', 18);
		MockAggregator feed = new MockAggregator(8, 42e8);
		bytes memory listing = abi.encodeCall(ValueInterpreter.addPrimitive, (address(listed), address(feed), 1 hours));
		vm.prank(admin);
		v2.callOldRegistrar(abi.encodeCall(PoolPriceRegistrar.execute, (listing)));
		assertEq(vi.calcUsdRate(address(listed)), 42e18);
		bytes memory bad = abi.encodeCall(ValueInterpreter.addPrimitive, (address(0), address(feed), 1 hours));
		vm.prank(admin);
		vm.expectRevert(ValueInterpreter.ZeroAddress.selector); // the VI's own revert bubbles through both registrars
		v2.callOldRegistrar(abi.encodeCall(PoolPriceRegistrar.execute, (bad)));
	}

	function test_setPoolV4_correctsWithoutALiquidityCheck() public {
		PoolKey memory key = _key(address(tkn), address(usdc), address(0));
		_initPool(key, PLENTY);
		address first = v2.registerV4(address(tkn), key);
		PoolKey memory thin = PoolKey({currency0: key.currency0, currency1: key.currency1, fee: 3000, tickSpacing: 60, hooks: address(0)});
		bytes32 thinId = _initUnapprovedPool(thin, 1);
		vm.prank(admin);
		address second = v2.setPoolV4(address(tkn), thin);
		assertTrue(v2.isPoolApproved(thinId), 'the owner choosing a pool approves it');
		assertTrue(second != first);
		assertEq(v2.poolPricedAdapter(address(tkn)), second);
		assertEq(v2.getRegisteredAssets().length, 1, 'listed once');
	}

	function test_ownerOnly() public {
		bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone);
		vm.startPrank(anyone);
		vm.expectRevert(unauthorized);
		v2.setHook(HOOK, true, '');
		vm.expectRevert(unauthorized);
		v2.setQuote(address(usdc), false);
		vm.expectRevert(unauthorized);
		v2.callOldRegistrar('');
		vm.expectRevert(unauthorized);
		v2.acceptOldRegistrar();
		vm.expectRevert(unauthorized);
		v2.setPool(address(tkn), address(1));
		vm.stopPrank();
		assertEq(old.owner(), address(v2), 'V2 owns today registrar');
		assertEq(vi.owner(), address(old), 'which keeps owning the VI');
	}
}
