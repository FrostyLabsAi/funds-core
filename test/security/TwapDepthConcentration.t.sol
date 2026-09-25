// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {TwapAggregatorAdapter, IConcentratedPoolOracle} from '../../src/pricing/TwapAggregatorAdapter.sol';
import {AggregatorV3Interface} from '../../src/interfaces/AggregatorV3Interface.sol';
import {TickMath} from '../../src/libraries/TickMath.sol';
import {IUniswapV3NonfungiblePositionManager} from '../../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {MockERC20} from '../utils/Mocks.sol';

interface IUniswapV3FactoryCreate {
	function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

interface IUniswapV3PoolInit {
	function initialize(uint160 sqrtPriceX96) external;
	function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
	function token0() external view returns (address);
}

/// @notice Security review 2026-09-24, finding M-1 (RED until fixed): the TWAP adapter's ±10%
///         "depth" applies the pool's in-range liquidity AT THE CURRENT TICK uniformly across
///         the whole band. A small position concentrated tightly around spot therefore reads as
///         a large ±10% depth — cheap to buy, and it moves the listing floor, the 72-hour clock
///         and the exposure caps that all measure against this number.
///         Fresh pool on a Base fork (real Uniswap v3 factory + NPM, real Chainlink USDC feed):
///         $20k/side spread over ±10.5%, then an attacker adds $2k/side in ±1 tick spacing.
///         Run: BASE_MAINNET_RPC=<url> forge test --match-path test/security/TwapDepthConcentration.t.sol -vv
contract TwapDepthConcentrationTest is Test {
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant CL_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
	address internal constant UNI_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
	address internal constant UNI_NPM = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
	uint24 internal constant FEE = 3000;
	int24 internal constant SPACING = 60;

	bool internal forked;
	MockERC20 internal meme;
	address internal pool;
	bool internal memeIs0;
	int24 internal center;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc);
		forked = true;

		meme = new MockERC20('Thin Meme', 'THIN', 18);
		pool = IUniswapV3FactoryCreate(UNI_FACTORY).createPool(address(meme), USDC, FEE);
		memeIs0 = IUniswapV3PoolInit(pool).token0() == address(meme);
		// $0.01 per THIN: floor(log_1.0001(0.01e6 / 1e18)) with THIN as token0
		center = memeIs0 ? int24(-322_379) : int24(322_379);
		IUniswapV3PoolInit(pool).initialize(TickMath.getSqrtRatioAtTick(center));
		IUniswapV3PoolInit(pool).increaseObservationCardinalityNext(50);

		meme.mint(address(this), 100_000_000e18);
		deal(USDC, address(this), 1_000_000e6);
		meme.approve(UNI_NPM, type(uint256).max);
		IERC20(USDC).approve(UNI_NPM, type(uint256).max);
	}

	function _floor(int24 tick) internal pure returns (int24) {
		int24 r = tick % SPACING;
		return r < 0 ? tick - r - SPACING : tick - r;
	}

	function _mint(int24 halfRange, uint256 usdcPerSide) internal {
		uint256 memePerSide = usdcPerSide * 1e12 * 100; // $0.01 each
		IUniswapV3NonfungiblePositionManager(UNI_NPM).mint(
			IUniswapV3NonfungiblePositionManager.MintParams({
				token0: memeIs0 ? address(meme) : USDC,
				token1: memeIs0 ? USDC : address(meme),
				fee: FEE,
				tickLower: _floor(center - halfRange),
				tickUpper: _floor(center + halfRange) + SPACING,
				amount0Desired: memeIs0 ? memePerSide : usdcPerSide,
				amount1Desired: memeIs0 ? usdcPerSide : memePerSide,
				amount0Min: 0,
				amount1Min: 0,
				recipient: address(this),
				deadline: block.timestamp
			})
		);
	}

	function test_fork_tightRangeInflatesBandDepth() public {
		vm.skip(!forked);
		_mint(1_000, 20_000e6); // honest LP: ≈$40k across ±10.5%
		vm.warp(block.timestamp + 31 minutes);
		vm.roll(block.number + 1);

		TwapAggregatorAdapter adapter = new TwapAggregatorAdapter(
			IConcentratedPoolOracle(pool), address(meme), AggregatorV3Interface(CL_USDC_USD), 30 minutes, 50_000, 500, 2 days, 'THIN'
		);
		uint256 honestDepth = adapter.poolDepthUsd();
		emit log_named_decimal_uint('depth, honest $40k LP     ', honestDepth, 18);
		assertTrue(adapter.isBelowFloor(), 'setup: $40k of real liquidity is under the $50k floor');

		_mint(SPACING, 2_000e6); // attacker: $4k total, ±1 tick spacing (~0.6%)
		vm.warp(block.timestamp + 31 minutes);
		vm.roll(block.number + 1);
		uint256 inflatedDepth = adapter.poolDepthUsd();
		emit log_named_decimal_uint('depth, + $4k tight position', inflatedDepth, 18);

		// Real ±10% capital grew by $4k — the reading must not grow by more than that (+10% slack)
		assertLe(inflatedDepth, honestDepth + 4_400e18, 'M-1: $4k of tight liquidity reads as far more band depth');
		assertTrue(adapter.isBelowFloor(), 'M-1: a $4k tight position lifts a $40k pool over the $50k floor');
	}
}
