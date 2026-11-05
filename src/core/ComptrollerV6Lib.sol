// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import {Vault} from '../fund/Vault.sol';
import {IIntegrationAdapter} from '../interfaces/IIntegrationAdapter.sol';
import {AggregatorV3Interface} from '../interfaces/AggregatorV3Interface.sol';
import {IExternalPosition} from '../interfaces/IExternalPosition.sol';
import {BalanceRead} from './BalanceRead.sol';
import {ComptrollerV3Lib} from './ComptrollerV3Lib.sol';
import {FundValuationV6} from './FundValuationV6.sol';

/// @title ComptrollerV6Lib
/// @notice Fund version 6's liquidation (founder 2026-10-11): once a redemption is overdue, the queue's keeper turns the
///         fund into USDC without the manager. Moved out of ComptrollerV6 for EIP-170 room; external functions run by
///         DELEGATECALL in the comptroller's context, as ComptrollerV3Lib's do.
library ComptrollerV6Lib {
	address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

	using EnumerableSet for EnumerableSet.AddressSet;

	uint256 internal constant BPS = 10_000;
	/// @notice The most a liquidation may lose against the oracle, per trade or per batch of position actions (founder
	///         2026-10-11, D5: the investors who stay absorb it). A long-tail token sells in chunks small enough to fit.
	uint256 internal constant MAX_LIQUIDATION_LOSS_BPS = 300;
	/// @dev VerantaPerpPositionV4.Action.CloseTrade.
	uint8 internal constant CLOSE_TRADE = 1;
	/// @dev The LP pull-backs the keeper may run besides risk-reducing actions (SlipstreamLPPosition(V2) and
	///      UniswapV3LPPosition.Action: DecreaseLiquidity, Collect (paid to the vault), Unstake). Every live LP answers
	///      isRiskReducing false, even for these. On a perp account the same ids are risk-reducing (CancelLimitOrder,
	///      CancelPendingMarketOrder, ReturnToVault); on a limit-order position 2 is ReturnToVault and 3 and 6 revert.
	///      A new position type must keep these three ids from opening risk (founder 2026-10-11).
	uint8 internal constant LP_DECREASE_LIQUIDITY = 2;
	uint8 internal constant LP_COLLECT = 3;
	uint8 internal constant LP_UNSTAKE = 6;

	event Liquidated(
		address indexed adapter, address[] spendAssets, uint256[] spentAmounts, address incomingAsset, uint256 received
	);
	event PositionLiquidated(address indexed position, uint256 actions, uint256 lossValue);

	event AssetWrittenOff(address indexed asset, uint256 amount);

	error NotASale();
	error NotAtFloor(address asset);
	error LiquidationLoss(uint256 lossValue, uint256 maxLossValue);
	error CloseOfNothing();
	error NotAPullBack(uint8 action);

	/// @notice A liquidation trade: sells tracked tokens into the denomination asset through a registered adapter,
	///         losing at most MAX_LIQUIDATION_LOSS_BPS of what it sold at the oracle's price. Every adapter is single-hop,
	///         so a long-tail (pool-priced) token may instead sell into a feed-priced asset (its pool's WETH or cbBTC
	///         quote), which the next sale takes to the denomination, each hop under the cap. Amounts are vault balance
	///         deltas, never the adapter's claims; what arrives is tracked, past the tracked-asset cap: a full set (20)
	///         made every sale into a WETH or cbBTC quote revert, which locked a ghosted fund's overdue exit (red-team
	///         EXITADAPTERS-01, 2026-10-27). The manager's trading policies don't run: this cap is the rule.
	function liquidateTrade(
		EnumerableSet.AddressSet storage trackedAssets,
		ComptrollerV3Lib.Tracking memory tracking,
		mapping(address => uint256) storage costBasis,
		FundValuationV6.Context memory ctx,
		address adapter,
		bytes calldata integrationData
	) external {
		(address[] memory spendAssets, uint256[] memory spendBefore, address[] memory incoming, uint256[] memory received, uint256 soldValue) =
			_sell(ctx, adapter, integrationData);
		ComptrollerV3Lib.trackAsset(trackedAssets, _uncapped(tracking), incoming[0]);
		uint256[] memory spent = new uint256[](spendAssets.length);
		for (uint256 i; i < spendAssets.length; ++i) {
			uint256 left = IERC20(spendAssets[i]).balanceOf(ctx.vault);
			if (left < spendBefore[i]) spent[i] = spendBefore[i] - left;
		}
		_capLoss(soldValue, FundValuationV6.assetsValue(incoming, received, ctx), soldValue);
		FundValuationV6.followTrade(trackedAssets, costBasis, ctx, spendAssets, spendBefore, incoming, received);
		emit Liquidated(adapter, spendAssets, spent, incoming[0], received[0]);
	}

	/// @dev Runs the sale (checked by _checkSale): sends the spend assets to the adapter, executes it, and returns what
	///      the vault held of them before, the one incoming asset with the amount the vault received of it, and what the
	///      spend amounts were worth BEFORE the sale (final review 2026-10-11, I1: a pool-priced token's price reads its
	///      pool, which the sale itself moves — valued after, a sale draining the pool made the cap pass at any price).
	function _sell(FundValuationV6.Context memory ctx, address adapter, bytes calldata integrationData)
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
		soldValue = FundValuationV6.assetsValue(spendAssets, spendAmounts, ctx);

		spendBefore = ComptrollerV3Lib.vaultBalances(ctx.vault, spendAssets);
		received = ComptrollerV3Lib.vaultBalances(ctx.vault, incoming);
		ComptrollerV3Lib.withdrawAll(Vault(ctx.vault), adapter, spendAssets, spendAmounts);
		IIntegrationAdapter(adapter).executeAction(ctx.vault, integrationData);

		received[0] = IERC20(incoming[0]).balanceOf(ctx.vault) - received[0];
		if (received[0] < minIncoming[0]) revert ComptrollerV3Lib.MinIncomingAmountNotMet(incoming[0], received[0], minIncoming[0]);
	}

	/// @dev One incoming asset: the denomination, from anything but the denomination; or a feed-priced asset, from
	///      long-tail (pool-priced) tokens only.
	function _checkSale(FundValuationV6.Context memory ctx, address[] memory spendAssets, address[] memory incoming)
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
	///         manager's would, so a stale oracle never stops it. A batch with an LP pull-back (unstake, decrease,
	///         collect) is priced: the position's value plus what reached the vault may drop at most
	///         MAX_LIQUIDATION_LOSS_BPS of the position's value. Any other action reverts: the keeper never opens risk
	///         (founder 2026-10-11; a 3% cap per call bounds a mistake, not a compromised keeper). Arrivals in
	///         `assetsToReceive` are tracked.
	function liquidatePosition(
		EnumerableSet.AddressSet storage trackedAssets,
		ComptrollerV3Lib.Tracking memory tracking,
		FundValuationV6.Context memory ctx,
		address perpConfig,
		IExternalPosition position,
		address[] calldata assetsToReceive,
		bytes[] calldata actions
	) external {
		bool priced = _priced(perpConfig, position, actions);
		trackHeld(trackedAssets, tracking, position);
		uint256 beforeValue = priced ? FundValuationV6.positionValue(position, ctx) : 0;
		uint256[] memory balancesBefore = ComptrollerV3Lib.vaultBalances(ctx.vault, assetsToReceive);

		for (uint256 i; i < actions.length; ++i) {
			position.receiveCallFromFund(actions[i]);
		}

		uint256 received = ComptrollerV3Lib.receivedValue(
			trackedAssets, tracking, ctx.vault, ctx.denominationAsset, assetsToReceive, balancesBefore, priced
		);
		uint256 lossValue = priced ? _positionLoss(position, ctx, beforeValue, received) : 0;
		emit PositionLiquidated(address(position), actions.length, lossValue);
	}

	/// @notice A token whose pool reads 1 wei leaves the vault for good (ComptrollerV6.writeOffAsset). A token whose transfer
	///         reverts stays: governance can still zero-price it.
	function writeOff(
		EnumerableSet.AddressSet storage trackedAssets,
		mapping(address => uint256) storage costBasis,
		FundValuationV6.Context memory ctx,
		address asset
	) external {
		address adapter = ctx.registrar.poolPricedAdapter(asset);
		if (adapter == address(0)) revert NotAtFloor(asset);
		(, int256 answer,,,) = AggregatorV3Interface(adapter).latestRoundData();
		if (answer != 1) revert NotAtFloor(asset);
		uint256 amount = IERC20(asset).balanceOf(ctx.vault);
		trackedAssets.remove(asset);
		costBasis[asset] = 0;
		if (amount > 0) Vault(ctx.vault).withdraw(asset, BURN_ADDRESS, amount);
		emit AssetWrittenOff(asset, amount);
	}

	/// @notice Before any action on a position (the manager's or a liquidation), track every token it holds, so whatever
	///         it sends to the vault counts in GAV whether or not the caller lists it in `assetsToReceive` (review
	///         2026-10-11: a return of an untracked token, unlisted, dropped it out of GAV, and the manager could settle
	///         the queue at that lower NAV, then track it again). A position whose holdings can't be read now (a perp
	///         account on a stale price) is skipped, so a cut in risk never waits on a price: a perp account returns
	///         USDC, which is always tracked. A read that failed for want of gas reverts instead (BalanceRead's rule).
	///         What a position reports is tracked past the tracked-asset cap, bounded by what positions hold: at a full
	///         set (20), one more reported asset (a 1-wei donation to a limit-order position, a filled perp long's
	///         marker) made every position action revert, the keeper's liquidations included, and locked a ghosted
	///         fund's overdue exit. Skipping the asset instead would reopen the hidden-value hole above (red-team
	///         POSITIONS-01, 2026-10-27).
	function trackHeld(
		EnumerableSet.AddressSet storage trackedAssets,
		ComptrollerV3Lib.Tracking memory tracking,
		IExternalPosition position
	) public {
		uint256 gasBefore = gasleft();
		try position.getManagedAssets() returns (address[] memory assets, uint256[] memory) {
			ComptrollerV3Lib.Tracking memory uncapped = _uncapped(tracking);
			for (uint256 i; i < assets.length; ++i) {
				ComptrollerV3Lib.trackAsset(trackedAssets, uncapped, assets[i]);
			}
		} catch {
			if (gasleft() < gasBefore / 63) revert BalanceRead.CallStarved();
		}
	}

	/// @dev The fund's tracking rules without the tracked-asset cap (a new struct: assigning the memory struct would
	///      alias the caller's). The supported-asset and risky-asset rules still apply.
	function _uncapped(ComptrollerV3Lib.Tracking memory tracking) private pure returns (ComptrollerV3Lib.Tracking memory) {
		return ComptrollerV3Lib.Tracking(tracking.valueInterpreter, tracking.allowRiskyAssets, type(uint256).max);
	}

	/// @dev Whether the batch must be priced (an LP pull-back); a perp close of 0 reverts, and so does any action that
	///      is neither risk-reducing nor an LP pull-back.
	function _priced(address perpConfig, IExternalPosition position, bytes[] calldata actions) private view returns (bool priced) {
		for (uint256 i; i < actions.length; ++i) {
			if (closesNothing(perpConfig, address(position), actions[i])) revert CloseOfNothing();
			if (position.isRiskReducing(actions[i])) continue;
			(uint8 action,) = abi.decode(actions[i], (uint8, bytes));
			if (action != LP_DECREASE_LIQUIDITY && action != LP_COLLECT && action != LP_UNSTAKE) revert NotAPullBack(action);
			priced = true;
		}
	}

	/// @dev The value the batch lost (position plus what reached the vault, before vs after), capped.
	function _positionLoss(IExternalPosition position, FundValuationV6.Context memory ctx, uint256 beforeValue, uint256 received)
		private
		returns (uint256)
	{
		uint256 afterValue = FundValuationV6.positionValue(position, ctx) + received;
		_capLoss(beforeValue, afterValue, beforeValue);
		return beforeValue > afterValue ? beforeValue - afterValue : 0;
	}

	/// @notice A Veranta perp account's CloseTrade of 0 collateral (2026-10-11, fork-proven): Veranta takes it, never
	///         fills it, keeps it pending until its operator cancels it, and refuses the trade's other closes meanwhile,
	///         so one would block a liquidation (or any close). A perp account names `perpConfig` as positionFactory().
	function closesNothing(address perpConfig, address position, bytes calldata actionData) public view returns (bool) {
		(uint8 action, bytes memory args) = abi.decode(actionData, (uint8, bytes));
		if (action != CLOSE_TRADE || args.length < 96) return false;
		(bool ok, bytes memory ret) = position.staticcall(abi.encodeWithSignature('positionFactory()'));
		if (!ok || ret.length != 32 || abi.decode(ret, (address)) != perpConfig) return false;
		(,, uint256 amount) = abi.decode(args, (uint256, uint256, uint256));
		return amount == 0;
	}

	/// @dev `afterValue` short of `beforeValue` by more than MAX_LIQUIDATION_LOSS_BPS of `base` reverts.
	function _capLoss(uint256 beforeValue, uint256 afterValue, uint256 base) private pure {
		uint256 maxLoss = base * MAX_LIQUIDATION_LOSS_BPS / BPS;
		if (afterValue + maxLoss < beforeValue) revert LiquidationLoss(beforeValue - afterValue, maxLoss);
	}
}
