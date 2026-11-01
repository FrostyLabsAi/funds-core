// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {AggregatorV3Interface} from '../interfaces/AggregatorV3Interface.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {IExternalPosition} from '../interfaces/IExternalPosition.sol';
import {IFrostyClmStrategy} from '../interfaces/external/IFrostyClm.sol';
import {IPoolPriceAdapter} from '../interfaces/IPoolPriceAdapter.sol';
import {IPoolWatch} from '../interfaces/IPoolWatch.sol';
import {PoolPriceRegistrar} from '../pricing/PoolPriceRegistrar.sol';
import {BalanceRead} from './BalanceRead.sol';
import {ValueInterpreter} from './ValueInterpreter.sol';

/// @title FundValuationV6
/// @notice FundValuation for fund version 6 (USDC-only exit, founder 2026-10-11): the same pricing, but a tracked
///         token whose balance can't be read counts as $0 instead of reverting (D2, BalanceRead), and without the
///         per-holding detail the old queue paid in kind from. A linked library (external functions run by
///         DELEGATECALL on the fund's own storage), as FundValuation is.
library FundValuationV6 {
	using EnumerableSet for EnumerableSet.AddressSet;

	/// @notice A VI heartbeat above this marks a market-session feed: a tokenized stock's Chainlink feed (5 days, listed so
	///         a closed market stays readable) stops from Friday's close to the next open. Every other feed is 25 h or less.
	uint256 internal constant SESSION_HEARTBEAT = 2 days;
	/// @notice A session feed's price older than this reads as a closed market: nobody may trade the fund at it (red-team
	///         PF-02, 2026-10-27). NVDAc's feed moved on 0.5% around the clock on weekdays (longest quiet gap 8.4 h in 60
	///         rounds, cast 2026-11-01); a quiet feed only delays an exit or deposit until its next update.
	uint256 internal constant MAX_SESSION_PRICE_AGE = 4 hours;

	/// @dev The fund's fixed wiring.
	struct Context {
		IValueInterpreter valueInterpreter;
		PoolPriceRegistrar registrar;
		address vault;
		address denominationAsset;
	}

	/// @dev Everything the fund's pricing needs, from one pass over the holdings.
	struct Valuation {
		uint256 gav; // every holding at its price: deposits are priced on it, exits paid on it
		uint256 feeGav; // pool-priced tokens at the lower of value and cost basis
		bool complete; // every price was read, and none is a closed market's
		bool unsettled; // a pool-priced holding reads 1 wei, or its pool is draining: a rug, or an LP's own pulls (review 2026-11-01)
		address[] assets;
		bool[] inKind; // held, and pool-priced, or its price can't be read or is a closed market's: the instant exit refuses
	}

	/// @dev Unrealized long-tail gains don't count toward the fee GAV until sold; losses count at once. A price that
	///      can't be read bubbles its revert unless `tolerant`, which marks the holding in kind and the valuation
	///      incomplete instead. A balance that can't be read counts as 0 either way. Positions always revert. A closed
	///      market's price still values the holding (the fund stays readable) but marks the valuation incomplete, so exits
	///      and deposits wait for the market instead of trading at a price everyone knows is old.
	function value(
		EnumerableSet.AddressSet storage trackedAssets,
		EnumerableSet.AddressSet storage externalPositions,
		mapping(address => uint256) storage costBasis,
		Context memory ctx,
		bool tolerant
	) external returns (Valuation memory v) {
		v.assets = trackedAssets.values();
		v.inKind = new bool[](v.assets.length);
		v.complete = true;
		for (uint256 i; i < v.assets.length; ++i) {
			address asset = v.assets[i];
			(, uint256 balance) = BalanceRead.tryRead(asset, ctx.vault);
			if (balance == 0) continue;
			bool poolPriced = ctx.registrar.poolPricedAdapter(asset) != address(0);
			v.inKind[i] = poolPriced;
			try ctx.valueInterpreter.calcCanonicalAssetValue(asset, balance, ctx.denominationAsset) returns (
				uint256 assetValue
			) {
				v.gav += assetValue;
				v.feeGav += poolPriced ? Math.min(assetValue, costBasis[asset]) : assetValue;
				(bool closed, bool unsettled) = _priceFlags(ctx, asset);
				if (closed) {
					v.inKind[i] = true;
					v.complete = false;
				}
				if (unsettled) v.unsettled = true;
			} catch (bytes memory reason) {
				if (!tolerant) {
					assembly ('memory-safe') {
						revert(add(reason, 32), mload(reason))
					}
				}
				v.inKind[i] = true;
				v.complete = false;
			}
		}

		uint256 positionsValue;
		uint256 positionCount = externalPositions.length();
		for (uint256 i; i < positionCount; ++i) {
			(uint256 valued, bool closed, bool unsettled) = _positionValue(IExternalPosition(externalPositions.at(i)), ctx);
			positionsValue += valued;
			if (closed) v.complete = false;
			if (unsettled) v.unsettled = true;
		}
		v.gav += positionsValue;
		v.feeGav += positionsValue;
	}

	/// @notice Keep long-tail cost bases in step with a trade: bought pool-priced units add what was spent on them, at
	///         most their value now; units that left the vault take their share of the basis. Booked at the value alone, a
	///         buy under a lagging 30-minute price read as an instant gain and paid the manager a fee on it (red-team
	///         V6FEES-01, 2026-10-27). Returns what left the vault: a deposit's refund was never spent.
	function followTrade(
		mapping(address => uint256) storage costBasis,
		Context memory ctx,
		address[] memory spendAssets,
		uint256[] memory spendBefore,
		address[] memory incomingAssets,
		uint256[] memory incomingAmounts
	) external returns (uint256[] memory spent) {
		spent = new uint256[](spendAssets.length);
		for (uint256 i; i < spendAssets.length; ++i) {
			uint256 left = IERC20(spendAssets[i]).balanceOf(ctx.vault);
			if (left < spendBefore[i]) spent[i] = spendBefore[i] - left;
		}
		_addBasis(costBasis, ctx, spendAssets, spent, incomingAssets, incomingAmounts);
		for (uint256 i; i < spendAssets.length; ++i) {
			if (spent[i] > 0) reduceCostBasis(costBasis, spendAssets[i], spent[i], spendBefore[i]);
		}
	}

	/// @dev With several incoming assets the spend is shared by value. The spend is priced only for a pool-priced buy, so a
	///      stale price on it never stops any other trade.
	function _addBasis(
		mapping(address => uint256) storage costBasis,
		Context memory ctx,
		address[] memory spendAssets,
		uint256[] memory spent,
		address[] memory incomingAssets,
		uint256[] memory incomingAmounts
	) private {
		uint256 spentValue;
		uint256 receivedValue;
		for (uint256 i; i < incomingAssets.length; ++i) {
			if (incomingAmounts[i] == 0 || ctx.registrar.poolPricedAdapter(incomingAssets[i]) == address(0)) continue;
			if (receivedValue == 0) {
				spentValue = assetsValue(spendAssets, spent, ctx);
				receivedValue = assetsValue(incomingAssets, incomingAmounts, ctx);
			}
			uint256 assetValue = ctx.valueInterpreter.calcCanonicalAssetValue(incomingAssets[i], incomingAmounts[i], ctx.denominationAsset);
			costBasis[incomingAssets[i]] += spentValue < receivedValue ? Math.mulDiv(assetValue, spentValue, receivedValue) : assetValue;
		}
	}

	/// @dev `units` of a `balance` left the vault: the cost basis shrinks in proportion.
	function reduceCostBasis(mapping(address => uint256) storage costBasis, address asset, uint256 units, uint256 balance)
		internal
	{
		uint256 basis = costBasis[asset];
		if (basis == 0 || units == 0) return;
		costBasis[asset] = basis - Math.mulDiv(basis, units, balance);
	}

	/// @notice The total value of `amounts` of `assets` (what leaves the vault for a position).
	function assetsValue(address[] memory assets, uint256[] memory amounts, Context memory ctx)
		public
		returns (uint256 total)
	{
		for (uint256 i; i < assets.length; ++i) {
			if (amounts[i] > 0) {
				total += ctx.valueInterpreter.calcCanonicalAssetValue(assets[i], amounts[i], ctx.denominationAsset);
			}
		}
	}

	/// @notice A position's managed assets minus its debt, floored at zero: a position's liability
	///         is limited to the position itself.
	function positionValue(IExternalPosition position, Context memory ctx) public returns (uint256 valued) {
		(valued,,) = _positionValue(position, ctx);
	}

	/// @dev Also whether a held asset's price is a closed market's (a stock in an LP or a limit order), or its pool unsettled.
	function _positionValue(IExternalPosition position, Context memory ctx) private returns (uint256, bool closed, bool unsettled) {
		(address[] memory managedAssets, uint256[] memory managedAmounts) = position.getManagedAssets();
		(address[] memory debtAssets, uint256[] memory debtAmounts) = position.getDebtAssets();

		uint256 managed;
		for (uint256 i; i < managedAssets.length; ++i) {
			if (managedAmounts[i] == 0) continue;
			managed += ctx.valueInterpreter.calcCanonicalAssetValue(managedAssets[i], managedAmounts[i], ctx.denominationAsset);
			(bool assetClosed, bool assetUnsettled) = _priceFlags(ctx, managedAssets[i]);
			if (assetClosed) closed = true;
			if (assetUnsettled) unsettled = true;
		}

		uint256 debt;
		for (uint256 i; i < debtAssets.length; ++i) {
			if (debtAmounts[i] == 0) continue;
			debt += ctx.valueInterpreter.calcCanonicalAssetValue(debtAssets[i], debtAmounts[i], ctx.denominationAsset);
		}

		return (managed > debt ? managed - debt : 0, closed, unsettled);
	}

	/// @dev Whether `asset`'s price, read successfully, comes from a session feed past MAX_SESSION_PRICE_AGE, and whether its pool
	///      is unsettled (1 wei, or IPoolWatch). A pool-priced token and a derivative take on what they are priced from: the quote
	///      token, a CLM vault's two tokens, an ERC4626's asset (review 2026-11-01, Medium 3: the live IPOR vaults on stocks). A
	///      side pocket's zero-priced tokens have no session feed, and the denomination asset is the unit NAV is counted in,
	///      whatever its feed.
	function _priceFlags(Context memory ctx, address asset) private view returns (bool closed, bool unsettled) {
		if (asset == ctx.denominationAsset || ctx.valueInterpreter.isZeroPricedAsset(asset)) return (false, false);
		(address aggregator, uint32 heartbeat,,) = ValueInterpreter(address(ctx.valueInterpreter)).getAssetInfo(asset);
		if (aggregator != address(0)) {
			if (ctx.registrar.poolPricedAdapter(asset) != address(0)) {
				(closed, unsettled) = _priceFlags(ctx, IPoolPriceAdapter(aggregator).config().quoteAsset);
				return (closed, unsettled || _poolUnsettled(aggregator));
			}
			if (heartbeat <= SESSION_HEARTBEAT) return (false, false);
			(,,, uint256 updatedAt,) = AggregatorV3Interface(aggregator).latestRoundData();
			return (block.timestamp > updatedAt + MAX_SESSION_PRICE_AGE, false);
		}
		(bool ok, bytes memory data) = asset.staticcall(abi.encodeWithSignature('strategy()'));
		if (ok && data.length == 32) {
			IFrostyClmStrategy strategy = IFrostyClmStrategy(abi.decode(data, (address)));
			(bool closed0, bool unsettled0) = _priceFlags(ctx, strategy.lpToken0());
			(bool closed1, bool unsettled1) = _priceFlags(ctx, strategy.lpToken1());
			return (closed0 || closed1, unsettled0 || unsettled1);
		}
		(ok, data) = asset.staticcall(abi.encodeWithSignature('asset()'));
		if (ok && data.length == 32) return _priceFlags(ctx, abi.decode(data, (address)));
		return (false, false);
	}

	/// @dev The watch is tried, never required: it only adds a wait, so it must not be able to stop a valuation.
	function _poolUnsettled(address adapter) private view returns (bool) {
		(, int256 answer,,,) = AggregatorV3Interface(adapter).latestRoundData();
		if (answer == 1) return true;
		try IPoolWatch(adapter).poolUnsettled() returns (bool draining) {
			return draining;
		} catch {
			return false;
		}
	}
}
