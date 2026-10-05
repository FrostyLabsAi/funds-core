// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {IExternalPosition} from '../interfaces/IExternalPosition.sol';
import {PoolPriceRegistrar} from '../pricing/PoolPriceRegistrar.sol';

/// @title FundValuation
/// @notice ComptrollerV2's pricing, as a linked library (external functions run by DELEGATECALL
///         on the fund's own storage) so the fund contract stays under EIP-170.
library FundValuation {
	using EnumerableSet for EnumerableSet.AddressSet;

	/// @dev The fund's fixed wiring.
	struct Context {
		IValueInterpreter valueInterpreter;
		PoolPriceRegistrar registrar;
		address vault;
		address denominationAsset;
	}

	/// @dev Everything the fund's pricing needs, from one pass over the holdings.
	struct Valuation {
		uint256 gav; // every holding at its price: deposits are priced on it
		uint256 feeGav; // pool-priced tokens at the lower of value and cost basis
		uint256 cashValue; // readable, not pool-priced holdings + positions: what redeemShares pays in cash
		bool complete; // every price was read
		address[] assets;
		bool[] inKind; // pool-priced, or its price can't be read now
	}

	/// @dev Unrealized long-tail gains don't count toward the fee GAV until sold; losses count at
	///      once. A price that can't be read bubbles its revert unless `tolerant`, which marks the
	///      holding in kind and the valuation incomplete instead. Positions always revert.
	function value(
		EnumerableSet.AddressSet storage trackedAssets,
		EnumerableSet.AddressSet storage externalPositions,
		mapping(address => uint256) storage costBasis,
		Context memory ctx,
		bool tolerant
	) external returns (Valuation memory v) {
		v.assets = trackedAssets.values();
		v.inKind = new bool[](v.assets.length);
		v.complete = true;
		for (uint256 i; i < v.assets.length; ++i) {
			address asset = v.assets[i];
			uint256 balance = IERC20(asset).balanceOf(ctx.vault);
			if (balance == 0) continue;
			bool poolPriced = ctx.registrar.poolPricedAdapter(asset) != address(0);
			v.inKind[i] = poolPriced;
			try ctx.valueInterpreter.calcCanonicalAssetValue(asset, balance, ctx.denominationAsset) returns (
				uint256 assetValue
			) {
				v.gav += assetValue;
				v.feeGav += poolPriced ? Math.min(assetValue, costBasis[asset]) : assetValue;
				if (!poolPriced) v.cashValue += assetValue;
			} catch (bytes memory reason) {
				if (!tolerant) {
					assembly ('memory-safe') {
						revert(add(reason, 32), mload(reason))
					}
				}
				v.inKind[i] = true;
				v.complete = false;
			}
		}

		uint256 positionCount = externalPositions.length();
		for (uint256 i; i < positionCount; ++i) {
			uint256 positionsValue = positionValue(IExternalPosition(externalPositions.at(i)), ctx);
			v.gav += positionsValue;
			v.feeGav += positionsValue;
			v.cashValue += positionsValue;
		}
	}

	/// @notice Keep long-tail cost bases in step with a trade: bought pool-priced units add their
	///         value at the trade; units that left the vault take their share of the basis.
	function followTrade(
		mapping(address => uint256) storage costBasis,
		Context memory ctx,
		address[] memory spendAssets,
		uint256[] memory spendBefore,
		address[] memory incomingAssets,
		uint256[] memory incomingAmounts
	) external {
		for (uint256 i; i < incomingAssets.length; ++i) {
			if (incomingAmounts[i] == 0 || ctx.registrar.poolPricedAdapter(incomingAssets[i]) == address(0)) continue;
			costBasis[incomingAssets[i]] +=
				ctx.valueInterpreter.calcCanonicalAssetValue(incomingAssets[i], incomingAmounts[i], ctx.denominationAsset);
		}
		for (uint256 i; i < spendAssets.length; ++i) {
			uint256 left = IERC20(spendAssets[i]).balanceOf(ctx.vault);
			if (left < spendBefore[i]) reduceCostBasis(costBasis, spendAssets[i], spendBefore[i] - left, spendBefore[i]);
		}
	}

	/// @dev `units` of a `balance` left the vault: the cost basis shrinks in proportion.
	function reduceCostBasis(mapping(address => uint256) storage costBasis, address asset, uint256 units, uint256 balance)
		internal
	{
		uint256 basis = costBasis[asset];
		if (basis == 0 || units == 0) return;
		costBasis[asset] = basis - Math.mulDiv(basis, units, balance);
	}

	/// @notice The total value of `amounts` of `assets` (what leaves the vault for a position).
	function assetsValue(address[] memory assets, uint256[] memory amounts, Context memory ctx)
		external
		returns (uint256 total)
	{
		for (uint256 i; i < assets.length; ++i) {
			if (amounts[i] > 0) {
				total += ctx.valueInterpreter.calcCanonicalAssetValue(assets[i], amounts[i], ctx.denominationAsset);
			}
		}
	}

	/// @notice A position's managed assets minus its debt, floored at zero: a position's liability
	///         is limited to the position itself.
	function positionValue(IExternalPosition position, Context memory ctx) public returns (uint256) {
		(address[] memory managedAssets, uint256[] memory managedAmounts) = position.getManagedAssets();
		(address[] memory debtAssets, uint256[] memory debtAmounts) = position.getDebtAssets();

		uint256 managed;
		for (uint256 i; i < managedAssets.length; ++i) {
			if (managedAmounts[i] == 0) continue;
			managed += ctx.valueInterpreter.calcCanonicalAssetValue(managedAssets[i], managedAmounts[i], ctx.denominationAsset);
		}

		uint256 debt;
		for (uint256 i; i < debtAssets.length; ++i) {
			if (debtAmounts[i] == 0) continue;
			debt += ctx.valueInterpreter.calcCanonicalAssetValue(debtAssets[i], debtAmounts[i], ctx.denominationAsset);
		}

		return managed > debt ? managed - debt : 0;
	}
}
