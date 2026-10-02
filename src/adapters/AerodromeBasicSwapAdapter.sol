// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IIntegrationAdapter} from '../interfaces/IIntegrationAdapter.sol';
import {IAerodromeRouter} from '../interfaces/external/IAerodromeRouter.sol';

/// @title AerodromeBasicSwapAdapter
/// @notice Single-hop exactIn swaps on Aerodrome basic VOLATILE pools (vAMM, x·y=k).
/// @dev integrationData = abi.encode(tokenIn, tokenOut, amountIn, minAmountOut).
///      Stable (sAMM) pools are never routed, matching the TWAP listing registry. Swaps the adapter's
///      whole tokenIn balance (what actually arrived, so a taxed transfer in is spent as received)
///      through the router's fee-on-transfer path. Stateless and holds no funds between calls;
///      output goes directly to the vault.
contract AerodromeBasicSwapAdapter is IIntegrationAdapter {
	using SafeERC20 for IERC20;

	IAerodromeRouter public immutable router;
	/// @notice The PoolFactory whose volatile pools are routed (the router's defaultFactory).
	address public immutable poolFactory;

	constructor(IAerodromeRouter router_, address poolFactory_) {
		router = router_;
		poolFactory = poolFactory_;
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
		(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut) =
			abi.decode(integrationData, (address, address, uint256, uint256));

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
		(address tokenIn, address tokenOut,, uint256 minAmountOut) =
			abi.decode(integrationData, (address, address, uint256, uint256));

		uint256 balance = IERC20(tokenIn).balanceOf(address(this));
		IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
		routes[0] = IAerodromeRouter.Route({from: tokenIn, to: tokenOut, stable: false, factory: poolFactory});

		IERC20(tokenIn).forceApprove(address(router), balance);
		router.swapExactTokensForTokensSupportingFeeOnTransferTokens(balance, minAmountOut, routes, vault, block.timestamp);
	}
}
