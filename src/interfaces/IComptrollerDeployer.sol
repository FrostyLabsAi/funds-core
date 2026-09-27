// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Comptroller} from '../core/Comptroller.sol';
import {IValueInterpreter} from './IValueInterpreter.sol';

/// @title IComptrollerDeployer
/// @notice What FundFactory needs from a Comptroller deployer. The deployer passes ITS CALLER
///         through as the Comptroller's `factory` authority (see FundComponentDeployers.sol).
interface IComptrollerDeployer {
	function deploy(
		address fundOwner,
		IERC20 denominationAsset,
		IValueInterpreter valueInterpreter,
		Comptroller.FeeConfig calldata feeConfig,
		uint256 sharesActionTimelock,
		uint256 minRequestDuration,
		uint256 executionWindow,
		bool allowRiskyAssets
	) external returns (Comptroller comptroller);
}
