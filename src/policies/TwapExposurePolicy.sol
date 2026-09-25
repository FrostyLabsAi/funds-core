// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IPolicy} from '../interfaces/IPolicy.sol';
import {IExternalPosition} from '../interfaces/IExternalPosition.sol';
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
///      External positions (security review 2026-09-24, M-2): a non-degen fund can neither
///      open an LP on a TWAP-priced token (checked at creation — an LP's pair is fixed) nor
///      place a limit order that BUYS one (checked after every position call on the newest
///      order); both caps count TWAP units held inside positions (e.g. limit-order sell
///      inventory), so parking tokens in a position cannot hide exposure.
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
	error TwapAssetInExternalPosition(address asset);
	error UnsupportedHook(PolicyHook hook);

	constructor(TwapListingRegistry registry_) {
		registry = registry_;
	}

	/// @inheritdoc IPolicy
	function implementedHooks() external pure returns (PolicyHook[] memory hooks) {
		hooks = new PolicyHook[](4);
		hooks[0] = PolicyHook.PostCallOnIntegration;
		hooks[1] = PolicyHook.PostDepositRequest;
		hooks[2] = PolicyHook.CreateExternalPosition;
		hooks[3] = PolicyHook.PostCallOnExternalPosition;
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
		} else if (hook == PolicyHook.CreateExternalPosition) {
			(, address position) = abi.decode(validationData, (uint256, address));
			if (!comptroller.allowRiskyAssets()) _checkLpPair(position);
		} else if (hook == PolicyHook.PostCallOnExternalPosition) {
			(address position,) = abi.decode(validationData, (address, uint256));
			if (!comptroller.allowRiskyAssets()) _checkNewestOrder(position);
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

	/// @dev The fund's holding (vault + external positions), in USD, against its pool's ±10% depth.
	function _checkPoolShare(Comptroller comptroller, address asset) internal {
		IValueInterpreter vi = comptroller.valueInterpreter();
		uint256 units = IERC20(asset).balanceOf(address(comptroller.vault())) + _unitsInPositions(comptroller, asset);
		uint256 holdingUsd18 = Math.mulDiv(vi.calcUsdRate(asset), units, 10 ** IERC20Metadata(asset).decimals());
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
		// TWAP legs inside external positions count too
		IValueInterpreter vi = comptroller.valueInterpreter();
		address denomination = address(comptroller.denominationAsset());
		address[] memory positions = comptroller.getExternalPositions();
		for (uint256 p; p < positions.length; ++p) {
			(address[] memory assets, uint256[] memory amounts) = IExternalPosition(positions[p]).getManagedAssets();
			for (uint256 i; i < assets.length; ++i) {
				if (amounts[i] > 0 && registry.isTwapPriced(assets[i])) {
					twapValue += vi.calcCanonicalAssetValue(assets[i], amounts[i], denomination);
				}
			}
		}
		uint256 shareBps = Math.mulDiv(twapValue, BPS, gav);
		if (shareBps > MAX_GAV_BPS) revert TwapShareOfGavExceeded(shareBps);
	}

	/// @dev Units of `asset` the fund's external positions manage.
	function _unitsInPositions(Comptroller comptroller, address asset) internal returns (uint256 units) {
		address[] memory positions = comptroller.getExternalPositions();
		for (uint256 p; p < positions.length; ++p) {
			(address[] memory assets, uint256[] memory amounts) = IExternalPosition(positions[p]).getManagedAssets();
			for (uint256 i; i < assets.length; ++i) {
				if (assets[i] == asset) units += amounts[i];
			}
		}
	}

	/// @dev An LP position's pair is fixed at creation (token0/token1) — a TWAP-priced side is
	///      refused for non-degen funds. Positions without a pair answer nothing and pass.
	function _checkLpPair(address position) internal view {
		_refuseTwap(_addressView(position, 'token0()'));
		_refuseTwap(_addressView(position, 'token1()'));
	}

	/// @dev A limit-order position's newest order must not BUY a TWAP-priced asset (selling
	///      one is an exit and always allowed). Positions without orders answer nothing and pass.
	function _checkNewestOrder(address position) internal view {
		(bool ok, bytes memory ret) = position.staticcall(abi.encodeWithSignature('orderCount()'));
		if (!ok || ret.length != 32) return;
		uint256 newest = abi.decode(ret, (uint256));
		if (newest == 0) return;
		(ok, ret) = position.staticcall(abi.encodeWithSignature('orders(uint256)', newest));
		if (!ok || ret.length < 64) return;
		(, address buyToken, uint128 sellRemaining) = abi.decode(ret, (address, address, uint128));
		if (sellRemaining > 0) _refuseTwap(buyToken);
	}

	function _refuseTwap(address asset) internal view {
		if (asset != address(0) && registry.isTwapPriced(asset)) revert TwapAssetInExternalPosition(asset);
	}

	function _addressView(address target, string memory signature) internal view returns (address) {
		(bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(signature));
		return ok && ret.length == 32 ? abi.decode(ret, (address)) : address(0);
	}
}
