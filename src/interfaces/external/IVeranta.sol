// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title Veranta (ex-Avantis) v2 external interfaces
/// @notice Transcribed from the VERIFIED proxies on Base mainnet (checked 2026-09-14):
///         TradingRouter `0x44914408af82bC9983bbb330e3578E1105e11d4e` (impl TradingRouter),
///         Multicall     `0xA7cFc43872F4D7B0E6141ee8c36f1F7FEe5d099e` (impl Multicall),
///         TradingStorage `0x8a311D7048c35985aa31C131B9A13e03a5f7422d` — USDC collateral is
///         pulled from the trader via allowance to TradingStorage.
/// @dev Struct member names may differ from Veranta's source (ABI layout is what matters);
///      notably their `block` members are renamed `blockNumber` here. Scales: USDC 1e6,
///      prices/leverage/slippage/coinExposure 1e10.
interface IVerantaTradingRouter {
	/// @dev FIELD SEMANTICS differ between submission and storage (fork-proven vs live
	///      trades 2026-09-15; their own source comments initialPosToken "collateral" and
	///      positionSizeUSDC "dummy"): on SUBMISSION (openTrade) collateral goes in
	///      positionSizeUSDC; once STORED (openTrades / Multicall rows) collateral lives in
	///      initialPosToken and positionSizeUSDC holds a dummy. Pending market orders keep
	///      the submitted form (storePendingMarketOpenOrder stores the struct verbatim).
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

	/// @dev SINGLE-TX margin change (fork-proven): the caller supplies the Pyth payload and
	///      the aggregator fulfills inline — no operator round-trip. _type 0=DEPOSIT
	///      1=WITHDRAW; msg.value must cover pyth.getUpdateFee(priceUpdateData) (0 wei on
	///      Base today — read it, never hardcode); _priceSourcing 0=PYTH_CORE. An empty
	///      payload works when the stored Pyth price is <30s old. DEPOSIT pulls USDC from
	///      the trader and credits collateral minus a small venue fee (~3bps observed);
	///      WITHDRAW pays the trader only. Delegatable via delegatedAction.
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
