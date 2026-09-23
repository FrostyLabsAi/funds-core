// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IVerantaTradingRouter, IVerantaMulticall} from '../../src/interfaces/external/IVeranta.sol';

/// @notice One mock playing Veranta's whole surface: TradingRouter (writes), Multicall
///         (reads) and TradingStorage (the USDC spender). Mirrors the real two-step market
///         open: openTrade escrows collateral as a PENDING order; the test acts as the
///         operator via fillPending / expirePending.
contract MockVeranta is IVerantaTradingRouter, IVerantaMulticall {
	IERC20 public immutable usdc;

	PendingOrder[] internal _pending;
	AggregatedTrade[] internal _trades;
	AggregatedOpenLimitOrder[] internal _limits;
	mapping(uint256 => mapping(uint256 => int256)) public fundingFee; // pairIndex => index => fee
	mapping(address => mapping(address => uint256)) public delegations;
	uint256 internal _nextOrderId = 1;
	/// @dev Transient delegated-trader context (mirrors the real router's delegatedAction).
	address internal _delegatedTrader;

	constructor(IERC20 usdc_) {
		usdc = usdc_;
	}

	// ─── IVerantaTradingRouter ───────────────────────────────────────────────────

	/// @notice The keeper's path: a delegate executes trade calls in the trader's context.
	///         Mirrors the real router: delegation must be enabled and unexpired; the
	///         delegate can trade but funds only ever move trader ↔ venue.
	function delegatedAction(address trader, bytes calldata call_data) external payable {
		uint256 expiry = delegations[trader][msg.sender];
		require(expiry != 0 && expiry > block.timestamp, 'MockVeranta: not delegated');
		_delegatedTrader = trader;
		(bool ok, bytes memory ret) = address(this).call(call_data);
		_delegatedTrader = address(0);
		if (!ok) {
			assembly { revert(add(ret, 32), mload(ret)) }
		}
	}

	function _trader() internal view returns (address) {
		return _delegatedTrader != address(0) ? _delegatedTrader : msg.sender;
	}

	function openTrade(Trade calldata _trade, uint8, uint256 _slippageP) external payable {
		require(_trade.trader == _trader(), 'MockVeranta: trader mismatch');
		usdc.transferFrom(_trade.trader, address(this), _trade.positionSizeUSDC);
		_pending.push(
			PendingOrder({
				orderId: _nextOrderId++,
				orderInfo: PendingOrderInfo({
					trade: _trade,
					blockNumber: block.number,
					wantedPrice: _trade.openPrice,
					slippageP: _slippageP
				})
			})
		);
	}

	function closeTradeMarket(uint256 _pairIndex, uint256 _index, uint256 _amount, uint256) external payable {
		// Real semantics: _amount = collateral (1e6) to close; partial closes shrink the
		// trade proportionally. Instant at open price for test simplicity (PnL 0).
		address trader = _trader();
		for (uint256 i; i < _trades.length; ++i) {
			Trade storage t = _trades[i].trade;
			if (t.trader == trader && t.pairIndex == _pairIndex && t.index == _index) {
				uint256 collateral = t.initialPosToken;
				uint256 toClose = _amount > collateral ? collateral : _amount;
				usdc.transfer(trader, toClose);
				if (toClose == collateral) {
					_trades[i] = _trades[_trades.length - 1];
					_trades.pop();
				} else {
					_trades[i].coinExposure -= (_trades[i].coinExposure * toClose) / collateral;
					t.initialPosToken = collateral - toClose;
				}
				return;
			}
		}
		revert('MockVeranta: no trade');
	}

	/// @notice Mirrors the fork-proven single-tx margin flow: DEPOSIT pulls USDC from the
	///         TRADER (delegation context included) and credits collateral minus the small
	///         venue processing fee (~3bps observed live); WITHDRAW pays the trader only.
	///         The Pyth payload/msg.value are accepted and ignored (fee is 0 wei on Base).
	function updateMargin(uint256 _pairIndex, uint256 _index, uint8 _type, uint256 _amount, bytes[] calldata, uint8)
		external
		payable
	{
		address trader = _trader();
		for (uint256 i; i < _trades.length; ++i) {
			Trade storage t = _trades[i].trade;
			if (t.trader == trader && t.pairIndex == _pairIndex && t.index == _index) {
				if (_type == 0) {
					usdc.transferFrom(trader, address(this), _amount);
					t.initialPosToken += _amount - (_amount * 3) / 10_000;
				} else {
					require(t.initialPosToken > _amount, 'MockVeranta: margin underflow');
					t.initialPosToken -= _amount;
					usdc.transfer(trader, _amount);
				}
				return;
			}
		}
		revert('MockVeranta: no trade');
	}

	function cancelOpenLimitOrder(uint256 _pairIndex, uint256 _index) external {
		for (uint256 i; i < _limits.length; ++i) {
			if (_limits[i].order.pairIndex == _pairIndex && _limits[i].order.index == _index) {
				usdc.transfer(_limits[i].order.trader, _limits[i].order.positionSize);
				_limits[i] = _limits[_limits.length - 1];
				_limits.pop();
				return;
			}
		}
		revert('MockVeranta: no limit order');
	}

	function cancelPendingMarketOrder(uint256 _order) external {
		for (uint256 i; i < _pending.length; ++i) {
			if (_pending[i].orderId == _order) {
				usdc.transfer(_pending[i].orderInfo.trade.trader, _pending[i].orderInfo.trade.positionSizeUSDC);
				_pending[i] = _pending[_pending.length - 1];
				_pending.pop();
				return;
			}
		}
		revert('MockVeranta: no pending order');
	}

	function setDelegate(address _delegate, uint256 _expiry) external {
		delegations[msg.sender][_delegate] = _expiry;
	}

	function removeDelegate(address delegate) external {
		delegations[msg.sender][delegate] = 0;
	}

	function multipleDelegations(address trader, address delegate) external view returns (bool, uint256) {
		uint256 expiry = delegations[trader][delegate];
		return (expiry != 0, expiry);
	}

	// ─── Pyth stand-in (keeper margin path reads these; fees are 0 wei on Base too) ─

	function getUpdateFee(bytes[] calldata) external pure returns (uint256) {
		return 0;
	}

	function getPriceUnsafe(bytes32) external view returns (int64, uint64, int32, uint256) {
		return (0, 0, 0, block.timestamp); // always fresh — payload-free top-ups allowed
	}

	// ─── Test-side operator controls ─────────────────────────────────────────────

	/// @notice "Operator fills" the oldest pending order at `fillPrice`, sizing coinExposure
	///         exactly like Veranta: notional (collateral × leverage) / price, 1e10 scale.
	function fillPending(uint256 fillPrice) external {
		require(_pending.length > 0, 'MockVeranta: nothing pending');
		Trade memory t = _pending[0].orderInfo.trade;
		_pending[0] = _pending[_pending.length - 1];
		_pending.pop();

		t.openPrice = fillPrice;
		uint256 coinExposure = (t.positionSizeUSDC * t.leverage * 1e10) / fillPrice / 1e6;
		// Faithful to the live venue: stored trades carry collateral in initialPosToken;
		// positionSizeUSDC becomes a dummy (a timestamp-magnitude value, like mainnet rows —
		// anything valuing or sizing off it must fail loudly in tests).
		t.initialPosToken = t.positionSizeUSDC;
		t.positionSizeUSDC = block.timestamp;
		_trades.push(
			AggregatedTrade({
				trade: t,
				tradeInfo: TradeInfo({
					openInterestUSDC: 0,
					tpLastUpdated: 0,
					slLastUpdated: 0,
					beingMarketClosed: false,
					lossProtection: 0
				}),
				rolloverFee: 0,
				liquidationPrice: 0,
				isPnl: false,
				coinExposure: coinExposure
			})
		);
	}

	function setRolloverFee(uint256 tradeIdx, uint256 fee) external {
		_trades[tradeIdx].rolloverFee = fee;
	}

	function setFundingFee(uint256 pairIndex, uint256 index, int256 fee) external {
		fundingFee[pairIndex][index] = fee;
	}

	function pushLimitOrder(address trader, uint256 pairIndex, uint256 index, uint256 positionSize) external {
		usdc.transferFrom(trader, address(this), positionSize);
		AggregatedLimitOrder memory order;
		order.trader = trader;
		order.pairIndex = pairIndex;
		order.index = index;
		order.positionSize = positionSize;
		_limits.push(AggregatedOpenLimitOrder({order: order, liquidationPrice: 0, orderType: 3, coinExposure: 0}));
	}

	// ─── IVerantaMulticall ───────────────────────────────────────────────────────

	/// @dev Pair-ranged variant (the keeper's fast path). End bound treated as inclusive
	///      like a defensive superset — our keeper filters rows by exact pair anyway.
	function getPositionsForPairIndexes(address userAddress, uint256 startPairIndex, uint256 endPairIndex, uint256)
		external
		view
		returns (AggregatedTrade[] memory trades, AggregatedOpenLimitOrder[] memory limitOrders)
	{
		AggregatedTrade[] memory all = _filterTrades(userAddress);
		uint256 count;
		for (uint256 i; i < all.length; ++i) {
			if (all[i].trade.pairIndex >= startPairIndex && all[i].trade.pairIndex <= endPairIndex) ++count;
		}
		trades = new AggregatedTrade[](count);
		uint256 j;
		for (uint256 i; i < all.length; ++i) {
			if (all[i].trade.pairIndex >= startPairIndex && all[i].trade.pairIndex <= endPairIndex) trades[j++] = all[i];
		}
		limitOrders = new AggregatedOpenLimitOrder[](0);
	}

	function getPositions(address userAddress)
		external
		view
		returns (AggregatedTrade[] memory trades, AggregatedOpenLimitOrder[] memory limitOrders)
	{
		trades = _filterTrades(userAddress);
		uint256 count;
		for (uint256 i; i < _limits.length; ++i) {
			if (_limits[i].order.trader == userAddress) ++count;
		}
		limitOrders = new AggregatedOpenLimitOrder[](count);
		uint256 j;
		for (uint256 i; i < _limits.length; ++i) {
			if (_limits[i].order.trader == userAddress) limitOrders[j++] = _limits[i];
		}
	}

	function getPendingOrder(address _trader) external view returns (PendingOrder[] memory pendingOrders) {
		uint256 count;
		for (uint256 i; i < _pending.length; ++i) {
			if (_pending[i].orderInfo.trade.trader == _trader) ++count;
		}
		pendingOrders = new PendingOrder[](count);
		uint256 j;
		for (uint256 i; i < _pending.length; ++i) {
			if (_pending[i].orderInfo.trade.trader == _trader) pendingOrders[j++] = _pending[i];
		}
	}

	function getDynamicDataForPosition(address, uint256 pairIndex, uint256 index)
		external
		view
		returns (uint256, uint256, int256)
	{
		return (0, 0, fundingFee[pairIndex][index]);
	}

	function _filterTrades(address trader) internal view returns (AggregatedTrade[] memory trades) {
		uint256 count;
		for (uint256 i; i < _trades.length; ++i) {
			if (_trades[i].trade.trader == trader) ++count;
		}
		trades = new AggregatedTrade[](count);
		uint256 j;
		for (uint256 i; i < _trades.length; ++i) {
			if (_trades[i].trade.trader == trader) trades[j++] = _trades[i];
		}
	}
}
