// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IRedemptionUnwinder} from '../interfaces/IRedemptionUnwinder.sol';
import {IVerantaMulticall, IVerantaTradingStorage, IVerantaTradingRouter} from '../interfaces/external/IVeranta.sol';
import {VerantaPriceStore} from '../pricing/VerantaPriceStore.sol';

/// @notice Veranta PairStorage views the unwinder reads (verified on Base 2026-10-06:
///         pairMinLevPosUSDC(81) = 100e6, i.e. $100 of leveraged size).
interface IPerpPairStorage {
	function pairsCount() external view returns (uint256);
	function pairMinLevPosUSDC(uint256 pairIndex) external view returns (uint256);
}

/// @title PerpUnwinder
/// @notice The RedemptionQueue fallback's helper for Veranta perp accounts (founder 2026-10-06;
///         spec 2026-10-06 §3.3): it describes, never executes. For a fraction F of a fund owed to
///         overdue redeemers it lists one CloseTrade per open trade — F of the trade's collateral,
///         or the whole trade when what would remain is under the pair's minimum position — at the
///         price just stored from Veranta's signed feed, and the ReturnToVault that collects the
///         proceeds. The queue forwards them through ComptrollerV3.forwardUnwind, where the
///         account's own isRiskReducing decides. Holds nothing; switched off until approved and
///         switched on in the queue.
/// @dev Any perp account version must keep CloseTrade = 1 and ReturnToVault = 6, both risk-reducing.
contract PerpUnwinder is IRedemptionUnwinder {
	/// @notice A close is sent at the stored price only while it is this fresh: the caller stores
	///         Veranta's current signed price in the same transaction (Multicall3), as the keeper does.
	uint256 public constant PRICE_MAX_AGE = 120 seconds;
	uint8 internal constant CLOSE_TRADE = 1;
	uint8 internal constant RETURN_TO_VAULT = 6;

	/// @notice The shared perp config (the V2 factory) every Veranta perp account reports as its
	///         positionFactory(): how a perp account is recognized.
	address public immutable perpConfig;
	VerantaPriceStore public immutable store;
	IVerantaTradingStorage public immutable tradingStorage;
	IVerantaMulticall public immutable multicall;
	IPerpPairStorage public immutable pairStorage;
	IERC20 public immutable usdc;

	error StalePrice(uint256 pairIndex);
	error NoPrice(uint256 pairIndex);

	constructor(
		address perpConfig_,
		VerantaPriceStore store_,
		IVerantaTradingStorage tradingStorage_,
		IVerantaMulticall multicall_,
		address pairStorage_,
		IERC20 usdc_
	) {
		perpConfig = perpConfig_;
		store = store_;
		tradingStorage = tradingStorage_;
		multicall = multicall_;
		pairStorage = IPerpPairStorage(pairStorage_);
		usdc = usdc_;
	}

	/// @inheritdoc IRedemptionUnwinder
	function canUnwind(address position) external view returns (bool) {
		(bool ok, bytes memory ret) = position.staticcall(abi.encodeWithSignature('positionFactory()'));
		return ok && ret.length == 32 && abi.decode(ret, (address)) == perpConfig;
	}

	/// @inheritdoc IRedemptionUnwinder
	function closeActions(address position, uint256 fractionWad) external view returns (bytes[] memory actions) {
		uint256 pairs = pairStorage.pairsCount();
		uint256 total;
		for (uint256 pair; pair < pairs; ++pair) {
			total += tradingStorage.openTradesCount(position, pair);
		}
		actions = new bytes[](total);
		if (total == 0) return actions;

		uint256 maxSlots = tradingStorage.maxTradesPerPair();
		uint256 n;
		for (uint256 pair; pair < pairs && n < total; ++pair) {
			n = _pairActions(position, pair, maxSlots, fractionWad, actions, n);
		}
		// a slot read that failed leaves fewer actions than counted
		assembly ('memory-safe') {
			mstore(actions, n)
		}
	}

	/// @dev Appends one close per open trade of `pair` at `actions[n…]`; returns the new count.
	function _pairActions(address position, uint256 pair, uint256 maxSlots, uint256 fractionWad, bytes[] memory actions, uint256 n)
		internal
		view
		returns (uint256)
	{
		uint256 left = tradingStorage.openTradesCount(position, pair);
		if (left == 0) return n;
		uint256 price = _freshPrice(pair);
		for (uint256 slot; slot < maxSlots && left > 0; ++slot) {
			try tradingStorage.openTrades(position, pair, slot) returns (IVerantaTradingRouter.Trade memory t) {
				if (t.leverage == 0) continue;
				--left;
				actions[n++] = _close(t, pair, fractionWad, price);
			} catch {}
		}
		return n;
	}

	function _close(IVerantaTradingRouter.Trade memory t, uint256 pair, uint256 fractionWad, uint256 price)
		internal
		view
		returns (bytes memory)
	{
		return abi.encode(CLOSE_TRADE, abi.encode(pair, t.index, _closeAmount(t, pair, fractionWad), price));
	}

	/// @inheritdoc IRedemptionUnwinder
	function collectAction(address position) external view returns (bytes memory) {
		uint256 idle = usdc.balanceOf(position);
		return idle == 0 ? bytes('') : abi.encode(RETURN_TO_VAULT, abi.encode(idle));
	}

	/// @inheritdoc IRedemptionUnwinder
	function hasPending(address position) external view returns (bool) {
		return multicall.getPendingOrder(position).length > 0;
	}

	/// @dev F of the collateral, or all of it when the rest would be under the pair's minimum size.
	function _closeAmount(IVerantaTradingRouter.Trade memory t, uint256 pair, uint256 fractionWad)
		internal
		view
		returns (uint256 amount)
	{
		amount = Math.mulDiv(t.initialPosToken, fractionWad, 1e18);
		uint256 rest = t.initialPosToken - amount;
		if (rest > 0 && Math.mulDiv(rest, t.leverage, 1e10) < pairStorage.pairMinLevPosUSDC(pair)) {
			amount = t.initialPosToken;
		}
	}

	/// @dev The stored Lazer price at Veranta's 1e10 scale; refused unless stored in the last 2 minutes.
	function _freshPrice(uint256 pair) internal view returns (uint256) {
		(int64 price, int16 exponent, uint64 timestampUs) = store.latest(pair);
		if (timestampUs == 0 || price <= 0) revert NoPrice(pair);
		if (block.timestamp > timestampUs / 1e6 + PRICE_MAX_AGE) revert StalePrice(pair);
		int256 shift = 10 + int256(exponent);
		return shift >= 0
			? uint256(uint64(price)) * 10 ** uint256(shift)
			: uint256(uint64(price)) / 10 ** uint256(-shift);
	}
}
