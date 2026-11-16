// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IComptroller} from './IComptroller.sol';
import {IValueInterpreter} from './IValueInterpreter.sol';

/// @title IComptrollerDeployer
/// @notice Comptroller deployer used by FundFactory; the caller becomes the Comptroller's `factory`.
interface IComptrollerDeployer {
	function deploy(
		address fundOwner,
		IERC20 denominationAsset,
		IValueInterpreter valueInterpreter,
		IComptroller.FeeConfig calldata feeConfig,
		uint256 sharesActionTimelock,
		uint256 minRequestDuration,
		uint256 executionWindow,
		bool allowRiskyAssets
	) external returns (IComptroller comptroller);
}
