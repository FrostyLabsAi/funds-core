// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {IExternalPosition} from '../interfaces/IExternalPosition.sol';
import {IExternalPositionTypeFactory} from '../interfaces/IExternalPositionTypeFactory.sol';
import {Comptroller} from '../core/Comptroller.sol';
import {
	IVerantaTradingRouter,
	IVerantaMulticall,
	IVerantaTradingStorage,
	IVerantaPairStorage,
	IVerantaReferral
} from '../interfaces/external/IVeranta.sol';

/// @title VerantaPerpPositionV2
/// @notice Successor of VerantaPerpPosition (wave 7 — retired 2026-09-23; source in git
///         history) with a BOUNDED valuation read. V1 valued the account through Veranta's
///         Multicall.getPositions, which scans every pair × maxTradesPerPair slot —
///         measured on Base mainnet 2026-09-23 at ≈1.6–1.9M gas PER PAIR, ≈215M for the
///         live 135 pairs: every NAV-dependent action of a fund holding a V1 account cost
///         over half a block, and simulations exceeded every RPC's eth_call cap.
///         V2 asks TradingStorage for two COUNTS per pair (open trades, open limit orders —
///         one storage read each) and reads trade/order slots only where a count is
///         non-zero. It still sees EVERY pair the account holds — including hedges the
///         autopilot keeper opened through Veranta's delegation, which never pass through
///         this contract — so nothing can go unvalued.
/// @dev Additive over V1: LinkReferral (the protocol's Veranta referral code — fee discount
///      for the fund; Referral linking is caller-scoped, so only this contract can do it) and
///      TP/SL at open (OpenTrade carries tp/sl; V1 hardcoded both to 0).
///      Everything else is V1 verbatim: actions, custody, autopilot, and the linear
///      decomposition:
///      a perp is reported to the ValueInterpreter as spot-equivalent legs, priced by the
///      SAME oracles that price the fund's long leg (basis consistency for delta-neutral GAV):
///        short: managed USDC += collateral + coinExposure*openPrice − accruedFees;
///               debt[underlying] += coinExposure
///        long:  managed[underlying] += coinExposure;
///               USDC leg += collateral − coinExposure*openPrice − accruedFees (usually negative → debt)
///      Pending market orders and resting limit orders are valued at their escrowed collateral.
///      coinExposure is Veranta's own formula (PositionMath: scaleByLeverage then
///      usdcToCoinAtPrice), accrued fees are getDynamicDataForPosition's rollover + funding.
contract VerantaPerpPositionV2 is IExternalPosition {
	using SafeERC20 for IERC20;

	enum Action {
		OpenTrade,
		CloseTrade,
		CancelLimitOrder,
		CancelPendingMarketOrder,
		SetAutopilot,
		RemoveAutopilot,
		ReturnToVault,
		LinkReferral
	}

	/// @notice OpenTrade args (static tuple — same bytes as the flat abi.encode of its fields).
	///         Prices 1e10, collateral 1e6, leverage/slippage 1e10. tp/sl are Veranta's own
	///         full-position levels, validated and triggered by Veranta: tp 0 = the pair's
	///         max-gain cap, sl 0 = none.
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

	address public immutable comptroller;
	VerantaPerpPositionV2Factory public immutable positionFactory;
	IERC20 public immutable usdc;
	IVerantaTradingRouter public immutable router;
	IVerantaMulticall public immutable verantaMulticall;
	IVerantaTradingStorage public immutable tradingStorage;
	IVerantaPairStorage public immutable pairStorage;

	/// @notice The keeper currently delegated on Veranta (0 = autopilot off).
	address public activeDelegate;

	event TradeOpened(uint256 indexed pairIndex, uint256 collateral, uint256 leverage, bool buy, uint8 orderType);
	event TpSlRequested(uint256 indexed pairIndex, uint256 tp, uint256 sl);
	event TradeClosed(uint256 indexed pairIndex, uint256 index, uint256 collateralAmount);
	event LimitOrderCancelled(uint256 indexed pairIndex, uint256 index);
	event PendingMarketOrderCancelled(uint256 indexed orderId);
	event AutopilotSet(address indexed delegate, uint256 expiry);
	event AutopilotRemoved(address indexed delegate);
	event ReturnedToVault(uint256 amount);
	event ReferralLinked(bytes32 indexed code);

	error OnlyComptroller();
	error UnknownAction();
	error PairNotConfigured(uint256 pairIndex);
	error UnsupportedAsset(address asset);
	error AutopilotNotActive();
	error ReferralNotConfigured();

	modifier onlyComptroller() {
		if (msg.sender != comptroller) revert OnlyComptroller();
		_;
	}

	/// @dev Deployed only by VerantaPerpPositionV2Factory (the pair-mapping + keeper source).
	constructor(
		address comptroller_,
		IERC20 usdc_,
		IVerantaTradingRouter router_,
		IVerantaMulticall multicall_,
		address tradingStorage_,
		IVerantaPairStorage pairStorage_
	) {
		comptroller = comptroller_;
		positionFactory = VerantaPerpPositionV2Factory(msg.sender);
		usdc = usdc_;
		router = router_;
		verantaMulticall = multicall_;
		tradingStorage = IVerantaTradingStorage(tradingStorage_);
		pairStorage = pairStorage_;
		// Collateral is pulled from the trader (this contract) by Veranta's audited
		// TradingStorage — the standard trading approval, also required for the
		// delegate-driven rebalances (which cannot approve anything themselves).
		usdc_.forceApprove(tradingStorage_, type(uint256).max);
	}

	// ─── Manager actions (via Comptroller.callOnExternalPosition) ───────────────

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
			address keeper = positionFactory.autopilotKeeper();
			router.setDelegate(keeper, expiry);
			activeDelegate = keeper;
			emit AutopilotSet(keeper, expiry);
		} else if (rawAction == uint8(Action.RemoveAutopilot)) {
			address delegate = activeDelegate;
			if (delegate == address(0)) revert AutopilotNotActive();
			router.removeDelegate(delegate);
			activeDelegate = address(0);
			emit AutopilotRemoved(delegate);
		} else if (rawAction == uint8(Action.ReturnToVault)) {
			uint256 amount = abi.decode(args, (uint256));
			usdc.safeTransfer(address(Comptroller(comptroller).vault()), amount);
			emit ReturnedToVault(amount);
		} else if (rawAction == uint8(Action.LinkReferral)) {
			// The PROTOCOL's code only (factory config) — a manager cannot route the
			// referral rebate on the fund's fees to a code of their own.
			IVerantaReferral referral = positionFactory.referral();
			bytes32 code = positionFactory.referralCode();
			if (address(referral) == address(0) || code == bytes32(0)) revert ReferralNotConfigured();
			referral.setTraderReferralCodeByUser(code);
			emit ReferralLinked(code);
		} else {
			revert UnknownAction();
		}
	}

	function _openTrade(OpenTradeArgs memory a) internal {
		// The pair must be protocol-mapped to a VI-priceable underlying — GAV must never
		// hold a position it cannot value.
		address asset = positionFactory.pairAsset(a.pairIndex);
		if (asset == address(0)) revert PairNotConfigured(a.pairIndex);
		if (!Comptroller(comptroller).valueInterpreter().isSupportedAsset(asset)) {
			revert UnsupportedAsset(asset);
		}

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

		// Escrowed collateral of in-flight market opens (operator fills or refunds) —
		// a per-trader list, cheap (≈45k gas measured live)
		IVerantaMulticall.PendingOrder[] memory pending = verantaMulticall.getPendingOrder(address(this));
		for (uint256 i; i < pending.length; ++i) {
			usdcNet += int256(pending[i].orderInfo.trade.positionSizeUSDC);
		}

		uint256 pairs = pairStorage.pairsCount();
		uint256 maxSlots = tradingStorage.maxTradesPerPair();
		tokens = new address[](pairs);
		tokenAmts = new int256[](pairs);
		for (uint256 pairIndex; pairIndex < pairs; ++pairIndex) {
			(int256 usdcDelta, int256 units, bool held) = _valuePair(pairIndex, maxSlots);
			if (!held) continue;
			usdcNet += usdcDelta;

			address asset = positionFactory.pairAsset(pairIndex);
			// A pair zeroed mid-flight ("0 disables new opens") must DEGRADE, not brick
			// fund-wide GAV: the trade-local USDC leg stays, the coin leg is dropped
			// (security review 2026-09-22, M-8)
			if (asset == address(0) || units == 0) continue;
			// Merge same-underlying legs (pairs sharing an asset)
			bool merged;
			for (uint256 j; j < pairIndex; ++j) {
				if (tokens[j] == asset) {
					tokenAmts[j] += units;
					merged = true;
					break;
				}
			}
			if (!merged) {
				tokens[pairIndex] = asset;
				tokenAmts[pairIndex] = units;
			}
		}
	}

	/// @dev One pair: two count reads; slot reads only when the account holds something.
	function _valuePair(uint256 pairIndex, uint256 maxSlots)
		internal
		view
		returns (int256 usdcDelta, int256 units, bool held)
	{
		uint256 tradesLeft = tradingStorage.openTradesCount(address(this), pairIndex);
		uint256 ordersLeft = tradingStorage.openLimitOrdersCount(address(this), pairIndex);
		if (tradesLeft == 0 && ordersLeft == 0) return (0, 0, false);
		held = true;

		// Slot reads are try-wrapped exactly like Veranta's own Multicall ("skip row that
		// reverts on read") — one odd slot must never revert fund-wide GAV
		for (uint256 slot; slot < maxSlots && (tradesLeft > 0 || ordersLeft > 0); ++slot) {
			if (tradesLeft > 0) {
				try tradingStorage.openTrades(address(this), pairIndex, slot) returns (IVerantaTradingRouter.Trade memory t) {
					if (t.leverage != 0) {
						--tradesLeft;
						(int256 tradeUsdc, int256 tradeUnits) = _valueTrade(t, pairIndex, slot);
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
	}

	/// @dev One stored trade → its USDC-leg contribution and its signed coin units.
	///      STORED trades keep collateral in initialPosToken — positionSizeUSDC is a dummy
	///      there (fork-proven; it is collateral only on submission/pending).
	function _valueTrade(IVerantaTradingRouter.Trade memory t, uint256 pairIndex, uint256 slot)
		internal
		view
		returns (int256 usdcLeg, int256 units)
	{
		uint256 collateral = t.initialPosToken;
		// Veranta's own coinExposure: PositionMath.scaleByLeverage then usdcToCoinAtPrice
		uint256 coinExposure = (((collateral * t.leverage) / LEVERAGE_PRECISION) * PRICE_PRECISION * COIN_PRECISION)
			/ t.openPrice / USDC_PRECISION;
		// Accrued holding costs against the USDC leg (funding can be a credit)
		(, uint256 rolloverFee, int256 fundingFee) =
			verantaMulticall.getDynamicDataForPosition(address(this), pairIndex, slot);
		int256 fees = int256(rolloverFee) + fundingFee;

		// coinExposure (1e10) × openPrice (1e10) → USDC (1e6), Veranta's own conversion
		int256 notionalAtOpen = int256((coinExposure * t.openPrice * 1e6) / PRICE_PRECISION / COIN_PRECISION);

		address asset = positionFactory.pairAsset(pairIndex);
		if (asset != address(0)) {
			units = int256((coinExposure * 10 ** IERC20Metadata(asset).decimals()) / COIN_PRECISION);
		}
		if (t.buy) {
			usdcLeg = int256(collateral) - notionalAtOpen - fees;
		} else {
			usdcLeg = int256(collateral) + notionalAtOpen - fees;
			units = -units;
		}
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

/// @title VerantaPerpPositionV2Factory
/// @notice Type factory for V2 perp positions — V1's factory plus the PairStorage source
///         of the live pair count. Protocol-owned config, shared by every deployed position:
///         the pair→underlying mapping (which ERC20 the VI prices each Veranta pair against —
///         managers cannot self-map) and the pinned autopilot keeper.
contract VerantaPerpPositionV2Factory is IExternalPositionTypeFactory, Ownable2Step {
	IERC20 public immutable usdc;
	IVerantaTradingRouter public immutable router;
	IVerantaMulticall public immutable verantaMulticall;
	address public immutable tradingStorage;
	IVerantaPairStorage public immutable pairStorage;

	address public autopilotKeeper;
	/// @notice Veranta pairIndex → the ERC20 whose oracle prices that pair's underlying.
	mapping(uint256 => address) public pairAsset;
	/// @notice Veranta Referral contract + the protocol code positions link to (LinkReferral):
	///         the fund trades at the referred-trader fee discount; the rebate accrues to the
	///         code owner. Unset (0) = LinkReferral reverts.
	IVerantaReferral public referral;
	bytes32 public referralCode;

	event AutopilotKeeperSet(address indexed keeper);
	event PairAssetSet(uint256 indexed pairIndex, address indexed asset);
	event ReferralSet(address indexed referral, bytes32 indexed code);

	error ZeroAddress();

	constructor(
		IERC20 usdc_,
		IVerantaTradingRouter router_,
		IVerantaMulticall multicall_,
		address tradingStorage_,
		IVerantaPairStorage pairStorage_,
		address autopilotKeeper_
	) Ownable(msg.sender) {
		if (
			address(usdc_) == address(0) || address(router_) == address(0) || address(multicall_) == address(0)
				|| tradingStorage_ == address(0) || address(pairStorage_) == address(0) || autopilotKeeper_ == address(0)
		) {
			revert ZeroAddress();
		}
		usdc = usdc_;
		router = router_;
		verantaMulticall = multicall_;
		tradingStorage = tradingStorage_;
		pairStorage = pairStorage_;
		autopilotKeeper = autopilotKeeper_;
		emit AutopilotKeeperSet(autopilotKeeper_);
	}

	/// @notice Rotate the protocol keeper key. Applies to NEW SetAutopilot opt-ins; funds
	///         with an existing delegation keep it until they re-opt-in (or it expires).
	function setAutopilotKeeper(address keeper) external onlyOwner {
		if (keeper == address(0)) revert ZeroAddress();
		autopilotKeeper = keeper;
		emit AutopilotKeeperSet(keeper);
	}

	/// @notice Map a Veranta pair to its VI-priceable underlying (0 disables new opens).
	function setPairAsset(uint256 pairIndex, address asset) external onlyOwner {
		pairAsset[pairIndex] = asset;
		emit PairAssetSet(pairIndex, asset);
	}

	/// @notice Set the referral contract + protocol code for NEW LinkReferral calls; already
	///         linked positions keep their link until the manager links again.
	function setReferral(IVerantaReferral referral_, bytes32 code) external onlyOwner {
		referral = referral_;
		referralCode = code;
		emit ReferralSet(address(referral_), code);
	}

	/// @inheritdoc IExternalPositionTypeFactory
	function deployPosition(address comptroller, bytes calldata) external returns (address position) {
		position =
			address(new VerantaPerpPositionV2(comptroller, usdc, router, verantaMulticall, tradingStorage, pairStorage));
	}
}
