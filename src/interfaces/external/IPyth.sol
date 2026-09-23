// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice Minimal Pyth Core interface (pull oracle, api-reference/evm). Struct layout matches
///         PythStructs.Price exactly — verified live against the Base mainnet deployment at
///         0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a's real ABI via `getPriceUnsafe` reads
///         (ETH/USD expo -8, TSLA/USD + EUR/USD expo -5 — exponents VARY per feed).
interface IPyth {
	struct Price {
		int64 price;
		uint64 conf; // absolute confidence interval, same exponent as price
		int32 expo;
		uint256 publishTime; // unix seconds of the aggregate the contract last stored
	}

	/// @dev Returns the LAST STORED price without any staleness check ("unsafe" = caller
	///      must validate publishTime). Reverts PriceFeedNotFound for ids never pushed.
	function getPriceUnsafe(bytes32 id) external view returns (Price memory price);

	/// @dev Fee for pushing `updateData` on-chain (0 wei on Base today — never hardcode).
	function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);

	/// @dev Permissionless push of signed Hermes payloads (the keeper's pusher duty).
	function updatePriceFeeds(bytes[] calldata updateData) external payable;
}
