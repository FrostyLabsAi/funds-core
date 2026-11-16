// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import {Address} from '@openzeppelin/contracts/utils/Address.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IExternalPosition} from '../interfaces/IExternalPosition.sol';
import {IComptroller} from '../interfaces/IComptroller.sol';
import {IFundAccount} from '../interfaces/IFundAccount.sol';
import {IVerantaPerpConfig} from '../interfaces/IVerantaPerpConfig.sol';
import {
	IVerantaTradingRouter,
	IVerantaMulticall,
	IVerantaTradingStorage,
	IVerantaPairStorage,
	IVerantaPairCosts,
	IVerantaPendingOrders,
	IVerantaReferral
} from '../interfaces/external/IVeranta.sol';

/// @title VerantaPerpPosition
/// @notice A fund's Veranta perp account (spec docs/superpowers/specs/2026-10-08-perp-account-v4-design.md):
///         - valuation reads only the pairs the account holds while no keeper is delegated (a walk over every
///           Veranta pair costs ≈2.24M gas per account at 175 pairs) and every pair while one is;
///         - each open trade is valued net of Veranta's close fee and the pair's base spread;
///         - the manager can add margin (AddMargin) against a signed price;
///         - a held pair whose asset mapping is removed reverts valuation instead of dropping its leg;
///         - Veranta's zero-fee "PnL" order type is refused (its profit share isn't modelled).
/// @dev Bound to the shared VerantaPerpConfig (pair map, autopilot keeper, referral); perpConfig() identifies a fund
///      perp account (comptroller, keeper, terminal). A perp is reported as spot-equivalent legs, priced by the
///      same oracles as the fund's spot:
///        short: managed USDC += collateral + coinExposure*openPrice − accruedFees − closeCost;
///               debt[underlying] += coinExposure
///        long:  managed[underlying] += coinExposure;
///               USDC leg += collateral − coinExposure*openPrice − accruedFees − closeCost (usually < 0 → debt)
///      Pending market orders and resting limit orders count at their escrowed collateral.
///      coinExposure and accrued fees (rollover + funding) follow Veranta's own formulas.
contract VerantaPerpPosition is IExternalPosition, IFundAccount {
	using SafeERC20 for IERC20;
	using EnumerableSet for EnumerableSet.UintSet;

	/// @dev Ordinals are fixed: the terminal and keeper send them, and the comptroller's liquidation relies on
	///      CloseTrade = 1 and ReturnToVault = 6, both risk-reducing.
	enum Action {
		OpenTrade,
		CloseTrade,
		CancelLimitOrder,
		CancelPendingMarketOrder,
		SetAutopilot,
		RemoveAutopilot,
		ReturnToVault,
		LinkReferral,
		AddMargin,
		ReturnEth
	}

	/// @notice OpenTrade args (a static tuple). Prices 1e10, collateral 1e6, leverage/slippage 1e10.
	///         tp/sl are Veranta's full-position levels: tp 0 = the pair's max-gain cap, sl 0 = none.
	struct OpenTradeArgs {
		uint256 pairIndex;
		uint256 collateral;
		uint256 leverage;
		bool buy;
		uint256 openPrice;
		uint256 slippageP;
		uint8 orderType;
		uint256 tp;
		uint256 sl;
	}

	uint256 internal constant PRICE_PRECISION = 1e10;
	uint256 internal constant COIN_PRECISION = 1e10;
	uint256 internal constant LEVERAGE_PRECISION = 1e10;
	uint256 internal constant USDC_PRECISION = 1e6;

	/// @dev Per held pair, read once and shared by its trades.
	struct PairRead {
		uint8 decimals;
		uint256 closeCostP;
	}
	/// @dev Veranta's percentages: 1e10 = 1%
	uint256 internal constant PERCENT_SCALE = 100 * 1e10;
	/// @dev 0 market, 1 stop-limit, 2 limit. 3 = MARKET_PNL (zero-fee trades that pay a profit share
	///      on close) is refused: valuation doesn't model the profit share (spec 2026-10-08 §3.4)
	uint8 internal constant MAX_ORDER_TYPE = 2;
	/// @dev Veranta ITradingStorage.updateType.DEPOSIT
	uint8 internal constant MARGIN_DEPOSIT = 0;

	address public immutable comptroller;
	/// @notice The shared config, not the deployer of this contract.
	IVerantaPerpConfig public immutable perpConfig;
	IERC20 public immutable usdc;
	IVerantaTradingRouter public immutable router;
	IVerantaMulticall public immutable verantaMulticall;
	IVerantaTradingStorage public immutable tradingStorage;
	IVerantaPairStorage public immutable pairStorage;

	/// @notice The keeper currently delegated on Veranta (0 = autopilot off). Non-zero switches
	///         valuation to a walk over every Veranta pair (spec §3.1).
	address public activeDelegate;
	/// @dev Pairs the manager opened or ordered on, plus every held pair found when a keeper
	///      delegation ends; valuation reads only these while no keeper is delegated (spec §3.1).
	EnumerableSet.UintSet internal _heldPairs;

	event TradeOpened(uint256 indexed pairIndex, uint256 collateral, uint256 leverage, bool buy, uint8 orderType);
	event TpSlRequested(uint256 indexed pairIndex, uint256 tp, uint256 sl);
	event TradeClosed(uint256 indexed pairIndex, uint256 index, uint256 collateralAmount);
	event LimitOrderCancelled(uint256 indexed pairIndex, uint256 index);
	event PendingMarketOrderCancelled(uint256 indexed orderId);
	event AutopilotSet(address indexed delegate, uint256 expiry);
	event AutopilotRemoved(address indexed delegate);
	event ReturnedToVault(uint256 amount);
	event ReferralLinked(bytes32 indexed code);
	/// @notice The creation-time link was refused (e.g. Referral paused or the code made private);
	///         the account still opens, and linkReferral() repairs it later.
	event ReferralLinkFailed(bytes32 indexed code);
	event HeldPairAdded(uint256 indexed pairIndex);
	event HeldPairRemoved(uint256 indexed pairIndex);
	/// @notice A keeper delegation ended and one walk over every pair listed what the account holds.
	event SyncedHeldPairs(uint256 count);
	event MarginAdded(uint256 indexed pairIndex, uint256 index, uint256 amount);
	event EthReturned(address indexed to, uint256 amount);

	error OnlyComptroller();
	error UnknownAction();
	error PairNotConfigured(uint256 pairIndex);
	error UnsupportedAsset(address asset);
	error AutopilotNotActive();
	error ReferralNotConfigured();
	error ValuationIncomplete(uint256 pairIndex);
	error PairUnmapped(uint256 pairIndex);
	error UnsupportedOrderType(uint8 orderType);
	error FeeBalanceTooLow(uint256 fee, uint256 balance);
	error PendingOrderUnreadable(uint256 orderId);

	modifier onlyComptroller() {
		if (msg.sender != comptroller) revert OnlyComptroller();
		_;
	}

	/// @dev Deployed by VerantaPerpPositionFactory, bound to its config.
	constructor(address comptroller_, IVerantaPerpConfig perpConfig_) {
		comptroller = comptroller_;
		perpConfig = perpConfig_;
		IERC20 usdc_ = perpConfig_.usdc();
		address tradingStorage_ = perpConfig_.tradingStorage();
		usdc = usdc_;
		router = perpConfig_.router();
		verantaMulticall = perpConfig_.verantaMulticall();
		tradingStorage = IVerantaTradingStorage(tradingStorage_);
		pairStorage = perpConfig_.pairStorage();
		// Veranta's TradingStorage pulls collateral from this contract, including for keeper-driven rebalances
		usdc_.forceApprove(tradingStorage_, type(uint256).max);

		// Best-effort link to the protocol code: a paused Referral or a private code never blocks the account
		IVerantaReferral referral = perpConfig_.referral();
		bytes32 code = perpConfig_.referralCode();
		if (address(referral) != address(0) && code != bytes32(0)) {
			try referral.setTraderReferralCodeByUser(code) {
				emit ReferralLinked(code);
			} catch {
				emit ReferralLinkFailed(code);
			}
		}
	}

	/// @notice (Re)link this account to the config's current referral code. Anyone may call it
	///         (keeper, DAO): it takes no code, so the rebate can only go to the protocol's code.
	function linkReferral() external {
		_linkReferral();
	}

	/// @notice The listed pairs (list mode reads only these); the terminal reads it.
	function heldPairs() external view returns (uint256[] memory) {
		return _heldPairs.values();
	}

	// ─── Manager actions (via Comptroller.callOnExternalPosition) ───────────────

	/// @inheritdoc IExternalPosition
	/// @dev Close, cancel (refunds land here), remove-delegate and return-to-vault only move value back
	///      toward the fund. AddMargin moves value into a trade, so it is priced like an open.
	function isRiskReducing(bytes calldata actionData) external pure returns (bool) {
		(uint8 rawAction,) = abi.decode(actionData, (uint8, bytes));
		return rawAction == uint8(Action.CloseTrade) || rawAction == uint8(Action.CancelLimitOrder)
			|| rawAction == uint8(Action.CancelPendingMarketOrder) || rawAction == uint8(Action.RemoveAutopilot)
			|| rawAction == uint8(Action.ReturnToVault);
	}

	/// @inheritdoc IExternalPosition
	function receiveCallFromFund(bytes calldata actionData) external onlyComptroller {
		(uint8 rawAction, bytes memory args) = abi.decode(actionData, (uint8, bytes));

		if (rawAction == uint8(Action.OpenTrade)) {
			_openTrade(abi.decode(args, (OpenTradeArgs)));
		} else if (rawAction == uint8(Action.CloseTrade)) {
			(uint256 pairIndex, uint256 index, uint256 amount, uint256 wantedPrice) =
				abi.decode(args, (uint256, uint256, uint256, uint256));
			router.closeTradeMarket(pairIndex, index, amount, wantedPrice);
			emit TradeClosed(pairIndex, index, amount);
		} else if (rawAction == uint8(Action.CancelLimitOrder)) {
			(uint256 pairIndex, uint256 index) = abi.decode(args, (uint256, uint256));
			router.cancelOpenLimitOrder(pairIndex, index);
			emit LimitOrderCancelled(pairIndex, index);
		} else if (rawAction == uint8(Action.CancelPendingMarketOrder)) {
			uint256 orderId = abi.decode(args, (uint256));
			router.cancelPendingMarketOrder(orderId);
			emit PendingMarketOrderCancelled(orderId);
		} else if (rawAction == uint8(Action.SetAutopilot)) {
			uint256 expiry = abi.decode(args, (uint256));
			address keeper = perpConfig.autopilotKeeper();
			address previous = activeDelegate;
			// one keeper at most (spec §3.1): a rotated-out keeper keeps no delegation that list mode,
			// entered only through RemoveAutopilot's sync, could miss trades from
			if (previous != address(0) && previous != keeper) {
				router.removeDelegate(previous);
				emit AutopilotRemoved(previous);
			}
			router.setDelegate(keeper, expiry);
			activeDelegate = keeper;
			emit AutopilotSet(keeper, expiry);
		} else if (rawAction == uint8(Action.RemoveAutopilot)) {
			address delegate = activeDelegate;
			if (delegate == address(0)) revert AutopilotNotActive();
			router.removeDelegate(delegate);
			activeDelegate = address(0);
			emit AutopilotRemoved(delegate);
			// the keeper may have opened trades the account never saw: list every held pair
			_syncHeldPairs();
		} else if (rawAction == uint8(Action.ReturnToVault)) {
			uint256 amount = abi.decode(args, (uint256));
			usdc.safeTransfer(address(IComptroller(comptroller).vault()), amount);
			emit ReturnedToVault(amount);
		} else if (rawAction == uint8(Action.LinkReferral)) {
			_linkReferral();
		} else if (rawAction == uint8(Action.AddMargin)) {
			_addMargin(args);
		} else if (rawAction == uint8(Action.ReturnEth)) {
			// the AddMargin fee float (2026-10-08): never part of NAV, so it goes back to the fund owner, who
			// paid it in through the terminal's top-up
			address owner = IComptroller(comptroller).fundOwner();
			uint256 amount = address(this).balance;
			Address.sendValue(payable(owner), amount);
			emit EthReturned(owner, amount);
		} else {
			revert UnknownAction();
		}
		_pruneHeldPairs();
	}

	/// @dev The protocol's code only, so a manager or caller can't route the rebate to a code of their own.
	function _linkReferral() private {
		IVerantaReferral referral = perpConfig.referral();
		bytes32 code = perpConfig.referralCode();
		if (address(referral) == address(0) || code == bytes32(0)) revert ReferralNotConfigured();
		referral.setTraderReferralCodeByUser(code);
		emit ReferralLinked(code);
	}

	function _openTrade(OpenTradeArgs memory a) internal {
		if (a.orderType > MAX_ORDER_TYPE) revert UnsupportedOrderType(a.orderType);
		// the pair must map to a priceable underlying, or GAV couldn't value the position
		address asset = perpConfig.pairAsset(a.pairIndex);
		if (asset == address(0)) revert PairNotConfigured(a.pairIndex);
		if (!IComptroller(comptroller).valueInterpreter().isSupportedAsset(asset)) {
			revert UnsupportedAsset(asset);
		}
		// listed before Veranta's operator can fill it, so list mode never misses the trade
		_addHeldPair(a.pairIndex);

		router.openTrade(
			IVerantaTradingRouter.Trade({
				trader: address(this),
				pairIndex: a.pairIndex,
				index: 0,
				initialPosToken: 0,
				positionSizeUSDC: a.collateral,
				openPrice: a.openPrice,
				buy: a.buy,
				leverage: a.leverage,
				tp: a.tp,
				sl: a.sl,
				timestamp: 0
			}),
			a.orderType,
			a.slippageP
		);
		emit TradeOpened(a.pairIndex, a.collateral, a.leverage, a.buy, a.orderType);
		if (a.tp != 0 || a.sl != 0) emit TpSlRequested(a.pairIndex, a.tp, a.sl);
	}

	/// @dev Spec 2026-10-08 §4: deposit margin into one open trade
	///      against a signed price Veranta verifies (Lazer: under 30 s old, not ahead of the chain's clock).
	///      The manager's call moves the USDC from the vault first. Flat args
	///      (pairIndex, index, amount, priceUpdateData, priceSourcing, fee); the verification fee is paid
	///      in ETH from this account's own balance (receive()).
	function _addMargin(bytes memory args) internal {
		(uint256 pairIndex, uint256 index, uint256 amount, bytes[] memory priceUpdateData, uint8 priceSourcing, uint256 fee) =
			abi.decode(args, (uint256, uint256, uint256, bytes[], uint8, uint256));
		uint256 balance = address(this).balance;
		if (balance < fee) revert FeeBalanceTooLow(fee, balance);
		router.updateMargin{value: fee}(pairIndex, index, MARGIN_DEPOSIT, amount, priceUpdateData, priceSourcing);
		emit MarginAdded(pairIndex, index, amount);
	}

	/// @notice ETH for Veranta's price-verification fee (AddMargin): a few wei, never part of NAV.
	receive() external payable {}

	// ─── Held pairs (spec §3.1) ──────────────────────────────────────────────────

	function _addHeldPair(uint256 pairIndex) internal {
		if (_heldPairs.add(pairIndex)) emit HeldPairAdded(pairIndex);
	}

	/// @dev Drop listed pairs with no trade, no limit order and no pending market order. Backwards:
	///      EnumerableSet.remove moves the last element into the freed slot, which was already visited.
	function _pruneHeldPairs() internal {
		for (uint256 i = _heldPairs.length(); i > 0; --i) {
			uint256 pairIndex = _heldPairs.at(i - 1);
			if (_holds(pairIndex)) continue;
			_heldPairs.remove(pairIndex);
			emit HeldPairRemoved(pairIndex);
		}
	}

	/// @dev One walk over every Veranta pair: list each one the account holds anything on.
	function _syncHeldPairs() internal {
		uint256 pairs = pairStorage.pairsCount();
		for (uint256 pairIndex; pairIndex < pairs; ++pairIndex) {
			if (_holds(pairIndex)) _addHeldPair(pairIndex);
		}
		emit SyncedHeldPairs(_heldPairs.length());
	}

	/// @dev A trade, a resting order or a market order pending the operator on the pair. Veranta's own
	///      per-pair counters, so coin-sized opens count too (Multicall.getPendingOrder returns those
	///      zeroed, pair 0 included — final review 2026-10-08).
	function _holds(uint256 pairIndex) internal view returns (bool) {
		IVerantaPendingOrders orders = IVerantaPendingOrders(address(tradingStorage));
		return tradingStorage.openTradesCount(address(this), pairIndex) > 0
			|| tradingStorage.openLimitOrdersCount(address(this), pairIndex) > 0
			|| orders.pendingMarketOpenCount(address(this), pairIndex) > 0
			|| orders.pendingMarketCloseCount(address(this), pairIndex) > 0;
	}

	// ─── IExternalPosition ───────────────────────────────────────────────────────

	/// @inheritdoc IExternalPosition
	function getManagedAssets() external view returns (address[] memory assets, uint256[] memory amounts) {
		(int256 usdcNet, address[] memory tokens, int256[] memory tokenAmts) = _valuation();
		return _side(usdcNet, tokens, tokenAmts, true);
	}

	/// @inheritdoc IExternalPosition
	function getDebtAssets() external view returns (address[] memory assets, uint256[] memory amounts) {
		(int256 usdcNet, address[] memory tokens, int256[] memory tokenAmts) = _valuation();
		return _side(usdcNet, tokens, tokenAmts, false);
	}

	/// @dev One pass over Veranta state → net USDC leg (signed) + per-underlying legs (signed;
	///      positive = the fund is long the underlying, negative = short/owed).
	function _valuation() internal view returns (int256 usdcNet, address[] memory tokens, int256[] memory tokenAmts) {
		usdcNet = int256(usdc.balanceOf(address(this)));

		usdcNet += _pendingEscrow();

		uint256[] memory pairs = _pairsToValue();
		uint256 maxSlots = tradingStorage.maxTradesPerPair();
		tokens = new address[](pairs.length);
		tokenAmts = new int256[](pairs.length);
		for (uint256 i; i < pairs.length; ++i) {
			(int256 usdcDelta, int256 units, address asset) = _valuePair(pairs[i], maxSlots);
			usdcNet += usdcDelta;
			if (units == 0) continue;
			// Merge same-underlying legs (pairs sharing an asset)
			bool merged;
			for (uint256 j; j < i; ++j) {
				if (tokens[j] == asset) {
					tokenAmts[j] += units;
					merged = true;
					break;
				}
			}
			if (!merged) {
				tokens[i] = asset;
				tokenAmts[i] = units;
			}
		}
	}

	/// @dev Escrowed collateral of market orders pending the operator (a cheap per-trader list, every pair;
	///      a pending close carries 0). A coin-sized open (openTradeWithCoinExposure — the keeper can place
	///      one) comes back zeroed from getPendingOrder: its escrow is read from its own mapping, and an
	///      order neither mapping attributes to this account is refused rather than left out of GAV
	///      (final review 2026-10-08).
	function _pendingEscrow() internal view returns (int256 escrow) {
		IVerantaMulticall.PendingOrder[] memory pending = verantaMulticall.getPendingOrder(address(this));
		for (uint256 i; i < pending.length; ++i) {
			IVerantaTradingRouter.Trade memory t = pending[i].orderInfo.trade;
			if (t.trader != address(this)) {
				t = IVerantaPendingOrders(address(tradingStorage)).reqIdPendingMarketOrderWithCoinExposure(pending[i].orderId).trade;
				if (t.trader != address(this)) revert PendingOrderUnreadable(pending[i].orderId);
			}
			escrow += int256(t.positionSizeUSDC);
		}
	}

	/// @dev The listed pairs while no keeper is delegated; every pair while one is, since it can open
	///      trades through Veranta's delegatedAction that the account never sees (spec §3.1, option A).
	function _pairsToValue() internal view returns (uint256[] memory pairs) {
		if (activeDelegate == address(0)) return _heldPairs.values();
		pairs = new uint256[](pairStorage.pairsCount());
		for (uint256 i; i < pairs.length; ++i) {
			pairs[i] = i;
		}
	}

	/// @dev One pair: two count reads; the mapping and slot reads only when the account holds something.
	function _valuePair(uint256 pairIndex, uint256 maxSlots)
		internal
		view
		returns (int256 usdcDelta, int256 units, address asset)
	{
		uint256 tradesLeft = tradingStorage.openTradesCount(address(this), pairIndex);
		uint256 ordersLeft = tradingStorage.openLimitOrdersCount(address(this), pairIndex);
		if (tradesLeft == 0 && ordersLeft == 0) return (0, 0, address(0));

		asset = perpConfig.pairAsset(pairIndex);
		// spec §3.2: a held pair without a mapping would lose its coin leg — refuse instead
		if (asset == address(0)) revert PairUnmapped(pairIndex);
		PairRead memory read = PairRead({decimals: IERC20Metadata(asset).decimals(), closeCostP: _closeCostP(pairIndex)});

		// try-wrapped so an empty slot is skipped; every counted row must still be read (below)
		for (uint256 slot; slot < maxSlots && (tradesLeft > 0 || ordersLeft > 0); ++slot) {
			if (tradesLeft > 0) {
				try tradingStorage.openTrades(address(this), pairIndex, slot) returns (IVerantaTradingRouter.Trade memory t) {
					if (t.leverage != 0) {
						--tradesLeft;
						(int256 tradeUsdc, int256 tradeUnits) = _valueTrade(t, pairIndex, slot, read);
						usdcDelta += tradeUsdc;
						units += tradeUnits;
					}
				} catch {}
			}
			if (ordersLeft > 0) {
				// Resting limit orders: collateral escrowed at face value
				try tradingStorage.getOpenLimitOrder(address(this), pairIndex, slot) returns (
					IVerantaMulticall.AggregatedLimitOrder memory o
				) {
					if (o.leverage != 0) {
						--ordersLeft;
						usdcDelta += int256(o.positionSize);
					}
				} catch {}
			}
		}
		// a counted trade or order that couldn't be read is refused, never silently left out of GAV
		if (tradesLeft > 0 || ordersLeft > 0) revert ValuationIncomplete(pairIndex);
	}

	/// @dev One stored trade → its USDC-leg contribution and its signed coin units.
	///      Stored trades keep collateral in initialPosToken; positionSizeUSDC is a dummy there.
	function _valueTrade(IVerantaTradingRouter.Trade memory t, uint256 pairIndex, uint256 slot, PairRead memory read)
		internal
		view
		returns (int256 usdcLeg, int256 units)
	{
		uint256 collateral = t.initialPosToken;
		uint256 leveragedSize = (collateral * t.leverage) / LEVERAGE_PRECISION;
		// Veranta's own coinExposure: PositionMath.scaleByLeverage then usdcToCoinAtPrice
		uint256 coinExposure = (leveragedSize * PRICE_PRECISION * COIN_PRECISION) / t.openPrice / USDC_PRECISION;
		// Accrued holding costs against the USDC leg (funding can be a credit), and what a close costs
		(, uint256 rolloverFee, int256 fundingFee) =
			verantaMulticall.getDynamicDataForPosition(address(this), pairIndex, slot);
		int256 fees = int256(rolloverFee) + fundingFee + int256((leveragedSize * read.closeCostP) / PERCENT_SCALE);

		// coinExposure (1e10) × openPrice (1e10) → USDC (1e6), Veranta's own conversion
		int256 notionalAtOpen = int256((coinExposure * t.openPrice * 1e6) / PRICE_PRECISION / COIN_PRECISION);

		units = int256((coinExposure * 10 ** read.decimals) / COIN_PRECISION);
		if (t.buy) {
			usdcLeg = int256(collateral) - notionalAtOpen - fees;
		} else {
			usdcLeg = int256(collateral) + notionalAtOpen - fees;
			units = -units;
		}
	}

	/// @dev What closing costs on the pair, as a rate of the leveraged size (spec §3.3, 2026-10-08), read once
	///      per pair: the higher of Veranta's close maker and taker fee rates plus the pair's base spread.
	///      Veranta charges maker, taker or a blend depending on live open-interest skew, which a large trader
	///      can move; the higher rate keeps NAV from reading above what a close pays whatever the skew (at most
	///      taker − maker low, 3.5 bps of notional on ETH/BTC today). Both are plain PairStorage getters (no
	///      extension that Veranta's governance could swap). Not modelled: the referral's 5% fee discount and the
	///      operator's dynamic spread above the base.
	function _closeCostP(uint256 pairIndex) internal view returns (uint256) {
		IVerantaPairCosts costs = IVerantaPairCosts(address(pairStorage));
		(, uint256 closeMakerFeeP,, uint256 closeTakerFeeP) = costs.additionalPairParams2(pairIndex);
		(,,,,, uint256 spreadP) = costs.pairs(pairIndex);
		return Math.max(closeMakerFeeP, closeTakerFeeP) + spreadP;
	}

	function _side(int256 usdcNet, address[] memory tokens, int256[] memory tokenAmts, bool managed)
		internal
		view
		returns (address[] memory assets, uint256[] memory amounts)
	{
		uint256 count;
		bool includeUsdc = managed ? usdcNet > 0 : usdcNet < 0;
		if (includeUsdc) ++count;
		for (uint256 i; i < tokens.length; ++i) {
			if (tokens[i] != address(0) && (managed ? tokenAmts[i] > 0 : tokenAmts[i] < 0)) ++count;
		}

		assets = new address[](count);
		amounts = new uint256[](count);
		uint256 j;
		if (includeUsdc) {
			assets[j] = address(usdc);
			amounts[j] = uint256(managed ? usdcNet : -usdcNet);
			++j;
		}
		for (uint256 i; i < tokens.length; ++i) {
			if (tokens[i] != address(0) && (managed ? tokenAmts[i] > 0 : tokenAmts[i] < 0)) {
				assets[j] = tokens[i];
				amounts[j] = uint256(managed ? tokenAmts[i] : -tokenAmts[i]);
				++j;
			}
		}
	}
}
