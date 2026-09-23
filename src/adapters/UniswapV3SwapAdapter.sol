// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IIntegrationAdapter} from '../interfaces/IIntegrationAdapter.sol';
import {IUniswapV3SwapRouter} from '../interfaces/external/IUniswapV3SwapRouter.sol';

/// @title UniswapV3SwapAdapter
/// @notice Single-hop exactIn swaps on Uniswap v3 pools.
/// @dev integrationData = abi.encode(tokenIn, tokenOut, fee, amountIn, minAmountOut).
///      Stateless and holds no funds between calls; output goes directly to the vault.
contract UniswapV3SwapAdapter is IIntegrationAdapter {
	using SafeERC20 for IERC20;

	IUniswapV3SwapRouter public immutable router;

	constructor(IUniswapV3SwapRouter router_) {
		router = router_;
	}

	/// @inheritdoc IIntegrationAdapter
	function parseAssetsForAction(bytes calldata integrationData)
		external
		pure
		returns (
			address[] memory spendAssets,
			uint256[] memory spendAmounts,
			address[] memory incomingAssets,
			uint256[] memory minIncomingAmounts
		)
	{
		(address tokenIn, address tokenOut,, uint256 amountIn, uint256 minAmountOut) =
			abi.decode(integrationData, (address, address, uint24, uint256, uint256));

		spendAssets = new address[](1);
		spendAssets[0] = tokenIn;
		spendAmounts = new uint256[](1);
		spendAmounts[0] = amountIn;
		incomingAssets = new address[](1);
		incomingAssets[0] = tokenOut;
		minIncomingAmounts = new uint256[](1);
		minIncomingAmounts[0] = minAmountOut;
	}

	/// @inheritdoc IIntegrationAdapter
	function executeAction(address vault, bytes calldata integrationData) external {
		(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint256 minAmountOut) =
			abi.decode(integrationData, (address, address, uint24, uint256, uint256));

		IERC20(tokenIn).forceApprove(address(router), amountIn);
		router.exactInputSingle(
			IUniswapV3SwapRouter.ExactInputSingleParams({
				tokenIn: tokenIn,
				tokenOut: tokenOut,
				fee: fee,
				recipient: vault,
				amountIn: amountIn,
				amountOutMinimum: minAmountOut,
				sqrtPriceLimitX96: 0
			})
		);
	}
}
