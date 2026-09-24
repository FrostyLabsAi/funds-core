// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IPolicy} from '../interfaces/IPolicy.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {Comptroller} from '../core/Comptroller.sol';
import {TwapListingRegistry} from '../pricing/TwapListingRegistry.sol';
import {TwapAggregatorAdapter} from '../pricing/TwapAggregatorAdapter.sol';

/// @title TwapExposurePolicy
/// @notice The limits every fund lives within when it holds TWAP-priced assets
///         (docs/design/twap-oracle.md, founder decisions 2026-09-23/24):
///         - at most 20% of GAV across all TWAP-priced holdings;
///         - per asset, at most a share of its pool's ±10% depth: 10% while the pool is under
///           $250k, 50% at or above — so a position always stays small enough to sell back
///           into its own pool;
///         - a DELISTED asset (its pool under the $50k floor for 72h — TwapListingRegistry)
///           pauses NEW deposits into any fund still holding it, until the fund sells it.
///           Redemptions and exits are never paused by this policy.
/// @dev Caps are checked on BUYS only — a trade whose incoming assets include a TWAP-priced
///      asset. A sale is never blocked, even when the fund is over a cap because the pool
///      thinned after it bought: exits must always work.
///      DEGEN funds (`allowRiskyAssets`, investors opted in) skip the caps — a fund may take
///      over a token's float ("community takeover") there, with NAV relying on a pool it may
///      itself provide. The deposit pause applies to every fund.
///      Counts the fund vault's tracked holdings; TWAP assets held inside external positions
///      (e.g. an LP) are not counted here.
contract TwapExposurePolicy is IPolicy {
	uint256 public constant BPS = 10_000;
	uint256 public constant MAX_GAV_BPS = 2_000;
	uint256 public constant LARGE_POOL_USD = 250_000;
	uint256 public constant SMALL_POOL_CAP_BPS = 1_000;
	uint256 public constant LARGE_POOL_CAP_BPS = 5_000;

	TwapListingRegistry public immutable registry;

	error TwapShareOfGavExceeded(uint256 shareBps);
	error PoolShareExceeded(address asset, uint256 holdingUsd18, uint256 capUsd18);
	error BuyingDelistedAsset(address asset);
	error DepositsPausedDelistedHolding(address asset);
	error UnsupportedHook(PolicyHook hook);

	constructor(TwapListingRegistry registry_) {
		registry = registry_;
	}

	/// @inheritdoc IPolicy
	function implementedHooks() external pure returns (PolicyHook[] memory hooks) {
		hooks = new PolicyHook[](2);
		hooks[0] = PolicyHook.PostCallOnIntegration;
		hooks[1] = PolicyHook.PostDepositRequest;
	}

	/// @inheritdoc IPolicy
	function validate(PolicyHook hook, bytes calldata validationData) external {
		Comptroller comptroller = Comptroller(msg.sender);
		if (hook == PolicyHook.PostDepositRequest) {
			_checkNoDelistedHolding(comptroller);
		} else if (hook == PolicyHook.PostCallOnIntegration) {
			(,,, address[] memory incomingAssets,) =
				abi.decode(validationData, (address, address[], uint256[], address[], uint256[]));
			_checkBuy(comptroller, incomingAssets);
		} else {
			revert UnsupportedHook(hook);
		}
	}

	function _checkNoDelistedHolding(Comptroller comptroller) internal view {
		address[] memory held = comptroller.getTrackedAssets();
		address vault = address(comptroller.vault());
		for (uint256 i; i < held.length; ++i) {
			address asset = held[i];
			if (registry.isDelisted(asset) && registry.isTwapPriced(asset) && IERC20(asset).balanceOf(vault) > 0) {
				revert DepositsPausedDelistedHolding(asset);
			}
		}
	}

	function _checkBuy(Comptroller comptroller, address[] memory incomingAssets) internal {
		if (comptroller.allowRiskyAssets()) return;

		bool boughtTwap;
		for (uint256 i; i < incomingAssets.length; ++i) {
			address asset = incomingAssets[i];
			if (!registry.isTwapPriced(asset)) continue;
			if (registry.isDelisted(asset)) revert BuyingDelistedAsset(asset);
			boughtTwap = true;
			_checkPoolShare(comptroller, asset);
		}
		if (boughtTwap) _checkShareOfGav(comptroller);
	}

	/// @dev The fund's holding, in USD, against its pool's ±10% depth.
	function _checkPoolShare(Comptroller comptroller, address asset) internal view {
		IValueInterpreter vi = comptroller.valueInterpreter();
		uint256 balance = IERC20(asset).balanceOf(address(comptroller.vault()));
		uint256 holdingUsd18 = Math.mulDiv(vi.calcUsdRate(asset), balance, 10 ** IERC20Metadata(asset).decimals());
		uint256 depthUsd18 = TwapAggregatorAdapter(registry.adapterOf(asset)).poolDepthUsd();
		uint256 capBps = depthUsd18 < LARGE_POOL_USD * 1e18 ? SMALL_POOL_CAP_BPS : LARGE_POOL_CAP_BPS;
		uint256 capUsd18 = Math.mulDiv(depthUsd18, capBps, BPS);
		if (holdingUsd18 > capUsd18) revert PoolShareExceeded(asset, holdingUsd18, capUsd18);
	}

	function _checkShareOfGav(Comptroller comptroller) internal {
		uint256 gav = comptroller.calcGav();
		if (gav == 0) return;
		address[] memory held = comptroller.getTrackedAssets();
		uint256 twapValue;
		for (uint256 i; i < held.length; ++i) {
			if (registry.isTwapPriced(held[i])) twapValue += comptroller.calcAssetGav(held[i]);
		}
		uint256 shareBps = Math.mulDiv(twapValue, BPS, gav);
		if (shareBps > MAX_GAV_BPS) revert TwapShareOfGavExceeded(shareBps);
	}
}
