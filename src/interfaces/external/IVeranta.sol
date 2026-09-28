// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title Veranta (ex-Avantis) v2 external interfaces
/// @notice From the verified Base proxies: TradingRouter `0x44914408af82bC9983bbb330e3578E1105e11d4e`,
///         Multicall `0xA7cFc43872F4D7B0E6141ee8c36f1F7FEe5d099e`, TradingStorage
///         `0x8a311D7048c35985aa31C131B9A13e03a5f7422d` (USDC collateral is pulled via allowance to it).
/// @dev Struct member names may differ from Veranta's (ABI layout is what matters; `block` is
///      `blockNumber` here). Scales: USDC 1e6; prices/leverage/slippage/coinExposure 1e10.
interface IVerantaTradingRouter {
	/// @dev Field meaning differs by stage: on submission (openTrade) collateral is in
	///      positionSizeUSDC; once stored (openTrades / Multicall rows) it is in initialPosToken
	///      and positionSizeUSDC is a dummy. Pending market orders keep the submitted form.
	struct Trade {
		address trader;
		uint256 pairIndex;
		uint256 index;
		uint256 initialPosToken; // STORED trades: collateral (1e6); 0 on submission
		uint256 positionSizeUSDC; // SUBMISSION: collateral (1e6) — dummy once stored
		uint256 openPrice; // 1e10
		bool buy;
		uint256 leverage; // 1e10
		uint256 tp;
		uint256 sl;
		uint256 timestamp;
	}

	/// @dev _type: 0=market, 1=stop_limit, 2=limit, 3=market_pnl (Upside).
	///      Market opens are two-step: this stores a pending order that Veranta's operator
	///      fills at the oracle price (or it expires and refunds).
	function openTrade(Trade calldata _trade, uint8 _type, uint256 _slippageP) external payable;

	/// @dev _amount = collateral (1e6) to close; full collateral = full close.
	function closeTradeMarket(uint256 _pairIndex, uint256 _index, uint256 _amount, uint256 _wantedPrice)
		external
		payable;

	function cancelOpenLimitOrder(uint256 _pairIndex, uint256 _index) external;
	function cancelPendingMarketOrder(uint256 _order) external;

	/// @dev Single-tx margin change; the caller supplies the Pyth payload. _type 0=DEPOSIT 1=WITHDRAW;
	///      msg.value covers pyth.getUpdateFee (read it, never hardcode); _priceSourcing 0=PYTH_CORE.
	///      An empty payload works when the stored Pyth price is <30s old. DEPOSIT pulls USDC and
	///      credits collateral minus a small venue fee; WITHDRAW pays the trader only. Delegatable.
	function updateMargin(
		uint256 _pairIndex,
		uint256 _index,
		uint8 _type,
		uint256 _amount,
		bytes[] calldata priceUpdateData,
		uint8 _priceSourcing
	) external payable;

	/// @dev Veranta's own delegation: a delegate may trade on the trader's behalf via
	///      delegatedAction but can NEVER move funds, approve USDC, or manage delegations.
	function setDelegate(address _delegate, uint256 _expiry) external;
	function removeDelegate(address delegate) external;
	function multipleDelegations(address trader, address delegate)
		external
		view
		returns (bool isEnabled, uint256 expiry);
}

interface IVerantaMulticall {
	struct TradeInfo {
		uint256 openInterestUSDC;
		uint256 tpLastUpdated;
		uint256 slLastUpdated;
		bool beingMarketClosed;
		uint256 lossProtection;
	}

	struct AggregatedTrade {
		IVerantaTradingRouter.Trade trade;
		TradeInfo tradeInfo;
		uint256 rolloverFee; // accrued, 1e6
		uint256 liquidationPrice; // 1e10
		bool isPnl;
		uint256 coinExposure; // base-asset units, 1e10
	}

	struct AggregatedLimitOrder {
		address trader;
		uint256 pairIndex;
		uint256 index;
		uint256 positionSize; // escrowed collateral, 1e6
		bool buy;
		uint256 leverage;
		uint256 tp;
		uint256 sl;
		uint256 price;
		uint256 slippageP;
		uint256 blockNumber;
		uint256 executionFee;
	}

	struct AggregatedOpenLimitOrder {
		AggregatedLimitOrder order;
		uint256 liquidationPrice;
		uint8 orderType;
		uint256 coinExposure;
	}

	struct PendingOrderInfo {
		IVerantaTradingRouter.Trade trade;
		uint256 blockNumber;
		uint256 wantedPrice;
		uint256 slippageP;
	}

	struct PendingOrder {
		uint256 orderId;
		PendingOrderInfo orderInfo;
	}

	/// @dev Compact arrays — active entries only.
	function getPositions(address userAddress)
		external
		view
		returns (AggregatedTrade[] memory trades, AggregatedOpenLimitOrder[] memory limitOrders);

	function getPendingOrder(address _trader) external view returns (PendingOrder[] memory pendingOrders);

	function getDynamicDataForPosition(address trader, uint256 pairIndex, uint256 index)
		external
		view
		returns (uint256 liquidationPrice, uint256 rolloverFee, int256 unrealisedFundingFee);
}

/// @notice Veranta TradingStorage per-trader reads (verified via Multicall impl
///         0x8b44d59d2db7b2e191b1388b78465756cab91159). Two count reads per pair and slot reads only
///         where non-zero, instead of Multicall.getPositions (~1.6–1.9M gas per pair).
interface IVerantaTradingStorage {
	function openTradesCount(address trader, uint256 pairIndex) external view returns (uint256);
	function openLimitOrdersCount(address trader, uint256 pairIndex) external view returns (uint256);
	function maxTradesPerPair() external view returns (uint256);
	function openTrades(address trader, uint256 pairIndex, uint256 index)
		external
		view
		returns (IVerantaTradingRouter.Trade memory);
	/// @dev Same field layout as ITradingStorage.OpenLimitOrder (`block` ↔ blockNumber).
	function getOpenLimitOrder(address trader, uint256 pairIndex, uint256 index)
		external
		view
		returns (IVerantaMulticall.AggregatedLimitOrder memory);
}

/// @notice Veranta PairStorage (Multicall.pairsStorage()) — the live pair count.
interface IVerantaPairStorage {
	function pairsCount() external view returns (uint256);
}

/// @notice Veranta Referral (Base 0x1A110bBA13A1f16cCa4b79758BD39290f29De82D). Linking is
///         caller-scoped: the trader itself must call; a delegate cannot.
interface IVerantaReferral {
	function setTraderReferralCodeByUser(bytes32 code) external;
	function traderReferralCodes(address trader) external view returns (bytes32);
}
