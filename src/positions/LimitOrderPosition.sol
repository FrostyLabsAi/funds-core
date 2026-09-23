// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IExternalPosition} from '../interfaces/IExternalPosition.sol';
import {IExternalPositionTypeFactory} from '../interfaces/IExternalPositionTypeFactory.sol';
import {Comptroller} from '../core/Comptroller.sol';

/// @title LimitOrderPosition
/// @notice On-chain resting limit orders for funds — the order-book venue class
///         (melon-terminal's OasisDex/0x lane) rebuilt for a contract-custody world.
///         Off-chain orderbooks (1inch LOP, CoW) need the maker to SIGN orders; a fund
///         vault is a contract with deliberately no arbitrary-call or signing power, so
///         instead the order rests here ON-CHAIN: the manager escrows inventory and
///         commits to a fixed limit rate; any taker (arb bots, our keeper, anyone) fills
///         at that rate or better, in whole or in part, until expiry.
/// @dev Custody guarantees preserved: inventory sits in this position (valued into GAV
///      the whole time via getManagedAssets — both legs are always VI-priced), proceeds
///      accumulate here, and only the ReturnToVault action (comptroller-gated) moves
///      funds home — always to the vault, never to an arbitrary address. Fully on-chain:
///      no attestor, no off-chain book, testnet-testable end to end.
contract LimitOrderPosition is IExternalPosition {
	using SafeERC20 for IERC20;

	enum Action {
		PlaceOrder,
		CancelOrder,
		ReturnToVault
	}

	struct Order {
		address sellToken;
		address buyToken;
		uint128 sellRemaining; // inventory still for sale
		uint128 buyRemaining; // buyToken still owed for sellRemaining (fixes the limit rate)
		uint64 expiry;
	}

	address public immutable comptroller;

	uint256 internal constant BPS = 10_000;
	/// @notice Max discount vs the ValueInterpreter cross-rate an exchange may impose on
	///         the fund — enforced at placement AND at every fill (security review
	///         2026-09-22, C-3: without it a manager could rest a sell at any price and
	///         self-fill, draining the fund past every policy). Fills where the fund
	///         RECEIVES more than it gives are always allowed — only the downside is
	///         banded. 1% barely touches honest resting orders (they fill at the moment
	///         the market crosses the limit, i.e. ~zero discount).
	uint256 public constant MAX_ORACLE_DISCOUNT_BPS = 100;
	/// @notice Fill-discount budget: fills may cost the fund at most this fraction of
	///         the position's held value per period, linearly replenishing — the same
	///         rate-limit philosophy as CumulativeSlippageTolerancePolicy, enforced HERE
	///         because fills are taker-side transactions no comptroller hook ever sees.
	///         Kills the cycle-the-band skim (place at −1%, self-fill, repeat).
	uint256 public constant MAX_FILL_DISCOUNT_BPS_PER_PERIOD = 200;
	uint256 public constant DISCOUNT_TOLERANCE_PERIOD = 7 days;

	uint256 public fillDiscountUsed; // denomination units, replenishes linearly
	uint64 public fillDiscountLastUpdate;

	uint256 public orderCount;
	mapping(uint256 => Order) public orders;
	/// @notice Per-token inventory reserved by open orders — ReturnToVault can never
	///         strip escrow out from under a resting order.
	mapping(address => uint256) public committed;

	address[] internal heldAssets;
	mapping(address => bool) internal isHeld;

	event OrderPlaced(
		uint256 indexed orderId, address indexed sellToken, address indexed buyToken,
		uint256 sellAmount, uint256 minBuyAmount, uint64 expiry
	);
	event OrderCancelled(uint256 indexed orderId);
	event OrderFilled(uint256 indexed orderId, address indexed taker, uint256 sellFilled, uint256 buyPaid);
	event ReturnedToVault(address indexed asset, uint256 amount);

	error OnlyComptroller();
	error UnknownAction();
	error InvalidOrder();
	error OrderInactive(uint256 orderId);
	error OrderExpired(uint256 orderId);
	error InsufficientInventory();
	error InventoryCommitted();
	error UnsupportedAsset(address asset);
	error ZeroFill();
	error BelowOracleBand(uint256 valueIn, uint256 minValueIn);
	error FillDiscountBudgetExceeded(uint256 used, uint256 budget);

	modifier onlyComptroller() {
		if (msg.sender != comptroller) revert OnlyComptroller();
		_;
	}

	constructor(address comptroller_) {
		comptroller = comptroller_;
	}

	// ─── Manager actions (via Comptroller.callOnExternalPosition) ───────────────

	/// @inheritdoc IExternalPosition
	function receiveCallFromFund(bytes calldata actionData) external onlyComptroller {
		(uint8 rawAction, bytes memory args) = abi.decode(actionData, (uint8, bytes));

		if (rawAction == uint8(Action.PlaceOrder)) {
			(address sellToken, address buyToken, uint128 sellAmount, uint128 minBuyAmount, uint64 expiry) =
				abi.decode(args, (address, address, uint128, uint128, uint64));
			_placeOrder(sellToken, buyToken, sellAmount, minBuyAmount, expiry);
		} else if (rawAction == uint8(Action.CancelOrder)) {
			uint256 orderId = abi.decode(args, (uint256));
			Order storage order = orders[orderId];
			if (order.sellRemaining == 0) revert OrderInactive(orderId);
			committed[order.sellToken] -= order.sellRemaining;
			order.sellRemaining = 0;
			order.buyRemaining = 0;
			emit OrderCancelled(orderId);
		} else if (rawAction == uint8(Action.ReturnToVault)) {
			(address asset, uint256 amount) = abi.decode(args, (address, uint256));
			if (IERC20(asset).balanceOf(address(this)) < committed[asset] + amount) revert InventoryCommitted();
			IERC20(asset).safeTransfer(address(Comptroller(comptroller).vault()), amount);
			emit ReturnedToVault(asset, amount);
		} else {
			revert UnknownAction();
		}
	}

	function _placeOrder(address sellToken, address buyToken, uint128 sellAmount, uint128 minBuyAmount, uint64 expiry)
		internal
	{
		if (sellAmount == 0 || minBuyAmount == 0 || sellToken == buyToken || expiry <= block.timestamp) {
			revert InvalidOrder();
		}
		// Both legs must be protocol-priceable — GAV must never brick on a fill
		if (!Comptroller(comptroller).valueInterpreter().isSupportedAsset(buyToken)) {
			revert UnsupportedAsset(buyToken);
		}
		// The limit rate may never underpay the fund beyond the oracle band; valuing the
		// sell leg here also rejects unsupported sellTokens (which would brick GAV once
		// held — review H-2's limit-order ingestion path).
		_requireWithinOracleBand(sellToken, sellAmount, buyToken, minBuyAmount);
		if (IERC20(sellToken).balanceOf(address(this)) < committed[sellToken] + sellAmount) {
			revert InsufficientInventory();
		}

		committed[sellToken] += sellAmount;
		uint256 orderId = ++orderCount;
		orders[orderId] = Order({
			sellToken: sellToken,
			buyToken: buyToken,
			sellRemaining: sellAmount,
			buyRemaining: minBuyAmount,
			expiry: expiry
		});
		_hold(sellToken);
		_hold(buyToken);
		emit OrderPlaced(orderId, sellToken, buyToken, sellAmount, minBuyAmount, expiry);
	}

	// ─── Taker side (public — anyone can fill at the limit rate or better) ──────

	/// @notice Fill an order: pay `buyAmount` of the order's buyToken, receive sellToken
	///         pro-rata at the order's fixed limit rate. Partial fills welcome.
	function fill(uint256 orderId, uint256 buyAmount) external {
		Order storage order = orders[orderId];
		if (order.sellRemaining == 0) revert OrderInactive(orderId);
		if (block.timestamp > order.expiry) revert OrderExpired(orderId);

		uint256 sellOut;
		if (buyAmount >= order.buyRemaining) {
			// Full fill of the remainder — taker pays exactly what is owed
			buyAmount = order.buyRemaining;
			sellOut = order.sellRemaining;
		} else {
			// Pro-rata at the fixed rate, rounded down (in the fund's favor)
			sellOut = (uint256(order.sellRemaining) * buyAmount) / order.buyRemaining;
		}
		if (sellOut == 0) revert ZeroFill();

		// Re-check at fill time: a parity order placed before a large market move must
		// not become a drain (fills price at CURRENT oracle, so fills of equity legs
		// revert while feeds are stale — same market-hours discipline as deposits).
		(uint256 valueOut, uint256 valueIn) = _requireWithinOracleBand(order.sellToken, sellOut, order.buyToken, buyAmount);
		_accrueFillDiscount(valueOut, valueIn);

		order.sellRemaining -= uint128(sellOut);
		order.buyRemaining -= uint128(buyAmount);
		committed[order.sellToken] -= sellOut;

		IERC20(order.buyToken).safeTransferFrom(msg.sender, address(this), buyAmount);
		IERC20(order.sellToken).safeTransfer(msg.sender, sellOut);
		emit OrderFilled(orderId, msg.sender, sellOut, buyAmount);
	}

	/// @dev What the fund receives must be worth ≥ (1 − MAX_ORACLE_DISCOUNT_BPS) of what
	///      it gives up, both legs valued through the denomination asset (always a
	///      primitive, so derivative legs price too). Reverts UnsupportedAsset for any
	///      leg the ValueInterpreter can't price. Returns both leg values so fill() can
	///      run the cumulative-discount budget on top.
	function _requireWithinOracleBand(address sellToken, uint256 sellAmount, address buyToken, uint256 buyAmount)
		internal
		returns (uint256 valueOut, uint256 valueIn)
	{
		Comptroller fund = Comptroller(comptroller);
		address denomination = address(fund.denominationAsset());
		valueOut = fund.valueInterpreter().calcCanonicalAssetValue(sellToken, sellAmount, denomination);
		valueIn = fund.valueInterpreter().calcCanonicalAssetValue(buyToken, buyAmount, denomination);
		uint256 minValueIn = (valueOut * (BPS - MAX_ORACLE_DISCOUNT_BPS)) / BPS;
		if (valueIn < minValueIn) revert BelowOracleBand(valueIn, minValueIn);
	}

	/// @dev Rate-limit the value fills may cost the fund: each fill's discount draws on
	///      a budget of MAX_FILL_DISCOUNT_BPS_PER_PERIOD of the position's current held
	///      value, replenishing linearly over DISCOUNT_TOLERANCE_PERIOD. Premium fills
	///      (fund receives more than it gives) consume nothing.
	function _accrueFillDiscount(uint256 valueOut, uint256 valueIn) internal {
		if (valueIn >= valueOut) return;
		uint256 discount = valueOut - valueIn;

		Comptroller fund = Comptroller(comptroller);
		address denomination = address(fund.denominationAsset());
		uint256 heldValue;
		for (uint256 i; i < heldAssets.length; ++i) {
			uint256 balance = IERC20(heldAssets[i]).balanceOf(address(this));
			if (balance > 0) {
				heldValue += fund.valueInterpreter().calcCanonicalAssetValue(heldAssets[i], balance, denomination);
			}
		}
		uint256 budget = (heldValue * MAX_FILL_DISCOUNT_BPS_PER_PERIOD) / BPS;

		uint256 used = fillDiscountUsed;
		if (used > 0 && fillDiscountLastUpdate > 0) {
			uint256 replenished = (budget * (block.timestamp - fillDiscountLastUpdate)) / DISCOUNT_TOLERANCE_PERIOD;
			used = replenished >= used ? 0 : used - replenished;
		}
		used += discount;
		if (used > budget) revert FillDiscountBudgetExceeded(used, budget);
		fillDiscountUsed = used;
		fillDiscountLastUpdate = uint64(block.timestamp);
	}

	// ─── IExternalPosition ───────────────────────────────────────────────────────

	/// @inheritdoc IExternalPosition
	function getManagedAssets() external view returns (address[] memory assets, uint256[] memory amounts) {
		uint256 count;
		uint256 total = heldAssets.length;
		uint256[] memory balances = new uint256[](total);
		for (uint256 i; i < total; ++i) {
			balances[i] = IERC20(heldAssets[i]).balanceOf(address(this));
			if (balances[i] > 0) ++count;
		}
		assets = new address[](count);
		amounts = new uint256[](count);
		uint256 j;
		for (uint256 i; i < total; ++i) {
			if (balances[i] > 0) {
				assets[j] = heldAssets[i];
				amounts[j] = balances[i];
				++j;
			}
		}
	}

	/// @inheritdoc IExternalPosition
	function getDebtAssets() external pure returns (address[] memory assets, uint256[] memory amounts) {
		assets = new address[](0);
		amounts = new uint256[](0);
	}

	function _hold(address asset) internal {
		if (!isHeld[asset]) {
			isHeld[asset] = true;
			heldAssets.push(asset);
		}
	}
}

/// @title LimitOrderPositionFactory
/// @notice Type factory for the on-chain order-book venue. Stateless: no attestor, no
///         config — every fund gets a fresh, fully on-chain-valued position.
contract LimitOrderPositionFactory is IExternalPositionTypeFactory {
	/// @inheritdoc IExternalPositionTypeFactory
	function deployPosition(address comptroller, bytes calldata) external returns (address position) {
		position = address(new LimitOrderPosition(comptroller));
	}
}
