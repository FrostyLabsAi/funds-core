// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {AggregatorV3Interface} from './AggregatorV3Interface.sol';
import {IVerantaPriceStore} from './IVerantaPriceStore.sol';

/// @title IVerantaPriceFeed
/// @notice A ValueInterpreter feed priced from the Veranta price store: a perp pair (VerantaPriceAdapter) or a spot
///         stock token (B20VerantaPriceAdapter). Valuation reads the store's last trade time to tell a closed market.
interface IVerantaPriceFeed is AggregatorV3Interface {
	function store() external view returns (IVerantaPriceStore);
	function pairIndex() external view returns (uint256);

	/// @notice The oldest confirmation (seconds) the feed answers with.
	function maxPushAge() external view returns (uint32);

	/// @notice The oldest last trade (seconds) the feed answers with.
	function maxFeedAge() external view returns (uint32);
}
