// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {TwapAggregatorAdapter, IConcentratedPoolOracle} from '../src/pricing/TwapAggregatorAdapter.sol';
import {AggregatorV3Interface} from '../src/interfaces/AggregatorV3Interface.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';

interface ISwapRouter02 {
	struct ExactInputSingleParams {
		address tokenIn;
		address tokenOut;
		uint24 fee;
		address recipient;
		uint256 amountIn;
		uint256 amountOutMinimum;
		uint160 sqrtPriceLimitX96;
	}

	function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice TWAP adapter against REAL Base pools: Uniswap v3 WETH/USDC 0.05% and Aerodrome
///         Slipstream WETH/USDC (tick spacing 100). Prices must track Chainlink; a real
///         multi-million swap pushing spot 8% must make the adapter REFUSE, not reprice.
///         Run: BASE_MAINNET_RPC=<url> [BASE_FORK_BLOCK=<n>] forge test --match-path test/TwapAggregatorAdapterFork.t.sol
contract TwapAggregatorAdapterForkTest is Test {
	address internal constant WETH = 0x4200000000000000000000000000000000000006;
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant CL_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
	address internal constant CL_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
	// Uniswap v3 factory getPool(WETH, USDC, 500) / Slipstream CL factory getPool(WETH, USDC, 100), read 2026-09-24
	address internal constant UNI_WETH_USDC_500 = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
	address internal constant CL_WETH_USDC_100 = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
	address internal constant SWAP_ROUTER02 = 0x2626664c2603336E57B271c5C0b26F421741e481;

	bool internal forked;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		uint256 blockNumber = vm.envOr('BASE_FORK_BLOCK', uint256(0));
		if (blockNumber > 0) vm.createSelectFork(rpc, blockNumber);
		else vm.createSelectFork(rpc);
		forked = true;
	}

	function _adapter(address pool, uint256 floorUsd) internal returns (TwapAggregatorAdapter) {
		return new TwapAggregatorAdapter(
			IConcentratedPoolOracle(pool), WETH, AggregatorV3Interface(CL_USDC_USD), 30 minutes, floorUsd, 500, 2 days, 'WETH / USD (TWAP)'
		);
	}

	function _chainlinkEth18() internal view returns (uint256) {
		(, int256 answer,,,) = AggregatorV3Interface(CL_ETH_USD).latestRoundData();
		return uint256(answer) * 1e10;
	}

	function _price(TwapAggregatorAdapter a) internal view returns (uint256) {
		(, int256 answer,,,) = a.latestRoundData();
		return uint256(answer);
	}

	function test_fork_uniswapPool_tracksChainlink() public {
		vm.skip(!forked);
		TwapAggregatorAdapter a = _adapter(UNI_WETH_USDC_500, 50_000);
		uint256 twap = _price(a);
		emit log_named_decimal_uint('uniswap TWAP ETH', twap, 18);
		emit log_named_decimal_uint('chainlink ETH  ', _chainlinkEth18(), 18);
		emit log_named_decimal_uint('+-10% depth USD', a.poolDepthUsd(), 18);
		assertApproxEqRel(twap, _chainlinkEth18(), 0.01e18); // within Chainlink's own 0.15% band + 30-min drift
		assertGt(a.poolDepthUsd(), 50_000e18);
	}

	function test_fork_slipstreamPool_tracksChainlink() public {
		vm.skip(!forked);
		TwapAggregatorAdapter a = _adapter(CL_WETH_USDC_100, 50_000);
		uint256 twap = _price(a);
		emit log_named_decimal_uint('slipstream TWAP ETH', twap, 18);
		emit log_named_decimal_uint('+-10% depth USD    ', a.poolDepthUsd(), 18);
		assertApproxEqRel(twap, _chainlinkEth18(), 0.01e18);
	}

	function test_fork_valueInterpreterPricesThroughTheAdapter() public {
		vm.skip(!forked);
		TwapAggregatorAdapter a = _adapter(UNI_WETH_USDC_500, 50_000);
		ValueInterpreter vi = new ValueInterpreter(address(this));
		vi.addPrimitive(USDC, CL_USDC_USD, 2 days);
		vi.addPrimitive(WETH, address(a), 1 hours);
		uint256 usdcFor2Eth = vi.calcCanonicalAssetValue(WETH, 2e18, USDC);
		emit log_named_decimal_uint('VI: 2 WETH in USDC', usdcFor2Eth, 6);
		assertApproxEqRel(usdcFor2Eth * 1e12, 2 * _chainlinkEth18(), 0.01e18);
	}

	function test_fork_floorAboveThePoolsDepth_isReported() public {
		vm.skip(!forked);
		uint256 depth = _adapter(UNI_WETH_USDC_500, 1).poolDepthUsd();
		TwapAggregatorAdapter strict = _adapter(UNI_WETH_USDC_500, depth / 1e18 + 1);
		assertTrue(strict.isBelowFloor());
		assertGt(_price(strict), 0, 'still prices');
		assertFalse(_adapter(UNI_WETH_USDC_500, 50_000).isBelowFloor());
	}

	/// The attack the guard exists for: buy enough WETH to push the pool 8% off, in one block.
	/// Spot moves 8%, the 30-min mean barely moves — and the adapter refuses to price.
	function test_fork_realSwapPushingSpot8pct_refusesToPrice() public {
		vm.skip(!forked);
		TwapAggregatorAdapter a = _adapter(UNI_WETH_USDC_500, 50_000);
		(int24 meanBefore,) = a.consult();

		// WETH is token0: buying WETH raises the price (tick up); stop at +8%
		(uint160 sqrtBefore,,,,,,) = IUniswapV3Slot0(UNI_WETH_USDC_500).slot0();
		uint160 limit = uint160((uint256(sqrtBefore) * 10_392) / 10_000); // √1.08 = 1.0392
		address whale = makeAddr('whale');
		deal(USDC, whale, 50_000_000e6);
		vm.startPrank(whale);
		IERC20(USDC).approve(SWAP_ROUTER02, type(uint256).max);
		ISwapRouter02(SWAP_ROUTER02).exactInputSingle(
			ISwapRouter02.ExactInputSingleParams(USDC, WETH, 500, whale, 50_000_000e6, 0, limit)
		);
		vm.stopPrank();

		(uint160 sqrtAfter, int24 spotAfter,,,,,) = IUniswapV3Slot0(UNI_WETH_USDC_500).slot0();
		uint256 spotMoveBps = (uint256(sqrtAfter) * sqrtAfter / sqrtBefore * 10_000) / sqrtBefore - 10_000;
		emit log_named_uint('spot moved, bps', spotMoveBps);
		assertGt(spotMoveBps, 700);

		(int24 meanAfter,) = a.consult();
		emit log_named_int('mean tick moved, ticks', int256(meanAfter) - int256(meanBefore));
		assertLt(_abs(int256(meanAfter) - int256(meanBefore)), 5); // < 0.05%: the window absorbs a one-block push

		vm.expectRevert(abi.encodeWithSelector(TwapAggregatorAdapter.SpotDeviatesFromTwap.selector, spotAfter, meanAfter));
		a.latestRoundData();
	}

	function _abs(int256 x) internal pure returns (uint256) {
		return uint256(x >= 0 ? x : -x);
	}
}

interface IUniswapV3Slot0 {
	function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}
