// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {IRedemptionQueue} from '../../src/interfaces/IRedemptionQueue.sol';
import {IExternalPosition} from '../../src/interfaces/IExternalPosition.sol';
import {IExternalPositionTypeFactory} from '../../src/interfaces/IExternalPositionTypeFactory.sol';

/// @dev Stands in for the RedemptionQueue in Comptroller unit tests: a settable overdue flag and direct calls into the
///      comptroller's queue-only hooks.
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

	function payOut(Comptroller fund, address to, uint256 shares, uint256 amount) external {
		fund.payOutRedemption(to, shares, amount);
	}

	function settleFees(Comptroller fund) external returns (uint256 gav, bool complete) {
		return fund.settleFeesForRedemption();
	}

	function liquidateTrade(Comptroller fund, address adapter, bytes calldata integrationData) external {
		fund.liquidateTrade(adapter, integrationData);
	}

	function liquidatePosition(Comptroller fund, address position, address[] calldata assetsToReceive, bytes[] calldata actions)
		external
	{
		fund.liquidatePosition(position, assetsToReceive, actions);
	}
}

/// @dev A perp account as a fund sees one: it names its config (`perpConfig`, as VerantaPerpPosition does; here the
///      factory that deployed it) and takes VerantaPerpPosition's CloseTrade shape (pair, index, amount, price),
///      recording the last amount. Action 1 (CloseTrade) and 6 (ReturnToVault) are risk-reducing.
contract MockPerpAccount is IExternalPosition {
	address public immutable comptroller;
	address public immutable perpConfig;
	IERC20 public immutable usdc;
	uint256 public closes;
	uint256 public lastCloseAmount;

	constructor(address comptroller_, address perpConfig_, IERC20 usdc_) {
		comptroller = comptroller_;
		perpConfig = perpConfig_;
		usdc = usdc_;
	}

	function getManagedAssets() external view returns (address[] memory assets, uint256[] memory amounts) {
		assets = new address[](1);
		amounts = new uint256[](1);
		assets[0] = address(usdc);
		amounts[0] = usdc.balanceOf(address(this));
	}

	function getDebtAssets() external pure returns (address[] memory assets, uint256[] memory amounts) {
		assets = new address[](0);
		amounts = new uint256[](0);
	}

	function isRiskReducing(bytes calldata actionData) external pure returns (bool) {
		(uint8 action,) = abi.decode(actionData, (uint8, bytes));
		return action == 1 || action == 6;
	}

	function receiveCallFromFund(bytes calldata actionData) external {
		require(msg.sender == comptroller, 'only comptroller');
		(uint8 action, bytes memory args) = abi.decode(actionData, (uint8, bytes));
		if (action == 1) {
			(,, uint256 amount,) = abi.decode(args, (uint256, uint256, uint256, uint256));
			++closes;
			lastCloseAmount = amount;
		} else if (action == 6) {
			usdc.transfer(address(Comptroller(comptroller).vault()), abi.decode(args, (uint256)));
		}
	}
}

contract MockPerpAccountFactory is IExternalPositionTypeFactory {
	IERC20 public immutable usdc;

	constructor(IERC20 usdc_) {
		usdc = usdc_;
	}

	function deployPosition(address comptroller, bytes calldata) external returns (address) {
		return address(new MockPerpAccount(comptroller, address(this), usdc));
	}
}
