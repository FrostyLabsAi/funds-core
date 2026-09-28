// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice Aerodrome Slipstream CLGauge (subset used by SlipstreamLPPosition).
/// @dev Staking a position gives its trading fees to veAERO voters in exchange for AERO emissions.
interface ICLGauge {
	function deposit(uint256 tokenId) external;

	function withdraw(uint256 tokenId) external;

	function getReward(uint256 tokenId) external;

	function earned(address account, uint256 tokenId) external view returns (uint256);

	function rewardToken() external view returns (address);
}
