// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IUniswapV3NonfungiblePositionManager} from
	'../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {MockERC20} from '../test/utils/Mocks.sol';

/// @title CreateUniV3Pools
/// @notice Creates + seeds REAL Uniswap v3 pools on Base Sepolia for the demo tokens, so the
///         UniswapV3SwapAdapter can be exercised against the real router (SWAP_ROUTER env).
///         Pools: tUSDC/GPUx and tUSDC/EVRx, fee 3000, full range, initialized at the same
///         prices the mock feeds report ($182.50 / $46.75).
/// @dev Only works with the MOCK tokens (they must be mintable by the deployer).
///   Env: NPM (NonfungiblePositionManager), TUSDC, GPUX, EVRX.
///   forge script script/CreateUniV3Pools.s.sol --rpc-url base_sepolia --private-key $PRIVATE_KEY --broadcast
contract CreateUniV3Pools is Script {
	uint256 private constant Q96 = 0x1000000000000000000000000;
	uint24 private constant FEE = 3000;
	int24 private constant TICK_LOWER = -887_220; // multiple of spacing 60
	int24 private constant TICK_UPPER = 887_220;

	IUniswapV3NonfungiblePositionManager internal positionManager;

	function run() external {
		positionManager = IUniswapV3NonfungiblePositionManager(vm.envAddress('NPM'));
		MockERC20 usdc = MockERC20(vm.envAddress('TUSDC'));

		vm.startBroadcast();
		_createPool(usdc, MockERC20(vm.envAddress('GPUX')), 182_50e16, 500_000e6, 2740e18);
		_createPool(usdc, MockERC20(vm.envAddress('EVRX')), 46_75e16, 250_000e6, 5350e18);
		vm.stopBroadcast();
	}

	/// @param usdPrice18 the non-USDC token's USD price, 1e18-scaled
	function _createPool(MockERC20 usdc, MockERC20 token, uint256 usdPrice18, uint256 usdcAmount, uint256 tokenAmount)
		internal
	{
		usdc.mint(msg.sender, usdcAmount);
		token.mint(msg.sender, tokenAmount);
		usdc.approve(address(positionManager), usdcAmount);
		token.approve(address(positionManager), tokenAmount);

		// Uniswap orders pairs by address; price/amounts follow the ordering.
		(address token0, address token1) = address(usdc) < address(token)
			? (address(usdc), address(token))
			: (address(token), address(usdc));
		(uint256 rate0, uint256 rate1, uint256 scale0, uint256 scale1) = token0 == address(usdc)
			? (uint256(1e18), usdPrice18, uint256(1e6), uint256(1e18))
			: (usdPrice18, uint256(1e18), uint256(1e18), uint256(1e6));
		(uint256 amount0, uint256 amount1) =
			token0 == address(usdc) ? (usdcAmount, tokenAmount) : (tokenAmount, usdcAmount);

		uint160 sqrtPriceX96 = _sqrtPriceX96(rate0, rate1, scale0, scale1);
		address pool = positionManager.createAndInitializePoolIfNecessary(token0, token1, FEE, sqrtPriceX96);

		positionManager.mint(
			IUniswapV3NonfungiblePositionManager.MintParams({
				token0: token0,
				token1: token1,
				fee: FEE,
				tickLower: TICK_LOWER,
				tickUpper: TICK_UPPER,
				amount0Desired: amount0,
				amount1Desired: amount1,
				amount0Min: 0,
				amount1Min: 0,
				recipient: msg.sender,
				deadline: block.timestamp + 600
			})
		);

		console2.log('Pool created:', pool);
	}

	/// @dev Same fair-sqrt math as the LP positions (frosty-core PriceOracle port).
	function _sqrtPriceX96(uint256 rate0, uint256 rate1, uint256 scale0, uint256 scale1)
		internal
		pure
		returns (uint160)
	{
		uint256 ratioX96 = Math.mulDiv(Math.mulDiv(rate0, Q96, rate1), scale1, scale0);
		uint256 sqrtRatio =
			ratioX96 <= type(uint256).max >> 64 ? Math.sqrt(ratioX96 << 64) << 16 : Math.sqrt(ratioX96) << 48;
		return uint160(sqrtRatio);
	}
}
