// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IVault} from '../interfaces/IVault.sol';

/// @title Vault
/// @notice Dumb custody: holds the fund's ERC20 assets and releases them only at the Comptroller's call.
/// @dev Asset tracking lives in the Comptroller, not here.
contract Vault is IVault {
	using SafeERC20 for IERC20;

	address public immutable factory;
	address public comptroller;

	event ComptrollerMigrated(address indexed oldComptroller, address indexed newComptroller);

	error OnlyComptroller();
	error OnlyFactory();
	error ZeroAddress();

	modifier onlyComptroller() {
		if (msg.sender != comptroller) revert OnlyComptroller();
		_;
	}

	constructor(address comptroller_, address factory_) {
		if (comptroller_ == address(0) || factory_ == address(0)) revert ZeroAddress();
		factory = factory_;
		comptroller = comptroller_;
	}

	/// @dev Reconfiguration support: custody follows the fund's current Comptroller.
	function migrateComptroller(address newComptroller) external {
		if (msg.sender != factory) revert OnlyFactory();
		if (newComptroller == address(0)) revert ZeroAddress();
		emit ComptrollerMigrated(comptroller, newComptroller);
		comptroller = newComptroller;
	}

	function withdraw(address asset, address to, uint256 amount) external onlyComptroller {
		IERC20(asset).safeTransfer(to, amount);
	}
}
