// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IDerivativePriceFeed} from '../interfaces/IDerivativePriceFeed.sol';

/// @title ERC4626ExitValueFeed
/// @notice Derivative feed for ERC-4626 vaults that charge an EXIT FEE: shares are valued at
///         what redeeming them actually pays (`previewRedeem`, fee deducted), not at the
///         fee-free `convertToAssets` that ERC4626PriceFeed uses. Marking at convertToAssets
///         would let redeeming investors be paid a value the vault never honours, at the
///         expense of those who stay.
///         Built for Veranta's LP vault (avUSDC, Base 0x9447…E7f9): a flat 1.5% withdrawal fee
///         (collateralHealthFee 1500 / 1e5; previewRedeem 1.3486 vs convertToAssets 1.3688 per
///         share, read 2026-09-24), no deposit fee.
/// @dev Register only vaults whose previewRedeem is a pure function of accounting (EIP-4626:
///      it excludes caller-specific limits such as utilization-gated maxRedeem — those gate
///      WHEN a fund can exit, the fee gates HOW MUCH it gets). The fund's NAV shows the fee
///      from the moment it deposits, and earns it back as the share price accrues.
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
