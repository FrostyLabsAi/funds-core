// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IIntegrationAdapter} from '../interfaces/IIntegrationAdapter.sol';
import {ProtocolFeeAdapter} from './ProtocolFeeAdapter.sol';
import {ISlipstreamSwapRouter} from '../interfaces/external/ISlipstreamSwapRouter.sol';

/// @title AerodromeSlipstreamSwapAdapter
/// @dev Single-hop Slipstream swaps with the protocol fee (ProtocolFeeAdapter) and a gas floor (2026-11-12, founder "build
///      the adapter"):
///      Every pool on Aero's factory (0x9CB2…7a76) calls a swap hook whose MEV-tax read takes about 7,800 more gas in a
///      real transaction than in an estimate made without fees (getMevTax: 285 gas against 5,179, and 2,800 more in the
///      hook's record). MetaMask sends its own fee-less estimate with no margin and discards the limit a site suggests,
///      so a buy with nothing after the swap to absorb the difference ran out of gas (fund YAFT, TSLAc, 2026-11-12:
///      limit 768,161, needed 775,953). No request field survives the wallet, so the margin travels in the trade
///      itself: the swap reverts unless `minGasLeft` is still there when it starts, and an estimate, being the least
///      gas that succeeds, then has to include it. Measured on Base state with a wallet-style estimate: 1,174,759
///      where the trade needs 774,458 (.ops-scratch/aero-gas-floor-proof-2026-11-12).
///      The floor is the caller's: 0 switches it off. A manager who sets it too low only runs
///      their own trade out of gas, as before.
/// @notice Single-hop exactIn swaps on Aerodrome Slipstream pools.
/// @dev integrationData = abi.encode(tokenIn, tokenOut, tickSpacing, amountIn, minAmountOut, minGasLeft).
///      Swaps only.
contract AerodromeSlipstreamSwapAdapter is IIntegrationAdapter, ProtocolFeeAdapter {
	using SafeERC20 for IERC20;

	ISlipstreamSwapRouter public immutable router;

	error GasBelowFloor(uint256 gasLeft, uint256 minGasLeft);

	constructor(ISlipstreamSwapRouter router_, address treasury_, uint16 feeBps_, address owner_)
		ProtocolFeeAdapter(treasury_, feeBps_, owner_)
	{
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
		(address tokenIn, address tokenOut,, uint256 amountIn, uint256 minAmountOut,) =
			abi.decode(integrationData, (address, address, int24, uint256, uint256, uint256));

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
		(address tokenIn, address tokenOut, int24 tickSpacing, uint256 amountIn, uint256 minAmountOut, uint256 minGasLeft) =
			abi.decode(integrationData, (address, address, int24, uint256, uint256, uint256));
		// before anything moves: the fee and the swap never start on too little gas
		if (gasleft() < minGasLeft) revert GasBelowFloor(gasleft(), minGasLeft);

		amountIn = _takeFee(tokenIn, amountIn);
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
