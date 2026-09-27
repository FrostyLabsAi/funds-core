// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {
	TwapListingRegistry,
	IUniswapV3PoolFactory,
	ISlipstreamPoolFactory
} from '../src/pricing/TwapListingRegistry.sol';
import {TwapFloorLens} from '../src/pricing/TwapFloorLens.sol';
import {AggregatorV3Interface} from '../src/interfaces/AggregatorV3Interface.sol';
import {IValueInterpreter} from '../src/interfaces/IValueInterpreter.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';
import {ScriptedPool} from './TwapAggregatorAdapter.t.sol';
import {ScriptedFactory} from './TwapListingRegistry.t.sol';

/// @notice The lens must name EXACTLY the assets whose `pokeFloor` would change the stored
///         72-hour clock — the keeper workflow pokes what it returns and nothing else.
contract TwapFloorLensTest is Test {
	int24 internal constant TICK_2500 = -198_080;

	ValueInterpreter internal vi;
	ScriptedFactory internal uni;
	TwapListingRegistry internal registry;
	TwapFloorLens internal lens;
	MockERC20 internal usdc;
	MockAggregator internal usdcFeed;
	MockERC20[3] internal memes;
	ScriptedPool[3] internal pools;

	function setUp() public {
		vm.warp(10 days);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		usdcFeed = new MockAggregator(8, 1e8);
		vi = new ValueInterpreter(address(this));
		vi.addPrimitive(address(usdc), address(usdcFeed), 2 days);
		uni = new ScriptedFactory();
		registry = new TwapListingRegistry(
			IValueInterpreter(address(vi)),
			IUniswapV3PoolFactory(address(uni)),
			ISlipstreamPoolFactory(address(new ScriptedFactory())),
			ISlipstreamPoolFactory(address(new ScriptedFactory()))
		);
		registry.setQuote(address(usdc), AggregatorV3Interface(address(usdcFeed)), 2 days);
		lens = new TwapFloorLens();

		for (uint256 i; i < 3; ++i) {
			memes[i] = new MockERC20('Meme', 'MEME', 18);
			pools[i] = new ScriptedPool(address(memes[i]), address(usdc));
			pools[i].set(TICK_2500, TICK_2500, 1e18); // ≈ $4.9M of ±10% depth
			uni.setUni(address(memes[i]), address(usdc), 3000, address(pools[i]));
			registry.list(address(memes[i]), address(usdc), TwapListingRegistry.Venue.UniswapV3, 3000);
		}
	}

	function _thin(uint256 i) internal {
		pools[i].set(TICK_2500, TICK_2500, 1e14); // ≈ $489 of depth, floor $50k
	}

	function _restore(uint256 i) internal {
		pools[i].set(TICK_2500, TICK_2500, 1e18);
	}

	function _since(uint256 i) internal view returns (uint64 since) {
		(,,,, since) = registry.listings(address(memes[i]));
	}

	function test_emptyRegistry_returnsNothing() public {
		TwapListingRegistry empty = new TwapListingRegistry(
			IValueInterpreter(address(vi)),
			IUniswapV3PoolFactory(address(uni)),
			ISlipstreamPoolFactory(address(uni)),
			ISlipstreamPoolFactory(address(uni))
		);
		assertEq(lens.assetsNeedingPoke(empty).length, 0);
	}

	function test_everyPoolOverTheFloor_noClock_returnsNothing() public view {
		assertEq(lens.assetsNeedingPoke(registry).length, 0);
	}

	function test_thinnedPoolWithoutAClock_isReturned() public {
		_thin(1);
		address[] memory due = lens.assetsNeedingPoke(registry);
		assertEq(due.length, 1);
		assertEq(due[0], address(memes[1]));
	}

	function test_clockAlreadyRunningAndStillUnder_isNotReturned() public {
		_thin(1);
		registry.pokeFloor(address(memes[1]));
		assertEq(lens.assetsNeedingPoke(registry).length, 0);
	}

	function test_recoveredWhileTheClockRuns_isReturned() public {
		_thin(2);
		registry.pokeFloor(address(memes[2]));
		skip(10 hours);
		usdcFeed.setAnswer(1e8);
		_restore(2);
		address[] memory due = lens.assetsNeedingPoke(registry);
		assertEq(due.length, 1);
		assertEq(due[0], address(memes[2]));
	}

	/// the registry's own rule: a pool that cannot serve the window counts as under the floor —
	/// the adapter's revert must not revert the lens (it would kill the whole keeper run)
	function test_poolThatCannotServeTheWindow_countsAsUnder_andDoesNotRevert() public {
		pools[0].setYoung(true);
		address[] memory due = lens.assetsNeedingPoke(registry);
		assertEq(due.length, 1);
		assertEq(due[0], address(memes[0]));

		registry.pokeFloor(address(memes[0]));
		assertEq(lens.assetsNeedingPoke(registry).length, 0, 'clock running, still unable to serve');
	}

	function test_mixedStates_returnsOnlyTheChanges_inListingOrder() public {
		_thin(0); // needs a start
		_thin(1);
		registry.pokeFloor(address(memes[1])); // running, still under → nothing to do
		_thin(2);
		registry.pokeFloor(address(memes[2]));
		_restore(2); // needs a clear

		address[] memory due = lens.assetsNeedingPoke(registry);
		assertEq(due.length, 2);
		assertEq(due[0], address(memes[0]));
		assertEq(due[1], address(memes[2]));
	}

	/// the defining property: poking what the lens returns changes every clock it names and
	/// poking anything else changes none — and afterwards the lens has nothing left to say
	function testFuzz_lensAgreesWithPokeFloor(uint8 thinMask, uint8 pokedMask, uint8 restoreMask) public {
		for (uint256 i; i < 3; ++i) {
			if (((thinMask >> i) & 1) != 0) _thin(i);
			if (((pokedMask >> i) & 1) != 0) registry.pokeFloor(address(memes[i]));
			if (((restoreMask >> i) & 1) != 0) _restore(i);
		}
		address[] memory due = lens.assetsNeedingPoke(registry);

		for (uint256 i; i < 3; ++i) {
			bool named;
			for (uint256 j; j < due.length; ++j) {
				if (due[j] == address(memes[i])) named = true;
			}
			uint64 before = _since(i);
			registry.pokeFloor(address(memes[i]));
			bool changed = (before == 0) != (_since(i) == 0);
			assertEq(named, changed, 'lens and pokeFloor disagree');
		}
		assertEq(lens.assetsNeedingPoke(registry).length, 0);
	}
}
