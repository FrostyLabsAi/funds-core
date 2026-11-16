// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title IV4PriceSampler
/// @notice Price history for Uniswap v4 pools, which keep none of their own: an approved keeper's readings of each pool's
///         tick and in-range liquidity.
interface IV4PriceSampler {
	/// @dev One storage slot: 32 + 24 + 128 bits.
	struct Sample {
		uint32 time;
		int24 tick;
		uint128 liquidity;
	}

	/// @notice Reads each pool's tick and in-range liquidity now and keeps it. Keeper only.
	function sample(bytes32[] calldata poolIds) external;

	/// @notice The pool's kept readings, newest first.
	function samples(bytes32 poolId) external view returns (Sample[] memory out);

	/// @notice Samples ever taken for a pool.
	function sampleCount(bytes32 poolId) external view returns (uint256);
}
