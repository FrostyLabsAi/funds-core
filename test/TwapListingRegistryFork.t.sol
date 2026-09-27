// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {
	TwapListingRegistry,
	IUniswapV3PoolFactory,
	ISlipstreamPoolFactory
} from '../src/pricing/TwapListingRegistry.sol';
import {TwapAggregatorAdapter} from '../src/pricing/TwapAggregatorAdapter.sol';
import {AggregatorV3Interface} from '../src/interfaces/AggregatorV3Interface.sol';
import {IValueInterpreter} from '../src/interfaces/IValueInterpreter.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';

/// @notice The registry against the REAL canonical factories on Base: list AERO (a long-tail
///         asset our VI does not price) through two independent pools — USDC-quoted and
///         WETH-quoted — and they must agree; a thin real pool must be refused.
///         Run: BASE_MAINNET_RPC=<url> [BASE_FORK_BLOCK=<n>] forge test --match-path test/TwapListingRegistryFork.t.sol
contract TwapListingRegistryForkTest is Test {
	address internal constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant WETH = 0x4200000000000000000000000000000000000006;
	address internal constant CL_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
	address internal constant CL_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
	address internal constant UNI_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
	address internal constant CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
	address internal constant CL2_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef; // Aerodrome's newer Slipstream

	bool internal forked;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		uint256 blockNumber = vm.envOr('BASE_FORK_BLOCK', uint256(0));
		if (blockNumber > 0) vm.createSelectFork(rpc, blockNumber);
		else vm.createSelectFork(rpc);
		forked = true;
	}

	function _registry() internal returns (TwapListingRegistry r, ValueInterpreter vi) {
		vi = new ValueInterpreter(address(this));
		vi.addPrimitive(USDC, CL_USDC_USD, 2 days);
		r = new TwapListingRegistry(IValueInterpreter(address(vi)), IUniswapV3PoolFactory(UNI_FACTORY), ISlipstreamPoolFactory(CL_FACTORY), ISlipstreamPoolFactory(CL2_FACTORY));
		r.setQuote(USDC, AggregatorV3Interface(CL_USDC_USD), 2 days);
		r.setQuote(WETH, AggregatorV3Interface(CL_ETH_USD), 1 days);
	}

	function _price(TwapAggregatorAdapter a) internal view returns (uint256) {
		(, int256 answer,,,) = a.latestRoundData();
		return uint256(answer);
	}

	function test_fork_listAero_twoIndependentPoolsAgree() public {
		vm.skip(!forked);
		(TwapListingRegistry r1, ValueInterpreter vi) = _registry();
		TwapAggregatorAdapter viaUsdc = r1.list(AERO, USDC, TwapListingRegistry.Venue.Slipstream, 100);
		(TwapListingRegistry r2,) = _registry();
		TwapAggregatorAdapter viaWeth = r2.list(AERO, WETH, TwapListingRegistry.Venue.Slipstream, 200);

		uint256 pUsdc = _price(viaUsdc);
		uint256 pWeth = _price(viaWeth);
		emit log_named_decimal_uint('AERO via USDC pool', pUsdc, 18);
		emit log_named_decimal_uint('AERO via WETH pool', pWeth, 18);
		emit log_named_decimal_uint('USDC pool depth   ', viaUsdc.poolDepthUsd(), 18);
		emit log_named_decimal_uint('WETH pool depth   ', viaWeth.poolDepthUsd(), 18);
		assertApproxEqRel(pUsdc, pWeth, 0.01e18);
		assertEq(viaUsdc.description(), 'AERO / USD (TWAP)');

		// the VI owner's step, then the fund-facing price
		vi.addPrimitive(AERO, address(viaUsdc), 1 hours);
		assertTrue(r1.isTwapPriced(AERO));
		assertEq(vi.calcUsdRate(AERO), pUsdc);
	}

	function test_fork_thinRealPool_refused() public {
		vm.skip(!forked);
		(TwapListingRegistry r,) = _registry();
		// Uniswap AERO/USDC 1% — near-empty on 2026-09-24 (in-range L ≈ 5e14)
		try r.list(AERO, USDC, TwapListingRegistry.Venue.UniswapV3, 10_000) {
			fail();
		} catch (bytes memory err) {
			bytes4 selector = bytes4(err);
			assertTrue(
				selector == TwapListingRegistry.BelowFloorAtListing.selector
					|| selector == TwapAggregatorAdapter.ObservationWindowUnavailable.selector,
				'refused for depth or history, nothing else'
			);
		}
		assertEq(r.adapterOf(AERO), address(0));
	}

	/// A DEEP pool that keeps no price history: Slipstream AERO/USDC (tick spacing 200) had
	/// observation cardinality 1 on 2026-09-24 — liquidity alone does not make a TWAP. Anyone can
	/// raise it (increaseObservationCardinalityNext) and list once 30 minutes have accrued.
	function test_fork_deepPoolWithoutHistory_refused() public {
		vm.skip(!forked);
		(TwapListingRegistry r,) = _registry();
		vm.expectRevert(TwapAggregatorAdapter.ObservationWindowUnavailable.selector);
		r.list(AERO, USDC, TwapListingRegistry.Venue.Slipstream, 200);
	}

	function test_fork_chainlinkPricedAssetCannotBeListedOnTwap() public {
		vm.skip(!forked);
		(TwapListingRegistry r, ValueInterpreter vi) = _registry();
		// WETH has a Chainlink price in the VI → the TWAP tier must refuse it
		vi.addPrimitive(WETH, CL_ETH_USD, 1 days);
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistry.AlreadyPriced.selector, WETH));
		r.list(WETH, USDC, TwapListingRegistry.Venue.UniswapV3, 500);
	}
}
