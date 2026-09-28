// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice Minimal Pyth Core interface. Struct layout matches PythStructs.Price, verified against
///         the Base deployment 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a. Exponents vary per feed.
interface IPyth {
	struct Price {
		int64 price;
		uint64 conf; // absolute confidence interval, same exponent as price
		int32 expo;
		uint256 publishTime; // unix seconds of the aggregate the contract last stored
	}

	/// @dev Last stored price, no staleness check (caller validates publishTime). Reverts for ids never pushed.
	function getPriceUnsafe(bytes32 id) external view returns (Price memory price);

	/// @dev Fee for pushing `updateData` (0 wei on Base today; read it, never hardcode).
	function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);

	/// @dev Permissionless push of signed Hermes payloads.
	function updatePriceFeeds(bytes[] calldata updateData) external payable;
}
