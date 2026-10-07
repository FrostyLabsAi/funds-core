// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IExternalPosition} from '../../src/interfaces/IExternalPosition.sol';
import {IExternalPositionTypeFactory} from '../../src/interfaces/IExternalPositionTypeFactory.sol';

interface IVaultOf {
	function vault() external view returns (address);
}

/// @dev A position worth `locked + idle` USDC, with the perp account's action numbers: 0 locks USDC
///      the fund sent here (not risk-reducing), 1 closes part of the locked value into idle USDC,
///      6 returns idle USDC to the fund's vault (both risk-reducing). `rejectCloses` makes action 1
///      revert, as a venue that refuses a close would; `closeGas` makes it burn that much gas, and
///      `valuationGas` makes each getManagedAssets read do so (a perp account walking every pair).
contract MockUnwindPosition is IExternalPosition {
	address public immutable comptroller;
	IERC20 public immutable usdc;
	uint256 public locked;
	bool public rejectCloses;
	uint256 public closeGas;
	uint256 public valuationGas;

	error OnlyComptroller();
	error CloseRejected();

	constructor(address comptroller_, IERC20 usdc_) {
		comptroller = comptroller_;
		usdc = usdc_;
	}

	function setRejectCloses(bool reject) external {
		rejectCloses = reject;
	}

	function setCloseGas(uint256 gas_) external {
		closeGas = gas_;
	}

	function setValuationGas(uint256 gas_) external {
		valuationGas = gas_;
	}

	function idle() public view returns (uint256) {
		return usdc.balanceOf(address(this)) - locked;
	}

	function getManagedAssets() external view returns (address[] memory assets, uint256[] memory amounts) {
		uint256 start = gasleft();
		while (start - gasleft() < valuationGas) {}
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
		if (msg.sender != comptroller) revert OnlyComptroller();
		(uint8 action, bytes memory args) = abi.decode(actionData, (uint8, bytes));
		uint256 amount = abi.decode(args, (uint256));
		if (action == 0) {
			locked += amount;
		} else if (action == 1) {
			if (rejectCloses) revert CloseRejected();
			uint256 start = gasleft();
			while (start - gasleft() < closeGas) {}
			locked -= amount > locked ? locked : amount;
		} else if (action == 6) {
			uint256 available = idle();
			usdc.transfer(IVaultOf(comptroller).vault(), amount > available ? available : amount);
		}
	}
}

contract MockUnwindPositionFactory is IExternalPositionTypeFactory {
	IERC20 public immutable usdc;

	constructor(IERC20 usdc_) {
		usdc = usdc_;
	}

	function deployPosition(address comptroller, bytes calldata) external returns (address) {
		return address(new MockUnwindPosition(comptroller, usdc));
	}
}
