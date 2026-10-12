// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ComptrollerV6} from '../../src/core/ComptrollerV6.sol';
import {IExternalPosition} from '../../src/interfaces/IExternalPosition.sol';
import {IExternalPositionTypeFactory} from '../../src/interfaces/IExternalPositionTypeFactory.sol';
import {MockRedemptionQueue} from './MockRedemptionQueue.sol';

/// @dev Stands in for RedemptionQueueV2 in ComptrollerV6 unit tests: the V3 mock's settable overdue flag, plus direct
///      calls into fund v6's queue-only hooks.
contract MockRedemptionQueueV6 is MockRedemptionQueue {
	function payOutV6(ComptrollerV6 fund, address to, uint256 shares, uint256 amount) external {
		fund.payOutRedemption(to, shares, amount);
	}

	function settleFeesV6(ComptrollerV6 fund) external returns (uint256 gav, bool complete) {
		return fund.settleFeesForRedemption();
	}

	function liquidateTrade(ComptrollerV6 fund, address adapter, bytes calldata integrationData) external {
		fund.liquidateTrade(adapter, integrationData);
	}

	function liquidatePosition(ComptrollerV6 fund, address position, address[] calldata assetsToReceive, bytes[] calldata actions)
		external
	{
		fund.liquidatePosition(position, assetsToReceive, actions);
	}
}

/// @dev A perp account as fund v6 sees one: it names the factory that deployed it (`positionFactory`, as
///      VerantaPerpPositionV4 does) and takes VerantaPerpPositionV4's CloseTrade shape (pair, index, amount, price),
///      recording the last amount. Action 1 (CloseTrade) and 6 (ReturnToVault) are risk-reducing.
contract MockPerpAccount is IExternalPosition {
	address public immutable comptroller;
	address public immutable positionFactory;
	IERC20 public immutable usdc;
	uint256 public closes;
	uint256 public lastCloseAmount;

	constructor(address comptroller_, address positionFactory_, IERC20 usdc_) {
		comptroller = comptroller_;
		positionFactory = positionFactory_;
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
			usdc.transfer(address(ComptrollerV6(comptroller).vault()), abi.decode(args, (uint256)));
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
