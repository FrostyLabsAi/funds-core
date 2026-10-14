// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IIntegrationAdapter} from '../interfaces/IIntegrationAdapter.sol';
import {ProtocolFeeAdapter} from './ProtocolFeeAdapter.sol';
import {IUniswapV3SwapRouter} from '../interfaces/external/IUniswapV3SwapRouter.sol';
import {ISlipstreamSwapRouter} from '../interfaces/external/ISlipstreamSwapRouter.sol';
import {IAerodromeRouter} from '../interfaces/external/IAerodromeRouter.sol';

/// @title ViaWethSellAdapter
/// @notice The v6 keeper's sale of a feed-priced token whose liquidity is against WETH, not USDC (founder 2026-10-14;
///         the exit audit found cbETH with $1.5k of USDC on its deepest USDC pool and $2.09M of WETH on its WETH pool,
///         and WELL, LINK, DEGEN, ZRO alike): token → WETH → `outToken` in one action, each hop on one pool of Uniswap
///         v3, Slipstream-1/2/3 or Aerodrome basic (volatile). A feed-priced token can't be sold into WETH first
///         (ComptrollerV6Lib._checkSale: NotASale), so both hops go in one call, and one asset comes back, under the 3%
///         oracle cap on the whole sale.
/// @dev integrationData = abi.encode(token, amount, minOut, outToken, Hop toWeth, Hop fromWeth), Hop = (venue, param):
///      param is the Uniswap v3 fee, the Slipstream tick spacing, or 0 for Aerodrome's volatile pool. Each hop sells
///      this adapter's whole balance of its input on one pool; a pool out of liquidity fills part and leaves the rest
///      here, so a hop reverts Unsold unless all of its input went. The first hop pays this adapter, the second the
///      fund's Vault. The protocol fee (ProtocolFeeAdapter: `feeBps` of the input to the Treasury, as the V2 spot
///      adapters) is taken once per sale, before the first hop (founder 2026-10-14: registered on the shared factory, a
///      fee-free two-hop swap would let any manager skip the fee). Minimums are the Comptroller's to check (vault
///      balance deltas); the swaps take none of their own. It never holds tokens after a call.
contract ViaWethSellAdapter is IIntegrationAdapter, ProtocolFeeAdapter {
	using SafeERC20 for IERC20;

	enum Venue {
		UniswapV3,
		Slipstream1,
		Slipstream2,
		Slipstream3,
		AerodromeBasic
	}

	struct Hop {
		Venue venue;
		int24 param;
	}

	address public immutable weth;
	/// @notice Uniswap SwapRouter02 (Base 0x2626…e481).
	address public immutable uniswapV3Router;
	/// @notice The Slipstream-1/2/3 SwapRouters (Base: 0xBE6D…18a5, 0x698C…A92F, 0xcbBb…Ce0D).
	address public immutable slipstream1Router;
	address public immutable slipstream2Router;
	address public immutable slipstream3Router;
	/// @notice The Aerodrome Router (Base 0xcF77…4E43) and its default basic pool factory (0x420D…40Da).
	address public immutable aerodromeRouter;
	address public immutable aerodromePoolFactory;

	error BadSale();
	error BadHop();
	error Unsold(address token);

	constructor(
		address weth_,
		address uniswapV3Router_,
		address slipstream1Router_,
		address slipstream2Router_,
		address slipstream3Router_,
		address aerodromeRouter_,
		address aerodromePoolFactory_,
		address treasury_,
		uint16 feeBps_,
		address owner_
	) ProtocolFeeAdapter(treasury_, feeBps_, owner_) {
		if (
			weth_ == address(0) || uniswapV3Router_ == address(0) || slipstream1Router_ == address(0)
				|| slipstream2Router_ == address(0) || slipstream3Router_ == address(0) || aerodromeRouter_ == address(0)
				|| aerodromePoolFactory_ == address(0)
		) revert ZeroAddress();
		weth = weth_;
		uniswapV3Router = uniswapV3Router_;
		slipstream1Router = slipstream1Router_;
		slipstream2Router = slipstream2Router_;
		slipstream3Router = slipstream3Router_;
		aerodromeRouter = aerodromeRouter_;
		aerodromePoolFactory = aerodromePoolFactory_;
	}

	/// @inheritdoc IIntegrationAdapter
	function parseAssetsForAction(bytes calldata integrationData)
		external
		view
		returns (
			address[] memory spendAssets,
			uint256[] memory spendAmounts,
			address[] memory incomingAssets,
			uint256[] memory minIncomingAmounts
		)
	{
		(address token, uint256 amount, uint256 minOut, address outToken,,) =
			abi.decode(integrationData, (address, uint256, uint256, address, Hop, Hop));
		if (token == weth || outToken == weth || token == outToken) revert BadSale();
		return (_one(token), _amount(amount), _one(outToken), _amount(minOut));
	}

	/// @inheritdoc IIntegrationAdapter
	function executeAction(address vault, bytes calldata integrationData) external {
		(address token,,, address outToken, Hop memory toWeth, Hop memory fromWeth) =
			abi.decode(integrationData, (address, uint256, uint256, address, Hop, Hop));
		_takeFee(token, IERC20(token).balanceOf(address(this)));
		_sellAll(toWeth, token, weth, address(this));
		_sellAll(fromWeth, weth, outToken, vault);
	}

	/// @dev Sells this adapter's whole balance of `tokenIn` on the hop's pool, paying `recipient`; reverts Unsold when
	///      any of it stays here.
	function _sellAll(Hop memory hop, address tokenIn, address tokenOut, address recipient) private {
		uint256 amountIn = IERC20(tokenIn).balanceOf(address(this));
		if (amountIn == 0) return;
		if (hop.venue == Venue.UniswapV3) {
			if (hop.param <= 0) revert BadHop();
			IERC20(tokenIn).forceApprove(uniswapV3Router, amountIn);
			IUniswapV3SwapRouter(uniswapV3Router).exactInputSingle(
				IUniswapV3SwapRouter.ExactInputSingleParams({
					tokenIn: tokenIn,
					tokenOut: tokenOut,
					fee: uint24(uint256(int256(hop.param))),
					recipient: recipient,
					amountIn: amountIn,
					amountOutMinimum: 0,
					sqrtPriceLimitX96: 0
				})
			);
		} else if (hop.venue == Venue.AerodromeBasic) {
			if (hop.param != 0) revert BadHop();
			IERC20(tokenIn).forceApprove(aerodromeRouter, amountIn);
			IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
			routes[0] = IAerodromeRouter.Route({from: tokenIn, to: tokenOut, stable: false, factory: aerodromePoolFactory});
			IAerodromeRouter(aerodromeRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(
				amountIn, 0, routes, recipient, block.timestamp
			);
		} else {
			address router = hop.venue == Venue.Slipstream1
				? slipstream1Router
				: hop.venue == Venue.Slipstream2 ? slipstream2Router : slipstream3Router;
			IERC20(tokenIn).forceApprove(router, amountIn);
			ISlipstreamSwapRouter(router).exactInputSingle(
				ISlipstreamSwapRouter.ExactInputSingleParams({
					tokenIn: tokenIn,
					tokenOut: tokenOut,
					tickSpacing: hop.param,
					recipient: recipient,
					deadline: block.timestamp,
					amountIn: amountIn,
					amountOutMinimum: 0,
					sqrtPriceLimitX96: 0
				})
			);
		}
		if (IERC20(tokenIn).balanceOf(address(this)) != 0) revert Unsold(tokenIn);
	}

	function _one(address asset) private pure returns (address[] memory assets) {
		assets = new address[](1);
		assets[0] = asset;
	}

	function _amount(uint256 amount) private pure returns (uint256[] memory amounts) {
		amounts = new uint256[](1);
		amounts[0] = amount;
	}
}
