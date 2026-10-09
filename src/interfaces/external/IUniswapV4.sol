// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice Uniswap v4 on Base, the surface FrostyFunds uses — mirrored from the deployed, verified sources
///         (v4-core PoolManager 0x4985…2b2b, v4-periphery StateView 0xA3c0…7A71; read 2026-10-08). Types are
///         ABI-identical to v4's: `Currency` and `IHooks` are addresses (address(0) = native ETH), `BalanceDelta`
///         is an int256 (amount0 in the high 128 bits, amount1 in the low 128).
struct PoolKey {
	address currency0;
	address currency1;
	uint24 fee;
	int24 tickSpacing;
	address hooks;
}

/// @notice v4-core PoolIdLibrary.toId: keccak256 over the key's five words.
library PoolKeyId {
	function toId(PoolKey memory key) internal pure returns (bytes32) {
		return keccak256(abi.encode(key));
	}
}

/// @notice v4-core BalanceDeltaLibrary: amount0 = high 128 bits (signed), amount1 = low 128 bits (signed).
library V4Delta {
	function amount0(int256 delta) internal pure returns (int128) {
		return int128(delta >> 128);
	}

	function amount1(int256 delta) internal pure returns (int128) {
		return int128(delta);
	}
}

interface IV4PoolManager {
	struct SwapParams {
		bool zeroForOne;
		/// @dev negative = exact input, positive = exact output
		int256 amountSpecified;
		uint160 sqrtPriceLimitX96;
	}

	function unlock(bytes calldata data) external returns (bytes memory);
	function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256 swapDelta);
	/// @dev Before paying an ERC-20 in: checkpoint its PoolManager balance (native ETH needs none)
	function sync(address currency) external;
	/// @dev Credits what arrived since `sync` (ERC-20) or msg.value (native, with nothing synced)
	function settle() external payable returns (uint256 paid);
	function take(address currency, address to, uint256 amount) external;
}

interface IV4UnlockCallback {
	function unlockCallback(bytes calldata data) external returns (bytes memory);
}

interface IV4StateView {
	function getSlot0(bytes32 poolId)
		external
		view
		returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
	function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity);
}
