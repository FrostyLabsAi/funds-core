// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IComptroller} from '../../src/interfaces/IComptroller.sol';
import {IExternalPosition} from '../../src/interfaces/IExternalPosition.sol';
import {IExternalPositionTypeFactory} from '../../src/interfaces/IExternalPositionTypeFactory.sol';

/// @dev A position that holds tokens for a fund, for the suites that check what a fund counts while tokens sit outside
///      its vault (GAV, the tracked list, closed markets). Shaped like an order book entry:
///      - 0 Place(sellToken, buyToken, sellAmount, buyAmount, expiry): commits `sellAmount` of what the fund sent; both
///        tokens are reported from then on;
///      - 1 Cancel(id): releases every commitment (risk-reducing);
///      - 2 ReturnToVault(token, amount): sends an uncommitted amount back to the fund's vault (risk-reducing).
///      It reports every token it holds a balance of, so a donation counts too.
contract MockEscrowPosition is IExternalPosition {
	address public immutable comptroller;
	address[] internal heldAssets;
	mapping(address => bool) internal isHeld;
	mapping(address => uint256) public committed;
	uint256 public orderCount;

	error InventoryCommitted();
	error UnknownAction();

	constructor(address comptroller_) {
		comptroller = comptroller_;
	}

	function getManagedAssets() external view returns (address[] memory assets, uint256[] memory amounts) {
		uint256 count;
		uint256[] memory balances = new uint256[](heldAssets.length);
		for (uint256 i; i < heldAssets.length; ++i) {
			balances[i] = IERC20(heldAssets[i]).balanceOf(address(this));
			if (balances[i] > 0) ++count;
		}
		assets = new address[](count);
		amounts = new uint256[](count);
		uint256 j;
		for (uint256 i; i < heldAssets.length; ++i) {
			if (balances[i] == 0) continue;
			assets[j] = heldAssets[i];
			amounts[j] = balances[i];
			++j;
		}
	}

	function getDebtAssets() external pure returns (address[] memory assets, uint256[] memory amounts) {
		assets = new address[](0);
		amounts = new uint256[](0);
	}

	function isRiskReducing(bytes calldata actionData) external pure returns (bool) {
		(uint8 action,) = abi.decode(actionData, (uint8, bytes));
		return action == 1 || action == 2;
	}

	function receiveCallFromFund(bytes calldata actionData) external {
		require(msg.sender == comptroller, 'only comptroller');
		(uint8 action, bytes memory args) = abi.decode(actionData, (uint8, bytes));
		if (action == 0) {
			(address sellToken, address buyToken, uint128 sellAmount,,) = abi.decode(args, (address, address, uint128, uint128, uint64));
			if (IERC20(sellToken).balanceOf(address(this)) < committed[sellToken] + sellAmount) revert InventoryCommitted();
			committed[sellToken] += sellAmount;
			++orderCount;
			_hold(sellToken);
			_hold(buyToken);
		} else if (action == 1) {
			for (uint256 i; i < heldAssets.length; ++i) {
				committed[heldAssets[i]] = 0;
			}
		} else if (action == 2) {
			(address asset, uint256 amount) = abi.decode(args, (address, uint256));
			if (IERC20(asset).balanceOf(address(this)) < committed[asset] + amount) revert InventoryCommitted();
			IERC20(asset).transfer(address(IComptroller(comptroller).vault()), amount);
		} else {
			revert UnknownAction();
		}
	}

	function _hold(address asset) internal {
		if (isHeld[asset]) return;
		isHeld[asset] = true;
		heldAssets.push(asset);
	}
}

contract MockEscrowPositionFactory is IExternalPositionTypeFactory {
	function deployPosition(address comptroller, bytes calldata) external returns (address) {
		return address(new MockEscrowPosition(comptroller));
	}
}
