// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {Vault} from '../fund/Vault.sol';
import {FundValuation} from './FundValuation.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {IPolicy} from '../interfaces/IPolicy.sol';

/// @title ComptrollerV3Lib
/// @notice ComptrollerV3's payout loops, moved out so the comptroller fits EIP-170 with the
///         redemption-queue hooks (founder 2026-10-06; V2 had 603 bytes to spare). External
///         functions run by DELEGATECALL in the comptroller's context, as FundValuation's do.
library ComptrollerV3Lib {
	using EnumerableSet for EnumerableSet.AddressSet;

	/// @dev The comptroller's tracked-asset rules, passed in (its immutables).
	struct Tracking {
		IValueInterpreter valueInterpreter;
		bool allowRiskyAssets;
		uint256 maxTrackedAssets;
	}

	event TrackedAssetAdded(address indexed asset);

	error AssetNotSupported(address asset);
	error RiskyAssetsNotAllowed(address asset);
	error TrackedAssetsLimitReached();
	error MinIncomingAmountNotMet(address asset, uint256 received, uint256 minAmount);

	/// @notice Shared by explicit tracking and auto-tracking. Idempotent.
	function trackAsset(EnumerableSet.AddressSet storage trackedAssets, Tracking memory rules, address asset) public {
		if (trackedAssets.contains(asset)) return;
		if (!rules.valueInterpreter.isSupportedAsset(asset)) revert AssetNotSupported(asset);
		if (rules.valueInterpreter.isZeroPricedAsset(asset) && !rules.allowRiskyAssets) revert RiskyAssetsNotAllowed(asset);
		if (trackedAssets.length() >= rules.maxTrackedAssets) revert TrackedAssetsLimitReached();
		trackedAssets.add(asset);
		emit TrackedAssetAdded(asset);
	}

	function vaultBalances(address vault, address[] memory assets) external view returns (uint256[] memory balances) {
		balances = new uint256[](assets.length);
		for (uint256 i; i < assets.length; ++i) {
			balances[i] = IERC20(assets[i]).balanceOf(vault);
		}
	}

	/// @notice Values what the vault actually received and auto-tracks it; duplicates are skipped
	///         (counting a delta twice would hide losses).
	function receivedValue(
		EnumerableSet.AddressSet storage trackedAssets,
		Tracking memory rules,
		address vault,
		address denominationAsset,
		address[] memory assets,
		uint256[] memory balancesBefore,
		bool priced
	) external returns (uint256 value) {
		for (uint256 i; i < assets.length; ++i) {
			trackAsset(trackedAssets, rules, assets[i]);
			if (!priced) continue;
			bool duplicate;
			for (uint256 j; j < i; ++j) {
				if (assets[j] == assets[i]) {
					duplicate = true;
					break;
				}
			}
			if (duplicate) continue;
			uint256 received = IERC20(assets[i]).balanceOf(vault) - balancesBefore[i];
			if (received > 0) {
				value += rules.valueInterpreter.calcCanonicalAssetValue(assets[i], received, denominationAsset);
			}
		}
	}

	/// @notice Pay `amounts` of `assets` from the vault to `to`; a pool-priced token's cost basis
	///         leaves with its units (FundValuation.reduceCostBasis).
	function payOut(
		mapping(address => uint256) storage costBasis,
		Vault vault,
		address to,
		address[] memory assets,
		uint256[] memory amounts
	) external {
		for (uint256 i; i < assets.length; ++i) {
			if (amounts[i] == 0) continue;
			FundValuation.reduceCostBasis(costBasis, assets[i], amounts[i], IERC20(assets[i]).balanceOf(address(vault)));
			vault.withdraw(assets[i], to, amounts[i]);
		}
	}

	/// @notice The redeemer's pro-rata units of every tracked asset, zero for `assetsToSkip`.
	function inKindSlice(
		EnumerableSet.AddressSet storage trackedAssets,
		address vault,
		uint256 sharesAmount,
		uint256 totalSupply,
		address[] memory assetsToSkip
	) external view returns (address[] memory assets, uint256[] memory amounts) {
		assets = trackedAssets.values();
		amounts = new uint256[](assets.length);
		for (uint256 i; i < assets.length; ++i) {
			bool skip;
			for (uint256 j; j < assetsToSkip.length; ++j) {
				if (assetsToSkip[j] == assets[i]) {
					skip = true;
					break;
				}
			}
			if (!skip) amounts[i] = Math.mulDiv(IERC20(assets[i]).balanceOf(vault), sharesAmount, totalSupply);
		}
	}

	/// @notice A policy may only attach to hooks it implements (else it bricks or silently no-ops).
	function implementsHook(address policy, IPolicy.PolicyHook hook) external view returns (bool) {
		IPolicy.PolicyHook[] memory implemented = IPolicy(policy).implementedHooks();
		for (uint256 i; i < implemented.length; ++i) {
			if (implemented[i] == hook) return true;
		}
		return false;
	}

	/// @notice The tolerant valuation redeemShares and the queue's settlement price from, with the
	///         payout snapshot RedemptionQueue decodes (assets, balances, values, inKind,
	///         positionsValue) encoded from the same pass (2026-10-07: one valuation per settlement).
	function redemptionValue(
		EnumerableSet.AddressSet storage trackedAssets,
		EnumerableSet.AddressSet storage externalPositions,
		mapping(address => uint256) storage costBasis,
		FundValuation.Context memory ctx
	) external returns (FundValuation.Valuation memory v, bytes memory snapshot) {
		FundValuation.Detail memory d;
		(v, d) = FundValuation.valueDetailed(trackedAssets, externalPositions, costBasis, ctx, true);
		snapshot = abi.encode(v.assets, d.balances, d.values, v.inKind, d.positionsValue);
	}

	/// @notice Sends each amount from the vault to `to`: a trade's spend, a position's funding
	///         (here for EIP-170 room, 2026-10-07).
	function withdrawAll(Vault vault, address to, address[] memory assets, uint256[] memory amounts) external {
		for (uint256 i; i < assets.length; ++i) {
			vault.withdraw(assets[i], to, amounts[i]);
		}
	}

	/// @notice Reconfiguration: carry the prior fund's tracked assets over.
	function copyTracked(EnumerableSet.AddressSet storage trackedAssets, address[] memory priorTracked) external {
		for (uint256 i; i < priorTracked.length; ++i) {
			trackedAssets.add(priorTracked[i]);
		}
	}

	/// @notice A trade's incoming amounts, measured as vault balance deltas (never adapter claims),
	///         each at least its minimum, each auto-tracked.
	function receivedAmounts(
		EnumerableSet.AddressSet storage trackedAssets,
		Tracking memory rules,
		address vault,
		address[] memory incomingAssets,
		uint256[] memory balancesBefore,
		uint256[] memory minIncomingAmounts
	) external returns (uint256[] memory incomingAmounts) {
		incomingAmounts = new uint256[](incomingAssets.length);
		for (uint256 i; i < incomingAssets.length; ++i) {
			uint256 received = IERC20(incomingAssets[i]).balanceOf(vault) - balancesBefore[i];
			if (received < minIncomingAmounts[i]) revert MinIncomingAmountNotMet(incomingAssets[i], received, minIncomingAmounts[i]);
			incomingAmounts[i] = received;
			trackAsset(trackedAssets, rules, incomingAssets[i]);
		}
	}
}
