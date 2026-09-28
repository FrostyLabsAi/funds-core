// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IIntegrationAdapter} from '../interfaces/IIntegrationAdapter.sol';

/// @title ERC4626Adapter
/// @notice Deposit/redeem adapter for any ERC-4626 vault. A received share must be a
///         registered ValueInterpreter derivative, or the trade reverts at auto-tracking.
/// @dev integrationData = abi.encode(action, vault, amount, minOut)
///      action 0 (Deposit): amount = underlying assets in, minOut = min shares back
///      action 1 (Redeem):  amount = shares in,            minOut = min assets back
///      Outputs go straight to the fund's Vault; the Comptroller checks amounts by balance delta.
contract ERC4626Adapter is IIntegrationAdapter {
	using SafeERC20 for IERC20;

	uint8 public constant ACTION_DEPOSIT = 0;
	uint8 public constant ACTION_REDEEM = 1;

	error UnknownAction();

	/// @inheritdoc IIntegrationAdapter
	function parseAssetsForAction(bytes calldata integrationData)
		external
		view
		returns (
			address[] memory spendAssets,
			uint256[] memory spendAmounts,
			address[] memory incomingAssets,
			uint256[] memory minIncomingAmounts
		)
	{
		(uint8 action, address vault, uint256 amount, uint256 minOut) =
			abi.decode(integrationData, (uint8, address, uint256, uint256));
		address underlying = IERC4626(vault).asset();

		spendAssets = new address[](1);
		spendAmounts = new uint256[](1);
		incomingAssets = new address[](1);
		minIncomingAmounts = new uint256[](1);
		spendAmounts[0] = amount;
		minIncomingAmounts[0] = minOut;

		if (action == ACTION_DEPOSIT) {
			spendAssets[0] = underlying;
			incomingAssets[0] = vault; // the share token is the vault contract
		} else if (action == ACTION_REDEEM) {
			spendAssets[0] = vault;
			incomingAssets[0] = underlying;
		} else {
			revert UnknownAction();
		}
	}

	/// @inheritdoc IIntegrationAdapter
	function executeAction(address vault, bytes calldata integrationData) external {
		(uint8 action, address target4626, uint256 amount,) =
			abi.decode(integrationData, (uint8, address, uint256, uint256));

		if (action == ACTION_DEPOSIT) {
			IERC20(IERC4626(target4626).asset()).forceApprove(target4626, amount);
			IERC4626(target4626).deposit(amount, vault); // shares minted straight to the fund's Vault
		} else if (action == ACTION_REDEEM) {
			// shares arrived here as the spend asset; the underlying goes to the fund's Vault
			IERC4626(target4626).redeem(amount, vault, address(this));
		} else {
			revert UnknownAction();
		}
	}
}
