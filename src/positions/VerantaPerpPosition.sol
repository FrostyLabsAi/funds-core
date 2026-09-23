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
import {IVerantaTradingRouter, IVerantaMulticall} from '../interfaces/external/IVeranta.sol';

/// @title VerantaPerpPosition
/// @notice The fund's perp account on Veranta (Base-native oracle-execution perps; ex-Avantis)
///         — the hedge leg of the delta-neutral strategy, SELF-CUSTODIED. Unlike the
///         HyperliquidPerpPosition (off-EVM equity, attestor-priced), everything here is
///         on-chain on Base: this contract IS the trader, collateral is the fund's own USDC,
///         payouts can only ever come back here, and valuation reads Veranta's verified
///         contracts live — no attestor, no keeper custody of funds.
/// @dev VALUATION (linear decomposition — no price oracle needed in this contract):
///      a perp is reported to the ValueInterpreter as spot-equivalent legs, priced by the
///      SAME oracles that price the fund's long leg (basis consistency for delta-neutral GAV):
///        short: managed USDC += collateral + coinExposure*openPrice − accruedFees;
///               debt[underlying] += coinExposure
///        long:  managed[underlying] += coinExposure;
///               USDC leg += collateral − coinExposure*openPrice − accruedFees (usually negative → debt)
///      Pending market orders and resting limit orders are valued at their escrowed collateral.
///      KNOWN APPROXIMATIONS (documented, keeper-managed): Veranta's profit cap (2500% of
///      collateral) and the liquidation floor (value → 0 at −85%) are not modeled — the linear
///      value overstates GAV near liquidation and past the cap. The autopilot's margin monitor
///      keeps hedges far from both regimes; low-leverage shorts is the product.
///
///      AUTOPILOT (Veranta-native, opt-in per fund): the SetAutopilot action calls Veranta's
///      own setDelegate with the factory-pinned keeper — the delegate can rebalance the hedge
///      via delegatedAction but can NEVER withdraw funds, approve USDC, or delegate further
///      (enforced by Veranta's audited contracts, not ours). Expiry-bounded, revocable via
///      RemoveAutopilot. NOTE: delegate trades bypass this fund's policy hooks by design —
///      the manager's opt-in (which does pass policy hooks) is the consent gate.
///
///      TP/SL are intent-only on Veranta v2 (no public contract entry) — a contract trader
///      cannot set them; the keeper monitors margin instead.
contract VerantaPerpPosition is IExternalPosition {
	using SafeERC20 for IERC20;

	enum Action {
		OpenTrade,
		CloseTrade,
		CancelLimitOrder,
		CancelPendingMarketOrder,
		SetAutopilot,
		RemoveAutopilot,
		ReturnToVault
	}

	uint256 internal constant PRICE_PRECISION = 1e10;
	uint256 internal constant COIN_PRECISION = 1e10;

	address public immutable comptroller;
	VerantaPerpPositionFactory public immutable positionFactory;
	IERC20 public immutable usdc;
	IVerantaTradingRouter public immutable router;
	IVerantaMulticall public immutable verantaMulticall;

	/// @notice The keeper currently delegated on Veranta (0 = autopilot off).
	address public activeDelegate;

	event TradeOpened(uint256 indexed pairIndex, uint256 collateral, uint256 leverage, bool buy, uint8 orderType);
	event TradeClosed(uint256 indexed pairIndex, uint256 index, uint256 collateralAmount);
	event LimitOrderCancelled(uint256 indexed pairIndex, uint256 index);
	event PendingMarketOrderCancelled(uint256 indexed orderId);
	event AutopilotSet(address indexed delegate, uint256 expiry);
	event AutopilotRemoved(address indexed delegate);
	event ReturnedToVault(uint256 amount);

	error OnlyComptroller();
	error UnknownAction();
	error PairNotConfigured(uint256 pairIndex);
	error UnsupportedAsset(address asset);
	error AutopilotNotActive();

	modifier onlyComptroller() {
		if (msg.sender != comptroller) revert OnlyComptroller();
		_;
	}

	/// @dev Deployed only by VerantaPerpPositionFactory (the pair-mapping + keeper source).
	constructor(address comptroller_, IERC20 usdc_, IVerantaTradingRouter router_, IVerantaMulticall multicall_, address tradingStorage_) {
		comptroller = comptroller_;
		positionFactory = VerantaPerpPositionFactory(msg.sender);
		usdc = usdc_;
		router = router_;
		verantaMulticall = multicall_;
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
			(uint256 pairIndex, uint256 collateral, uint256 leverage, bool buy, uint256 openPrice, uint256 slippageP, uint8 orderType) =
				abi.decode(args, (uint256, uint256, uint256, bool, uint256, uint256, uint8));
			_openTrade(pairIndex, collateral, leverage, buy, openPrice, slippageP, orderType);
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
		} else {
			revert UnknownAction();
		}
	}

	function _openTrade(
		uint256 pairIndex,
		uint256 collateral,
		uint256 leverage,
		bool buy,
		uint256 openPrice,
		uint256 slippageP,
		uint8 orderType
	) internal {
		// The pair must be protocol-mapped to a VI-priceable underlying — GAV must never
		// hold a position it cannot value.
		address asset = positionFactory.pairAsset(pairIndex);
		if (asset == address(0)) revert PairNotConfigured(pairIndex);
		if (!Comptroller(comptroller).valueInterpreter().isSupportedAsset(asset)) {
			revert UnsupportedAsset(asset);
		}

		router.openTrade(
			IVerantaTradingRouter.Trade({
				trader: address(this),
				pairIndex: pairIndex,
				index: 0,
				initialPosToken: 0,
				positionSizeUSDC: collateral,
				openPrice: openPrice,
				buy: buy,
				leverage: leverage,
				tp: 0, // 0 = Veranta resets to the pair's max-gain cap
				sl: 0,
				timestamp: 0
			}),
			orderType,
			slippageP
		);
		emit TradeOpened(pairIndex, collateral, leverage, buy, orderType);
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

		// Escrowed collateral of in-flight market opens (operator fills or refunds)
		IVerantaMulticall.PendingOrder[] memory pending = verantaMulticall.getPendingOrder(address(this));
		for (uint256 i; i < pending.length; ++i) {
			usdcNet += int256(pending[i].orderInfo.trade.positionSizeUSDC);
		}

		(IVerantaMulticall.AggregatedTrade[] memory trades, IVerantaMulticall.AggregatedOpenLimitOrder[] memory limits)
			= verantaMulticall.getPositions(address(this));

		// Resting limit orders: collateral escrowed at face value
		for (uint256 i; i < limits.length; ++i) {
			usdcNet += int256(limits[i].order.positionSize);
		}

		tokens = new address[](trades.length);
		tokenAmts = new int256[](trades.length);
		for (uint256 i; i < trades.length; ++i) {
			IVerantaTradingRouter.Trade memory t = trades[i].trade;
			// STORED trades keep collateral in initialPosToken — positionSizeUSDC is a
			// dummy there (fork-proven; it is collateral only on submission/pending).
			uint256 collateral = t.initialPosToken;
			(,, int256 fundingFee) = verantaMulticall.getDynamicDataForPosition(address(this), t.pairIndex, t.index);
			// Accrued holding costs against the USDC leg (funding can be a credit)
			int256 fees = int256(trades[i].rolloverFee) + fundingFee;

			// coinExposure (1e10) × openPrice (1e10) → USDC (1e6), Veranta's own conversion
			int256 notionalAtOpen =
				int256((trades[i].coinExposure * t.openPrice * 1e6) / PRICE_PRECISION / COIN_PRECISION);

			address asset = positionFactory.pairAsset(t.pairIndex);
			// A pair zeroed mid-flight ("0 disables new opens") must DEGRADE, not brick
			// fund-wide GAV: keep the trade-local USDC leg, drop the unpriceable coin
			// leg (security review 2026-09-22, M-8)
			int256 units;
			if (asset != address(0)) {
				units = int256((trades[i].coinExposure * 10 ** IERC20Metadata(asset).decimals()) / COIN_PRECISION);
			}

			if (t.buy) {
				usdcNet += int256(collateral) - notionalAtOpen - fees;
			} else {
				usdcNet += int256(collateral) + notionalAtOpen - fees;
				units = -units;
			}
			if (asset == address(0)) continue;

			// Merge same-underlying legs (multiple trades per pair / pairs sharing an asset)
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

/// @title VerantaPerpPositionFactory
/// @notice Type factory for Veranta perp positions. Protocol-owned config, shared by every
///         deployed position: the pair→underlying mapping (which ERC20 the VI prices each
///         Veranta pair against — managers cannot self-map) and the pinned autopilot keeper
///         (rotatable; same trust pattern as the HL attestor pin).
contract VerantaPerpPositionFactory is IExternalPositionTypeFactory, Ownable2Step {
	IERC20 public immutable usdc;
	IVerantaTradingRouter public immutable router;
	IVerantaMulticall public immutable verantaMulticall;
	address public immutable tradingStorage;

	address public autopilotKeeper;
	/// @notice Veranta pairIndex → the ERC20 whose oracle prices that pair's underlying.
	mapping(uint256 => address) public pairAsset;

	event AutopilotKeeperSet(address indexed keeper);
	event PairAssetSet(uint256 indexed pairIndex, address indexed asset);

	error ZeroAddress();

	constructor(
		IERC20 usdc_,
		IVerantaTradingRouter router_,
		IVerantaMulticall multicall_,
		address tradingStorage_,
		address autopilotKeeper_
	) Ownable(msg.sender) {
		if (address(usdc_) == address(0) || address(router_) == address(0) || address(multicall_) == address(0) || tradingStorage_ == address(0) || autopilotKeeper_ == address(0)) {
			revert ZeroAddress();
		}
		usdc = usdc_;
		router = router_;
		verantaMulticall = multicall_;
		tradingStorage = tradingStorage_;
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

	/// @inheritdoc IExternalPositionTypeFactory
	function deployPosition(address comptroller, bytes calldata) external returns (address position) {
		position = address(new VerantaPerpPosition(comptroller, usdc, router, verantaMulticall, tradingStorage));
	}
}
