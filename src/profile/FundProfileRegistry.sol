// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IComptroller} from '../interfaces/IComptroller.sol';

/// @title FundProfileRegistry
/// @notice A fund's public links, set by its manager for investors (founder 2026-10-11): website, X, Telegram, Discord,
///         as one short JSON record. The terminal validates every link and shows them as provided by the manager, never
///         verified by FrostyFunds. Signed by the manager's wallet, so no one else can change them.
/// @dev Ownerless; holds no funds and no permissions, and nothing on-chain reads it.
contract FundProfileRegistry {
	/// @notice Room for four links; the cap keeps a record small enough for any reader.
	uint256 public constant MAX_PROFILE_BYTES = 1024;

	mapping(address comptroller => string) public profileOf;

	event ProfileSet(address indexed comptroller, string profile);

	error NotFundOwner();
	error ProfileTooLong(uint256 length);

	/// @notice Publish or replace the fund's links (an empty `profile` clears them). Only the fund's owner.
	function setProfile(address comptroller, string calldata profile) external {
		if (IComptroller(comptroller).fundOwner() != msg.sender) revert NotFundOwner();
		if (bytes(profile).length > MAX_PROFILE_BYTES) revert ProfileTooLong(bytes(profile).length);
		profileOf[comptroller] = profile;
		emit ProfileSet(comptroller, profile);
	}
}
