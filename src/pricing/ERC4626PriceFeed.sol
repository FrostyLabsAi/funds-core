// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IDerivativePriceFeed} from '../interfaces/IDerivativePriceFeed.sol';

/// @title ERC4626PriceFeed
/// @notice Generic derivative feed for ERC-4626 vault shares: one deployed instance serves
///         every registered 4626 vault. shares → convertToAssets → underlying amount.
/// @dev Stateless; curation happens where it belongs — the ValueInterpreter's owner decides
///      WHICH 4626 vaults get registered as derivatives. Register only audited vaults whose
///      `convertToAssets` is manipulation-resistant (spec/topics/position-pricing.md warns
///      about exactly this class: the feed trusts the vault's own accounting — a vault
///      vulnerable to donation/rounding attacks would mis-price fund shares).
///      `convertToAssets` (not previewRedeem) per EIP-4626: MUST NOT revert, excludes
///      caller-dependent exit fees. Vaults with material exit fees deserve a bespoke feed.
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
