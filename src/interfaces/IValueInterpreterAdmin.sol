// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IValueInterpreter} from './IValueInterpreter.sol';

/// @title IValueInterpreterAdmin
/// @notice The ValueInterpreter's owner calls: what the pool-price registrar, its owner, writes and passes through.
interface IValueInterpreterAdmin is IValueInterpreter {
	function addPrimitive(address asset, address aggregator, uint32 heartbeat) external;
	function removePrimitive(address asset) external;
	function addDerivative(address asset, address feed) external;
	function removeDerivative(address asset) external;
	function addZeroPricedAsset(address asset) external;
	function removeZeroPricedAsset(address asset) external;
	function setAnswerBounds(address asset, int256 min, int256 max) external;
	function setSequencerUptimeFeed(address feed, uint32 gracePeriod) external;

	/// @notice Ownable2Step: completes a transfer the current owner proposed.
	function acceptOwnership() external;
}
