// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IIntegrationAdapter} from '../interfaces/IIntegrationAdapter.sol';
import {ISlipstreamSwapRouter} from '../interfaces/external/ISlipstreamSwapRouter.sol';

/// @title AerodromeSlipstreamSwapAdapter
/// @notice Single-hop exactIn swaps on Aerodrome Slipstream pools.
/// @dev integrationData = abi.encode(tokenIn, tokenOut, tickSpacing, amountIn, minAmountOut).
///      Swaps only; Slipstream LP positions are an external position type.
contract AerodromeSlipstreamSwapAdapter is IIntegrationAdapter {
	using SafeERC20 for IERC20;

	ISlipstreamSwapRouter public immutable router;

	constructor(ISlipstreamSwapRouter router_) {
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
			abi.decode(integrationData, (address, address, int24, uint256, uint256));

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
		(address tokenIn, address tokenOut, int24 tickSpacing, uint256 amountIn, uint256 minAmountOut) =
			abi.decode(integrationData, (address, address, int24, uint256, uint256));

		IERC20(tokenIn).forceApprove(address(router), amountIn);
		router.exactInputSingle(
			ISlipstreamSwapRouter.ExactInputSingleParams({
				tokenIn: tokenIn,
				tokenOut: tokenOut,
				tickSpacing: tickSpacing,
				recipient: vault,
				deadline: block.timestamp,
				amountIn: amountIn,
				amountOutMinimum: minAmountOut,
				sqrtPriceLimitX96: 0
			})
		);
	}
}
