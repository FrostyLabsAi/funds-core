// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {AggregatorV3Interface} from '../interfaces/AggregatorV3Interface.sol';
import {VerantaPriceStore} from './VerantaPriceStore.sol';

/// @title VerantaPriceAdapter
/// @notice One Veranta pair's price from a VerantaPriceStore exposed as a Chainlink AggregatorV3
///         feed (8 decimals); registered on the pair's PriceMarker, it values a perp leg at
///         Veranta's settlement price.
/// @dev `maxPushAge` bounds the stored print's age: relaying is permissionless, so a pair must not
///      stay readable at a print nobody refreshed (1h crypto; closed markets get a weekend).
contract VerantaPriceAdapter is AggregatorV3Interface {
	uint8 internal constant DECIMALS = 8;

	VerantaPriceStore public immutable store;
	uint256 public immutable pairIndex;
	uint32 public immutable maxPushAge;
	string public description;

	error ZeroArgument();
	error NeverPushed(uint256 pairIndex);
	error StalePush(uint256 updatedAt);
	error ExponentOutOfRange(int16 exponent);

	constructor(VerantaPriceStore store_, uint256 pairIndex_, uint32 maxPushAge_, string memory description_) {
		if (address(store_) == address(0) || maxPushAge_ == 0) revert ZeroArgument();
		store = store_;
		pairIndex = pairIndex_;
		maxPushAge = maxPushAge_;
		description = description_;
	}

	/// @inheritdoc AggregatorV3Interface
	function decimals() external pure returns (uint8) {
		return DECIMALS;
	}

	/// @inheritdoc AggregatorV3Interface
	function latestRoundData()
		external
		view
		returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
	{
		(int64 price, int16 exponent, uint64 timestampUs) = store.latest(pairIndex);
		if (timestampUs == 0) revert NeverPushed(pairIndex);
		updatedAt = timestampUs / 1e6;
		if (block.timestamp > updatedAt + maxPushAge) revert StalePush(updatedAt);

		int256 shift = int256(uint256(DECIMALS)) + exponent;
		if (shift > 30 || shift < -30) revert ExponentOutOfRange(exponent);
		answer = shift >= 0 ? int256(price) * int256(10 ** uint256(shift)) : int256(price) / int256(10 ** uint256(-shift));
		roundId = uint80(updatedAt);
		answeredInRound = roundId;
		startedAt = updatedAt;
	}
}
