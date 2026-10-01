// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Vm} from 'forge-std/Vm.sol';
import {TwapListingRegistryV2} from '../src/pricing/TwapListingRegistryV2.sol';
import {TwapAggregatorAdapterV2} from '../src/pricing/TwapAggregatorAdapterV2.sol';
import {IConcentratedPoolOracle} from '../src/pricing/TwapAggregatorAdapter.sol';
import {IUniswapV3PoolFactory, ISlipstreamPoolFactory} from '../src/pricing/TwapListingRegistry.sol';
import {IValueInterpreter} from '../src/interfaces/IValueInterpreter.sol';
import {AggregatorV3Interface} from '../src/interfaces/AggregatorV3Interface.sol';
import {ISlipstreamSwapRouter} from '../src/interfaces/external/ISlipstreamSwapRouter.sol';
import {TickMath} from '../src/libraries/TickMath.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/// @dev An adapter stand-in whose depth the test sets (the registry derives "under the floor" from
///      it); `broken` makes the read revert, `burn` makes it spend that much gas first.
contract FloorProbeAdapter {
	uint256 public depth;
	bool public broken;
	uint256 public burn;

	function setDepth(uint256 depth_) external {
		depth = depth_;
	}

	function setBroken(bool broken_) external {
		broken = broken_;
	}

	function setBurn(uint256 burn_) external {
		burn = burn_;
	}

	function poolDepthUsd() external view returns (uint256) {
		_burn();
		require(!broken, 'BROKEN');
		return depth;
	}

	/// @dev Spend `burn` gas, like an expensive band walk.
	function _burn() internal view {
		uint256 start = gasleft();
		while (start - gasleft() < burn) {}
	}
}

