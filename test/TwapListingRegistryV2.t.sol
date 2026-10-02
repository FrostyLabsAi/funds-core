// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Vm} from 'forge-std/Vm.sol';
import {
	TwapListingRegistryV2, IUniswapV2Factory, IAerodromeBasicFactory
} from '../src/pricing/TwapListingRegistryV2.sol';
import {
	ConcentratedTwapAdapterDeployer,
	UniswapV2TwapAdapterDeployer,
	AerodromeBasicTwapAdapterDeployer
} from '../src/pricing/TwapAdapterDeployers.sol';
import {TwapAggregatorAdapterV2} from '../src/pricing/TwapAggregatorAdapterV2.sol';
import {UniswapV2TwapAdapter} from '../src/pricing/UniswapV2TwapAdapter.sol';
import {AerodromeBasicTwapAdapter, IAerodromeBasicPool} from '../src/pricing/AerodromeBasicTwapAdapter.sol';
import {UniswapV2ObservationRecorder, IUniswapV2Pair} from '../src/pricing/UniswapV2ObservationRecorder.sol';
import {IConcentratedPoolOracle} from '../src/pricing/TwapAggregatorAdapter.sol';
import {IUniswapV3PoolFactory, ISlipstreamPoolFactory} from '../src/pricing/TwapListingRegistry.sol';
import {ITwapPriceAdapter} from '../src/interfaces/ITwapPriceAdapter.sol';
import {IValueInterpreter} from '../src/interfaces/IValueInterpreter.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {AggregatorV3Interface} from '../src/interfaces/AggregatorV3Interface.sol';
import {ISlipstreamSwapRouter} from '../src/interfaces/external/ISlipstreamSwapRouter.sol';
import {IUniswapV3NonfungiblePositionManager} from
	'../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {TickMath} from '../src/libraries/TickMath.sol';
import {MockAggregator} from './utils/Mocks.sol';
import {ScriptedPool} from './TwapAggregatorAdapter.t.sol';
import {ScriptedFactory} from './TwapListingRegistry.t.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';

/// @dev The registry's Venues with a fresh recorder and the three real adapter deployers; the
///      factories are whatever the test passes (placeholders in unit tests, the real Base factories
///      on a fork).
library TestVenues {
	function build(
		IValueInterpreter vi,
		address uniswapV3,
		address slipstream,
		address slipstream2,
		address slipstream3,
		address uniswapV2,
		address aerodromeBasic
	) internal returns (TwapListingRegistryV2.Venues memory v) {
		v.valueInterpreter = vi;
		v.uniswapV3 = IUniswapV3PoolFactory(uniswapV3);
		v.slipstream = ISlipstreamPoolFactory(slipstream);
		v.slipstream2 = ISlipstreamPoolFactory(slipstream2);
		v.slipstream3 = ISlipstreamPoolFactory(slipstream3);
		v.uniswapV2 = IUniswapV2Factory(uniswapV2);
		v.aerodromeBasic = IAerodromeBasicFactory(aerodromeBasic);
		v.recorder = new UniswapV2ObservationRecorder();
		v.clDeployer = new ConcentratedTwapAdapterDeployer();
		v.v2Deployer = new UniswapV2TwapAdapterDeployer();
		v.aeroDeployer = new AerodromeBasicTwapAdapterDeployer();
	}
}

/// @dev An adapter stand-in whose two liquidity reads the test sets: the quote reserve (the
///      registry's listing and delist-clock floor) and the band depth (what a lister records and
///      what repoint's margin compares). `broken` makes both reads revert, `bandBroken` only the
///      band read; a burn makes a read spend that much gas first, like an expensive walk.
contract FloorProbeAdapter {
	uint256 public reserve;
	uint256 public depth;
	bool public broken;
	bool public bandBroken;
	uint256 public reserveBurn;
	uint256 public depthBurn;

	function setReserve(uint256 reserve_) external {
		reserve = reserve_;
	}

	function setDepth(uint256 depth_) external {
		depth = depth_;
	}

	function setBroken(bool broken_) external {
		broken = broken_;
	}

	function setBandBroken(bool bandBroken_) external {
		bandBroken = bandBroken_;
	}

	function setBurn(uint256 reserveBurn_, uint256 depthBurn_) external {
		reserveBurn = reserveBurn_;
		depthBurn = depthBurn_;
	}

	function quoteReserveUsd() external view returns (uint256) {
		_burn(reserveBurn);
		require(!broken, 'BROKEN');
		return reserve;
	}

	function poolDepthUsd() external view returns (uint256) {
		_burn(depthBurn);
		require(!broken && !bandBroken, 'BROKEN');
		return depth;
	}

	/// @dev Spend `amount` gas.
	function _burn(uint256 amount) internal view {
		uint256 start = gasleft();
		while (start - gasleft() < amount) {}
	}
}

/// @dev The registry plus helpers that list an asset on a probe adapter (skipping `_qualify`) and
///      fill the listed-asset array.
contract TwapListingRegistryV2Harness is TwapListingRegistryV2 {
	constructor(Venues memory venues) TwapListingRegistryV2(venues) {}

	function listOnProbe(address asset, address adapter) external {
		listings[asset] = Listing(ITwapPriceAdapter(adapter), adapter, address(0), uint64(block.timestamp), 0);
	}

	function pushListed(address asset) external {
		listedAssets.push(asset);
	}

	function observationCardinalityOf(address pool) external view returns (uint16) {
		return _observationCardinality(pool);
	}
}

