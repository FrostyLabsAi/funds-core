// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IExternalPosition} from '../interfaces/IExternalPosition.sol';
import {IExternalPositionTypeFactory} from '../interfaces/IExternalPositionTypeFactory.sol';
import {Comptroller} from '../core/Comptroller.sol';

/// @title LimitOrderPosition
/// @notice On-chain resting limit orders for a fund: the manager escrows inventory at a fixed
///         limit rate and any taker fills it, fully or partially, until expiry.
/// @dev Inventory and proceeds stay here (counted in GAV); only ReturnToVault moves them, and
///      only to the fund's vault.
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
	/// @notice Max discount vs the oracle cross-rate the fund may take, checked at placement and
	///         at every fill (stops a manager self-filling a mispriced order). Premium fills always pass.
	uint256 public constant MAX_ORACLE_DISCOUNT_BPS = 100;
	/// @notice Fills may cost the fund at most this share of the position's held value per
	///         period, replenishing linearly (stops repeated in-band self-fills).
	uint256 public constant MAX_FILL_DISCOUNT_BPS_PER_PERIOD = 200;
	uint256 public constant DISCOUNT_TOLERANCE_PERIOD = 7 days;

	uint256 public fillDiscountUsed; // denomination units, replenishes linearly
	uint64 public fillDiscountLastUpdate;

	uint256 public orderCount;
	mapping(uint256 => Order) public orders;
	/// @notice Per-token inventory reserved by open orders; ReturnToVault can't touch it.
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
	/// @dev Cancel and ReturnToVault only move value back toward the fund; placing an order is always priced.
	function isRiskReducing(bytes calldata actionData) external pure returns (bool) {
		(uint8 rawAction,) = abi.decode(actionData, (uint8, bytes));
		return rawAction == uint8(Action.CancelOrder) || rawAction == uint8(Action.ReturnToVault);
	}

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
		// both legs must be priceable, or GAV bricks on a fill
		if (!Comptroller(comptroller).valueInterpreter().isSupportedAsset(buyToken)) {
			revert UnsupportedAsset(buyToken);
		}
		// the rate must stay within the oracle band; valuing the sell leg also rejects unpriceable sellTokens
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

	// ─── Taker side ──────────────────────────────────────────────────────────────

	/// @notice Pay `buyAmount` of the buyToken and receive sellToken pro-rata at the order's rate.
	function fill(uint256 orderId, uint256 buyAmount) external {
		Order storage order = orders[orderId];
		if (order.sellRemaining == 0) revert OrderInactive(orderId);
		if (block.timestamp > order.expiry) revert OrderExpired(orderId);

		uint256 sellOut;
		if (buyAmount >= order.buyRemaining) {
			// full fill of the remainder
			buyAmount = order.buyRemaining;
			sellOut = order.sellRemaining;
		} else {
			// pro-rata, rounded down in the fund's favor
			sellOut = (uint256(order.sellRemaining) * buyAmount) / order.buyRemaining;
		}
		if (sellOut == 0) revert ZeroFill();

		// re-check at the current oracle: an order placed before a big move must not become a drain
		(uint256 valueOut, uint256 valueIn) = _requireWithinOracleBand(order.sellToken, sellOut, order.buyToken, buyAmount);
		_accrueFillDiscount(valueOut, valueIn);

		order.sellRemaining -= uint128(sellOut);
		order.buyRemaining -= uint128(buyAmount);
		committed[order.sellToken] -= sellOut;

		IERC20(order.buyToken).safeTransferFrom(msg.sender, address(this), buyAmount);
		IERC20(order.sellToken).safeTransfer(msg.sender, sellOut);
		emit OrderFilled(orderId, msg.sender, sellOut, buyAmount);
	}

	/// @dev The fund must receive ≥ (1 − MAX_ORACLE_DISCOUNT_BPS) of what it gives, both legs valued in
	///      the denomination asset. Returns both values for the fill-discount budget.
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

	/// @dev Each fill's discount draws on a budget of MAX_FILL_DISCOUNT_BPS_PER_PERIOD of the
	///      position's held value, replenishing over DISCOUNT_TOLERANCE_PERIOD.
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
/// @notice Type factory for LimitOrderPosition.
contract LimitOrderPositionFactory is IExternalPositionTypeFactory {
	/// @inheritdoc IExternalPositionTypeFactory
	function deployPosition(address comptroller, bytes calldata) external returns (address position) {
		position = address(new LimitOrderPosition(comptroller));
	}
}
