// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IDerivativePriceFeed} from '../interfaces/IDerivativePriceFeed.sol';

/// @title ERC4626ExitValueFeed
/// @notice Derivative feed for ERC-4626 vaults with an exit fee: shares are valued at `previewRedeem`
///         (what redeeming pays), not the fee-free `convertToAssets`, so redeemers are never paid a
///         value the vault does not honour at the expense of those who stay.
/// @dev Register only vaults whose previewRedeem depends on accounting alone (no caller-specific
///      limits). Built for Veranta's LP vault (avUSDC, 1.5% withdrawal fee).
contract ERC4626ExitValueFeed is IDerivativePriceFeed {
	/// @inheritdoc IDerivativePriceFeed
	function calcUnderlyingValues(address derivative, uint256 amount)
		external
		view
		returns (address[] memory underlyings, uint256[] memory underlyingAmounts)
	{
		underlyings = new address[](1);
		underlyings[0] = IERC4626(derivative).asset();
		underlyingAmounts = new uint256[](1);
		underlyingAmounts[0] = IERC4626(derivative).previewRedeem(amount);
	}

	/// @inheritdoc IDerivativePriceFeed
	function isSupportedAsset(address asset) external view returns (bool) {
		(bool success, bytes memory returnData) = asset.staticcall(abi.encodeCall(IERC4626.asset, ()));
		return success && returnData.length == 32;
	}
}
