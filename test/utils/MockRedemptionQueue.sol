// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IRedemptionQueue} from '../../src/interfaces/IRedemptionQueue.sol';
import {ComptrollerV3} from '../../src/core/ComptrollerV3.sol';

/// @dev Stands in for RedemptionQueue in ComptrollerV3 unit tests: a settable overdue flag and
///      direct calls into the queue-only hooks.
contract MockRedemptionQueue is IRedemptionQueue {
	mapping(address => bool) public overdue;

	function setOverdue(address comptroller, bool value) external {
		overdue[comptroller] = value;
	}

	/// @dev No open requests: what a reconfiguration asks (head == length).
	function queueBounds(address) external pure returns (uint256 head, uint256 length) {
		return (0, 0);
	}

	function isOverdue(address comptroller) external view returns (bool) {
		return overdue[comptroller];
	}

	function payOut(ComptrollerV3 fund, address to, uint256 shares, address[] calldata assets, uint256[] calldata amounts)
		external
	{
		fund.payOutRedemption(to, shares, assets, amounts);
	}

	function forward(ComptrollerV3 fund, address position, bytes calldata actionData) external {
		fund.forwardUnwind(position, actionData);
	}

	function settleFees(ComptrollerV3 fund) external returns (bytes memory snapshot) {
		return fund.settleFeesForRedemption();
	}
}
