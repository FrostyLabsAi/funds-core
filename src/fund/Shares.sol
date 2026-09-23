// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

interface ISharesTransferValidator {
	function validateSharesTransfer(address from, address to, uint256 amount) external;
}

/// @title Shares
/// @notice Fund share token. Mint/burn only by the fund's Comptroller; transfers are validated
///         by the Comptroller (sharesActionTimelock + PreTransferShares policies).
/// @dev Successor to melon-v1 Shares (melon-v1/src/fund/shares/Shares.sol). 18 decimals,
///      per spec/topics/fund-holdings.md#shares.
contract Shares is ERC20 {
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

	constructor(string memory name_, string memory symbol_, address comptroller_, address factory_)
		ERC20(name_, symbol_)
	{
		if (comptroller_ == address(0) || factory_ == address(0)) revert ZeroAddress();
		factory = factory_;
		comptroller = comptroller_;
	}

	/// @dev Reconfiguration support: the factory swaps in a fund's new Comptroller
	///      (spec/topics/creation-migration-reconfiguration.md). The old Comptroller loses
	///      all mint/burn rights atomically.
	function migrateComptroller(address newComptroller) external {
		if (msg.sender != factory) revert OnlyFactory();
		if (newComptroller == address(0)) revert ZeroAddress();
		emit ComptrollerMigrated(comptroller, newComptroller);
		comptroller = newComptroller;
	}

	function mint(address to, uint256 amount) external onlyComptroller {
		_mint(to, amount);
	}

	function burn(address from, uint256 amount) external onlyComptroller {
		_burn(from, amount);
	}

	/// @dev Transfers (not mints/burns) pass through the Comptroller's validation.
	function _update(address from, address to, uint256 value) internal override {
		if (from != address(0) && to != address(0)) {
			ISharesTransferValidator(comptroller).validateSharesTransfer(from, to, value);
		}
		super._update(from, to, value);
	}
}
