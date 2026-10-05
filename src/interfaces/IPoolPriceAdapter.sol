// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {AggregatorV3Interface} from './AggregatorV3Interface.sol';
import {IValueInterpreter} from './IValueInterpreter.sol';

/// @title IPoolPriceAdapter
/// @notice A price feed for one asset read from one DEX pool (PoolPriceRegistrar's clones).
interface IPoolPriceAdapter is AggregatorV3Interface {
	/// @notice What one clone prices, fixed at creation: the clone's immutable args,
	///         abi.encode(Config).
	struct Config {
		IValueInterpreter valueInterpreter;
		address pool;
		address asset;
		address quoteAsset;
		bool assetIsToken0;
		uint8 assetDecimals;
		uint8 quoteDecimals;
	}

	function config() external view returns (Config memory);

	/// @notice USD (18 decimals) of the quote token the pool holds, counting only liquidity
	///         that has been there over the price window.
	function liquidityUsd() external view returns (uint256);
}
