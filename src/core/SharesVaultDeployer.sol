// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Shares} from '../fund/Shares.sol';
import {Vault} from '../fund/Vault.sol';
import {IShares} from '../interfaces/IShares.sol';
import {IVault} from '../interfaces/IVault.sol';
import {ISharesVaultDeployer} from '../interfaces/ISharesVaultDeployer.sol';

/// @title SharesVaultDeployer
/// @notice Holds Shares and Vault creation code outside FundFactory to keep it under EIP-170.
/// @dev The caller becomes both components' `factory`. Anyone else calling it gets components wired to themselves —
///      harmless, they are never in the registry.
contract SharesVaultDeployer is ISharesVaultDeployer {
	function deploy(string calldata name, string calldata symbol, address comptroller)
		external
		returns (IShares shares, IVault vault)
	{
		shares = new Shares(name, symbol, comptroller, msg.sender);
		vault = new Vault(comptroller, msg.sender);
	}
}
