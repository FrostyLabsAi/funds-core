// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {AggregatorV3Interface} from '../interfaces/AggregatorV3Interface.sol';
import {IVerantaPriceFeed} from '../interfaces/IVerantaPriceFeed.sol';
import {IVerantaPriceStore} from '../interfaces/IVerantaPriceStore.sol';

/// @title VerantaPriceAdapter
/// @notice One Veranta pair's price from the VerantaPriceStore as a Chainlink AggregatorV3 feed (8 decimals), registered on
///         the pair's PriceMarker, for markets that close: stocks, indices, FX, metals. On a store keeping only the feed's time and a
///         10-minute heartbeat a perp on a closed market couldn't be priced at all, because a fresh packet still carries the last
///         trade's time: the fund's NAV, its deposits and its queue all reverted until the next session (red-team PF-01,
///         2026-10-27; founder 2026-11-03: a closed market must never stop a deposit).
/// @dev Two ages, both against block.timestamp, as B20VerantaPriceAdapter:
///      - `maxPushAge` on the confirmation (when Pyth last signed the price as current): relaying is permissionless, so a
///        price must be re-confirmed recently to be read (security review 2026-09-22, H-3);
///      - `maxFeedAge` on the last trade: a closed market keeps reading its close, a pair Pyth stops updating stops pricing.
///      `updatedAt` is the LAST TRADE, unlike B20VerantaPriceAdapter: registered with a heartbeat over
///      FundValuation.SESSION_HEARTBEAT, an old trade reads as a closed market, so the queue waits for a real price and
///      deposits don't. `store()`, `pairIndex()`, `maxPushAge()` and `maxFeedAge()` are what funds-keeper and the terminal
///      probe to push this price on demand and to inject it in the store's layout.
contract VerantaPriceAdapter is IVerantaPriceFeed {
	uint8 internal constant DECIMALS = 8;

	IVerantaPriceStore public immutable store;
	uint256 public immutable pairIndex;
	uint32 public immutable maxPushAge;
	uint32 public immutable maxFeedAge;
	string public description;

	error ZeroArgument();
	error NeverPushed(uint256 pairIndex);
	error StalePush(uint256 confirmedAt);
	error StaleFeed(uint256 feedUpdatedAt);
	error ExponentOutOfRange(int16 exponent);

	constructor(IVerantaPriceStore store_, uint256 pairIndex_, uint32 maxPushAge_, uint32 maxFeedAge_, string memory description_) {
		if (address(store_) == address(0) || maxPushAge_ == 0 || maxFeedAge_ == 0) revert ZeroArgument();
		store = store_;
		pairIndex = pairIndex_;
		maxPushAge = maxPushAge_;
		maxFeedAge = maxFeedAge_;
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
		(int64 price, int16 exponent, uint64 confirmedUs) = store.latest(pairIndex);
		if (confirmedUs == 0) revert NeverPushed(pairIndex);
		uint256 confirmedAt = confirmedUs / 1e6;
		if (block.timestamp > confirmedAt + maxPushAge) revert StalePush(confirmedAt);
		updatedAt = store.feedUpdatedUs(pairIndex) / 1e6;
		if (block.timestamp > updatedAt + maxFeedAge) revert StaleFeed(updatedAt);

		int256 shift = int256(uint256(DECIMALS)) + exponent;
		if (shift > 30 || shift < -30) revert ExponentOutOfRange(exponent);
		answer = shift >= 0 ? int256(price) * int256(10 ** uint256(shift)) : int256(price) / int256(10 ** uint256(-shift));
		roundId = uint80(updatedAt);
		answeredInRound = roundId;
		startedAt = updatedAt;
	}
}
