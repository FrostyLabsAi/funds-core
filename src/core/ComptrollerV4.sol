// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {IRedemptionQueue} from '../interfaces/IRedemptionQueue.sol';
import {PoolPriceRegistrar} from '../pricing/PoolPriceRegistrar.sol';
import {ComptrollerV3} from './ComptrollerV3.sol';

/// @title ComptrollerV4
/// @notice Fund version 4 = version 3 without the in-kind exit that forfeits. V3's in kind pays a slice
///         of the vault's tokens and leaves the redeemer's share of every perp and LP behind
///         (TestFund4 2026-10-09: 10 shares worth $9.51 paid $1.97 of SPCXc). Founder 2026-10-09: no
///         exit may pay a redeemer less than their shares' value. While the fund holds an external
///         position, both in-kind exits revert and the RedemptionQueue is the exit (cash at the NAV of
///         settlement, oldest first; past the deadline the manager's fees stop and the fallback, once
///         switched on, closes the overdue share of the perps). A pure-spot fund keeps in kind: a
///         slice of every token is its whole value.
contract ComptrollerV4 is ComptrollerV3 {
	using EnumerableSet for EnumerableSet.AddressSet;

	constructor(
		address factory_,
		address fundOwner_,
		IERC20 denominationAsset_,
		IValueInterpreter valueInterpreter_,
		FeeConfig memory feeConfig_,
		uint256 sharesActionTimelock_,
		uint256 minRequestDuration_,
		uint256 executionWindow_,
		bool allowRiskyAssets_,
		PoolPriceRegistrar registrar_,
		IRedemptionQueue redemptionQueue_
	)
		ComptrollerV3(
			factory_,
			fundOwner_,
			denominationAsset_,
			valueInterpreter_,
			feeConfig_,
			sharesActionTimelock_,
			minRequestDuration_,
			executionWindow_,
			allowRiskyAssets_,
			registrar_,
			redemptionQueue_
		)
	{}

	/// @dev Every in-kind exit lands here: refused while any perp, LP or limit-order position is held.
	function _redeemSharesInKind(uint256 sharesAmount, address[] memory assetsToSkip) internal override {
		if (externalPositions.length() != 0) revert UseRedemptionQueue();
		super._redeemSharesInKind(sharesAmount, assetsToSkip);
	}
}
