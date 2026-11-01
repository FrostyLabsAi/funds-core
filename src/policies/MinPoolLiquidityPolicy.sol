// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IPolicy} from '../interfaces/IPolicy.sol';
import {IPoolPriceAdapter} from '../interfaces/IPoolPriceAdapter.sol';
import {PoolPriceRegistrar} from '../pricing/PoolPriceRegistrar.sol';

/// @title MinPoolLiquidityPolicy
/// @notice The rules on long-tail (pool-priced) tokens, for every fund:
///         - buying one: after the trade its pool must hold at least the registrar's
///           MIN_LIQUIDITY_USD ($25k), measured as the adapter does (the lower of the quote balance
///           now and the window's liquidity, so liquidity added in the trade's own transaction
///           doesn't count). Sells are never checked;
///         - they stay out of positions: no LP position with one on either side, no limit order
///           buying or selling one. A fund pays redeemers its long-tail tokens in kind, which a
///           position can't do, so a pumped pool price must never reach a position's value.
///           Cancelling an order always passes.
///         Tokens priced any other way (Chainlink, derivatives) are never checked. No caps, no
///         deposit or redemption rules, no owner, no settings. Mandatory on new funds
///         (FundFactory.setMandatoryPolicies, on all three hooks).
contract MinPoolLiquidityPolicy is IPolicy {
	PoolPriceRegistrar public immutable registrar;

	error PoolTooThin(address asset, uint256 liquidityUsd18);
	error PoolPricedTokenInPosition(address asset);
	error SoldAtFloor(address asset);
	error UnsupportedHook(PolicyHook hook);

	constructor(PoolPriceRegistrar registrar_) {
		registrar = registrar_;
	}

	/// @inheritdoc IPolicy
	function implementedHooks() external pure returns (PolicyHook[] memory hooks) {
		hooks = new PolicyHook[](3);
		hooks[0] = PolicyHook.PostCallOnIntegration;
		hooks[1] = PolicyHook.CreateExternalPosition;
		hooks[2] = PolicyHook.PostCallOnExternalPosition;
	}

	/// @inheritdoc IPolicy
	function validate(PolicyHook hook, bytes calldata validationData) external view {
		if (hook == PolicyHook.PostCallOnIntegration) {
			(, address[] memory spendAssets, uint256[] memory spendAmounts, address[] memory incomingAssets,) =
				abi.decode(validationData, (address, address[], uint256[], address[], uint256[]));
			_checkSells(spendAssets, spendAmounts);
			_checkBuys(incomingAssets);
		} else if (hook == PolicyHook.CreateExternalPosition) {
			(, address position) = abi.decode(validationData, (uint256, address));
			_refusePoolPriced(_addressView(position, 'token0()'));
			_refusePoolPriced(_addressView(position, 'token1()'));
		} else if (hook == PolicyHook.PostCallOnExternalPosition) {
			(address position,) = abi.decode(validationData, (address, uint256));
			_checkNewestOrder(position);
		} else {
			revert UnsupportedHook(hook);
		}
	}

	/// @dev At 1 wei the slippage policy values a token at nothing, so selling the fund's whole holding to the manager's own pool
	///      for nothing would cost no budget (review 2026-11-01). A dead token leaves by ComptrollerV6.writeOffAsset, which pays
	///      nobody. Keeper liquidations don't run this: their route isn't the manager's to pick.
	function _checkSells(address[] memory spendAssets, uint256[] memory spendAmounts) internal view {
		for (uint256 i; i < spendAssets.length; ++i) {
			if (spendAmounts[i] == 0) continue;
			address adapter = registrar.poolPricedAdapter(spendAssets[i]);
			if (adapter == address(0)) continue;
			(, int256 answer,,,) = IPoolPriceAdapter(adapter).latestRoundData();
			if (answer == 1) revert SoldAtFloor(spendAssets[i]);
		}
	}

	function _checkBuys(address[] memory incomingAssets) internal view {
		uint256 minimum = registrar.MIN_LIQUIDITY_USD() * 1e18;
		for (uint256 i; i < incomingAssets.length; ++i) {
			address adapter = registrar.poolPricedAdapter(incomingAssets[i]);
			if (adapter == address(0)) continue;
			uint256 liquidity = IPoolPriceAdapter(adapter).liquidityUsd();
			if (liquidity < minimum) revert PoolTooThin(incomingAssets[i], liquidity);
		}
	}

	/// @dev The newest limit order must neither buy nor sell a pool-priced token while it still has
	///      something to sell; an order with nothing left (cancelled, filled) passes, so cancelling
	///      always clears the position. Positions without orders pass. (TwapExposurePolicyV3's read.)
	function _checkNewestOrder(address position) internal view {
		(bool ok, bytes memory ret) = position.staticcall(abi.encodeWithSignature('orderCount()'));
		if (!ok || ret.length != 32) return;
		uint256 newest = abi.decode(ret, (uint256));
		if (newest == 0) return;
		(ok, ret) = position.staticcall(abi.encodeWithSignature('orders(uint256)', newest));
		if (!ok || ret.length < 96) return;
		(address sellToken, address buyToken, uint128 sellRemaining) = abi.decode(ret, (address, address, uint128));
		if (sellRemaining == 0) return;
		_refusePoolPriced(sellToken);
		_refusePoolPriced(buyToken);
	}

	function _refusePoolPriced(address asset) internal view {
		if (asset != address(0) && registrar.poolPricedAdapter(asset) != address(0)) {
			revert PoolPricedTokenInPosition(asset);
		}
	}

	function _addressView(address target, string memory signature) internal view returns (address) {
		(bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(signature));
		return ok && ret.length == 32 ? abi.decode(ret, (address)) : address(0);
	}
}
