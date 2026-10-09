// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {IRedemptionQueue} from '../interfaces/IRedemptionQueue.sol';
import {PoolPriceRegistrar} from '../pricing/PoolPriceRegistrar.sol';
import {ComptrollerV3} from './ComptrollerV3.sol';
import {InKindRedemption} from './InKindRedemption.sol';

/// @title ComptrollerV5
/// @notice Fund version 5 = version 3 with an in-kind exit that pays the whole value (founder 2026-10-09). V3's in kind
///         pays a slice of the vault's tokens and forfeits the share of every perp and LP (TestFund4: 10 shares worth
///         $9.51 paid $1.97 of SPCXc); V4 refused it while a position is held. V5's pays, while the fund holds a
///         position, the slice of every vault token and the share of the positions in USDC, then in the vault's
///         readable, non-pool-priced tokens (InKindRedemption, the queue fallback's rule) — all of it, or it reverts
///         and the redeemer keeps the shares. It values the fund, so it needs readable positions and fresh perp
///         prices (the terminal stores them first). A pure-spot fund keeps V3's in kind: a slice of every token is
///         its whole value, and it needs no price. Skipping a token isn't allowed while a position is held (it would
///         forfeit that slice).
contract ComptrollerV5 is ComptrollerV3 {
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

	/// @notice The terminal offers in kind on a fund holding positions only where it pays the whole value.
	function inKindPaysFullValue() external pure returns (bool) {
		return true;
	}

	function redeemSharesInKind(uint256 sharesAmount) external override nonReentrant {
		_inKind(sharesAmount, new address[](0));
	}

	function redeemSharesInKindWithSkips(uint256 sharesAmount, address[] calldata assetsToSkip)
		external
		override
		nonReentrant
	{
		_inKind(sharesAmount, assetsToSkip);
	}

	/// @dev Both in-kind exits; the library pays (V3's in-kind code isn't in this contract: EIP-170 room). Holding no
	///      position: management and protocol fees settle, then the slice of every token (V3's in kind, no price read).
	///      Holding one: fees settle as for a cash redemption (the performance fee waits while a price can't be read),
	///      then the whole value or a revert. No policy runs, as for V3's in kind.
	function _inKind(uint256 sharesAmount, address[] memory assetsToSkip) private {
		_checkTimelockAndBalance(msg.sender, sharesAmount);
		bytes memory snapshot;
		if (externalPositions.length() == 0) {
			_settleManagementFee();
			_settleProtocolFee(); // no pricing dependency; redeemers must not escape the dilution
		} else {
			(, snapshot) = _settleFeesTolerant();
		}
		InKindRedemption.redeem(costBasis, trackedAssets, snapshot, sharesAmount, assetsToSkip);
	}
}
