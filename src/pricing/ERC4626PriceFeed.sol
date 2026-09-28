// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IDerivativePriceFeed} from '../interfaces/IDerivativePriceFeed.sol';

/// @title ERC4626PriceFeed
/// @notice Derivative feed for ERC-4626 vault shares (one instance serves every registered vault):
///         shares → convertToAssets → underlying.
/// @dev Trusts the vault's own accounting: register only audited vaults whose convertToAssets resists
///      donation/rounding manipulation. Vaults with a material exit fee use ERC4626ExitValueFeed.
contract ERC4626PriceFeed is IDerivativePriceFeed {
	/// @inheritdoc IDerivativePriceFeed
	function calcUnderlyingValues(address derivative, uint256 amount)
		external
		view
		returns (address[] memory underlyings, uint256[] memory underlyingAmounts)
	{
		underlyings = new address[](1);
		underlyings[0] = IERC4626(derivative).asset();
		underlyingAmounts = new uint256[](1);
		underlyingAmounts[0] = IERC4626(derivative).convertToAssets(amount);
	}

	/// @inheritdoc IDerivativePriceFeed
	function isSupportedAsset(address asset) external view returns (bool) {
		(bool success, bytes memory returnData) = asset.staticcall(abi.encodeCall(IERC4626.asset, ()));
		return success && returnData.length == 32;
	}
}
