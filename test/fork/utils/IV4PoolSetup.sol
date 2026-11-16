// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {PoolKey} from '../../../src/interfaces/external/IUniswapV4.sol';

/// @notice v4-core PoolManager's pool setup, for the partial-fill proof's own pool.
interface IV4PoolSetup {
	struct ModifyLiquidityParams {
		int24 tickLower;
		int24 tickUpper;
		int256 liquidityDelta;
		bytes32 salt;
	}

	function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
	function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
		external
		returns (int256 callerDelta, int256 feesAccrued);
}
