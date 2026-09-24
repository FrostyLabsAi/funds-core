// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {TickMath} from '../src/libraries/TickMath.sol';
import {IUniswapV3NonfungiblePositionManager} from '../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {MockERC20} from '../test/utils/Mocks.sol';

interface IUniswapV3FactoryCreate {
	function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

interface IUniswapV3PoolInit {
	function initialize(uint160 sqrtPriceX96) external;
	function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
	function token0() external view returns (address);
}

/// @notice A thin pool WE own, on Veranta's testnet, for demonstrating the TWAP tier's 72-hour
///         liquidity clock without touching anyone else's pool: tMEME (open-mint test token) vs
///         USDC on Uniswap v3 (0.3%), priced at $0.01, with ≈$80k of our own liquidity inside
///         ±~10% — over the $50k floor. Pulling part of it later drops the pool under the floor.
///         Listing must wait until the pool has 30 minutes of observations.
///         Run: forge script script/DeployTmemeDemoPool.s.sol --rpc-url https://devnet-rpc.veranta.xyz --broadcast
///         Env: VT_DEPLOYER_KEY, [TMEME]
contract DeployTmemeDemoPool is Script {
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant UNI_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
	address internal constant UNI_NPM = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
	uint24 internal constant FEE = 3000;
	int24 internal constant SPACING = 60;
	// floor(log_1.0001(0.01 USD × 1e6 / 1e18)) — $0.01 per tMEME with tMEME as token0
	int24 internal constant TICK_MEME_TOKEN0 = -322_379;
	int24 internal constant HALF_RANGE = 1_000; // 1.0001^1000 ≈ +10.5%

	function run() external {
		uint256 key = vm.envUint('VT_DEPLOYER_KEY');
		require(block.chainid == 8453, 'Veranta testnet is chainId 8453');

		vm.startBroadcast(key);
		// TMEME set = resume with an already-deployed token (a broadcast that stopped midway)
		MockERC20 tmeme = MockERC20(vm.envOr('TMEME', address(0)));
		if (address(tmeme) == address(0)) {
			tmeme = new MockERC20('Test Meme', 'tMEME', 18);
			tmeme.mint(vm.addr(key), 10_000_000e18);
		}
		address pool = IUniswapV3FactoryCreate(UNI_FACTORY).createPool(address(tmeme), USDC, FEE);
		bool memeIs0 = IUniswapV3PoolInit(pool).token0() == address(tmeme);
		int24 center = memeIs0 ? TICK_MEME_TOKEN0 : -TICK_MEME_TOKEN0;
		IUniswapV3PoolInit(pool).initialize(TickMath.getSqrtRatioAtTick(center));
		IUniswapV3PoolInit(pool).increaseObservationCardinalityNext(200);
		tmeme.approve(UNI_NPM, type(uint256).max);
		IERC20(USDC).approve(UNI_NPM, type(uint256).max);
		(uint256 tokenId, uint128 liquidity) = _mint(address(tmeme), memeIs0, center, vm.addr(key));
		vm.stopBroadcast();

		console2.log('tMEME', address(tmeme));
		console2.log('pool', pool);
		console2.log('tMEME is token0', memeIs0);
		console2.log('tokenId', tokenId);
		console2.log('liquidity', liquidity);
	}

	/// @dev $40k each side at $0.01, range ≈ ±10.5% around the center tick
	function _mint(address tmeme, bool memeIs0, int24 center, address to) internal returns (uint256 tokenId, uint128 liquidity) {
		(uint256 amountMeme, uint256 amountUsdc) = (4_000_000e18, 40_000e6);
		(tokenId, liquidity,,) = IUniswapV3NonfungiblePositionManager(UNI_NPM).mint(
			IUniswapV3NonfungiblePositionManager.MintParams({
				token0: memeIs0 ? tmeme : USDC,
				token1: memeIs0 ? USDC : tmeme,
				fee: FEE,
				tickLower: _floor(center - HALF_RANGE),
				tickUpper: _floor(center + HALF_RANGE) + SPACING,
				amount0Desired: memeIs0 ? amountMeme : amountUsdc,
				amount1Desired: memeIs0 ? amountUsdc : amountMeme,
				amount0Min: 0,
				amount1Min: 0,
				recipient: to,
				deadline: block.timestamp + 600
			})
		);
	}

	/// @dev round down to the tick spacing (toward −∞)
	function _floor(int24 tick) internal pure returns (int24) {
		int24 r = tick % SPACING;
		return r < 0 ? tick - r - SPACING : tick - r;
	}
}
