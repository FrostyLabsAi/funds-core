// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IShares} from './IShares.sol';
import {IVault} from './IVault.sol';

/// @title ISharesVaultDeployer
/// @notice Deploys a new fund's Shares and Vault for FundFactory; the caller becomes both components' `factory`.
interface ISharesVaultDeployer {
	function deploy(string calldata name, string calldata symbol, address comptroller)
		external
		returns (IShares shares, IVault vault);
}