/// @dev The registry plus helpers that list an asset on a probe adapter (skipping `_qualify`) and
///      fill the listed-asset array.
contract TwapListingRegistryV2Harness is TwapListingRegistryV2 {
	constructor(
		IValueInterpreter valueInterpreter_,
		IUniswapV3PoolFactory uniswapFactory_,
		ISlipstreamPoolFactory slipstreamFactory_,
		ISlipstreamPoolFactory slipstream2Factory_,
		ISlipstreamPoolFactory slipstream3Factory_
	) TwapListingRegistryV2(valueInterpreter_, uniswapFactory_, slipstreamFactory_, slipstream2Factory_, slipstream3Factory_) {}

	function listOnProbe(address asset, address adapter) external {
		listings[asset] = Listing(TwapAggregatorAdapterV2(adapter), adapter, address(0), uint64(block.timestamp), 0);
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

	function setUp() public {
		r = new TwapListingRegistryV2(
			IValueInterpreter(vi),
			IUniswapV3PoolFactory(makeAddr('uni')),
			ISlipstreamPoolFactory(makeAddr('s1')),
			ISlipstreamPoolFactory(makeAddr('s2')),
			ISlipstreamPoolFactory(makeAddr('s3'))
		);
	}

	function test_constructorRejectsZero() public {
		vm.expectRevert(TwapListingRegistryV2.ZeroAddress.selector);
		new TwapListingRegistryV2(
			IValueInterpreter(vi),
			IUniswapV3PoolFactory(makeAddr('uni')),
			ISlipstreamPoolFactory(makeAddr('s1')),
			ISlipstreamPoolFactory(makeAddr('s2')),
			ISlipstreamPoolFactory(address(0))
		);
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

	// ─── amendment A: only a lister makes a positive depth claim ────────────────

	function _harness() internal returns (TwapListingRegistryV2Harness h, FloorProbeAdapter probe, address asset) {
		h = new TwapListingRegistryV2Harness(
			IValueInterpreter(vi),
			IUniswapV3PoolFactory(makeAddr('uni')),
			ISlipstreamPoolFactory(makeAddr('s1')),
			ISlipstreamPoolFactory(makeAddr('s2')),
			ISlipstreamPoolFactory(makeAddr('s3'))
		);
		probe = new FloorProbeAdapter();
		asset = makeAddr('asset');
		h.listOnProbe(asset, address(probe));
	}

	/// same-transaction liquidity makes the pool read over the floor; a stranger's poke still cannot clear the clock
	function test_publicPokeCannotClearClock() public {
		(TwapListingRegistryV2Harness h, FloorProbeAdapter probe, address asset) = _harness();
		address lister = makeAddr('lister');
		h.setLister(lister, true);

		// anyone may START the clock
		probe.setDepth(1_000e18);
		vm.expectEmit(address(h));
		emit TwapListingRegistryV2.FloorBreached(asset, block.timestamp);
		vm.prank(stranger);
		assertTrue(h.pokeFloor(asset));
		(,,,, uint64 since) = h.listings(asset);
		assertEq(since, block.timestamp);
		assertEq(h.recordedDepthUsd18(asset), 0, 'a stranger never records depth');

		// the pool now reads deep (e.g. a JIT mint): the stranger's clear is a silent no-op
		skip(72 hours);
		probe.setDepth(60_000e18);
		vm.recordLogs();
		vm.prank(stranger);
		assertFalse(h.pokeFloor(asset), 'still reports the live read');
		assertEq(vm.getRecordedLogs().length, 0, 'no FloorRestored, no DepthRecorded');
		(,,,, uint64 stillSince) = h.listings(asset);
		assertEq(stillSince, since, 'clock not cleared');
		assertTrue(h.isDelisted(asset));
		assertEq(h.recordedDepthUsd18(asset), 0);

		// the lister (the keeper, via the module) may clear it
		vm.expectEmit(address(h));
		emit TwapListingRegistryV2.FloorRestored(asset);
		vm.expectEmit(address(h));
		emit TwapListingRegistryV2.DepthRecorded(asset, 60_000e18);
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

		// over the floor: records the live depth, no clock change
		probe.setDepth(80_000e18);
		vm.recordLogs();
		vm.prank(lister);
		assertFalse(h.pokeFloor(asset));
		Vm.Log[] memory logs = vm.getRecordedLogs();
		assertEq(logs.length, 1, 'only DepthRecorded');
		assertEq(logs[0].topics[0], TwapListingRegistryV2.DepthRecorded.selector);
		assertEq(logs[0].topics[1], bytes32(uint256(uint160(asset))));
		assertEq(abi.decode(logs[0].data, (uint256)), 80_000e18);
		assertEq(h.recordedDepthUsd18(asset), 80_000e18);

		// a stranger's poke never moves the recorded depth, up or down
		probe.setDepth(500_000e18);
		vm.prank(stranger);
		h.pokeFloor(asset);
		assertEq(h.recordedDepthUsd18(asset), 80_000e18);

		// under the floor: a lister's poke starts the clock AND records the lower depth
		probe.setDepth(20_000e18);
		vm.prank(lister);
		assertTrue(h.pokeFloor(asset));
		(,,,, uint64 since) = h.listings(asset);
		assertEq(since, block.timestamp);
		assertEq(h.recordedDepthUsd18(asset), 20_000e18);

		// an unanswerable pool: under the floor, recorded depth 0
		probe.setDepth(90_000e18);
		probe.setBroken(true);
		vm.expectEmit(address(h));
		emit TwapListingRegistryV2.DepthRecorded(asset, 0);
		vm.prank(lister);
		assertTrue(h.pokeFloor(asset));
		assertEq(h.recordedDepthUsd18(asset), 0);
		(,,,, uint64 stillSince) = h.listings(asset);
		assertEq(stillSince, since, 'a later poke keeps the ORIGINAL start');
	}

	/// a stranger can't starve the depth read so that its out-of-gas catch reads as "under the floor"
	function test_gasStarvedPokeCannotStartClock() public {
		(TwapListingRegistryV2Harness h, FloorProbeAdapter probe, address asset) = _harness();
		probe.setDepth(80_000e18); // over the floor
		probe.setBurn(3_000_000); // an expensive band walk

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
		probe.setDepth(20_000e18);
		vm.prank(stranger);
		assertTrue(h.pokeFloor(asset));
		(,,,, since) = h.listings(asset);
		assertEq(since, block.timestamp);
	}

	/// a read that exhausts MIN_READ_GAS or more (e.g. a pool dusted on thousands of ticks) is the
	/// pool's failure, not the caller's: it counts as under the floor, so the clock can still start.
	/// `repoint` shares this branch (`_currentDepth`); Task 7 covers it on a real pool.
	function test_unreadablePoolCountsUnderFloor() public {
		(TwapListingRegistryV2Harness h, FloorProbeAdapter probe, address asset) = _harness();
		address lister = makeAddr('lister');
		h.setLister(lister, true);
		probe.setDepth(80_000e18); // over the floor, if it could ever be read
		probe.setBurn(20_000_000); // more than any transaction can give the read
		uint256 gas = 10_000_000;
		assertGe(gas, h.MIN_READ_GAS());

		vm.expectEmit(address(h));
		emit TwapListingRegistryV2.FloorBreached(asset, block.timestamp);
		vm.prank(stranger);
		assertTrue(h.pokeFloor{gas: gas}(asset));
		(,,,, uint64 since) = h.listings(asset);
		assertEq(since, block.timestamp);

		// a lister's poke on the same pool records 0 (never the unread 80k) and keeps the start
		skip(1 hours);
		vm.expectEmit(address(h));
		emit TwapListingRegistryV2.DepthRecorded(asset, 0);
		vm.prank(lister);
		assertTrue(h.pokeFloor{gas: gas}(asset));
		assertEq(h.recordedDepthUsd18(asset), 0);
		(,,,, uint64 stillSince) = h.listings(asset);
		assertEq(stillSince, since);
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

/// @notice `_qualify` against real Base pools: the tick-spacing floor refuses spacing-1 pools on both
///         venue types, the observation floor refuses a cardinality-1 pool until its ring is raised,
///         and a real listing records its qualifying depth.
///         Run: BASE_MAINNET_RPC=<url> [BASE_FORK_BLOCK=<n>] forge test --match-path test/TwapListingRegistryV2.t.sol -vv
contract TwapListingRegistryV2ForkTest is Test {
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
	address internal constant USDT = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;
	// Slipstream ts1, ~$330k of USDC within ±10%: deep enough to list but for its spacing (cast, 2026-09-30)
	address internal constant USDT_USDC_CL1 = 0xa41Bc0AFfbA7Fd420d186b84899d7ab2aC57fcD1;
	address internal constant USDT_USDC_UNI100 = 0xD56da2B74bA826f19015E6B7Dd9Dae1903E85DA1; // UniV3 0.01%, ts1
	address internal constant VIRTUAL = 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b;
	address internal constant VIRTUAL_POOL = 0x529d2863a1521d0b57db028168fdE2E97120017C; // UniV3 0.3% vs USDC
	address internal constant VIRTUAL_POOL_500 = 0x23211B35d62a5C9A76Cf1AA1Cc391bb331D50659; // UniV3 0.05%, ts10
	address internal constant VI = 0x3CDbaBE5Bf4E6cfE10A2A326E0ad31b2d16398D4; // live genesis ValueInterpreter
	address internal constant UNI_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
	address internal constant CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
	address internal constant CL2_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;
	address internal constant CL3_FACTORY = 0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a;
	address internal constant CL3_SWAP_ROUTER = 0xcbBb8035cAc7D4B3Ca7aBb74cF7BdF900215Ce0D; // factory() = CL3_FACTORY
	// "USDL Stablecoin", 18 dp, unpriced; its USDC Slipstream-3 ts50 pool holds $345k of USDC within ±10%
	// but ONE oracle observation: slot0 (index 0, cardinality 1, next 1) at block 52008523 (cast)
	address internal constant USDL = 0x78E8CF657742e10eaC8F64007615AA741fC76414;
	address internal constant USDL_USDC_SLIP3_50 = 0xf0d64B4fe5D2619a3aDBE2734AD0584FC54bed88;

	TwapListingRegistryV2 internal r;
	bool internal forked;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		uint256 blockNumber = vm.envOr('BASE_FORK_BLOCK', uint256(0));
		if (blockNumber > 0) vm.createSelectFork(rpc, blockNumber);
		else vm.createSelectFork(rpc);
		forked = true;

		r = new TwapListingRegistryV2(
			IValueInterpreter(VI),
			IUniswapV3PoolFactory(UNI_FACTORY),
			ISlipstreamPoolFactory(CL_FACTORY),
			ISlipstreamPoolFactory(CL2_FACTORY),
			ISlipstreamPoolFactory(CL3_FACTORY)
		);
		r.setQuote(USDC, AggregatorV3Interface(USDC_USD), 90_000);
		r.setLister(address(this), true);
	}

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
		TwapAggregatorAdapterV2 a = r.list(VIRTUAL, USDC, TwapListingRegistryV2.Venue.UniswapV3, 3000);
		assertEq(address(a.pool()), VIRTUAL_POOL);
		assertEq(uint8(r.venueOf(VIRTUAL)), uint8(TwapListingRegistryV2.Venue.UniswapV3));
		assertGt(r.recordedDepthUsd18(VIRTUAL), 50_000e18);
		assertEq(r.recordedDepthUsd18(VIRTUAL), a.poolDepthUsd(), 'the qualifying read, same block');
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

		TwapAggregatorAdapterV2 a = r.list(USDL, USDC, TwapListingRegistryV2.Venue.Slipstream3, 50);
		assertEq(address(a.pool()), USDL_USDC_SLIP3_50);
		assertGt(r.recordedDepthUsd18(USDL), 50_000e18);
		assertEq(r.listedCount(), 1);
	}

	/// the floor is inclusive: spacing 10 (Uniswap's 0.05% tier) passes the spacing check. The listing
	/// may still pass or fail on price or depth; only TickSpacingTooFine is ruled out.
	function test_fork_tickSpacingTenPassesTheCheck() public {
		vm.skip(!forked);
		assertEq(IUniswapV3PoolFactory(UNI_FACTORY).getPool(VIRTUAL, USDC, 500), VIRTUAL_POOL_500);
		assertEq(IConcentratedPoolOracle(VIRTUAL_POOL_500).tickSpacing(), 10);
		try r.list(VIRTUAL, USDC, TwapListingRegistryV2.Venue.UniswapV3, 500) {}
		catch (bytes memory err) {
			assertTrue(bytes4(err) != TwapListingRegistryV2.TickSpacingTooFine.selector, 'spacing 10 is listable');
		}
	}

	/// @dev slot0's observationCardinality (fourth word on Uniswap v3 and Slipstream alike).
	function _cardinality(address pool) internal view returns (uint16 cardinality) {
		(bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature('slot0()'));
		assertTrue(ok);
		(,,, cardinality) = abi.decode(data, (uint160, int24, uint16, uint16));
	}

	/// @dev One real observation write on a Slipstream-3 pool: a swap of token0 through the real
	///      router that moves the tick down by one (a write only happens when the tick changes, and
	///      at most once per block, so a pool that already wrote this block is traded a block later).
	function _writeObservation(address pool, address token0, address token1, int24 tickSpacing) internal {
		(bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature('slot0()'));
		assertTrue(ok);
		(, int24 tick, uint16 index) = abi.decode(data, (uint160, int24, uint16));
		(uint32 newest,,,) = IPoolOracleRing(pool).observations(index);
		if (newest == block.timestamp) {
			vm.roll(block.number + 1);
			vm.warp(block.timestamp + 2);
		}
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
}
