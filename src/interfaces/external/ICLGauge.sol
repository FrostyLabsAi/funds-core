// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice Aerodrome Slipstream CLGauge (subset used by SlipstreamLPPosition).
/// @dev Verified against aerodrome-finance/slipstream gauge. Staking a position surrenders
///      its trading fees to veAERO voters in exchange for AERO emissions (see living doc,
///      Slipstream fee mechanics).
interface ICLGauge {
	function deposit(uint256 tokenId) external;

	function withdraw(uint256 tokenId) external;

	function getReward(uint256 tokenId) external;

	function earned(address account, uint256 tokenId) external view returns (uint256);

	function rewardToken() external view returns (address);
}
