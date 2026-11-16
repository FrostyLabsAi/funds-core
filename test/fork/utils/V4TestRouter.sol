// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IV4PoolManager, IV4UnlockCallback, PoolKey, V4Delta} from '../../../src/interfaces/external/IUniswapV4.sol';
import {TickMath} from '../../../src/libraries/TickMath.sol';
import {IV4PoolSetup} from './IV4PoolSetup.sol';

/// @dev Swaps or adds liquidity on the real PoolManager from its own balances (native ETH or ERC-20) and takes
///      what it is owed to `to`: the pump-and-unwind whale and the thin pool's liquidity provider.
contract V4TestRouter is IV4UnlockCallback {
	using SafeERC20 for IERC20;

	IV4PoolManager internal immutable poolManager;

	constructor(IV4PoolManager poolManager_) {
		poolManager = poolManager_;
	}

	receive() external payable {}

	function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn, address to) external {
		poolManager.unlock(abi.encode(true, key, zeroForOne, int256(amountIn), to, int24(0), int24(0)));
	}

	function addLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity) external {
		poolManager.unlock(abi.encode(false, key, false, int256(liquidity), address(this), tickLower, tickUpper));
	}

	function unlockCallback(bytes calldata data) external returns (bytes memory) {
		(bool isSwap, PoolKey memory key, bool zeroForOne, int256 amount, address to, int24 lower, int24 upper) =
			abi.decode(data, (bool, PoolKey, bool, int256, address, int24, int24));
		int256 delta;
		if (isSwap) {
			delta = poolManager.swap(
				key,
				IV4PoolManager.SwapParams({
					zeroForOne: zeroForOne,
					amountSpecified: -amount,
					sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
				}),
				''
			);
		} else {
			(delta,) = IV4PoolSetup(address(poolManager)).modifyLiquidity(
				key, IV4PoolSetup.ModifyLiquidityParams(lower, upper, amount, bytes32(0)), ''
			);
		}
		_settle(key.currency0, V4Delta.amount0(delta), to);
		_settle(key.currency1, V4Delta.amount1(delta), to);
		return '';
	}

	function _settle(address currency, int128 delta, address to) internal {
		if (delta < 0) {
			uint256 owed = uint256(uint128(-delta));
			if (currency == address(0)) {
				poolManager.settle{value: owed}();
			} else {
				poolManager.sync(currency);
				IERC20(currency).safeTransfer(address(poolManager), owed);
				poolManager.settle();
			}
		} else if (delta > 0) {
			poolManager.take(currency, to, uint256(uint128(delta)));
		}
	}
}
