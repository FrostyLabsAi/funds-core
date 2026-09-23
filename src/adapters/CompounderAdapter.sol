// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IIntegrationAdapter} from '../interfaces/IIntegrationAdapter.sol';
import {FrostyCompounder} from '../yield/FrostyCompounder.sol';

/// @title CompounderAdapter
/// @notice Funds deposit into / withdraw from FrostyCompounder vaults through their
///         normal callOnIntegration rails (mandate-gated, GAV-priced via the
///         CompounderPriceFeed). One instance serves every compounder.
/// @dev integrationData = abi.encode(action, compounder, a, b, c)
///      action 0 (Deposit):  a = amount0Desired, b = amount1Desired, c = minShares
///      action 1 (Withdraw): a = shares,         b = amount0Min,     c = amount1Min
///      Deposits pull both tokens at the live pool ratio; whatever the ratio doesn't
///      take is forwarded straight back to the fund's Vault (both tokens are already
///      tracked assets, so refunds land clean in GAV).
contract CompounderAdapter is IIntegrationAdapter {
	using SafeERC20 for IERC20;

	uint8 public constant ACTION_DEPOSIT = 0;
	uint8 public constant ACTION_WITHDRAW = 1;

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
		(uint8 action, address compounder, uint256 a, uint256 b, uint256 c) =
			abi.decode(integrationData, (uint8, address, uint256, uint256, uint256));
		address token0 = address(FrostyCompounder(compounder).token0());
		address token1 = address(FrostyCompounder(compounder).token1());

		if (action == ACTION_DEPOSIT) {
			spendAssets = new address[](2);
			spendAssets[0] = token0;
			spendAssets[1] = token1;
			spendAmounts = new uint256[](2);
			spendAmounts[0] = a;
			spendAmounts[1] = b;
			incomingAssets = new address[](1);
			incomingAssets[0] = compounder;
			minIncomingAmounts = new uint256[](1);
			minIncomingAmounts[0] = c;
		} else if (action == ACTION_WITHDRAW) {
			spendAssets = new address[](1);
			spendAssets[0] = compounder;
			spendAmounts = new uint256[](1);
			spendAmounts[0] = a;
			incomingAssets = new address[](2);
			incomingAssets[0] = token0;
			incomingAssets[1] = token1;
			minIncomingAmounts = new uint256[](2);
			minIncomingAmounts[0] = b;
			minIncomingAmounts[1] = c;
		} else {
			revert UnknownAction();
		}
	}

	/// @inheritdoc IIntegrationAdapter
	function executeAction(address vault, bytes calldata integrationData) external {
		(uint8 action, address compounderAddr, uint256 a, uint256 b, uint256 c) =
			abi.decode(integrationData, (uint8, address, uint256, uint256, uint256));
		FrostyCompounder compounder = FrostyCompounder(compounderAddr);
		IERC20 token0 = compounder.token0();
		IERC20 token1 = compounder.token1();

		if (action == ACTION_DEPOSIT) {
			token0.forceApprove(compounderAddr, a);
			token1.forceApprove(compounderAddr, b);
			// c = min shares, enforced BOTH here (the compounder refuses a skewed mint)
			// and by the Comptroller's balance-delta check on the incoming shares
			uint256 shares = compounder.deposit(a, b, 0, 0, c);
			IERC20(compounderAddr).safeTransfer(vault, shares);
			// The pool ratio decides what's used — refund the rest to the fund's Vault
			uint256 left0 = token0.balanceOf(address(this));
			uint256 left1 = token1.balanceOf(address(this));
			if (left0 > 0) token0.safeTransfer(vault, left0);
			if (left1 > 0) token1.safeTransfer(vault, left1);
		} else if (action == ACTION_WITHDRAW) {
			// Both mins ride the Comptroller's balance-delta min-incoming checks (b, c)
			compounder.withdraw(a, 0, 0);
			token0.safeTransfer(vault, token0.balanceOf(address(this)));
			token1.safeTransfer(vault, token1.balanceOf(address(this)));
		} else {
			revert UnknownAction();
		}
	}
}
