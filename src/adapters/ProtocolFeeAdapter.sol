// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

/// @title ProtocolFeeAdapter
/// @notice The protocol fee on fund spot swaps: `feeBps` of each swap's input goes to the Treasury Safe before the
///         swap (founder 2026-10-08: owner-set between 0 and 10 bps, 5 at deployment; it pays for the v4 price
///         sampling and more). The fund spends the full amount it states and receives at least its minimum out,
///         so the fee counts as part of the trade's cost (and its slippage allowance).
/// @dev The 10 bps ceiling is a bytecode constant (hard rule 5: risk parameters get bytecode-level caps).
abstract contract ProtocolFeeAdapter is Ownable2Step {
	using SafeERC20 for IERC20;

	uint16 public constant MAX_FEE_BPS = 10;
	uint16 internal constant BPS = 10_000;

	address public immutable treasury;
	uint16 public feeBps;

	event FeeSet(uint16 feeBps);
	event FeePaid(address indexed token, uint256 amount);

	error FeeAboveCap(uint16 feeBps);
	error ZeroAddress();

	constructor(address treasury_, uint16 feeBps_, address owner_) Ownable(owner_) {
		if (treasury_ == address(0)) revert ZeroAddress();
		treasury = treasury_;
		_setFee(feeBps_);
	}

	function setFeeBps(uint16 feeBps_) external onlyOwner {
		_setFee(feeBps_);
	}

	function _setFee(uint16 feeBps_) private {
		if (feeBps_ > MAX_FEE_BPS) revert FeeAboveCap(feeBps_);
		feeBps = feeBps_;
		emit FeeSet(feeBps_);
	}

	/// @dev Send the fee on `amount` of `token` (held here) to the Treasury; returns what's left to swap.
	function _takeFee(address token, uint256 amount) internal returns (uint256 net) {
		uint256 fee = (amount * feeBps) / BPS;
		if (fee != 0) {
			IERC20(token).safeTransfer(treasury, fee);
			emit FeePaid(token, fee);
		}
		return amount - fee;
	}
}
