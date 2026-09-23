// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title IProtocolFeeReserve
/// @notice The Comptroller's view of the protocol-fee reserve: the contract that receives
///         protocol-fee shares and prices their discounted buyback against the burn asset
///         (FROST). Implementing this interface IS the reserve's consent to have its fee
///         shares burned by a fund's Comptroller — a plain treasury address never
///         implements it, so buybacks against a non-reserve recipient simply revert.
/// @dev Port of Enzyme v4's ProtocolFeeReserve (protocol/contracts/persistent/
///      protocol-fee-reserve/ProtocolFeeReserveLib.sol, MLN buyback at 50% discount).
interface IProtocolFeeReserve {
	/// @notice The asset burned in buybacks (FROST).
	function burnAsset() external view returns (address);

	/// @notice Price a buyback: given the market value of `sharesAmount` fee shares
	///         expressed in the burn asset, return the discounted amount to burn.
	function buyBackShares(uint256 sharesAmount, uint256 burnAssetValue)
		external
		returns (uint256 amountToBurn);
}
