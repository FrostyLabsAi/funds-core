// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IPoolPriceAdapter} from './IPoolPriceAdapter.sol';
import {IV4PriceSampler} from './IV4PriceSampler.sol';
import {IV4StateView} from './external/IUniswapV4.sol';

/// @title IV4PoolPriceAdapter
/// @notice A pool-price feed for one asset on a Uniswap v4 pool (V4PoolPriceAdapter's clones): its clone args are
///         abi.encode(Config, V4Extra).
interface IV4PoolPriceAdapter is IPoolPriceAdapter {
	/// @notice The v4 half of the clone args: where the samples and the pool's state are read.
	struct V4Extra {
		IV4PriceSampler sampler;
		IV4StateView stateView;
		bytes32 poolId;
	}

	/// @notice The v4 half of the clone args.
	function v4Extra() external view returns (V4Extra memory);
}
