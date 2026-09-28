// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title IProtocolFeeReserve
/// @notice Receives protocol-fee shares and prices their discounted buyback in the burn asset (FROST).
/// @dev Implementing it is the reserve's consent to have its shares burned; a plain treasury
///      address doesn't, so buybacks against it revert.
interface IProtocolFeeReserve {
	/// @notice The asset burned in buybacks (FROST).
	function burnAsset() external view returns (address);

	/// @notice Given the burn-asset value of `sharesAmount` fee shares, return the discounted amount to burn.
	function buyBackShares(uint256 sharesAmount, uint256 burnAssetValue)
		external
		returns (uint256 amountToBurn);
}