contract TwapListingRegistryV2Test is Test {
	TwapListingRegistryV2 internal r;
	address internal vi = makeAddr('vi');
	address internal stranger = makeAddr('stranger');

	// a quote reserve over / under the $25k floor, and band depths that differ from both, so a read
	// used in the other's place changes the outcome
	uint256 internal constant RESERVE_OVER = 30_000e18;
	uint256 internal constant RESERVE_UNDER = 20_000e18;
	uint256 internal constant BAND_THIN = 4_000e18; // under the reserve floor's number, over the band floor
	uint256 internal constant BAND_WIDE = 60_000e18; // over both: a band never restores on its own
	// the floor's second part (MIN_BAND_DEPTH_USD × 1e18), kept literal on purpose;
	// test_bandFloorIsAFullRangePoolAtTheReserveFloor pins it to the registry's constant
	uint256 internal constant BAND_FLOOR = 1_282e18;
	// the scripted MEME/USDC pool at $2,500 (tick −198,080): flat liquidity whose −10% band holds
	// $1,283.30 (L = 5e14, ≈ $25k of USDC as L·√P: a full-range pool at the reserve floor), and
	// liquidities a hair under / over the band floor (L·(√P − √(0.9P)) = $1,281.99 / $1,282.02)
	int24 internal constant TICK_2500 = -198_080;
	uint128 internal constant L_AT_RESERVE_FLOOR = 5e14;
	uint128 internal constant L_BAND_UNDER = 4.9949e14;
	uint128 internal constant L_BAND_OVER = 4.995e14;

	function setUp() public {
		r = new TwapListingRegistryV2(_venues(IValueInterpreter(vi)));
	}

	function _venues(IValueInterpreter vi_) internal returns (TwapListingRegistryV2.Venues memory) {
		return TestVenues.build(
			vi_, makeAddr('uni'), makeAddr('s1'), makeAddr('s2'), makeAddr('s3'), makeAddr('uniV2'), makeAddr('aero')
		);
	}

	// ─── construction ───────────────────────────────────────────────────────────

	/// every one of the eleven Venues fields is required
	function test_constructorRejectsEachZeroField() public {
		for (uint256 i; i < 11; ++i) {
			TwapListingRegistryV2.Venues memory v = _venues(IValueInterpreter(vi));
			// a Venues in memory is eleven consecutive address words
			assembly ('memory-safe') {
				mstore(add(v, mul(i, 0x20)), 0)
			}
			vm.expectRevert(TwapListingRegistryV2.ZeroAddress.selector);
			new TwapListingRegistryV2(v);
		}
	}

	function test_constructorStoresEveryVenue() public {
		TwapListingRegistryV2.Venues memory v = _venues(IValueInterpreter(vi));
		TwapListingRegistryV2 reg = new TwapListingRegistryV2(v);
		assertEq(address(reg.valueInterpreter()), vi);
		assertEq(address(reg.uniswapFactory()), makeAddr('uni'));
		assertEq(address(reg.slipstreamFactory()), makeAddr('s1'));
		assertEq(address(reg.slipstream2Factory()), makeAddr('s2'));
		assertEq(address(reg.slipstream3Factory()), makeAddr('s3'));
		assertEq(address(reg.uniswapV2Factory()), makeAddr('uniV2'));
		assertEq(address(reg.aerodromeBasicFactory()), makeAddr('aero'));
		assertEq(address(reg.recorder()), address(v.recorder));
		assertEq(address(reg.clDeployer()), address(v.clDeployer));
		assertEq(address(reg.v2Deployer()), address(v.v2Deployer));
		assertEq(address(reg.aeroDeployer()), address(v.aeroDeployer));
		assertEq(reg.owner(), address(this));
	}

	/// the new venues are appended: the four existing indices (stored in events and venueOf) are unchanged
	function test_venueIndicesAppendOnly() public pure {
		assertEq(uint8(TwapListingRegistryV2.Venue.UniswapV3), 0);
		assertEq(uint8(TwapListingRegistryV2.Venue.Slipstream), 1);
		assertEq(uint8(TwapListingRegistryV2.Venue.Slipstream2), 2);
		assertEq(uint8(TwapListingRegistryV2.Venue.Slipstream3), 3);
		assertEq(uint8(TwapListingRegistryV2.Venue.UniswapV2), 4);
		assertEq(uint8(TwapListingRegistryV2.Venue.AerodromeBasic), 5);
	}

	function test_floorIsTwentyFiveThousandOfQuoteReserve() public view {
		assertEq(r.MIN_QUOTE_RESERVE_USD(), 25_000);
		assertGt(RESERVE_OVER, r.MIN_QUOTE_RESERVE_USD() * 1e18);
		assertLt(RESERVE_UNDER, r.MIN_QUOTE_RESERVE_USD() * 1e18);
	}

	/// Ruling 23: the band floor is what a full-range x·y=k pool holding exactly the reserve floor
	/// has within −10% — (1 − √0.9) of $25,000, rounded down — the same expression every adapter
	/// applies to its minLiquidityUsd.
	function test_bandFloorIsAFullRangePoolAtTheReserveFloor() public view {
		assertEq(r.MIN_BAND_DEPTH_USD(), 1_282);
		assertEq(r.MIN_BAND_DEPTH_USD() * 1e18, BAND_FLOOR);
		uint256 ppm = 51_316; // floor((1 − √0.9) · 1e6): (1e6 − ppm − 1)² < 0.9e12 ≤ (1e6 − ppm)²
		assertLt((1e6 - ppm - 1) ** 2, 0.9e12);
		assertGe((1e6 - ppm) ** 2, 0.9e12);
		assertEq(r.MIN_BAND_DEPTH_USD(), r.MIN_QUOTE_RESERVE_USD() * ppm / 1e6);
	}

	function test_deployerIsNotALister() public view {
		assertFalse(r.listers(address(this)), 'v2 listers are granted explicitly (the module)');
	}

	function test_listAndRepointAreListerOnly() public {
		vm.prank(stranger);
		vm.expectRevert(TwapListingRegistryV2.NotLister.selector);
		r.list(makeAddr('a'), makeAddr('q'), TwapListingRegistryV2.Venue.UniswapV3, 3000);
		vm.prank(stranger);
		vm.expectRevert(TwapListingRegistryV2.NotLister.selector);
		r.repoint(makeAddr('a'), makeAddr('q'), TwapListingRegistryV2.Venue.UniswapV3, 3000);
	}

	function test_configIsOwnerOnly() public {
		vm.startPrank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		r.setQuote(makeAddr('q'), AggregatorV3Interface(makeAddr('f')), 3600);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		r.setLister(stranger, true);
		vm.stopPrank();
	}

	function test_pagination() public view {
		assertEq(r.listedCount(), 0);
		assertEq(r.getListedAssetsPage(0, 50).length, 0);
		assertEq(r.getListedAssetsPage(10, 50).length, 0, 'offset past the end is empty, never reverts');
	}

	function test_pokeUnlistedReverts() public {
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.NotListed.selector, makeAddr('a')));
		r.pokeFloor(makeAddr('a'));
	}

	/// Uniswap v2 and Aerodrome basic have one canonical pool per pair (volatile, for Aerodrome):
	/// any nonzero fee / tick spacing names no pool, and the factory is never asked (these
	/// placeholder factories have no code, so asking would revert without PoolNotFound)
	function test_newVenuesNeedZeroFeeOrTickSpacing() public {
		ValueInterpreter realVi = new ValueInterpreter(address(this));
		TwapListingRegistryV2 reg = new TwapListingRegistryV2(_venues(IValueInterpreter(address(realVi))));
		address asset = makeAddr('asset');
		address quote = makeAddr('quote');
		reg.setQuote(quote, AggregatorV3Interface(makeAddr('feed')), 3600);
		reg.setLister(address(this), true);
		int24[4] memory nonzero = [int24(1), int24(-1), int24(3000), type(int24).max];
		for (uint256 i; i < nonzero.length; ++i) {
			vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.PoolNotFound.selector, asset, quote));
			reg.list(asset, quote, TwapListingRegistryV2.Venue.UniswapV2, nonzero[i]);
			vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.PoolNotFound.selector, asset, quote));
			reg.list(asset, quote, TwapListingRegistryV2.Venue.AerodromeBasic, nonzero[i]);
		}
		assertEq(reg.listedCount(), 0);
	}

	/// The reserve half of the listing floor is inclusive: the policy suite's scripted MEME/USDC pool
	/// at $2,500 (USDC feed exactly $1) with flat liquidity worth a full-range pool at the floor
	/// (band $1,283.30, over the band floor) lists holding exactly $25,000 of USDC — its band is what
	/// gets recorded — and one raw USDC unit less is refused with that exact reserve.
	function test_listingFloorIsTheQuoteReserveInclusive() public {
		(TwapListingRegistryV2 reg, ScriptedPool pool, address meme, address usdc) = _scriptedListing(L_AT_RESERVE_FLOOR);

		deal(usdc, address(pool), 25_000e6 - 1);
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.BelowFloorAtListing.selector, 25_000e18 - 1e12));
		reg.list(meme, usdc, TwapListingRegistryV2.Venue.UniswapV3, 3000);

		deal(usdc, address(pool), 25_000e6);
		ITwapPriceAdapter a = reg.list(meme, usdc, TwapListingRegistryV2.Venue.UniswapV3, 3000);
		assertEq(a.quoteReserveUsd(), 25_000e18, 'exactly the floor');
		uint256 band = a.poolDepthUsd();
		assertGe(band, BAND_FLOOR, 'a full-range pool at the reserve floor clears the band floor');
		assertLt(band, BAND_FLOOR + 2e18, 'by under $2: the band floor is that pool');
		assertEq(reg.recordedDepthUsd18(meme), band, 'the band is recorded');
		assertFalse(a.isBelowFloor());
	}

	/// The band half of the listing floor (Ruling 23), inclusive, on the same scripted pool holding
	/// exactly the $25,000 reserve floor: liquidity whose −10% band is a cent under $1,282 is
	/// refused with that exact band; a hair more liquidity (a band 2 cents over) lists.
	function test_listingBandFloorIsInclusive() public {
		(TwapListingRegistryV2 reg, ScriptedPool pool, address meme, address usdc) = _scriptedListing(L_BAND_UNDER);
		deal(usdc, address(pool), 25_000e6);
		// the band the registry's adapter will read, through the registry's own deployer
		uint256 under = ITwapPriceAdapter(
			reg.clDeployer().deploy(
				IConcentratedPoolOracle(address(pool)),
				meme,
				AggregatorV3Interface(address(_feedOf(reg, usdc))),
				reg.WINDOW(),
				reg.MIN_QUOTE_RESERVE_USD(),
				reg.MAX_DEVIATION_BPS(),
				1 days,
				'probe'
			)
		).poolDepthUsd();
		assertLt(under, BAND_FLOOR);
		assertGt(under, BAND_FLOOR - 0.02e18, 'a cent or so under');
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.BandBelowFloorAtListing.selector, under));
		reg.list(meme, usdc, TwapListingRegistryV2.Venue.UniswapV3, 3000);
		assertEq(reg.listedCount(), 0);

		pool.set(TICK_2500, TICK_2500, L_BAND_OVER);
		ITwapPriceAdapter a = reg.list(meme, usdc, TwapListingRegistryV2.Venue.UniswapV3, 3000);
		uint256 band = a.poolDepthUsd();
		assertGe(band, BAND_FLOOR);
		assertLt(band, BAND_FLOOR + 0.03e18, 'a few cents over');
		assertEq(a.quoteReserveUsd(), 25_000e18);
		assertEq(reg.recordedDepthUsd18(meme), band);
		assertFalse(a.isBelowFloor());
	}

	/// @dev A registry whose Uniswap factory resolves MEME/USDC 0.3% to a scripted pool at $2,500
	///      with flat `liquidity`; USDC priced at exactly $1; this contract is a lister.
	function _scriptedListing(uint128 liquidity)
		internal
		returns (TwapListingRegistryV2 reg, ScriptedPool pool, address meme, address usdc)
	{
		meme = address(0x1111);
		usdc = address(0x2222);
		deployCodeTo('Mocks.sol:MockERC20', abi.encode('Meme', 'MEME', uint8(18)), meme);
		deployCodeTo('Mocks.sol:MockERC20', abi.encode('USD Coin', 'USDC', uint8(6)), usdc);
		pool = new ScriptedPool(meme, usdc);
		pool.set(TICK_2500, TICK_2500, liquidity);
		ScriptedFactory uni = new ScriptedFactory();
		uni.setUni(meme, usdc, 3000, address(pool));
		ValueInterpreter realVi = new ValueInterpreter(address(this));
		reg = new TwapListingRegistryV2(
			TestVenues.build(
				IValueInterpreter(address(realVi)),
				address(uni),
				makeAddr('s1'),
				makeAddr('s2'),
				makeAddr('s3'),
				makeAddr('uniV2'),
				makeAddr('aero')
			)
		);
		reg.setQuote(usdc, AggregatorV3Interface(address(new MockAggregator(8, 1e8))), 1 days);
		reg.setLister(address(this), true);
	}

	function _feedOf(TwapListingRegistryV2 reg, address quote) internal view returns (AggregatorV3Interface feed) {
		(feed,) = reg.quotes(quote);
	}

	// ─── amendment A: only a lister makes a positive depth claim ────────────────

	function _harness() internal returns (TwapListingRegistryV2Harness h, FloorProbeAdapter probe, address asset) {
		h = new TwapListingRegistryV2Harness(_venues(IValueInterpreter(vi)));
		probe = new FloorProbeAdapter();
		asset = makeAddr('asset');
		h.listOnProbe(asset, address(probe));
	}

	/// same-transaction liquidity makes the pool read over the floor; a stranger's poke still cannot clear the clock
	function test_publicPokeCannotClearClock() public {
		(TwapListingRegistryV2Harness h, FloorProbeAdapter probe, address asset) = _harness();
		address lister = makeAddr('lister');
		h.setLister(lister, true);

		// anyone may START the clock: the reserve is under the floor, whatever the band reads
		probe.setReserve(1_000e18);
		probe.setDepth(BAND_WIDE);
		vm.expectEmit(address(h));
		emit TwapListingRegistryV2.FloorBreached(asset, block.timestamp);
		vm.prank(stranger);
		assertTrue(h.pokeFloor(asset));
		(,,,, uint64 since) = h.listings(asset);
		assertEq(since, block.timestamp);
		assertEq(h.recordedDepthUsd18(asset), 0, 'a stranger never records depth');

		// the pool now reads deep (e.g. a JIT mint): the stranger's clear is a silent no-op
		skip(72 hours);
		probe.setReserve(60_000e18);
		probe.setDepth(BAND_THIN);
		vm.recordLogs();
		vm.prank(stranger);
		assertFalse(h.pokeFloor(asset), 'still reports the live read');
		assertEq(vm.getRecordedLogs().length, 0, 'no FloorRestored, no DepthRecorded');
		(,,,, uint64 stillSince) = h.listings(asset);
		assertEq(stillSince, since, 'clock not cleared');
		assertTrue(h.isDelisted(asset));
		assertEq(h.recordedDepthUsd18(asset), 0);

		// the lister (the keeper, via the module) may clear it, and records the BAND depth
		vm.expectEmit(address(h));
		emit TwapListingRegistryV2.FloorRestored(asset);
		vm.expectEmit(address(h));
		emit TwapListingRegistryV2.DepthRecorded(asset, BAND_THIN);
		vm.prank(lister);
		assertFalse(h.pokeFloor(asset));
		(,,,, uint64 cleared) = h.listings(asset);
		assertEq(cleared, 0);
		assertFalse(h.isDelisted(asset));
	}

	function test_listerPokeRecordsDepth() public {
		(TwapListingRegistryV2Harness h, FloorProbeAdapter probe, address asset) = _harness();
		address lister = makeAddr('lister');
		h.setLister(lister, true);

		// over both floors with a band thinner than the reserve floor's number: no clock, and the
		// lister records the band depth, not the reserve
		probe.setReserve(RESERVE_OVER);
		probe.setDepth(BAND_THIN);
		vm.recordLogs();
		vm.prank(lister);
		assertFalse(h.pokeFloor(asset));
		Vm.Log[] memory logs = vm.getRecordedLogs();
		assertEq(logs.length, 1, 'only DepthRecorded');
		assertEq(logs[0].topics[0], TwapListingRegistryV2.DepthRecorded.selector);
		assertEq(logs[0].topics[1], bytes32(uint256(uint160(asset))));
		assertEq(abi.decode(logs[0].data, (uint256)), BAND_THIN);
		assertEq(h.recordedDepthUsd18(asset), BAND_THIN);

		// a stranger's poke never moves the recorded depth, up or down
		probe.setDepth(500_000e18);
		vm.prank(stranger);
		h.pokeFloor(asset);
		assertEq(h.recordedDepthUsd18(asset), BAND_THIN);

		// under the floor with a wide band: a lister's poke starts the clock AND records the band
		probe.setReserve(RESERVE_UNDER);
		probe.setDepth(BAND_WIDE);
		vm.prank(lister);
		assertTrue(h.pokeFloor(asset));
		(,,,, uint64 since) = h.listings(asset);
		assertEq(since, block.timestamp);
		assertEq(h.recordedDepthUsd18(asset), BAND_WIDE);

		// an unanswerable pool: under the floor, recorded depth 0
		skip(1 hours);
		probe.setReserve(90_000e18);
		probe.setBroken(true);
		vm.expectEmit(address(h));
		emit TwapListingRegistryV2.DepthRecorded(asset, 0);
		vm.prank(lister);
		assertTrue(h.pokeFloor(asset));
		assertEq(h.recordedDepthUsd18(asset), 0);
		(,,,, uint64 stillSince) = h.listings(asset);
		assertEq(stillSince, since, 'a later poke keeps the ORIGINAL start');
	}

	/// a band that can't be read (its walk reverts) is half the floor unanswered (Ruling 23): the
	/// reserve over the floor no longer clears the clock, and the lister records 0, never the unread
	/// value
	function test_unreadableBandCountsUnderAndRecordsZero() public {
		(TwapListingRegistryV2Harness h, FloorProbeAdapter probe, address asset) = _harness();
		address lister = makeAddr('lister');
		h.setLister(lister, true);
		probe.setReserve(RESERVE_UNDER);
		vm.prank(stranger);
		assertTrue(h.pokeFloor(asset));
		(,,,, uint64 since) = h.listings(asset);

		skip(1 hours);
		probe.setReserve(RESERVE_OVER);
		probe.setDepth(BAND_WIDE);
		probe.setBandBroken(true);
		vm.recordLogs();
		vm.prank(lister);
		assertTrue(h.pokeFloor{gas: 2_500_000}(asset), 'a genuine band revert under MIN_READ_GAS is no starvation');
		Vm.Log[] memory logs = vm.getRecordedLogs();
		assertEq(logs.length, 1, 'no FloorRestored: only DepthRecorded');
		assertEq(logs[0].topics[0], TwapListingRegistryV2.DepthRecorded.selector);
		assertEq(abi.decode(logs[0].data, (uint256)), 0);
		(,,,, uint64 stillSince) = h.listings(asset);
		assertEq(stillSince, since, 'the clock keeps running');
		assertEq(h.recordedDepthUsd18(asset), 0);

		// with no clock running, an unreadable band starts one, for anyone
		(h, probe, asset) = _harness();
		probe.setReserve(RESERVE_OVER);
		probe.setDepth(BAND_WIDE);
		probe.setBandBroken(true);
		vm.expectEmit(address(h));
		emit TwapListingRegistryV2.FloorBreached(asset, block.timestamp);
		vm.prank(stranger);
		assertTrue(h.pokeFloor(asset));
		(,,,, since) = h.listings(asset);
		assertEq(since, block.timestamp);
	}

	/// a stranger can't starve the floor read so that its out-of-gas catch reads as "under the floor"
	function test_gasStarvedPokeCannotStartClock() public {
		(TwapListingRegistryV2Harness h, FloorProbeAdapter probe, address asset) = _harness();
		probe.setReserve(RESERVE_OVER);
		probe.setDepth(BAND_WIDE);
		probe.setBurn(3_000_000, 0); // an expensive floor read

		// 2.5M gas against a 3M read: the read runs out inside the try, and the 1/64 kept back
		// (~39k) would pay for writing the clock if the catch counted it as "under the floor".
		// ~39k is ample to encode the custom error, so the revert is exactly ReadOutOfGas.
		vm.prank(stranger);
		vm.expectRevert(TwapListingRegistryV2.ReadOutOfGas.selector);
		h.pokeFloor{gas: 2_500_000}(asset);
		(,,,, uint64 since) = h.listings(asset);
		assertEq(since, 0, 'a starved read never starts the clock');

		// with enough gas the same read answers: over the floor, no clock
		vm.prank(stranger);
		assertFalse(h.pokeFloor(asset));
		(,,,, since) = h.listings(asset);
		assertEq(since, 0);

		// a genuinely thin pool: a normal-gas poke by anyone starts the clock
		probe.setReserve(RESERVE_UNDER);
		vm.prank(stranger);
		assertTrue(h.pokeFloor(asset));
		(,,,, since) = h.listings(asset);
		assertEq(since, block.timestamp);
	}

	/// a lister's band read gets the same guard: a starved band walk reverts instead of recording 0
	function test_gasStarvedBandReadNeverRecordsZero() public {
		(TwapListingRegistryV2Harness h, FloorProbeAdapter probe, address asset) = _harness();
		address lister = makeAddr('lister');
		h.setLister(lister, true);
		probe.setReserve(RESERVE_OVER);
		probe.setDepth(BAND_WIDE);
		vm.prank(lister);
		h.pokeFloor(asset);
		assertEq(h.recordedDepthUsd18(asset), BAND_WIDE);

		probe.setBurn(0, 3_000_000); // an expensive band walk, a cheap floor read
		vm.prank(lister);
		vm.expectRevert(TwapListingRegistryV2.ReadOutOfGas.selector);
		h.pokeFloor{gas: 2_500_000}(asset);
		assertEq(h.recordedDepthUsd18(asset), BAND_WIDE, 'a starved walk never records 0');
	}

	/// the band read is half the floor, so a stranger's poke reads it too — under the same guard: a
	/// starved band walk reverts ReadOutOfGas instead of counting as "under the floor"
	function test_gasStarvedBandReadCannotStartClock() public {
		(TwapListingRegistryV2Harness h, FloorProbeAdapter probe, address asset) = _harness();
		probe.setReserve(RESERVE_OVER);
		probe.setDepth(BAND_WIDE);
		probe.setBurn(0, 3_000_000); // a cheap reserve read, an expensive band walk
		vm.prank(stranger);
		vm.expectRevert(TwapListingRegistryV2.ReadOutOfGas.selector);
		h.pokeFloor{gas: 2_500_000}(asset);
		(,,,, uint64 since) = h.listings(asset);
		assertEq(since, 0, 'a starved band read never starts the clock');

		// with enough gas the walk answers: over both floors, no clock
		vm.prank(stranger);
		assertFalse(h.pokeFloor(asset));
		(,,,, since) = h.listings(asset);
		assertEq(since, 0);
	}

	/// Ruling 23: the floor is two-part. A pool holding the reserve floor with a band under
	/// MIN_BAND_DEPTH_USD (F2: liquidity removed but never collected keeps the balance) is under it:
	/// anyone starts the clock. The band floor is inclusive, and only a lister clears the clock once
	/// the band is back.
	function test_bandUnderFloorStartsClock() public {
		(TwapListingRegistryV2Harness h, FloorProbeAdapter probe, address asset) = _harness();
		address lister = makeAddr('lister');
		h.setLister(lister, true);
		probe.setReserve(RESERVE_OVER);
		probe.setDepth(BAND_FLOOR - 1);
		vm.expectEmit(address(h));
		emit TwapListingRegistryV2.FloorBreached(asset, block.timestamp);
		vm.prank(stranger);
		assertTrue(h.pokeFloor(asset), 'reserve over, band a wei under: under the floor');
		(,,,, uint64 since) = h.listings(asset);
		assertEq(since, block.timestamp);
		assertEq(h.recordedDepthUsd18(asset), 0, 'a stranger never records depth');

		// the band back at exactly the floor: over it, but only a lister clears the clock
		skip(1 hours);
		probe.setDepth(BAND_FLOOR);
		vm.prank(stranger);
		assertFalse(h.pokeFloor(asset));
		(,,,, uint64 stillSince) = h.listings(asset);
		assertEq(stillSince, since);
		vm.expectEmit(address(h));
		emit TwapListingRegistryV2.FloorRestored(asset);
		vm.expectEmit(address(h));
		emit TwapListingRegistryV2.DepthRecorded(asset, BAND_FLOOR);
		vm.prank(lister);
		assertFalse(h.pokeFloor(asset));
		(,,,, since) = h.listings(asset);
		assertEq(since, 0);

		// and a lister's poke under the band floor starts it again, recording that band (read once)
		probe.setDepth(BAND_FLOOR - 1);
		vm.prank(lister);
		assertTrue(h.pokeFloor(asset));
		(,,,, since) = h.listings(asset);
		assertEq(since, block.timestamp);
		assertEq(h.recordedDepthUsd18(asset), BAND_FLOOR - 1);
	}

	/// a read that exhausts MIN_READ_GAS or more is the pool's failure, not the caller's: an
	/// exhausted floor read counts as under the floor (the clock can still start), and an exhausted
	/// band walk (e.g. a pool dusted on thousands of ticks) is recorded as 0 while the reserve alone
	/// decides the clock
	function test_unreadablePoolCountsUnderFloor() public {
		uint256 gas = 10_000_000;

		// the floor read exhausts its gas
		(TwapListingRegistryV2Harness h, FloorProbeAdapter probe, address asset) = _harness();
		probe.setReserve(80_000e18); // over the floor, if it could ever be read
		probe.setBurn(20_000_000, 0); // more than any transaction can give the read
		assertGe(gas, h.MIN_READ_GAS());
		vm.expectEmit(address(h));
		emit TwapListingRegistryV2.FloorBreached(asset, block.timestamp);
		vm.prank(stranger);
		assertTrue(h.pokeFloor{gas: gas}(asset));
		(,,,, uint64 since) = h.listings(asset);
		assertEq(since, block.timestamp);

		// the band walk exhausts its gas: unanswerable, so under the floor even with the reserve
		// over it — the clock starts and a lister's poke records 0 (never the unread 60k)
		(h, probe, asset) = _harness();
		address lister = makeAddr('lister');
		h.setLister(lister, true);
		probe.setReserve(RESERVE_OVER);
		probe.setDepth(BAND_WIDE);
		probe.setBurn(0, 20_000_000);
		vm.expectEmit(address(h));
		emit TwapListingRegistryV2.FloorBreached(asset, block.timestamp);
		vm.expectEmit(address(h));
		emit TwapListingRegistryV2.DepthRecorded(asset, 0);
		vm.prank(lister);
		assertTrue(h.pokeFloor{gas: gas}(asset));
		assertEq(h.recordedDepthUsd18(asset), 0);
		(,,,, since) = h.listings(asset);
		assertEq(since, block.timestamp);
	}

	/// only a STARVED read reverts: a pool whose read genuinely reverts counts as under the floor
	/// even when the caller forwards under MIN_READ_GAS (the revert leaves most of the gas unspent)
	function test_genuineRevertUnderMinReadGasCountsUnderFloor() public {
		(TwapListingRegistryV2Harness h, FloorProbeAdapter probe, address asset) = _harness();
		probe.setBroken(true);
		vm.prank(stranger);
		assertTrue(h.pokeFloor{gas: 2_500_000}(asset));
		(,,,, uint64 since) = h.listings(asset);
		assertEq(since, block.timestamp);
	}

	/// a slot0 that can't be read (no code: empty return; no slot0: a revert) counts as cardinality 0,
	/// which `_qualify` refuses with ObservationCardinalityTooLow(0)
	function test_unreadableSlot0ReadsZeroCardinality() public {
		(TwapListingRegistryV2Harness h, FloorProbeAdapter probe,) = _harness();
		assertEq(h.MIN_OBSERVATION_CARDINALITY(), 300);
		assertEq(h.observationCardinalityOf(makeAddr('noCode')), 0, 'empty return data');
		assertEq(h.observationCardinalityOf(address(probe)), 0, 'slot0 reverts');
	}

	// ─── pagination over real entries ──────────────────────────────────────────

	function test_paginationWithEntries() public {
		(TwapListingRegistryV2Harness h,,) = _harness();
		address a = makeAddr('a');
		address b = makeAddr('b');
		address c = makeAddr('c');
		h.pushListed(a);
		h.pushListed(b);
		h.pushListed(c);
		assertEq(h.listedCount(), 3);

		address[] memory page = h.getListedAssetsPage(0, 2);
		assertEq(page.length, 2);
		assertEq(page[0], a);
		assertEq(page[1], b);

		page = h.getListedAssetsPage(2, 2);
		assertEq(page.length, 1, 'a page past the end is clipped');
		assertEq(page[0], c);

		assertEq(h.getListedAssetsPage(3, 1).length, 0);

		page = h.getListedAssetsPage(1, type(uint256).max);
		assertEq(page.length, 2, 'an unbounded limit never overflows');
		assertEq(page[0], b);
		assertEq(page[1], c);
	}
}

