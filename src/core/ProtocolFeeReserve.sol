// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {IProtocolFeeReserve} from '../interfaces/IProtocolFeeReserve.sol';

/// @title ProtocolFeeReserve
/// @notice Receives the protocol AUM-fee shares and prices their buyback: a fund burns FROST
///         worth half the shares' value and the shares are burned, un-diluting the fund.
/// @dev Near-stateless: valuation and the actual burns happen in the calling Comptroller, so a
///      direct call from anything else only emits an event — it moves no shares and no FROST.
contract ProtocolFeeReserve is Ownable2Step, IProtocolFeeReserve {
	using SafeERC20 for IERC20;

	/// @notice Burn amount = value / divisor (a 50% discount).
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

	/// @notice Owner moves accrued fee shares (or any token sent here) out.
	function withdrawToken(address token, address to, uint256 amount) external onlyOwner {
		if (to == address(0)) revert ZeroAddress();
		IERC20(token).safeTransfer(to, amount);
		emit TokenWithdrawn(token, to, amount);
	}
}
