// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {AggregatorV3Interface} from '../interfaces/AggregatorV3Interface.sol';
import {IVerantaPriceFeed} from '../interfaces/IVerantaPriceFeed.sol';
import {IVerantaPriceStore} from '../interfaces/IVerantaPriceStore.sol';
import {IB20Multiplier} from '../interfaces/external/IB20Multiplier.sol';

/// @title B20VerantaPriceAdapter
/// @notice One Coinbase stock token priced as a Chainlink AggregatorV3 feed (8 decimals) for a stock with no Chainlink
///         feed (founder 2026-10-25: MUc, PLTRc, NFLXc, AMDc, AVGOc, MRVLc, LLYc): Veranta's Pyth-signed share price
///         from the VerantaPriceStore × the token's own `multiplier()` — never the share 1:1 (hard rule 3; the
///         founder accepted pricing from the share and the token's ratio instead of a per-token feed). Checked on
///         2026-10-25: Veranta's NVDA × NVDAc's multiplier was within 9 bps of Chainlink's "Coinbase NVDA" feed.
/// @dev Two ages, both against block.timestamp:
///      - `maxPushAge` on the confirmation (when Pyth last signed the price as current): relaying is permissionless,
///        so a price must be re-confirmed recently to be read (security review 2026-09-22, H-3);
///      - `maxFeedAge` on the last trade: a closed market (weekend, holiday) keeps reading its close while it is
///        re-confirmed, a stock Pyth stops updating stops pricing.
///      `store()`, `pairIndex()` and `maxPushAge()` are what funds-keeper and the terminal probe to push this price on
///      demand (VerantaPriceAdapter's surface). The constructor never calls the token: B20 tokens are a Base
///      precompile Foundry can't run, so deploy scripts must not touch them.
contract B20VerantaPriceAdapter is IVerantaPriceFeed {
	uint8 internal constant DECIMALS = 8;

	IVerantaPriceStore public immutable store;
	uint256 public immutable pairIndex;
	address public immutable token;
	uint32 public immutable maxPushAge;
	uint32 public immutable maxFeedAge;
	string public description;

	error ZeroArgument();
	error NeverPushed(uint256 pairIndex);
	error StalePush(uint256 updatedAt);
	error StaleFeed(uint256 feedUpdatedAt);
	error ExponentOutOfRange(int16 exponent);
	error BadMultiplier();

	constructor(
		IVerantaPriceStore store_,
		uint256 pairIndex_,
		address token_,
		uint32 maxPushAge_,
		uint32 maxFeedAge_,
		string memory description_
	) {
		if (address(store_) == address(0) || token_ == address(0) || maxPushAge_ == 0 || maxFeedAge_ == 0) {
			revert ZeroArgument();
		}
		store = store_;
		pairIndex = pairIndex_;
		token = token_;
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
		updatedAt = confirmedUs / 1e6;
		if (block.timestamp > updatedAt + maxPushAge) revert StalePush(updatedAt);
		uint256 feedUpdatedAt = store.feedUpdatedUs(pairIndex) / 1e6;
		if (block.timestamp > feedUpdatedAt + maxFeedAge) revert StaleFeed(feedUpdatedAt);

		uint256 multiplier = IB20Multiplier(token).multiplier();
		if (multiplier == 0) revert BadMultiplier();
		int256 shift = int256(uint256(DECIMALS)) + exponent;
		if (shift > 30 || shift < -30) revert ExponentOutOfRange(exponent);
		uint256 share = uint256(uint64(price)); // the store only keeps positive prices
		share = shift >= 0 ? share * 10 ** uint256(shift) : share / 10 ** uint256(-shift);
		answer = int256(Math.mulDiv(share, multiplier, 1e18));
		roundId = uint80(updatedAt);
		answeredInRound = roundId;
		startedAt = updatedAt;
	}
}