/// @notice The oracle-ring calls a keeper makes on a young pool (Uniswap v3 and Slipstream alike).
interface IPoolOracleRing {
	function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
	function observations(uint256 index)
		external
		view
		returns (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized);
}

/// @notice The Uniswap v3 pool's fee (the NPM keys pools by it).
interface IUniswapV3PoolFeeTier {
	function fee() external view returns (uint24);
}

/// @notice The parameters every TWAP adapter exposes under the same getters.
interface IAdapterParams {
	function asset() external view returns (address);
	function quoteAsset() external view returns (address);
	function quoteFeed() external view returns (address);
	function window() external view returns (uint32);
	function minLiquidityUsd() external view returns (uint256);
	function minBandDepthUsd() external view returns (uint256);
	function maxDeviationBps() external view returns (uint16);
	function quoteHeartbeat() external view returns (uint32);
	function description() external view returns (string memory);
}

/// @notice `_qualify` and `repoint` against real Base pools on all six venues: the tick-spacing and
///         observation floors (concentrated pools only), the quote-reserve listing floor with the
///         band depth recorded (a thin band lists; LUMIA's tiny reserve does not), Aerodrome basic
///         (volatile pool only) and Uniswap v2 (after 30 minutes of recorder history) listings
///         through the deployers, a nonzero fee / spacing on the new venues, and the repoint margin
///         lifted once the current pool's reserve is under the floor.
///         Run: BASE_MAINNET_RPC=<url> [BASE_FORK_BLOCK=<n>] forge test --match-path test/TwapListingRegistryV2.t.sol -vv
contract TwapListingRegistryV2ForkTest is Test {
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant WETH = 0x4200000000000000000000000000000000000006;
	address internal constant USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
	address internal constant ETH_USD = 0x50015f8b17fb2C290Dde41fDc246ed0dcEE93a8b; // the STANDARD proxy
	uint32 internal constant USDC_HEARTBEAT = 90_000;
	uint32 internal constant WETH_HEARTBEAT = 3600;
	address internal constant USDT = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;
	// Slipstream ts1, ~$330k of USDC within ±10%: deep enough to list but for its spacing (cast, 2026-09-30)
	address internal constant USDT_USDC_CL1 = 0xa41Bc0AFfbA7Fd420d186b84899d7ab2aC57fcD1;
	address internal constant USDT_USDC_UNI100 = 0xD56da2B74bA826f19015E6B7Dd9Dae1903E85DA1; // UniV3 0.01%, ts1
	address internal constant VIRTUAL = 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b;
	address internal constant VIRTUAL_POOL = 0x529d2863a1521d0b57db028168fdE2E97120017C; // UniV3 0.3% vs USDC
	address internal constant VIRTUAL_POOL_500 = 0x23211B35d62a5C9A76Cf1AA1Cc391bb331D50659; // UniV3 0.05%, ts10
	address internal constant VI = 0x3CDbaBE5Bf4E6cfE10A2A326E0ad31b2d16398D4; // live genesis ValueInterpreter
	address internal constant UNI_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
	address internal constant UNI_NPM = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1; // factory() = UNI_FACTORY
	address internal constant CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
	address internal constant CL2_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;
	address internal constant CL3_FACTORY = 0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a;
	address internal constant CL3_SWAP_ROUTER = 0xcbBb8035cAc7D4B3Ca7aBb74cF7BdF900215Ce0D; // factory() = CL3_FACTORY
	// router02.factory() and router.defaultFactory() (cast, 2026-09-30)
	address internal constant UNI_V2_FACTORY = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
	address internal constant AERO_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
	// "USDL Stablecoin", 18 dp, unpriced; its USDC Slipstream-3 ts50 pool holds $345k of USDC within ±10%
	// but ONE oracle observation: slot0 (index 0, cardinality 1, next 1) at block 52008523 (cast)
	address internal constant USDL = 0x78E8CF657742e10eaC8F64007615AA741fC76414;
	address internal constant USDL_USDC_SLIP3_50 = 0xf0d64B4fe5D2619a3aDBE2734AD0584FC54bed88;
	// symbol "LUMIA"; Uniswap getPool(LUMIA, WETH, 3000): ~0.98 WETH against 150M LUMIA, cardinality 1
	address internal constant LUMIA = 0x550161Ae735DebeE90Ba117025db0E83131bf9A6;
	address internal constant LUMIA_POOL = 0x36523a7A21139e0D85D1d3BA69E9F8Aa9A5bD185;
	// symbol "BRETT", unpriced; Slipstream getPool(BRETT, WETH, 200): ~$406k of WETH held, cardinality
	// 5000, but a thin band (cast + this test, 2026-09-30)
	address internal constant BRETT = 0x532f27101965dd16442E59d40670FaF5eBB142E4;
	address internal constant BRETT_WETH_SLIP_200 = 0x4e829F8A5213c42535AB84AA40BD4aDCCE9cBa02;
	// Aerodrome basic (test/AerodromeBasicTwapAdapterFork.t.sol): KTA is token1 vs WETH and has a stable
	// pool next to the volatile one; AWE is token0 vs USDC
	address internal constant KTA = 0xc0634090F2Fe6c6d75e61Be2b949464aBB498973;
	address internal constant KTA_WETH = 0xd9eDC75a3a797Ec92Ca370F19051BAbebfb2edEe; // getPool(KTA, WETH, false)
	address internal constant KTA_WETH_STABLE = 0x52f58Bc927230aa1b3895979a7DB55809Ac2cd63; // getPool(KTA, WETH, true)
	address internal constant AWE = 0x1B4617734C43F6159F3a70b7E06d883647512778;
	address internal constant AWE_USDC = 0xcb7f520d18141E36956fE0b3A6Bc3D4F11245521; // getPool(AWE, USDC, false)
	// Uniswap v2 (test/UniswapV2TwapAdapterFork.t.sol): getPair(asset, quote), asset = token0 in both
	address internal constant AGNT = 0x7484a9fB40b16c4DFE9195Da399e808aa45E9BB9;
	address internal constant AGNT_USDC = 0x378551Ab1B395B1E12a49aE3914DD8066860770D;
	address internal constant OPAL = 0x119B63B1605Be3A8ff4543c7F76f7f1f79eECd1f;
	address internal constant OPAL_WETH = 0x3F2Bb479C96227805DD98d862f564AFC0131478c;

	uint256 internal constant FLOOR_USD18 = 25_000e18;
	uint256 internal constant OLD_DEPTH_FLOOR_USD18 = 50_000e18;
	uint256 internal constant MARGIN_BPS = 12_500;
	uint16 internal constant ORACLE_RING = 300;

	TwapListingRegistryV2 internal r;
	bool internal forked;
	address internal stranger = makeAddr('stranger');

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		uint256 blockNumber = vm.envOr('BASE_FORK_BLOCK', uint256(0));
		if (blockNumber > 0) vm.createSelectFork(rpc, blockNumber);
		else vm.createSelectFork(rpc);
		forked = true;

		r = new TwapListingRegistryV2(_venues());
		_configure(r);
	}

	function _venues() internal returns (TwapListingRegistryV2.Venues memory) {
		return TestVenues.build(
			IValueInterpreter(VI), UNI_FACTORY, CL_FACTORY, CL2_FACTORY, CL3_FACTORY, UNI_V2_FACTORY, AERO_FACTORY
		);
	}

	function _configure(TwapListingRegistryV2 reg) internal {
		reg.setQuote(USDC, AggregatorV3Interface(USDC_USD), USDC_HEARTBEAT);
		reg.setQuote(WETH, AggregatorV3Interface(ETH_USD), WETH_HEARTBEAT);
		reg.setLister(address(this), true);
	}

	// ─── concentrated pools: the spacing and observation floors ─────────────────

	function test_fork_tickSpacingOneRefused() public {
		vm.skip(!forked);
		assertFalse(IValueInterpreter(VI).isSupportedAsset(USDT), 'USDT must reach the spacing check');
		assertEq(ISlipstreamPoolFactory(CL_FACTORY).getPool(USDT, USDC, 1), USDT_USDC_CL1);
		assertEq(IUniswapV3PoolFactory(UNI_FACTORY).getPool(USDT, USDC, 100), USDT_USDC_UNI100);

		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.TickSpacingTooFine.selector, int24(1)));
		r.list(USDT, USDC, TwapListingRegistryV2.Venue.Slipstream, 1);
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.TickSpacingTooFine.selector, int24(1)));
		r.list(USDT, USDC, TwapListingRegistryV2.Venue.UniswapV3, 100);
		assertEq(r.adapterOf(USDT), address(0));
		assertEq(r.listedCount(), 0);
	}

	function test_fork_listRecordsQualifyingDepth() public {
		vm.skip(!forked);
		assertFalse(IValueInterpreter(VI).isSupportedAsset(VIRTUAL));
		TwapAggregatorAdapterV2 a =
			TwapAggregatorAdapterV2(address(r.list(VIRTUAL, USDC, TwapListingRegistryV2.Venue.UniswapV3, 3000)));
		assertEq(address(a.pool()), VIRTUAL_POOL);
		assertEq(uint8(r.venueOf(VIRTUAL)), uint8(TwapListingRegistryV2.Venue.UniswapV3));
		_assertParams(address(a), VIRTUAL, USDC, USDC_USD, USDC_HEARTBEAT, 'VIRTUAL / USD (TWAP)');
		assertGe(a.quoteReserveUsd(), FLOOR_USD18);
		assertGt(r.recordedDepthUsd18(VIRTUAL), OLD_DEPTH_FLOOR_USD18);
		assertEq(r.recordedDepthUsd18(VIRTUAL), a.poolDepthUsd(), 'the band depth, same block');
		assertEq(r.listedCount(), 1);
	}

	/// a young pool with one oracle observation: deep and priced, but one tick-changing trade would
	/// leave it unable to serve the window for 30 minutes
	function test_fork_cardinalityOneRefused() public {
		vm.skip(!forked);
		assertFalse(IValueInterpreter(VI).isSupportedAsset(USDL));
		assertEq(ISlipstreamPoolFactory(CL3_FACTORY).getPool(USDL, USDC, 50), USDL_USDC_SLIP3_50);
		assertEq(_cardinality(USDL_USDC_SLIP3_50), 1);

		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.ObservationCardinalityTooLow.selector, uint16(1)));
		r.list(USDL, USDC, TwapListingRegistryV2.Venue.Slipstream3, 50);
		assertEq(r.listedCount(), 0);
	}

	/// the keeper's fix, on the same real pool: raise the ring to exactly the floor (300) and make one
	/// real observation write — for cardinality 1 the next write grows the ring (index 0 is its last
	/// slot). The gate opens and the listing goes through.
	function test_fork_raisedCardinalityPasses() public {
		vm.skip(!forked);
		IPoolOracleRing(USDL_USDC_SLIP3_50).increaseObservationCardinalityNext(300);
		assertEq(_cardinality(USDL_USDC_SLIP3_50), 1, 'asking alone does not grow the ring');
		// the gate reads the ring the pool HAS, not the one it was asked for (observationCardinalityNext)
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.ObservationCardinalityTooLow.selector, uint16(1)));
		r.list(USDL, USDC, TwapListingRegistryV2.Venue.Slipstream3, 50);

		_writeObservation(USDL_USDC_SLIP3_50, USDL, USDC, 50);
		assertEq(_cardinality(USDL_USDC_SLIP3_50), 300);

		TwapAggregatorAdapterV2 a =
			TwapAggregatorAdapterV2(address(r.list(USDL, USDC, TwapListingRegistryV2.Venue.Slipstream3, 50)));
		assertEq(address(a.pool()), USDL_USDC_SLIP3_50);
		assertGt(r.recordedDepthUsd18(USDL), OLD_DEPTH_FLOOR_USD18);
		assertEq(r.listedCount(), 1);
	}

	/// the floor is inclusive: spacing 10 (Uniswap's 0.05% tier) passes the spacing check. The listing
	/// may still pass or fail on price or reserve; only TickSpacingTooFine is ruled out.
	function test_fork_tickSpacingTenPassesTheCheck() public {
		vm.skip(!forked);
		assertEq(IUniswapV3PoolFactory(UNI_FACTORY).getPool(VIRTUAL, USDC, 500), VIRTUAL_POOL_500);
		assertEq(IConcentratedPoolOracle(VIRTUAL_POOL_500).tickSpacing(), 10);
		try r.list(VIRTUAL, USDC, TwapListingRegistryV2.Venue.UniswapV3, 500) {}
		catch (bytes memory err) {
			assertTrue(bytes4(err) != TwapListingRegistryV2.TickSpacingTooFine.selector, 'spacing 10 is listable');
		}
	}

	// ─── the rule split: reserves gate, the band is recorded ────────────────────

	/// BRETT's Slipstream WETH pool holds hundreds of thousands of dollars of WETH, but little of it
	/// within −10% of the price: under v2's old band floor ($50k) it was refused; on reserves (and
	/// a band far over Ruling 23's $1,282 band floor) it lists, and the THIN band is what the
	/// registry records (it sizes the exposure caps)
	function test_fork_thinBandListsOnReserves() public {
		vm.skip(!forked);
		assertFalse(IValueInterpreter(VI).isSupportedAsset(BRETT));
		assertEq(ISlipstreamPoolFactory(CL_FACTORY).getPool(BRETT, WETH, 200), BRETT_WETH_SLIP_200);

		TwapAggregatorAdapterV2 a =
			TwapAggregatorAdapterV2(address(r.list(BRETT, WETH, TwapListingRegistryV2.Venue.Slipstream, 200)));
		assertEq(address(a.pool()), BRETT_WETH_SLIP_200);
		uint256 reserve = a.quoteReserveUsd();
		uint256 band = a.poolDepthUsd();
		assertEq(reserve, _usd18(IERC20(WETH).balanceOf(BRETT_WETH_SLIP_200), WETH, ETH_USD), 'the WETH the pool holds');
		assertGe(reserve, FLOOR_USD18, 'over the reserve floor');
		assertLt(band, OLD_DEPTH_FLOOR_USD18, 'a band the old $50k band floor refused');
		assertGe(band, r.MIN_BAND_DEPTH_USD() * 1e18, "over Ruling 23's band floor");
		assertEq(r.recordedDepthUsd18(BRETT), band, 'the band is recorded, not the reserve');
		assertLt(band, reserve);
		emit log_named_decimal_uint('BRETT WETH reserve (USD)        ', reserve, 18);
		emit log_named_decimal_uint('BRETT band depth recorded (USD) ', band, 18);
	}

	/// LUMIA's pool holds ~1 WETH: under the reserve floor. With its oracle ring raised the way the
	/// keeper would, the reserve is what refuses it — exactly the WETH it holds × ETH / USD.
	function test_fork_lumiaRefusedBelowReserveFloor() public {
		vm.skip(!forked);
		assertFalse(IValueInterpreter(VI).isSupportedAsset(LUMIA));
		assertEq(IUniswapV3PoolFactory(UNI_FACTORY).getPool(LUMIA, WETH, 3000), LUMIA_POOL);
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.ObservationCardinalityTooLow.selector, uint16(1)));
		r.list(LUMIA, WETH, TwapListingRegistryV2.Venue.UniswapV3, 3000);

		_prepareUniOracle(LUMIA_POOL);
		uint256 expected = _usd18(IERC20(WETH).balanceOf(LUMIA_POOL), WETH, ETH_USD);
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.BelowFloorAtListing.selector, expected));
		r.list(LUMIA, WETH, TwapListingRegistryV2.Venue.UniswapV3, 3000);
		assertLt(expected, FLOOR_USD18);
		assertGt(expected, 1_000e18, 'the real WETH side');
		assertEq(r.listedCount(), 0);
		emit log_named_decimal_uint('LUMIA WETH reserve (USD), refused', expected, 18);
	}

	// ─── Aerodrome basic and Uniswap v2 through the deployers ───────────────────

	/// KTA/WETH (asset = token1; a stable pool exists beside it) and AWE/USDC (asset = token0): the
	/// registry resolves the VOLATILE pool, builds the adapter with its fixed parameters, and records
	/// the band
	function test_fork_aerodromeBasicListsThroughRegistry() public {
		vm.skip(!forked);
		assertEq(IAerodromeBasicFactory(AERO_FACTORY).getPool(KTA, WETH, false), KTA_WETH);
		assertEq(IAerodromeBasicFactory(AERO_FACTORY).getPool(KTA, WETH, true), KTA_WETH_STABLE, 'a stable pool exists');

		AerodromeBasicTwapAdapter kta = _listAerodrome(KTA, WETH, KTA_WETH, ETH_USD, WETH_HEARTBEAT, 'KTA / USD (TWAP)');
		assertFalse(kta.assetIsToken0());
		AerodromeBasicTwapAdapter awe = _listAerodrome(AWE, USDC, AWE_USDC, USDC_USD, USDC_HEARTBEAT, 'AWE / USD (TWAP)');
		assertTrue(awe.assetIsToken0());
		(, address pool,,,) = r.listings(KTA);
		assertTrue(pool != KTA_WETH_STABLE, 'never the stable pool');
		assertEq(r.listedCount(), 2);
	}

	/// a Uniswap v2 pair keeps no price history: the listing waits for the recorder's first
	/// snapshot to be 30 minutes old (AGNT/USDC, OPAL/WETH; asset = token0 in both)
	function test_fork_uniswapV2ListsAfterRecording() public {
		vm.skip(!forked);
		assertEq(IUniswapV2Factory(UNI_V2_FACTORY).getPair(AGNT, USDC), AGNT_USDC);
		assertEq(IUniswapV2Factory(UNI_V2_FACTORY).getPair(OPAL, WETH), OPAL_WETH);
		UniswapV2ObservationRecorder recorder = r.recorder();

		vm.expectRevert(abi.encodeWithSelector(UniswapV2ObservationRecorder.NoSnapshot.selector, AGNT_USDC));
		r.list(AGNT, USDC, TwapListingRegistryV2.Venue.UniswapV2, 0);

		assertTrue(recorder.record(AGNT_USDC));
		assertTrue(recorder.record(OPAL_WETH));
		vm.warp(block.timestamp + 20 minutes);
		vm.roll(block.number + 600);
		// 20 minutes of history is not a window
		vm.expectRevert(abi.encodeWithSelector(UniswapV2ObservationRecorder.NoSnapshot.selector, OPAL_WETH));
		r.list(OPAL, WETH, TwapListingRegistryV2.Venue.UniswapV2, 0);

		vm.warp(block.timestamp + 11 minutes);
		vm.roll(block.number + 330);
		(,,, uint256 ethUpdatedAt,) = AggregatorV3Interface(ETH_USD).latestRoundData();
		assertLe(block.timestamp - ethUpdatedAt, WETH_HEARTBEAT, 'ETH / USD still fresh after the warp');

		UniswapV2TwapAdapter agnt = _listUniswapV2(AGNT, USDC, AGNT_USDC, USDC_USD, USDC_HEARTBEAT, 'AGNT / USD (TWAP)');
		UniswapV2TwapAdapter opal = _listUniswapV2(OPAL, WETH, OPAL_WETH, ETH_USD, WETH_HEARTBEAT, 'OPAL / USD (TWAP)');
		assertEq(address(agnt.recorder()), address(recorder));
		assertEq(address(opal.recorder()), address(recorder));
		assertEq(r.listedCount(), 2);
	}

	/// the new venues have one canonical pool per pair: with the pair / volatile pool right there, a
	/// nonzero fee or tick spacing still names nothing
	function test_fork_newVenuesNeedZeroFeeOrTickSpacing() public {
		vm.skip(!forked);
		assertEq(IUniswapV2Factory(UNI_V2_FACTORY).getPair(AGNT, USDC), AGNT_USDC);
		assertEq(IAerodromeBasicFactory(AERO_FACTORY).getPool(KTA, WETH, false), KTA_WETH);
		int24[4] memory nonzero = [int24(1), int24(-1), int24(30), int24(3000)];
		for (uint256 i; i < nonzero.length; ++i) {
			vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.PoolNotFound.selector, AGNT, USDC));
			r.list(AGNT, USDC, TwapListingRegistryV2.Venue.UniswapV2, nonzero[i]);
			vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.PoolNotFound.selector, KTA, WETH));
			r.list(KTA, WETH, TwapListingRegistryV2.Venue.AerodromeBasic, nonzero[i]);
		}
		assertEq(r.listedCount(), 0);
	}

	/// no pair / no volatile pool: PoolNotFound
	function test_fork_newVenuesWithoutAPoolNotFound() public {
		vm.skip(!forked);
		assertEq(IUniswapV2Factory(UNI_V2_FACTORY).getPair(KTA, USDC), address(0));
		assertEq(IAerodromeBasicFactory(AERO_FACTORY).getPool(LUMIA, USDC, false), address(0));
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.PoolNotFound.selector, KTA, USDC));
		r.list(KTA, USDC, TwapListingRegistryV2.Venue.UniswapV2, 0);
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.PoolNotFound.selector, LUMIA, USDC));
		r.list(LUMIA, USDC, TwapListingRegistryV2.Venue.AerodromeBasic, 0);
	}

	/// the deployers are permissionless and pass every argument through to the adapter they create
	function test_fork_deployersArePermissionless() public {
		vm.skip(!forked);
		vm.startPrank(stranger);
		address cl = r.clDeployer().deploy(
			IConcentratedPoolOracle(VIRTUAL_POOL), VIRTUAL, AggregatorV3Interface(USDC_USD), 31 minutes, 7, 123, 4567, 'cl'
		);
		address v2 = r.v2Deployer().deploy(
			IUniswapV2Pair(OPAL_WETH), OPAL, AggregatorV3Interface(ETH_USD), r.recorder(), 32 minutes, 8, 124, 4568, 'v2'
		);
		address aero = r.aeroDeployer().deploy(
			IAerodromeBasicPool(AWE_USDC), AWE, AggregatorV3Interface(USDC_USD), 33 minutes, 9, 125, 4569, 'aero'
		);
		vm.stopPrank();
		_assertRawParams(cl, VIRTUAL, USDC, USDC_USD, 31 minutes, 7, 123, 4567, 'cl');
		_assertRawParams(v2, OPAL, WETH, ETH_USD, 32 minutes, 8, 124, 4568, 'v2');
		_assertRawParams(aero, AWE, USDC, USDC_USD, 33 minutes, 9, 125, 4569, 'aero');
		assertEq(address(TwapAggregatorAdapterV2(cl).pool()), VIRTUAL_POOL);
		assertEq(address(UniswapV2TwapAdapter(v2).pair()), OPAL_WETH);
		assertEq(address(UniswapV2TwapAdapter(v2).recorder()), address(r.recorder()));
		assertEq(address(AerodromeBasicTwapAdapter(aero).pool()), AWE_USDC);
	}

	// ─── repoint: the margin binds only while the current pool holds the floor ──

	/// The current listing is a probe (its two reads set by the test); the move target is a real
	/// pool through the real `_qualify`. The 25% margin over the current BAND applies only while the
	/// current pool holds the two-part floor (its RESERVE over the floor and its band read); otherwise
	/// any qualifying pool may replace it. (The acceptance suite takes a real pool under the floor
	/// with real sells.)
	function test_fork_repointMarginOnlyWhileTheCurrentPoolHoldsTheFloor() public {
		vm.skip(!forked);
		TwapListingRegistryV2Harness h = new TwapListingRegistryV2Harness(_venues());
		_configure(h);
		FloorProbeAdapter probe = new FloorProbeAdapter();
		h.listOnProbe(VIRTUAL, address(probe));
		probe.setDepth(1e30); // a band no real pool is 25% deeper than

		// floor held, band readable: the margin refuses
		probe.setReserve(FLOOR_USD18);
		bytes memory err = _repointRevert(h);
		assertEq(bytes4(err), TwapListingRegistryV2.NotDeepEnough.selector);
		(uint256 cur, uint256 next) = abi.decode(_args(err), (uint256, uint256));
		assertEq(cur, 1e30, 'measured against the current band');
		assertGt(next, 0);

		// reserve held, band unreadable: under the two-part floor, no margin to measure against
		uint256 snap = vm.snapshotState();
		probe.setBandBroken(true);
		_assertRepointedToVirtualPool(h);
		vm.revertToState(snap);

		// reserve under the floor, band still readable and huge: the margin is lifted
		probe.setReserve(FLOOR_USD18 - 1);
		vm.prank(stranger);
		assertTrue(h.pokeFloor(VIRTUAL));
		(,,,, uint64 since) = h.listings(VIRTUAL);
		assertEq(since, block.timestamp);
		_assertRepointedToVirtualPool(h);
		(,,,, since) = h.listings(VIRTUAL);
		assertEq(since, 0, 'the repoint resets the clock');
		vm.revertToState(snap);

		// the current pool can't answer at all
		probe.setBroken(true);
		_assertRepointedToVirtualPool(h);
	}

	function _repointRevert(TwapListingRegistryV2 reg) internal returns (bytes memory err) {
		try reg.repoint(VIRTUAL, USDC, TwapListingRegistryV2.Venue.UniswapV3, 3000) {
			revert('expected a revert');
		} catch (bytes memory e) {
			err = e;
		}
	}

	function _assertRepointedToVirtualPool(TwapListingRegistryV2 reg) internal {
		TwapAggregatorAdapterV2 a =
			TwapAggregatorAdapterV2(address(reg.repoint(VIRTUAL, USDC, TwapListingRegistryV2.Venue.UniswapV3, 3000)));
		(ITwapPriceAdapter adapter, address pool, address quote,,) = reg.listings(VIRTUAL);
		assertEq(address(adapter), address(a));
		assertEq(pool, VIRTUAL_POOL);
		assertEq(quote, USDC);
		assertEq(uint8(reg.venueOf(VIRTUAL)), uint8(TwapListingRegistryV2.Venue.UniswapV3));
		assertEq(reg.recordedDepthUsd18(VIRTUAL), a.poolDepthUsd(), 'the new band is recorded');
		assertLt(reg.recordedDepthUsd18(VIRTUAL), Math.mulDiv(1e30, MARGIN_BPS, 10_000), 'the margin alone would refuse it');
	}

	// ─── helpers ────────────────────────────────────────────────────────────────

	function _listAerodrome(
		address asset,
		address quote,
		address pool,
		address feed,
		uint32 heartbeat,
		string memory description
	) internal returns (AerodromeBasicTwapAdapter a) {
		a = AerodromeBasicTwapAdapter(address(r.list(asset, quote, TwapListingRegistryV2.Venue.AerodromeBasic, 0)));
		assertEq(address(a.pool()), pool);
		(uint256 r0, uint256 r1,) = IAerodromeBasicPool(pool).getReserves();
		_assertListed(address(a), asset, quote, pool, TwapListingRegistryV2.Venue.AerodromeBasic);
		_assertParams(address(a), asset, quote, feed, heartbeat, description);
		_assertReserveAndSpot(address(a), asset, quote, feed, a.assetIsToken0() ? r1 : r0, a.assetIsToken0() ? r0 : r1);
	}

	function _listUniswapV2(
		address asset,
		address quote,
		address pair,
		address feed,
		uint32 heartbeat,
		string memory description
	) internal returns (UniswapV2TwapAdapter a) {
		a = UniswapV2TwapAdapter(address(r.list(asset, quote, TwapListingRegistryV2.Venue.UniswapV2, 0)));
		assertEq(address(a.pair()), pair);
		(uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
		_assertListed(address(a), asset, quote, pair, TwapListingRegistryV2.Venue.UniswapV2);
		_assertParams(address(a), asset, quote, feed, heartbeat, description);
		_assertReserveAndSpot(address(a), asset, quote, feed, a.assetIsToken0() ? r1 : r0, a.assetIsToken0() ? r0 : r1);
	}

	function _assertListed(address adapter, address asset, address quote, address pool, TwapListingRegistryV2.Venue venue)
		internal
		view
	{
		(ITwapPriceAdapter stored, address storedPool, address storedQuote, uint64 listedAt, uint64 since) = r.listings(asset);
		assertEq(address(stored), adapter);
		assertEq(r.adapterOf(asset), adapter);
		assertEq(storedPool, pool);
		assertEq(storedQuote, quote);
		assertEq(listedAt, block.timestamp);
		assertEq(since, 0);
		assertEq(uint8(r.venueOf(asset)), uint8(venue));
		assertEq(r.recordedDepthUsd18(asset), ITwapPriceAdapter(adapter).poolDepthUsd(), 'the band is recorded');
	}

	/// @dev The registry's fixed parameters on an adapter it created.
	function _assertParams(
		address adapter,
		address asset,
		address quote,
		address feed,
		uint32 heartbeat,
		string memory description
	) internal view {
		_assertRawParams(
			adapter, asset, quote, feed, r.WINDOW(), r.MIN_QUOTE_RESERVE_USD(), r.MAX_DEVIATION_BPS(), heartbeat, description
		);
		assertEq(IAdapterParams(adapter).minBandDepthUsd(), r.MIN_BAND_DEPTH_USD(), "the registry's band floor");
	}

	function _assertRawParams(
		address adapter,
		address asset,
		address quote,
		address feed,
		uint32 window,
		uint256 minLiquidityUsd,
		uint16 maxDeviationBps,
		uint32 heartbeat,
		string memory description
	) internal view {
		IAdapterParams p = IAdapterParams(adapter);
		assertEq(p.asset(), asset);
		assertEq(p.quoteAsset(), quote);
		assertEq(p.quoteFeed(), feed);
		assertEq(p.window(), window);
		assertEq(p.minLiquidityUsd(), minLiquidityUsd);
		assertEq(p.minBandDepthUsd(), minLiquidityUsd * 51_316 / 1e6, 'the band floor follows the reserve floor');
		assertEq(p.maxDeviationBps(), maxDeviationBps);
		assertEq(p.quoteHeartbeat(), heartbeat);
		assertEq(p.description(), description);
	}

	/// @dev The quote reserve is exactly getReserves' quote × the feed; the TWAP price is within the
	///      adapter's 5% of the current reserves' spot.
	function _assertReserveAndSpot(address adapter, address asset, address quote, address feed, uint256 rQ, uint256 rA)
		internal
	{
		ITwapPriceAdapter a = ITwapPriceAdapter(adapter);
		uint256 reserve = a.quoteReserveUsd();
		assertEq(reserve, _usd18(rQ, quote, feed), 'the quote reserve x the feed');
		assertGe(reserve, FLOOR_USD18);
		(, int256 answer,,,) = a.latestRoundData();
		uint256 spot =
			Math.mulDiv(_usd18(rQ, quote, feed), 10 ** IERC20Metadata(asset).decimals(), rA);
		assertApproxEqRel(SafeCast.toUint256(answer), spot, 0.05e18, 'TWAP near spot');
		emit log_named_string('listed', IERC20Metadata(asset).symbol());
		emit log_named_decimal_uint('  quote reserve (USD)', reserve, 18);
		emit log_named_decimal_uint('  band depth (USD)   ', a.poolDepthUsd(), 18);
		emit log_named_decimal_uint('  TWAP price (USD)   ', SafeCast.toUint256(answer), 18);
		emit log_named_decimal_uint('  spot price (USD)   ', spot, 18);
	}

	/// @dev USD (18 dp) of `amount` raw units of `token` at `feed`.
	function _usd18(uint256 amount, address token, address feed) internal view returns (uint256) {
		(, int256 answer,,,) = AggregatorV3Interface(feed).latestRoundData();
		uint256 feedUsd18 = SafeCast.toUint256(answer) * 10 ** (18 - AggregatorV3Interface(feed).decimals());
		return Math.mulDiv(amount, feedUsd18, 10 ** IERC20Metadata(token).decimals());
	}

	function _args(bytes memory err) internal pure returns (bytes memory args) {
		args = new bytes(err.length - 4);
		for (uint256 i; i < args.length; ++i) {
			args[i] = err[i + 4];
		}
	}

	/// @dev slot0's observationCardinality (fourth word on Uniswap v3 and Slipstream alike).
	function _cardinality(address pool) internal view returns (uint16 cardinality) {
		(bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature('slot0()'));
		assertTrue(ok);
		(,,, cardinality) = abi.decode(data, (uint160, int24, uint16, uint16));
	}

	/// @dev (tick, observationIndex) from slot0; a pool that already wrote an observation this
	///      block writes the next one a block later.
	function _nextWritableBlock(address pool) internal returns (int24 tick, uint16 index) {
		(bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature('slot0()'));
		assertTrue(ok);
		(, tick, index) = abi.decode(data, (uint160, int24, uint16));
		(uint32 newest,,,) = IPoolOracleRing(pool).observations(index);
		if (newest == block.timestamp) {
			vm.roll(block.number + 1);
			vm.warp(block.timestamp + 2);
		}
	}

	/// @dev One real observation write on a Slipstream-3 pool: a swap of token0 through the real
	///      router that moves the tick down by one (a write only happens when the tick changes).
	function _writeObservation(address pool, address token0, address token1, int24 tickSpacing) internal {
		(int24 tick,) = _nextWritableBlock(pool);
		uint256 amount = 1_000_000e18;
		deal(token0, address(this), amount);
		IERC20(token0).approve(CL3_SWAP_ROUTER, amount);
		ISlipstreamSwapRouter(CL3_SWAP_ROUTER).exactInputSingle(
			ISlipstreamSwapRouter.ExactInputSingleParams({
				tokenIn: token0,
				tokenOut: token1,
				tickSpacing: tickSpacing,
				recipient: address(this),
				deadline: block.timestamp,
				amountIn: amount,
				amountOutMinimum: 0,
				sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(tick - 1)
			})
		);
		(, bytes memory after_) = pool.staticcall(abi.encodeWithSignature('slot0()'));
		(, int24 tickAfter) = abi.decode(after_, (uint160, int24));
		assertEq(tickAfter, tick - 1, 'the tick moved: the pool wrote an observation');
	}

	/// @dev What the keeper does before listing a Uniswap v3 pool with a short ring: ask for 300
	///      observations, then make one real write — a dust position minted through the real NPM in
	///      the spacing-wide range holding the current tick (an in-range mint writes without moving
	///      the price; for cardinality 1 that write grows the ring).
	function _prepareUniOracle(address pool) internal {
		IPoolOracleRing(pool).increaseObservationCardinalityNext(ORACLE_RING);
		(int24 tick, uint16 index) = _nextWritableBlock(pool);
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
		IUniswapV3NonfungiblePositionManager(UNI_NPM).mint(
			IUniswapV3NonfungiblePositionManager.MintParams({
				token0: token0,
				token1: token1,
				fee: IUniswapV3PoolFeeTier(pool).fee(),
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
		(bool ok, bytes memory after_) = pool.staticcall(abi.encodeWithSignature('slot0()'));
		assertTrue(ok);
		(, int24 tickAfter, uint16 indexAfter) = abi.decode(after_, (uint160, int24, uint16));
		assertEq(tickAfter, tick, 'an in-range mint leaves the price alone');
		assertTrue(indexAfter != index, 'an observation was written');
		assertGe(_cardinality(pool), ORACLE_RING, 'the ring grew');
	}
}
