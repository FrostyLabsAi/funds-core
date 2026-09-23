// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Comptroller} from './Comptroller.sol';
import {Shares} from '../fund/Shares.sol';
import {Vault} from '../fund/Vault.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';

/// @title Fund component deployers
/// @notice Creation bytecode lives here instead of inside FundFactory, keeping every
///         contract under the EIP-170 runtime limit — the same split melon-v1's
///         FundFactory and frosty-core's BondMarketDeployers use for the same reason.
/// @dev Both deployers pass THEIR CALLER through as the components' `factory` authority:
///      when the real FundFactory calls them, components trust the real FundFactory.
///      Anyone else calling a deployer mints components wired to themselves — harmless,
///      since only factory-registered funds exist in the registry or reserve names.

contract ComptrollerDeployer {
	function deploy(
		address fundOwner,
		IERC20 denominationAsset,
		IValueInterpreter valueInterpreter,
		Comptroller.FeeConfig calldata feeConfig,
		uint256 sharesActionTimelock,
		uint256 minRequestDuration,
		uint256 executionWindow,
		bool allowRiskyAssets
	) external returns (Comptroller comptroller) {
		comptroller = new Comptroller(
			msg.sender,
			fundOwner,
			denominationAsset,
			valueInterpreter,
			feeConfig,
			sharesActionTimelock,
			minRequestDuration,
			executionWindow,
			allowRiskyAssets
		);
	}
}

contract SharesVaultDeployer {
	function deploy(string calldata name, string calldata symbol, address comptroller)
		external
		returns (Shares shares, Vault vault)
	{
		shares = new Shares(name, symbol, comptroller, msg.sender);
		vault = new Vault(comptroller, msg.sender);
	}
}
