// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {PoolPriceRegistrar} from '../src/pricing/PoolPriceRegistrar.sol';
import {PoolPriceRegistrarV2} from '../src/pricing/PoolPriceRegistrarV2.sol';
import {PoolPriceRegistrarV3} from '../src/pricing/PoolPriceRegistrarV3.sol';
import {V4PriceSampler} from '../src/pricing/V4PriceSampler.sol';
import {IV4StateView} from '../src/interfaces/external/IUniswapV4.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';
import {ScriptedCLPool, MockUniswapV3Factory, MockSlipstreamFactory, MockAerodromeBasicFactory} from './utils/PoolPriceMocks.sol';
import {MockStateView} from './utils/V4Mocks.sol';

/// @notice PoolPriceRegistrarV3 (FrostyFi 2026-10-25): registrar V2 plus Aero's CL pools, owning V2, answering
///         long-tail status for its own tokens, V2's and today's registrar's.
contract PoolPriceRegistrarV3Test is Test {
	ValueInterpreter internal vi;
	PoolPriceRegistrar internal old;
	PoolPriceRegistrarV2 internal v2;
	PoolPriceRegistrarV3 internal v3;
	MockUniswapV3Factory internal uniswap;
	MockSlipstreamFactory internal aero; // Aero's CL factory has Slipstream's getPool(token0, token1, tickSpacing)
	MockSlipstreamFactory[3] internal slipstreams;
	MockERC20 internal usdc;
	MockERC20 internal weth;
	MockERC20 internal tkn;
	address internal admin = makeAddr('admin');
	address internal anyone = makeAddr('anyone');

	/// @dev USDC liquidity L at tick 0 is L raw USDC as a full-range reserve (PoolPriceRegistrarV2Test).
	uint128 internal constant PLENTY = 1_000_000e6;

	function setUp() public {
		vm.warp(30 days);
		vi = new ValueInterpreter(admin);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		weth = new MockERC20('Wrapped Ether', 'WETH', 18);
		tkn = new MockERC20('Memecoin', 'MEME', 6);
		vm.startPrank(admin);
		vi.addPrimitive(address(usdc), address(new MockAggregator(8, 1e8)), 25 hours);
		vi.addPrimitive(address(weth), address(new MockAggregator(8, 2000e8)), 1 hours);
		vm.stopPrank();

		uniswap = new MockUniswapV3Factory();
		aero = new MockSlipstreamFactory();
		for (uint256 i; i < 3; ++i) slipstreams[i] = new MockSlipstreamFactory();
		address[] memory quotes = new address[](2);
		quotes[0] = address(usdc);
		quotes[1] = address(weth);
		old = new PoolPriceRegistrar(
			PoolPriceRegistrar.Wiring({
				valueInterpreter: vi,
				uniswapV3Factory: address(uniswap),
				slipstreamFactories: [address(slipstreams[0]), address(slipstreams[1]), address(slipstreams[2])],
				aerodromeBasicFactory: address(new MockAerodromeBasicFactory()),
				quotes: quotes
			}),
			admin
		);
		vm.startPrank(admin);
		vi.transferOwnership(address(old));
		old.execute(abi.encodeCall(Ownable2Step.acceptOwnership, ()));
		vm.stopPrank();

		MockStateView stateView = new MockStateView();
		V4PriceSampler sampler = new V4PriceSampler(IV4StateView(address(stateView)), admin);
		v2 = new PoolPriceRegistrarV2(old, IV4StateView(address(stateView)), address(0x4444), sampler, address(weth), quotes, admin);
		v3 = new PoolPriceRegistrarV3(v2, address(aero), admin);
		// the hand-overs the owner steps do: today's → V2 (2026-10-09), V2 → V3
		vm.startPrank(admin);
		old.transferOwnership(address(v2));
		v2.acceptOldRegistrar();
		v2.transferOwnership(address(v3));
		v3.acceptRegistrarV2();
		vm.stopPrank();
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

	function _uniswapPool(MockERC20 asset, MockERC20 quote) internal returns (ScriptedCLPool pool) {
		pool = new ScriptedCLPool(address(asset), address(quote), address(uniswap), 3000, 60);
		pool.setHistory(2 days);
		pool.setOracle(0, PLENTY);
		quote.mint(address(pool), PLENTY);
		uniswap.setPool(address(asset), address(quote), 3000, address(pool));
	}

	function test_registersAnAeroPool() public {
		ScriptedCLPool pool = _aeroPool(tkn, usdc, PLENTY);
		vm.prank(anyone);
		address adapter = v3.register(address(tkn), address(pool));

		assertEq(v3.adapterOf(address(tkn)), adapter);
		assertEq(v3.poolPricedAdapter(address(tkn)), adapter, 'long-tail for funds on V3');
		(address aggregator, uint32 heartbeat,,) = vi.getAssetInfo(address(tkn));
		assertEq(aggregator, adapter, 'the VI prices it from its Aero pool');
		assertEq(heartbeat, v3.HEARTBEAT());
		assertEq(pool.observationCardinalityNext(), v3.OBSERVATION_SLOTS(), 'price history grown');
		assertApproxEqRel(vi.calcUsdRate(address(tkn)), 1e18, 1e15, 'tick 0, 6/6 decimals: $1');
		address[] memory all = v3.getRegisteredAssets();
		assertEq(all[all.length - 1], address(tkn), 'listed once, after V2 and today\'s registrar');
	}

	function test_constantsAreV2s() public view {
		assertEq(v3.MIN_LIQUIDITY_USD(), v2.MIN_LIQUIDITY_USD());
		assertEq(v3.OBSERVATION_SLOTS(), v2.OBSERVATION_SLOTS());
		assertEq(v3.HEARTBEAT(), v2.HEARTBEAT());
		assertEq(v3.concentratedAdapter(), v2.concentratedAdapter(), 'the same price adapter');
		assertEq(address(v3.valueInterpreter()), address(vi));
	}

	function test_refusesUnderMinLiquidity() public {
		ScriptedCLPool pool = _aeroPool(tkn, usdc, 20_000e6); // $20k of USDC
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrarV3.NotEnoughLiquidity.selector, 20_000e18));
		v3.register(address(tkn), address(pool));
	}

	function test_refusesUnapprovedQuote() public {
		MockERC20 other = new MockERC20('Other', 'OTH', 6);
		ScriptedCLPool pool = _aeroPool(tkn, other, PLENTY);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrarV3.QuoteNotAllowed.selector, address(other)));
		v3.register(address(tkn), address(pool));
	}

	function test_refusesOtherVenues() public {
		ScriptedCLPool pool = _pool(tkn, usdc, address(slipstreams[0]), PLENTY);
		slipstreams[0].setPool(address(tkn), address(usdc), 10, address(pool));
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrarV3.NotAeroPool.selector, address(slipstreams[0])));
		v3.register(address(tkn), address(pool));
	}

	function test_refusesANonCanonicalPool() public {
		ScriptedCLPool pool = _pool(tkn, usdc, address(aero), PLENTY); // claims Aero's factory, which doesn't know it
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrarV3.NotCanonicalPool.selector, address(pool)));
		v3.register(address(tkn), address(pool));
	}

	function test_alreadyPriced() public {
		ScriptedCLPool pool = _aeroPool(tkn, usdc, PLENTY);
		v3.register(address(tkn), address(pool));
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrarV3.AlreadyPriced.selector, address(tkn)));
		v3.register(address(tkn), address(pool));
	}

	function test_registerRevertsBeforeHandoff() public {
		PoolPriceRegistrarV3 early = new PoolPriceRegistrarV3(v2, address(aero), admin); // V2 belongs to `v3`
		ScriptedCLPool pool = _aeroPool(tkn, usdc, PLENTY);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(early)));
		early.register(address(tkn), address(pool));
		assertFalse(vi.isSupportedAsset(address(tkn)), 'nothing half-registered');
		assertEq(early.adapterOf(address(tkn)), address(0));
	}

	function test_poolPricedAdapter_followsTheVi() public {
		ScriptedCLPool aeroPool = _aeroPool(tkn, usdc, PLENTY);
		address v3Adapter = v3.register(address(tkn), address(aeroPool));
		// the owner moves it to a Uniswap v3 pool through V2 (a correction): V3 must name V2's adapter now
		ScriptedCLPool uniPool = _uniswapPool(tkn, usdc);
		vm.prank(admin);
		v3.callRegistrarV2(abi.encodeCall(PoolPriceRegistrarV2.setPool, (address(tkn), address(uniPool))));
		address v2Adapter = v2.adapterOf(address(tkn));
		assertTrue(v2Adapter != v3Adapter);
		assertEq(v3.poolPricedAdapter(address(tkn)), v2Adapter);
	}

	function test_seesV2AndV1Tokens() public {
		MockERC20 viaV2 = new MockERC20('Via V2', 'V2T', 6);
		MockERC20 viaV1 = new MockERC20('Via V1', 'V1T', 6);
		address v2Adapter = v2.register(address(viaV2), address(_uniswapPool(viaV2, usdc)));
		// today's registrar's open registration keeps working: it still owns the VI
		address v1Adapter = old.register(address(viaV1), address(_uniswapPool(viaV1, usdc)));
		assertEq(v3.poolPricedAdapter(address(viaV2)), v2Adapter, 'a V2 token is long-tail on V3');
		assertEq(v3.poolPricedAdapter(address(viaV1)), v1Adapter, 'so is a token from today\'s registrar');
		assertEq(v3.poolPricedAdapter(address(usdc)), address(0), 'a Chainlink-priced token is not');
	}

	function test_forwardsV4ApprovalsAndQuotesThroughTheOwnerPassthrough() public {
		bytes32 id = keccak256('a v4 pool');
		address hook = makeAddr('hook');
		MockERC20 stock = new MockERC20('NVIDIA', 'NVDAc', 8);
		MockAggregator feed = new MockAggregator(8, 180e8);
		// a Chainlink listing through V3 → V2.callOldRegistrar → today's registrar's execute → the VI
		bytes memory listing = abi.encodeCall(ValueInterpreter.addPrimitive, (address(stock), address(feed), 5 days));
		vm.prank(admin);
		v3.callRegistrarV2(
			abi.encodeCall(PoolPriceRegistrarV2.callOldRegistrar, (abi.encodeCall(PoolPriceRegistrar.execute, (listing))))
		);
		assertTrue(vi.isSupportedAsset(address(stock)));
		assertFalse(v3.isQuote(address(stock)));

		vm.startPrank(admin);
		v3.callRegistrarV2(abi.encodeCall(PoolPriceRegistrarV2.setPoolApproved, (id, true)));
		v3.callRegistrarV2(abi.encodeCall(PoolPriceRegistrarV2.setHook, (hook, true, hex'beef')));
		v3.setQuote(address(stock), true);
		vm.stopPrank();

		assertTrue(v3.isPoolApproved(id));
		assertTrue(v3.isHookAllowed(hook));
		assertTrue(v3.isHookAllowed(address(0)), 'no hook is allowed');
		(bool approved, bytes memory hookData) = v3.hookOf(hook);
		assertTrue(approved);
		assertEq(hookData, hex'beef');
		assertTrue(v3.isQuote(address(stock)), 'a stock quote set through V3 is V2\'s');
	}

	function test_callOldRegistrarIsV2sOneHopFurther() public {
		MockERC20 stock = new MockERC20('Apple', 'AAPLc', 8);
		MockAggregator feed = new MockAggregator(8, 250e8);
		bytes memory listing = abi.encodeCall(ValueInterpreter.addPrimitive, (address(stock), address(feed), 5 days));
		// what ListingModuleBook.execute sends, now to V3: the same call and the same return as V2's
		vm.prank(admin);
		bytes memory result = v3.callOldRegistrar(abi.encodeCall(PoolPriceRegistrar.execute, (listing)));
		assertEq(abi.decode(result, (bytes)).length, 0, 'addPrimitive returns nothing');
		(address aggregator,,,) = vi.getAssetInfo(address(stock));
		assertEq(aggregator, address(feed));

		vm.prank(anyone);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
		v3.callOldRegistrar(abi.encodeCall(PoolPriceRegistrar.execute, (listing)));
		vm.prank(admin);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
		v2.callOldRegistrar(abi.encodeCall(PoolPriceRegistrar.execute, (listing))); // the deployer no longer owns V2
	}

	/// funds-keeper's USDC exit reads these off a fund's registrar (src/protect/usdc-exit.ts): they must be V2's.
	function test_forwardsTheKeepersVenueReads() public view {
		assertEq(v3.uniswapV3Factory(), v2.uniswapV3Factory());
		assertEq(v3.slipstreamFactory1(), v2.slipstreamFactory1());
		assertEq(v3.slipstreamFactory2(), v2.slipstreamFactory2());
		assertEq(v3.slipstreamFactory3(), v2.slipstreamFactory3());
		assertEq(v3.aerodromeBasicFactory(), v2.aerodromeBasicFactory());
		assertEq(v3.weth(), v2.weth());
		assertEq(v3.weth(), address(weth));
	}

	function test_v4KeyOf_isV2sUnlessV3sAeroPriceIsLive() public {
		MockERC20 viaV2 = new MockERC20('Via V2', 'V2T', 6);
		// a token V2 holds a v4 key for: the stored key is what the keeper sells on
		bytes32 slot = keccak256(abi.encode(address(viaV2), uint256(_v4KeyOfSlot())));
		vm.store(address(v2), slot, bytes32(uint256(uint160(address(viaV2)))));
		(address c0,,,,) = v3.v4KeyOf(address(viaV2));
		assertEq(c0, address(viaV2), 'V2\'s key, forwarded');
		// the owner re-points it to its Aero pool through V3: V2's key is stale, V3 answers none
		ScriptedCLPool pool = _aeroPool(viaV2, usdc, PLENTY);
		vm.prank(admin);
		v3.setPool(address(viaV2), address(pool));
		(c0,,,,) = v3.v4KeyOf(address(viaV2));
		assertEq(c0, address(0), 'no v4 sale for a token priced on Aero');
	}

	/// @dev PoolPriceRegistrarV2's `v4KeyOf` mapping slot (`forge inspect PoolPriceRegistrarV2 storageLayout`).
	function _v4KeyOfSlot() internal pure returns (uint256) {
		return 5;
	}

	function test_passthroughBubblesV2Reverts() public {
		vm.prank(admin);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrarV2.QuoteNotPriced.selector, address(tkn)));
		v3.setQuote(address(tkn), true);
		vm.prank(admin);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(v3)));
		v3.callRegistrarV2(abi.encodeCall(Ownable2Step.acceptOwnership, ())); // V3 isn't V2's pending owner: V2's revert
	}

	/// Review 2026-10-25: V2's QuoteIsPoolPriced can't see V3's Aero tokens — V3's setQuote does, and the passthrough
	/// refuses setQuote so it can't be bypassed.
	function test_aPoolPricedAeroTokenCantBecomeAQuote() public {
		v3.register(address(tkn), address(_aeroPool(tkn, usdc, PLENTY)));
		vm.startPrank(admin);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrarV3.QuoteIsPoolPriced.selector, address(tkn)));
		v3.setQuote(address(tkn), true);
		vm.expectRevert(PoolPriceRegistrarV3.UseSetQuote.selector);
		v3.callRegistrarV2(abi.encodeCall(PoolPriceRegistrarV2.setQuote, (address(tkn), true)));
		v3.setQuote(address(usdc), false); // revoking needs no check
		vm.stopPrank();
		assertFalse(v3.isQuote(address(usdc)));
	}

	function test_onlyOwner() public {
		vm.startPrank(anyone);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
		v3.setPool(address(tkn), address(0x1));
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
		v3.callRegistrarV2(abi.encodeCall(PoolPriceRegistrarV2.setPoolApproved, (bytes32(0), true)));
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
		v3.setQuote(address(tkn), true);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
		v3.acceptRegistrarV2();
		vm.stopPrank();
	}

	function test_ownerSetPoolRepointsWithoutTheLiquidityCheck() public {
		ScriptedCLPool thin = _aeroPool(tkn, usdc, 1_000e6);
		vm.prank(admin);
		address adapter = v3.setPool(address(tkn), address(thin));
		assertEq(v3.poolPricedAdapter(address(tkn)), adapter);
	}
}
