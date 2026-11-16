// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IExternalPositionTypeFactory} from '../interfaces/IExternalPositionTypeFactory.sol';
import {IVerantaPerpConfig} from '../interfaces/IVerantaPerpConfig.sol';
import {VerantaPerpPosition} from './VerantaPerpPosition.sol';

/// @title VerantaPerpPositionFactory
/// @notice Stateless, ownerless type factory for fund perp accounts. Each account is bound to `config`, the
///         VerantaPerpConfig, the one place for the pair map, the autopilot keeper and the referral (owned and governed
///         there).
contract VerantaPerpPositionFactory is IExternalPositionTypeFactory {
	IVerantaPerpConfig public immutable config;

	error ZeroAddress();

	constructor(IVerantaPerpConfig config_) {
		if (address(config_) == address(0)) revert ZeroAddress();
		config = config_;
	}

	/// @inheritdoc IExternalPositionTypeFactory
	function deployPosition(address comptroller, bytes calldata) external returns (address position) {
		position = address(new VerantaPerpPosition(comptroller, config));
	}
}
