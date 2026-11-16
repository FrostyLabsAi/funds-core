// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IPolicy} from '../interfaces/IPolicy.sol';
import {IPoolPriceAdapter} from '../interfaces/IPoolPriceAdapter.sol';
import {IPoolPriceRegistrar} from '../interfaces/IPoolPriceRegistrar.sol';

/// @title MinPoolLiquidityPolicy
/// @notice The rules on long-tail (pool-priced) tokens, for every fund:
///         - buying one: after the trade its pool must hold at least the registrar's
///           MIN_LIQUIDITY_USD ($25k), measured as the adapter does (the lower of the quote balance
///           now and the window's liquidity, so liquidity added in the trade's own transaction
///           doesn't count);
///         - selling one priced at the 1-wei floor is refused (see _checkSells).
///         Tokens priced any other way (Chainlink, derivatives) are never checked. No caps, no
///         deposit or redemption rules, no owner, no settings. Mandatory on new funds
///         (FundFactory.setMandatoryPolicies, on PostCallOnIntegration).
contract MinPoolLiquidityPolicy is IPolicy {
	IPoolPriceRegistrar public immutable registrar;

	error PoolTooThin(address asset, uint256 liquidityUsd18);
	error SoldAtFloor(address asset);
	error UnsupportedHook(PolicyHook hook);

	constructor(IPoolPriceRegistrar registrar_) {
		registrar = registrar_;
	}

	/// @inheritdoc IPolicy
	function implementedHooks() external pure returns (PolicyHook[] memory hooks) {
		hooks = new PolicyHook[](1);
		hooks[0] = PolicyHook.PostCallOnIntegration;
	}

	/// @inheritdoc IPolicy
	function validate(PolicyHook hook, bytes calldata validationData) external view {
		if (hook == PolicyHook.PostCallOnIntegration) {
			(, address[] memory spendAssets, uint256[] memory spendAmounts, address[] memory incomingAssets,) =
				abi.decode(validationData, (address, address[], uint256[], address[], uint256[]));
			_checkSells(spendAssets, spendAmounts);
			_checkBuys(incomingAssets);
		} else {
			revert UnsupportedHook(hook);
		}
	}

	/// @dev At 1 wei the slippage policy values a token at nothing, so selling the fund's whole holding to the manager's own pool
	///      for nothing would cost no budget (review 2026-11-01). A dead token leaves by Comptroller.writeOffAsset, which pays
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
}
