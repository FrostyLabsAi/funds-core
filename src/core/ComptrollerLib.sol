// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {IPolicy} from '../interfaces/IPolicy.sol';
import {IVault} from '../interfaces/IVault.sol';
import {IIntegrationAdapter} from '../interfaces/IIntegrationAdapter.sol';
import {ISaleTaxAdapter} from '../interfaces/ISaleTaxAdapter.sol';
import {AggregatorV3Interface} from '../interfaces/AggregatorV3Interface.sol';
import {IExternalPosition} from '../interfaces/IExternalPosition.sol';
import {BalanceRead} from './BalanceRead.sol';
import {FundValuation} from './FundValuation.sol';

/// @title ComptrollerLib
/// @notice The comptroller's tracked-asset rules, trade and payout loops, and its liquidation (founder 2026-10-11: once a
///         redemption is overdue, the queue's keeper turns the fund into USDC without the manager). Kept out of the
///         Comptroller for EIP-170 room; its public functions run by DELEGATECALL in the comptroller's context.
library ComptrollerLib {
	address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

	using EnumerableSet for EnumerableSet.AddressSet;

	/// @dev The comptroller's tracked-asset rules, passed in (its immutables).
	struct Tracking {
		IValueInterpreter valueInterpreter;
		bool allowRiskyAssets;
		uint256 maxTrackedAssets;
	}

	uint256 internal constant BPS = 10_000;
	/// @notice The most a liquidation trade may lose against the oracle (founder 2026-10-11, D5: the investors who stay
	///         absorb it). A long-tail token sells in chunks small enough to fit. A sale through a pool with a recorded
	///         tax (ISaleTaxAdapter: a v4 hook's) may lose that much more, at most MAX_SALE_TAX_BPS (founder 2026-11-15).
	uint256 internal constant MAX_LIQUIDATION_LOSS_BPS = 300;
	/// @notice The most a recorded sale tax raises that cap, whatever an adapter reports (hard rule 5; the registrar
	///         refuses a higher record too).
	uint256 internal constant MAX_SALE_TAX_BPS = 500;
	/// @dev VerantaPerpPosition.Action.CloseTrade.
	uint8 internal constant CLOSE_TRADE = 1;

	event Liquidated(
		address indexed adapter, address[] spendAssets, uint256[] spentAmounts, address incomingAsset, uint256 received
	);
	event PositionLiquidated(address indexed position, uint256 actions);

	event AssetWrittenOff(address indexed asset, uint256 amount);
	event TrackedAssetAdded(address indexed asset);

	error NotASale();
	error NotAtFloor(address asset);
	error LiquidationLoss(uint256 lossValue, uint256 maxLossValue);
	error CloseOfNothing();
	error NotRiskReducing(uint8 action);
	error AssetNotSupported(address asset);
	error RiskyAssetsNotAllowed(address asset);
	error TrackedAssetsLimitReached();
	error MinIncomingAmountNotMet(address asset, uint256 received, uint256 minAmount);

	/// @notice A liquidation trade: sells tracked tokens into the denomination asset through a registered adapter,
	///         losing at most MAX_LIQUIDATION_LOSS_BPS of what it sold at the oracle's price, plus the tax recorded for the
	///         pool it sells through (ISaleTaxAdapter, at most MAX_SALE_TAX_BPS). Every adapter is single-hop,
	///         so a long-tail (pool-priced) token may instead sell into a feed-priced asset (its pool's WETH or cbBTC
	///         quote), which the next sale takes to the denomination, each hop under the cap. Amounts are vault balance
	///         deltas, never the adapter's claims; what arrives is tracked, past the tracked-asset cap: a full set (20)
	///         made every sale into a WETH or cbBTC quote revert, which locked a ghosted fund's overdue exit (red-team
	///         EXITADAPTERS-01, 2026-10-27). The manager's trading policies don't run: this cap is the rule.
	function liquidateTrade(
		EnumerableSet.AddressSet storage trackedAssets,
		Tracking memory tracking,
		mapping(address => uint256) storage costBasis,
		FundValuation.Context memory ctx,
		address adapter,
		bytes calldata integrationData
	) external {
		(address[] memory spendAssets, uint256[] memory spendBefore, address[] memory incoming, uint256[] memory received, uint256 soldValue) =
			_sell(ctx, adapter, integrationData);
		trackAsset(trackedAssets, _uncapped(tracking), incoming[0]);
		uint256[] memory spent = new uint256[](spendAssets.length);
		for (uint256 i; i < spendAssets.length; ++i) {
			uint256 left = IERC20(spendAssets[i]).balanceOf(ctx.vault);
			if (left < spendBefore[i]) spent[i] = spendBefore[i] - left;
		}
		_capLoss(soldValue, FundValuation.assetsValue(incoming, received, ctx), soldValue, _saleTax(adapter, integrationData));
		FundValuation.followTrade(trackedAssets, costBasis, ctx, spendAssets, spendBefore, incoming, received);
		emit Liquidated(adapter, spendAssets, spent, incoming[0], received[0]);
	}

	/// @dev Runs the sale (checked by _checkSale): sends the spend assets to the adapter, executes it, and returns what
	///      the vault held of them before, the one incoming asset with the amount the vault received of it, and what the
	///      spend amounts were worth BEFORE the sale (final review 2026-10-11, I1: a pool-priced token's price reads its
	///      pool, which the sale itself moves — valued after, a sale draining the pool made the cap pass at any price).
	function _sell(FundValuation.Context memory ctx, address adapter, bytes calldata integrationData)
		private
		returns (
			address[] memory spendAssets,
			uint256[] memory spendBefore,
			address[] memory incoming,
			uint256[] memory received,
			uint256 soldValue
		)
	{
		uint256[] memory spendAmounts;
		uint256[] memory minIncoming;
		(spendAssets, spendAmounts, incoming, minIncoming) = IIntegrationAdapter(adapter).parseAssetsForAction(integrationData);
		_checkSale(ctx, spendAssets, incoming);
		soldValue = FundValuation.assetsValue(spendAssets, spendAmounts, ctx);

		spendBefore = vaultBalances(ctx.vault, spendAssets);
		received = vaultBalances(ctx.vault, incoming);
		withdrawAll(IVault(ctx.vault), adapter, spendAssets, spendAmounts);
		IIntegrationAdapter(adapter).executeAction(ctx.vault, integrationData);

		received[0] = IERC20(incoming[0]).balanceOf(ctx.vault) - received[0];
		if (received[0] < minIncoming[0]) revert MinIncomingAmountNotMet(incoming[0], received[0], minIncoming[0]);
	}

	/// @dev One incoming asset: the denomination, from anything but the denomination; or a feed-priced asset, from
	///      long-tail (pool-priced) tokens only.
	function _checkSale(FundValuation.Context memory ctx, address[] memory spendAssets, address[] memory incoming)
		private
		view
	{
		if (incoming.length != 1) revert NotASale();
		bool intoDenomination = incoming[0] == ctx.denominationAsset;
		if (!intoDenomination && ctx.registrar.poolPricedAdapter(incoming[0]) != address(0)) revert NotASale();
		for (uint256 i; i < spendAssets.length; ++i) {
			if (spendAssets[i] == ctx.denominationAsset) revert NotASale();
			if (!intoDenomination && ctx.registrar.poolPricedAdapter(spendAssets[i]) == address(0)) revert NotASale();
		}
	}

	/// @notice A liquidation batch on one position: `actions` in order, nothing taken from the vault. A batch of
	///         risk-reducing actions only (a perp close, an order cancel, a return to the vault) runs unpriced, as a
	///         manager's would, so a stale oracle never stops it. Any other action reverts: the keeper never opens risk
	///         (founder 2026-10-11). Arrivals in
	///         `assetsToReceive` are tracked.
	function liquidatePosition(
		EnumerableSet.AddressSet storage trackedAssets,
		Tracking memory tracking,
		FundValuation.Context memory ctx,
		address perpConfig,
		IExternalPosition position,
		address[] calldata assetsToReceive,
		bytes[] calldata actions
	) external {
		_checkActions(perpConfig, position, actions);
		trackHeld(trackedAssets, tracking, position);
		uint256[] memory balancesBefore = vaultBalances(ctx.vault, assetsToReceive);

		for (uint256 i; i < actions.length; ++i) {
			position.receiveCallFromFund(actions[i]);
		}

		receivedValue(trackedAssets, tracking, ctx.vault, ctx.denominationAsset, assetsToReceive, balancesBefore, false);
		emit PositionLiquidated(address(position), actions.length);
	}

	/// @notice A token whose pool reads 1 wei leaves the vault for good (Comptroller.writeOffAsset). A token whose transfer
	///         reverts stays: governance can still zero-price it.
	function writeOff(
		EnumerableSet.AddressSet storage trackedAssets,
		mapping(address => uint256) storage costBasis,
		FundValuation.Context memory ctx,
		address asset
	) external {
		address adapter = ctx.registrar.poolPricedAdapter(asset);
		if (adapter == address(0)) revert NotAtFloor(asset);
		(, int256 answer,,,) = AggregatorV3Interface(adapter).latestRoundData();
		if (answer != 1) revert NotAtFloor(asset);
		uint256 amount = IERC20(asset).balanceOf(ctx.vault);
		trackedAssets.remove(asset);
		costBasis[asset] = 0;
		if (amount > 0) IVault(ctx.vault).withdraw(asset, BURN_ADDRESS, amount);
		emit AssetWrittenOff(asset, amount);
	}

	/// @notice Before any action on a position (the manager's or a liquidation), track every token it holds, so whatever
	///         it sends to the vault counts in GAV whether or not the caller lists it in `assetsToReceive` (review
	///         2026-10-11: a return of an untracked token, unlisted, dropped it out of GAV, and the manager could settle
	///         the queue at that lower NAV, then track it again). A position whose holdings can't be read now (a perp
	///         account on a stale price) is skipped, so a cut in risk never waits on a price: a perp account returns
	///         USDC, which is always tracked. A read that failed for want of gas reverts instead (BalanceRead's rule).
	///         What a position reports is tracked past the tracked-asset cap, bounded by what positions hold: at a full
	///         set (20), one more reported asset (a filled perp long's marker) made every position action revert, the keeper's liquidations included, and locked a ghosted
	///         fund's overdue exit. Skipping the asset instead would reopen the hidden-value hole above (red-team
	///         POSITIONS-01, 2026-10-27).
	function trackHeld(
		EnumerableSet.AddressSet storage trackedAssets,
		Tracking memory tracking,
		IExternalPosition position
	) public {
		uint256 gasBefore = gasleft();
		try position.getManagedAssets() returns (address[] memory assets, uint256[] memory) {
			Tracking memory uncapped = _uncapped(tracking);
			for (uint256 i; i < assets.length; ++i) {
				trackAsset(trackedAssets, uncapped, assets[i]);
			}
		} catch {
			if (gasleft() < gasBefore / 63) revert BalanceRead.CallStarved();
		}
	}

	/// @dev The fund's tracking rules without the tracked-asset cap (a new struct: assigning the memory struct would
	///      alias the caller's). The supported-asset and risky-asset rules still apply.
	function _uncapped(Tracking memory tracking) private pure returns (Tracking memory) {
		return Tracking(tracking.valueInterpreter, tracking.allowRiskyAssets, type(uint256).max);
	}

	/// @dev Every action must be risk-reducing; a perp close of 0 reverts.
	function _checkActions(address perpConfig, IExternalPosition position, bytes[] calldata actions) private view {
		for (uint256 i; i < actions.length; ++i) {
			if (closesNothing(perpConfig, address(position), actions[i])) revert CloseOfNothing();
			if (position.isRiskReducing(actions[i])) continue;
			(uint8 action,) = abi.decode(actions[i], (uint8, bytes));
			revert NotRiskReducing(action);
		}
	}

	/// @notice A Veranta perp account's CloseTrade of 0 collateral (2026-10-11, fork-proven): Veranta takes it, never
	///         fills it, keeps it pending until its operator cancels it, and refuses the trade's other closes meanwhile,
	///         so one would block a liquidation (or any close). A perp account names `perpConfig` as its perpConfig().
	function closesNothing(address perpConfig, address position, bytes calldata actionData) public view returns (bool) {
		(uint8 action, bytes memory args) = abi.decode(actionData, (uint8, bytes));
		if (action != CLOSE_TRADE || args.length < 96) return false;
		(bool ok, bytes memory ret) = position.staticcall(abi.encodeWithSignature('perpConfig()'));
		if (!ok || ret.length != 32 || abi.decode(ret, (address)) != perpConfig) return false;
		(,, uint256 amount) = abi.decode(args, (uint256, uint256, uint256));
		return amount == 0;
	}

	/// @dev `afterValue` short of `beforeValue` by more than MAX_LIQUIDATION_LOSS_BPS plus `taxBps` of `base` reverts.
	function _capLoss(uint256 beforeValue, uint256 afterValue, uint256 base, uint256 taxBps) private pure {
		uint256 maxLoss = base * (MAX_LIQUIDATION_LOSS_BPS + taxBps) / BPS;
		if (afterValue + maxLoss < beforeValue) revert LiquidationLoss(beforeValue - afterValue, maxLoss);
	}

	/// @dev The tax recorded for the pool this sale goes through, as its adapter reports it (ISaleTaxAdapter), capped at
	///      MAX_SALE_TAX_BPS; 0 for an adapter that doesn't report one (a plain static call: no answer, no tax).
	function _saleTax(address adapter, bytes calldata integrationData) private view returns (uint256 taxBps) {
		(bool ok, bytes memory ret) = adapter.staticcall(abi.encodeCall(ISaleTaxAdapter.saleTaxBps, (integrationData)));
		if (!ok || ret.length != 32) return 0;
		taxBps = abi.decode(ret, (uint256));
		if (taxBps > MAX_SALE_TAX_BPS) taxBps = MAX_SALE_TAX_BPS;
	}

	/// @notice Shared by explicit tracking and auto-tracking. Idempotent.
	function trackAsset(EnumerableSet.AddressSet storage trackedAssets, Tracking memory rules, address asset) public {
		if (trackedAssets.contains(asset)) return;
		if (!rules.valueInterpreter.isSupportedAsset(asset)) revert AssetNotSupported(asset);
		if (rules.valueInterpreter.isZeroPricedAsset(asset) && !rules.allowRiskyAssets) revert RiskyAssetsNotAllowed(asset);
		if (trackedAssets.length() >= rules.maxTrackedAssets) revert TrackedAssetsLimitReached();
		trackedAssets.add(asset);
		emit TrackedAssetAdded(asset);
	}

	function vaultBalances(address vault, address[] memory assets) public view returns (uint256[] memory balances) {
		balances = new uint256[](assets.length);
		for (uint256 i; i < assets.length; ++i) {
			balances[i] = IERC20(assets[i]).balanceOf(vault);
		}
	}

	/// @notice Values what the vault actually received and auto-tracks it; duplicates are skipped
	///         (counting a delta twice would hide losses).
	function receivedValue(
		EnumerableSet.AddressSet storage trackedAssets,
		Tracking memory rules,
		address vault,
		address denominationAsset,
		address[] memory assets,
		uint256[] memory balancesBefore,
		bool priced
	) public returns (uint256 value) {
		for (uint256 i; i < assets.length; ++i) {
			trackAsset(trackedAssets, rules, assets[i]);
			if (!priced) continue;
			bool duplicate;
			for (uint256 j; j < i; ++j) {
				if (assets[j] == assets[i]) {
					duplicate = true;
					break;
				}
			}
			if (duplicate) continue;
			uint256 received = IERC20(assets[i]).balanceOf(vault) - balancesBefore[i];
			if (received > 0) {
				value += rules.valueInterpreter.calcCanonicalAssetValue(assets[i], received, denominationAsset);
			}
		}
	}

	/// @notice A policy may only attach to hooks it implements (else it bricks or silently no-ops).
	function implementsHook(address policy, IPolicy.PolicyHook hook) public view returns (bool) {
		IPolicy.PolicyHook[] memory implemented = IPolicy(policy).implementedHooks();
		for (uint256 i; i < implemented.length; ++i) {
			if (implemented[i] == hook) return true;
		}
		return false;
	}

	/// @notice Sends each amount from the vault to `to`: a trade's spend, a position's funding
	///         (here for EIP-170 room, 2026-10-07).
	function withdrawAll(IVault vault, address to, address[] memory assets, uint256[] memory amounts) public {
		for (uint256 i; i < assets.length; ++i) {
			vault.withdraw(assets[i], to, amounts[i]);
		}
	}

	/// @notice Reconfiguration: carry the prior fund's tracked assets over.
	function copyTracked(EnumerableSet.AddressSet storage trackedAssets, address[] memory priorTracked) public {
		for (uint256 i; i < priorTracked.length; ++i) {
			trackedAssets.add(priorTracked[i]);
		}
	}

	/// @notice A trade's incoming amounts, measured as vault balance deltas (never adapter claims),
	///         each at least its minimum, each auto-tracked.
	function receivedAmounts(
		EnumerableSet.AddressSet storage trackedAssets,
		Tracking memory rules,
		address vault,
		address[] memory incomingAssets,
		uint256[] memory balancesBefore,
		uint256[] memory minIncomingAmounts
	) public returns (uint256[] memory incomingAmounts) {
		incomingAmounts = new uint256[](incomingAssets.length);
		for (uint256 i; i < incomingAssets.length; ++i) {
			uint256 received = IERC20(incomingAssets[i]).balanceOf(vault) - balancesBefore[i];
			if (received < minIncomingAmounts[i]) revert MinIncomingAmountNotMet(incomingAssets[i], received, minIncomingAmounts[i]);
			incomingAmounts[i] = received;
			trackAsset(trackedAssets, rules, incomingAssets[i]);
		}
	}
}
