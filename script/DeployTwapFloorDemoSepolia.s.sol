// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {TickMath} from '../src/libraries/TickMath.sol';
import {IUniswapV3NonfungiblePositionManager} from '../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {IValueInterpreter} from '../src/interfaces/IValueInterpreter.sol';
import {AggregatorV3Interface} from '../src/interfaces/AggregatorV3Interface.sol';
import {TwapListingRegistry, IUniswapV3PoolFactory, ISlipstreamPoolFactory} from '../src/pricing/TwapListingRegistry.sol';
import {TwapAggregatorAdapter} from '../src/pricing/TwapAggregatorAdapter.sol';
import {TwapFloorLens} from '../src/pricing/TwapFloorLens.sol';
import {MockERC20} from '../test/utils/Mocks.sol';

interface IUniswapV3FactoryCreate {
	function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

interface IUniswapV3PoolInit {
	function initialize(uint160 sqrtPriceX96) external;
	function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
	function token0() external view returns (address);
}

/// @dev Base Sepolia addresses, read on-chain 2026-09-25: the factory from the NPM's `factory()`,
///      the tUSDC feed from the testnet ValueInterpreter's `getAssetInfo(tUSDC)`.
abstract contract SepoliaTwapFloorDemo is Script {
	address internal constant TUSDC = 0x75F31B7C00E6282CDCFd7B4124d8ab327bE3Ab4D;
	address internal constant TUSDC_FEED = 0xCC67908Fc6C4eF9C12e628C3636749909CA7071C;
	address internal constant VALUE_INTERPRETER = 0xFe4045E483fB3Ab36e773EFd73de7F2440cC9eF6;
	address internal constant UNI_FACTORY = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
	address internal constant UNI_NPM = 0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2;
	uint24 internal constant FEE = 3000;
}

/// @notice The TWAP floor clock on BASE SEPOLIA — where FrostyFi keeper workflows can run (Engine
///         signs by chain id, and Veranta's devnet reuses 8453 = real Base). Side-by-side, touching
///         nothing deployed: a thin tMEME/tUSDC pool WE own (≈$80k inside ±~10%, over the $50k
///         floor), a listing registry (no VI step — the 72-hour clock never reads the VI) and the
///         floor lens the poke workflow reads. Mirrors DeployTmemeDemoPool on VT.
///         Aerodrome has no Base Sepolia deployment, so both Slipstream venues point at the
///         Uniswap factory: a Slipstream listing here would simply fail to resolve a pool.
///         Then wait 30 minutes (the pool needs a full TWAP window) and run ListTmemeSepolia.
///         Run: forge script script/DeployTwapFloorDemoSepolia.s.sol:DeployTwapFloorDemoSepolia \
///              --rpc-url https://sepolia.base.org --broadcast --slow --private-key <deployer>
contract DeployTwapFloorDemoSepolia is SepoliaTwapFloorDemo {
	int24 internal constant SPACING = 60;
	// floor(log_1.0001(0.01 USD × 1e6 / 1e18)) — $0.01 per tMEME with tMEME as token0
	int24 internal constant TICK_MEME_TOKEN0 = -322_379;
	int24 internal constant HALF_RANGE = 1_000; // 1.0001^1000 ≈ +10.5%

	function run() external {
		require(block.chainid == 84532, 'Base Sepolia only');
		vm.startBroadcast();
		MockERC20 tmeme = new MockERC20('Test Meme', 'tMEME', 18);
		tmeme.mint(msg.sender, 10_000_000e18);
		address pool = IUniswapV3FactoryCreate(UNI_FACTORY).createPool(address(tmeme), TUSDC, FEE);
		bool memeIs0 = IUniswapV3PoolInit(pool).token0() == address(tmeme);
		int24 center = memeIs0 ? TICK_MEME_TOKEN0 : -TICK_MEME_TOKEN0;
		IUniswapV3PoolInit(pool).initialize(TickMath.getSqrtRatioAtTick(center));
		IUniswapV3PoolInit(pool).increaseObservationCardinalityNext(200);
		tmeme.approve(UNI_NPM, type(uint256).max);
		IERC20(TUSDC).approve(UNI_NPM, type(uint256).max);
		(uint256 tokenId, uint128 liquidity) = _mint(address(tmeme), memeIs0, center, msg.sender);

		TwapListingRegistry registry = new TwapListingRegistry(
			IValueInterpreter(VALUE_INTERPRETER),
			IUniswapV3PoolFactory(UNI_FACTORY),
			ISlipstreamPoolFactory(UNI_FACTORY),
			ISlipstreamPoolFactory(UNI_FACTORY)
		);
		registry.setQuote(TUSDC, AggregatorV3Interface(TUSDC_FEED), 7 days);
		TwapFloorLens lens = new TwapFloorLens();
		vm.stopBroadcast();

		console2.log('tMEME', address(tmeme));
		console2.log('pool', pool);
		console2.log('tMEME is token0', memeIs0);
		console2.log('tokenId', tokenId);
		console2.log('liquidity', liquidity);
		console2.log('TwapListingRegistry', address(registry));
		console2.log('TwapFloorLens', address(lens));
	}

	/// @dev $40k each side at $0.01, range ≈ ±10.5% around the center tick
	function _mint(address tmeme, bool memeIs0, int24 center, address to) internal returns (uint256 tokenId, uint128 liquidity) {
		(uint256 amountMeme, uint256 amountUsdc) = (4_000_000e18, 40_000e6);
		(tokenId, liquidity,,) = IUniswapV3NonfungiblePositionManager(UNI_NPM).mint(
			IUniswapV3NonfungiblePositionManager.MintParams({
				token0: memeIs0 ? tmeme : TUSDC,
				token1: memeIs0 ? TUSDC : tmeme,
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

/// @notice Step 2, once the pool holds 30 minutes of observations: list tMEME on the Sepolia
///         registry (the lister is the deployer, set by the registry's constructor).
///         Run: REGISTRY=<…> TMEME=<…> forge script script/DeployTwapFloorDemoSepolia.s.sol:ListTmemeSepolia \
///              --rpc-url https://sepolia.base.org --broadcast --private-key <deployer>
contract ListTmemeSepolia is SepoliaTwapFloorDemo {
	function run() external {
		require(block.chainid == 84532, 'Base Sepolia only');
		TwapListingRegistry registry = TwapListingRegistry(vm.envAddress('REGISTRY'));
		address tmeme = vm.envAddress('TMEME');
		vm.startBroadcast();
		TwapAggregatorAdapter adapter = registry.list(tmeme, TUSDC, TwapListingRegistry.Venue.UniswapV3, int24(FEE));
		vm.stopBroadcast();

		(, int256 price,,,) = adapter.latestRoundData();
		console2.log('tMEME adapter', address(adapter));
		console2.log('price usd18', uint256(price));
		console2.log('depth usd18', adapter.poolDepthUsd());
	}
}
