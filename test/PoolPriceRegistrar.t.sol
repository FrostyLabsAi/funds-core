// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {IPoolPriceAdapter} from '../src/interfaces/IPoolPriceAdapter.sol';
import {PoolPriceRegistrar} from '../src/pricing/PoolPriceRegistrar.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';
import {
	ScriptedCLPool,
	ScriptedBasicPool,
	MockUniswapV3Factory,
	MockSlipstreamFactory,
	MockAerodromeBasicFactory
} from './utils/PoolPriceMocks.sol';

contract PoolPriceRegistrarTest is Test {
	ValueInterpreter internal vi;
	PoolPriceRegistrar internal registrar;
	MockUniswapV3Factory internal uniswap;
	MockSlipstreamFactory[3] internal slipstreams;
	MockAerodromeBasicFactory internal aerodrome;
	MockERC20 internal usdc;
	MockERC20 internal weth;
	MockERC20 internal tkn;
	address internal admin = makeAddr('admin');
	address internal manager = makeAddr('manager');

	/// @dev USDC liquidity L at tick 0 is L raw USDC as a full-range reserve.
	uint128 internal constant PLENTY = 1_000_000e6;

	function setUp() public {
		vm.warp(30 days);
		vi = new ValueInterpreter(admin);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		weth = new MockERC20('Wrapped Ether', 'WETH', 18);
		tkn = new MockERC20('Token', 'TKN', 6);
		vm.startPrank(admin);
		vi.addPrimitive(address(usdc), address(new MockAggregator(8, 1e8)), 25 hours);
		vi.addPrimitive(address(weth), address(new MockAggregator(8, 2000e8)), 1 hours);
		vm.stopPrank();

		uniswap = new MockUniswapV3Factory();
		aerodrome = new MockAerodromeBasicFactory();
		for (uint256 i; i < 3; ++i) slipstreams[i] = new MockSlipstreamFactory();
		registrar = new PoolPriceRegistrar(_wiring(), admin);

		// the takeover the mainnet migration does: the old owner hands over, the registrar accepts
		vm.startPrank(admin);
		vi.transferOwnership(address(registrar));
		registrar.execute(abi.encodeCall(Ownable2Step.acceptOwnership, ()));
		vm.stopPrank();
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	function _wiring() internal view returns (PoolPriceRegistrar.Wiring memory w) {
		address[] memory quotes = new address[](2);
		quotes[0] = address(usdc);
		quotes[1] = address(weth);
		w = PoolPriceRegistrar.Wiring({
			valueInterpreter: vi,
			uniswapV3Factory: address(uniswap),
			slipstreamFactories: [address(slipstreams[0]), address(slipstreams[1]), address(slipstreams[2])],
			aerodromeBasicFactory: address(aerodrome),
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

		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.AssetNotInPool.selector, address(other), address(pool)));
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
}
