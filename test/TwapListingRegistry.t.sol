// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {
	TwapListingRegistry,
	IUniswapV3PoolFactory,
	ISlipstreamPoolFactory
} from '../src/pricing/TwapListingRegistry.sol';
import {TwapAggregatorAdapter} from '../src/pricing/TwapAggregatorAdapter.sol';
import {AggregatorV3Interface} from '../src/interfaces/AggregatorV3Interface.sol';
import {IValueInterpreter} from '../src/interfaces/IValueInterpreter.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';
import {ScriptedPool} from './TwapAggregatorAdapter.t.sol';

/// @dev A canonical factory stand-in: getPool answers only for what was registered.
contract ScriptedFactory {
	mapping(bytes32 => address) internal pools;

	function setUni(address a, address b, uint24 fee, address pool) external {
		pools[_key(a, b, int256(uint256(fee)))] = pool;
	}

	function setCl(address a, address b, int24 spacing, address pool) external {
		pools[_key(a, b, int256(spacing))] = pool;
	}

	function getPool(address a, address b, uint24 fee) external view returns (address) {
		return pools[_key(a, b, int256(uint256(fee)))];
	}

	function getPool(address a, address b, int24 spacing) external view returns (address) {
		return pools[_key(a, b, int256(spacing))];
	}

	function _key(address a, address b, int256 tier) internal pure returns (bytes32) {
		(address x, address y) = a < b ? (a, b) : (b, a);
		return keccak256(abi.encode(x, y, tier));
	}
}

