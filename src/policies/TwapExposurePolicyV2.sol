// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IPolicy} from '../interfaces/IPolicy.sol';
import {IExternalPosition} from '../interfaces/IExternalPosition.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {Comptroller} from '../core/Comptroller.sol';
import {TwapListingRegistryV2} from '../pricing/TwapListingRegistryV2.sol';
import {ITwapPriceAdapter} from '../interfaces/ITwapPriceAdapter.sol';

/// @title TwapExposurePolicyV2
/// @notice Limits for funds holding TWAP-priced assets:
///         - at most 20% of GAV across all TWAP-priced holdings;
///         - per asset, at most 10% of its pool's ±10% QUOTE-side depth — the lower of the live
///           read and the keeper-recorded depth, so liquidity added in the same transaction never
///           lifts a cap (50% once ≥ $250k);
///         - a delisted asset pauses NEW deposits into funds still holding it until sold.
/// @dev Caps apply to buys only — sales are never blocked. Degen funds (`allowRiskyAssets`) skip
///      the caps but not the deposit pause. Non-degen funds can't LP a TWAP-priced token or place
///      a limit order buying one; TWAP units inside positions count toward the caps.
contract TwapExposurePolicyV2 is IPolicy {
	uint256 public constant BPS = 10_000;
	uint256 public constant MAX_GAV_BPS = 2_000;
	uint256 public constant LARGE_POOL_USD = 250_000;
	uint256 public constant SMALL_POOL_CAP_BPS = 1_000;
	uint256 public constant LARGE_POOL_CAP_BPS = 5_000;

	TwapListingRegistryV2 public immutable registry;

	error TwapShareOfGavExceeded(uint256 shareBps);
	error PoolShareExceeded(address asset, uint256 holdingUsd18, uint256 capUsd18);
	error BuyingDelistedAsset(address asset);
	error DepositsPausedDelistedHolding(address asset);
	error TwapAssetInExternalPosition(address asset);
	error UnsupportedHook(PolicyHook hook);

	constructor(TwapListingRegistryV2 registry_) {
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

	/// @dev The fund's holding (vault + external positions), in USD, against its pool's ±10%
	///      quote-side depth: the lower of the live read and the keeper-recorded depth.
	function _checkPoolShare(Comptroller comptroller, address asset) internal {
		IValueInterpreter vi = comptroller.valueInterpreter();
		uint256 units = IERC20(asset).balanceOf(address(comptroller.vault())) + _unitsInPositions(comptroller, asset);
		uint256 holdingUsd18 = Math.mulDiv(vi.calcUsdRate(asset), units, 10 ** IERC20Metadata(asset).decimals());
		uint256 depthUsd18 = Math.min(
			ITwapPriceAdapter(registry.adapterOf(asset)).poolDepthUsd(), registry.recordedDepthUsd18(asset)
		);
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

	/// @dev An LP's pair is fixed at creation: refuse a TWAP-priced side. Positions without a pair pass.
	function _checkLpPair(address position) internal view {
		_refuseTwap(_addressView(position, 'token0()'));
		_refuseTwap(_addressView(position, 'token1()'));
	}

	/// @dev The newest limit order must not buy a TWAP-priced asset (selling is allowed). Positions without orders pass.
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
