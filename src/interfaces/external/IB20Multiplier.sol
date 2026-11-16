// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice A Coinbase B20 stock token's share-to-token ratio (1e18 = one share), which moves with reinvested dividends,
///         fees and corporate actions.
interface IB20Multiplier {
	function multiplier() external view returns (uint256);
}