contract TwapListingRegistryTest is Test {
	int24 internal constant TICK_2500 = -198_080;

	ValueInterpreter internal vi;
	ScriptedFactory internal uni;
	ScriptedFactory internal cl;
	ScriptedFactory internal cl2;
	TwapListingRegistry internal registry;
	MockERC20 internal meme;
	MockERC20 internal usdc;
	MockAggregator internal usdcFeed;
	ScriptedPool internal pool;
	address internal keeper = makeAddr('keeper');
	address internal stranger = makeAddr('stranger');

	function setUp() public {
		vm.warp(10 days);
		deployCodeTo('Mocks.sol:MockERC20', abi.encode('Meme', 'MEME', uint8(18)), address(0x1111));
		deployCodeTo('Mocks.sol:MockERC20', abi.encode('USD Coin', 'USDC', uint8(6)), address(0x2222));
		meme = MockERC20(address(0x1111));
		usdc = MockERC20(address(0x2222));
		usdcFeed = new MockAggregator(8, 1e8);

		vi = new ValueInterpreter(address(this));
		vi.addPrimitive(address(usdc), address(usdcFeed), 2 days);
		uni = new ScriptedFactory();
		cl = new ScriptedFactory();
		cl2 = new ScriptedFactory();
		registry = new TwapListingRegistry(IValueInterpreter(address(vi)), IUniswapV3PoolFactory(address(uni)), ISlipstreamPoolFactory(address(cl)), ISlipstreamPoolFactory(address(cl2)));
		registry.setQuote(address(usdc), AggregatorV3Interface(address(usdcFeed)), 2 days);

		pool = new ScriptedPool(address(meme), address(usdc));
		pool.set(TICK_2500, TICK_2500, 1e18); // ≈ $4.9M of ±10% depth
		uni.setUni(address(meme), address(usdc), 3000, address(pool));
	}

	function _list() internal returns (TwapAggregatorAdapter) {
		return registry.list(address(meme), address(usdc), TwapListingRegistry.Venue.UniswapV3, 3000);
	}

	// ─── listing ────────────────────────────────────────────────────────────────

	function test_list_deploysTheAdapterWithProtocolParameters() public {
		TwapAggregatorAdapter a = _list();
		assertEq(registry.adapterOf(address(meme)), address(a));
		assertEq(address(a.pool()), address(pool));
		assertEq(a.window(), 30 minutes);
		assertEq(a.maxDeviationBps(), 500);
		assertEq(a.minLiquidityUsd(), 50_000);
		assertEq(address(a.quoteFeed()), address(usdcFeed));
		assertEq(a.description(), 'MEME / USD (TWAP)');
		address[] memory listed = registry.getListedAssets();
		assertEq(listed.length, 1);
		assertEq(listed[0], address(meme));
	}

	function test_list_slipstreamVenueUsesTickSpacing() public {
		ScriptedPool clPool = new ScriptedPool(address(meme), address(usdc));
		clPool.set(TICK_2500, TICK_2500, 1e18);
		cl.setCl(address(meme), address(usdc), 100, address(clPool));
		TwapAggregatorAdapter a = registry.list(address(meme), address(usdc), TwapListingRegistry.Venue.Slipstream, 100);
		assertEq(address(a.pool()), address(clPool));
	}

	/// Aerodrome's second Slipstream deployment resolves from ITS factory, never the other one
	function test_list_slipstream2VenueUsesTheSecondFactory() public {
		ScriptedPool clPool = new ScriptedPool(address(meme), address(usdc));
		clPool.set(TICK_2500, TICK_2500, 1e18);
		cl2.setCl(address(meme), address(usdc), 50, address(clPool));
		// not on the original deployment → PoolNotFound there
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistry.PoolNotFound.selector, address(meme), address(usdc)));
		registry.list(address(meme), address(usdc), TwapListingRegistry.Venue.Slipstream, 50);
		TwapAggregatorAdapter a = registry.list(address(meme), address(usdc), TwapListingRegistry.Venue.Slipstream2, 50);
		assertEq(address(a.pool()), address(clPool));
	}

	function test_list_onlyListers() public {
		vm.prank(stranger);
		vm.expectRevert(TwapListingRegistry.NotLister.selector);
		registry.list(address(meme), address(usdc), TwapListingRegistry.Venue.UniswapV3, 3000);

		registry.setLister(stranger, true);
		vm.prank(stranger);
		registry.list(address(meme), address(usdc), TwapListingRegistry.Venue.UniswapV3, 3000);
	}

	function test_list_refusesAQuoteOffTheAllowList() public {
		MockERC20 dai = new MockERC20('DAI', 'DAI', 18);
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistry.QuoteNotAllowed.selector, address(dai)));
		registry.list(address(meme), address(dai), TwapListingRegistry.Venue.UniswapV3, 3000);
	}

	function test_list_refusesAnAssetAHigherTierAlreadyPrices() public {
		vi.addPrimitive(address(meme), address(new MockAggregator(8, 2_500e8)), 1 days); // "Chainlink" wins
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistry.AlreadyPriced.selector, address(meme)));
		_list();
	}

	function test_list_resolvesThePoolOnlyFromTheFactory() public {
		// a fee tier the canonical factory has no pool for — the caller cannot supply one
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistry.PoolNotFound.selector, address(meme), address(usdc)));
		registry.list(address(meme), address(usdc), TwapListingRegistry.Venue.UniswapV3, 10_000);
	}

	function test_list_aThinPoolCannotBeListed() public {
		pool.set(TICK_2500, TICK_2500, 1e14); // ≈ $489 of depth, floor $50k
		vm.expectPartialRevert(TwapListingRegistry.BelowFloorAtListing.selector);
		_list();
		assertEq(registry.adapterOf(address(meme)), address(0));
		assertEq(registry.getListedAssets().length, 0);
	}

	function test_list_aPoolOffItsAverageCannotBeListed() public {
		pool.set(TICK_2500 + 600, TICK_2500, 1e18); // spot +6.2% over the TWAP
		vm.expectRevert(abi.encodeWithSelector(TwapAggregatorAdapter.SpotDeviatesFromTwap.selector, TICK_2500 + 600, TICK_2500));
		_list();
	}

	function test_list_twiceRefused() public {
		_list();
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistry.AlreadyListed.selector, address(meme)));
		_list();
	}

	// ─── the VI step stays with the VI owner ────────────────────────────────────

	function test_isTwapPriced_onlyOnceTheViPricesThroughTheListedAdapter() public {
		TwapAggregatorAdapter a = _list();
		assertFalse(registry.isTwapPriced(address(meme)), 'listed but not yet in the VI');
		vi.addPrimitive(address(meme), address(a), 1 hours);
		assertTrue(registry.isTwapPriced(address(meme)));
		assertApproxEqRel(vi.calcUsdRate(address(meme)), 2_500e18, 0.001e18);

		// the VI owner re-points the asset elsewhere → no longer the TWAP tier
		vi.removePrimitive(address(meme));
		vi.addPrimitive(address(meme), address(new MockAggregator(8, 2_500e8)), 1 days);
		assertFalse(registry.isTwapPriced(address(meme)));
	}

	// ─── the 72-hour clock ─────────────────────────────────────────────────────

	function test_pokeFloor_overTheFloorDoesNothing() public {
		_list();
		assertFalse(registry.pokeFloor(address(meme)));
		(,,,, uint64 since) = registry.listings(address(meme));
		assertEq(since, 0);
		assertFalse(registry.isDelisted(address(meme)));
	}

	function test_pokeFloor_startsTheClock_delistsAfter72h_priceKeepsFlowing() public {
		TwapAggregatorAdapter a = _list();
		pool.set(TICK_2500, TICK_2500, 1e14); // liquidity gone: ≈ $489 of depth
		vm.prank(stranger); // anyone may poke — the chain decides
		assertTrue(registry.pokeFloor(address(meme)));
		(,,,, uint64 since) = registry.listings(address(meme));
		assertEq(since, block.timestamp);

		skip(72 hours - 1);
		assertFalse(registry.isDelisted(address(meme)));
		registry.pokeFloor(address(meme)); // a later poke keeps the ORIGINAL start
		(,,,, uint64 stillSince) = registry.listings(address(meme));
		assertEq(stillSince, since);
		skip(1);
		assertTrue(registry.isDelisted(address(meme)));

		// the price never stopped: under the floor, delisted, still the market price
		usdcFeed.setAnswer(1e8); // keep the quote leg fresh across the skipped days
		(, int256 answer,,,) = a.latestRoundData();
		assertApproxEqRel(uint256(answer), 2_500e18, 0.001e18);
	}

	function test_pokeFloor_recoveryClearsTheClock() public {
		_list();
		pool.set(TICK_2500, TICK_2500, 1e14);
		registry.pokeFloor(address(meme));
		skip(80 hours);
		usdcFeed.setAnswer(1e8);
		assertTrue(registry.isDelisted(address(meme)));

		pool.set(TICK_2500, TICK_2500, 1e18); // liquidity back
		vm.prank(stranger); // e.g. the manager, after re-adding depth
		assertFalse(registry.pokeFloor(address(meme)));
		assertFalse(registry.isDelisted(address(meme)));
	}

	function test_pokeFloor_aPoolThatCannotServeTheWindowCountsAsUnder() public {
		_list();
		pool.setYoung(true);
		assertTrue(registry.pokeFloor(address(meme)));
	}

	function test_pokeFloor_unlisted() public {
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistry.NotListed.selector, address(meme)));
		registry.pokeFloor(address(meme));
	}

	// ─── owner config ───────────────────────────────────────────────────────────

	function test_config_onlyOwner() public {
		vm.startPrank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		registry.setQuote(address(usdc), AggregatorV3Interface(address(0)), 0);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		registry.setLister(stranger, true);
		vm.stopPrank();
	}

	function test_disallowedQuote_blocksNewListingsOnly() public {
		_list();
		registry.setQuote(address(usdc), AggregatorV3Interface(address(0)), 0);
		assertTrue(registry.adapterOf(address(meme)) != address(0), 'existing listing untouched');
		MockERC20 other = new MockERC20('Other', 'OTH', 18);
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistry.QuoteNotAllowed.selector, address(usdc)));
		registry.list(address(other), address(usdc), TwapListingRegistry.Venue.UniswapV3, 3000);
	}
}
