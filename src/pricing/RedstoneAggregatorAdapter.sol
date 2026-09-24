// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {AggregatorV3Interface} from '../interfaces/AggregatorV3Interface.sol';
import {RedstonePriceStore} from './RedstonePriceStore.sol';

/// @title RedstoneAggregatorAdapter
/// @notice One RedStone feed from a RedstonePriceStore, exposed as a Chainlink AggregatorV3
///         feed — so the ValueInterpreter prices RedStone-covered assets through the same
///         `addPrimitive` path as Chainlink and Pyth, with no protocol changes.
///         Order of preference per asset: Chainlink → RedStone / Pyth → TWAP → side pocket.
/// @dev STALENESS is two-layered, exactly like PythAggregatorAdapter: the VI's per-asset
///      heartbeat stays the market-hours gate (`updatedAt` = package time), and `maxPushAge`
///      bounds how old a stored print may be before reads revert (H-3: submissions are
///      permissionless, so a wide heartbeat alone would let an actor choose the print around
///      GAV actions — the keeper pushes fresher than maxPushAge before they happen).
contract RedstoneAggregatorAdapter is AggregatorV3Interface {
	RedstonePriceStore public immutable store;
	bytes32 public immutable dataFeedId;
	uint32 public immutable maxPushAge;
	string public description;

	error ZeroArgument();
	error NeverPushed(bytes32 dataFeedId);
	error StaleRedstonePush(uint256 updatedAt);

	constructor(RedstonePriceStore store_, bytes32 dataFeedId_, uint32 maxPushAge_, string memory description_) {
		if (address(store_) == address(0) || dataFeedId_ == bytes32(0) || maxPushAge_ == 0) revert ZeroArgument();
		store = store_;
		dataFeedId = dataFeedId_;
		maxPushAge = maxPushAge_;
		description = description_;
	}

	/// @inheritdoc AggregatorV3Interface
	/// @dev RedStone numeric values carry 8 decimals — the Chainlink USD convention
	function decimals() external pure returns (uint8) {
		return 8;
	}

	/// @inheritdoc AggregatorV3Interface
	function latestRoundData()
		external
		view
		returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
	{
		(uint256 value, uint64 timestampMs) = store.latest(dataFeedId);
		if (timestampMs == 0) revert NeverPushed(dataFeedId);
		updatedAt = timestampMs / 1000;
		if (block.timestamp > updatedAt + maxPushAge) revert StaleRedstonePush(updatedAt);

		answer = int256(value); // the store caps values at uint192
		roundId = uint80(updatedAt);
		answeredInRound = roundId;
		startedAt = updatedAt;
	}
}
