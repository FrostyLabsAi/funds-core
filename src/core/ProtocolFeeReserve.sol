// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {IProtocolFeeReserve} from '../interfaces/IProtocolFeeReserve.sol';

/// @title ProtocolFeeReserve
/// @notice Receives protocol AUM-fee shares (set as the FundFactory's protocol-fee
///         recipient) and prices their buyback: a fund manager burns FROST worth HALF the
///         shares' market value and the shares are burned, un-diluting the fund. Protocol
///         revenue arrives as FROST destruction; the reserve never has to sell fund shares.
/// @dev Port of Enzyme v4's ProtocolFeeReserve (protocol/contracts/persistent/
///      protocol-fee-reserve/ProtocolFeeReserveLib.sol; the 50% MLN-burn discount).
///      Deliberately near-stateless: valuation and the actual share-burn/FROST-transfer
///      happen in the calling Comptroller, which alone has mint/burn/custody authority
///      over its own fund. A direct call here by a non-fund contract can only emit a
///      meaningless event — it moves no shares and no FROST. Same trust shape as
///      Enzyme's `buyBackSharesViaTrustedVaultProxy`.
contract ProtocolFeeReserve is Ownable2Step, IProtocolFeeReserve {
	using SafeERC20 for IERC20;

	/// @notice Burn amount = value / divisor: a 50% discount, matching Enzyme.
	uint256 public constant BUYBACK_DISCOUNT_DIVISOR = 2;

	/// @notice The asset burned in buybacks (FROST).
	address public immutable burnAsset;

	event SharesBoughtBack(
		address indexed comptroller, uint256 sharesAmount, uint256 burnAssetValue, uint256 amountToBurn
	);
	event TokenWithdrawn(address indexed token, address indexed to, uint256 amount);

	error ZeroAddress();

	constructor(address burnAsset_, address owner_) Ownable(owner_) {
		if (burnAsset_ == address(0)) revert ZeroAddress();
		burnAsset = burnAsset_;
	}

	/// @inheritdoc IProtocolFeeReserve
	function buyBackShares(uint256 sharesAmount, uint256 burnAssetValue)
		external
		returns (uint256 amountToBurn)
	{
		amountToBurn = burnAssetValue / BUYBACK_DISCOUNT_DIVISOR;
		emit SharesBoughtBack(msg.sender, sharesAmount, burnAssetValue, amountToBurn);
	}

	/// @notice Treasury operations on accrued fee shares (or any token sent here):
	///         transfer out to redeem via the fund, sell, or distribute. Owner only.
	function withdrawToken(address token, address to, uint256 amount) external onlyOwner {
		if (to == address(0)) revert ZeroAddress();
		IERC20(token).safeTransfer(to, amount);
		emit TokenWithdrawn(token, to, amount);
	}
}
