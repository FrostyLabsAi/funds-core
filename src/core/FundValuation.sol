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
import {IPoolPriceRegistrar} from '../interfaces/IPoolPriceRegistrar.sol';
import {IVerantaPriceFeed} from '../interfaces/IVerantaPriceFeed.sol';
import {BalanceRead} from './BalanceRead.sol';

/// @title FundValuation
/// @notice A fund's valuation for the USDC-only exit (founder 2026-10-11): oracle prices through the ValueInterpreter; a
///         tracked token whose balance can't be read counts as $0 instead of reverting (D2, BalanceRead). A linked library
///         (external functions run by DELEGATECALL on the fund's own storage).
library FundValuation {
	using EnumerableSet for EnumerableSet.AddressSet;

	/// @notice A VI heartbeat above this marks a market-session feed: a tokenized stock's Chainlink feed (5 days, listed so
	///         a closed market stays readable) stops from Friday's close to the next open, and so does a perp on a market
	///         that closes (VerantaPriceAdapter, which answers its last trade's time). Every other feed is 25 h or less.
	uint256 internal constant SESSION_HEARTBEAT = 2 days;
	/// @notice A session feed's price older than this reads as a closed market: no exit is paid at it (red-team PF-02,
	///         2026-10-27); deposits buy at it (founder 2026-11-03). NVDAc's feed moved on 0.5% around the clock on weekdays
	///         (longest quiet gap 8.4 h in 60 rounds, cast 2026-11-01); a quiet feed only delays an exit until its next update.
	uint256 internal constant MAX_SESSION_PRICE_AGE = 4 hours;
	/// @notice The holdings causing an exit's wait must add up to this share of the fund's value (0.1%) or it doesn't apply: $2 of a
	///         token held up a $1M fund, and since a sold token stays tracked, anyone could switch a wait on by sending it 1 wei (founder
	///         2026-11-04). This far under the line can't move an exit's price by more than about 0.1%. A position's flags and a
	///         price that can't be read aren't sized: a perp's value is its margin, not its risk, and no price means no size.
	///         A deposit has no line (founder 2026-11-05, tool run Finding 1). At a token's $0 it buys in without paying for the token,
	///         which stays in the fund, so the same deposit repeats: in a $1M fund a $900 holding cost the holders 10% over 122 rounds,
	///         a $250 one 75% over 3,182. A dead token stops deposits until the manager writes it off, which also takes it off the list.
	uint256 internal constant MIN_WAITING_SHARE_BPS = 10;
	uint256 private constant BPS = 10_000;

	/// @dev The fund's fixed wiring.
	struct Context {
		IValueInterpreter valueInterpreter;
		IPoolPriceRegistrar registrar;
		address vault;
		address denominationAsset;
	}

	/// @dev The holdings each wait would rest on, and what they add up to; applied once the fund's whole value is known.
	struct Waiting {
		bool[] closed;
		bool[] longTail;
		bool unsettled;
		uint256 closedSize;
		uint256 longTailSize;
		uint256 unsettledSize;
	}

	/// @dev Everything the fund's pricing needs, from one pass over the holdings.
	struct Valuation {
		uint256 gav; // every holding at its price: deposits are priced on it, exits paid on it
		uint256 feeGav; // pool-priced tokens at the lower of value and cost basis
		bool complete; // every price was read, and none is a closed market's
		bool unsettled; // a pool-priced holding reads 1 wei, or its pool is draining: a rug, or an LP's own pulls (review 2026-11-01). At any size for a deposit, from the line up for the queue
		address[] assets;
		bool[] inKind; // held, and pool-priced, or its price can't be read or is a closed market's: the instant exit refuses
	}

	/// @dev Unrealized long-tail gains don't count toward the fee GAV until sold; losses count at once. A price that
	///      can't be read bubbles its revert unless `tolerant`, which marks the holding in kind and the valuation
	///      incomplete instead. A balance that can't be read counts as 0 either way. Positions always revert. A closed
	///      market's price still values the holding (the fund stays readable) but marks the valuation incomplete, so exits
	///      wait for the market instead of paying at a price everyone knows is old. Deposits don't wait (founder 2026-11-03).
	///      `tolerant` is the valuation exits run on; the one a deposit prices on isn't, so that's where a draining pool has no line.
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
		Waiting memory waiting;
		waiting.closed = new bool[](v.assets.length);
		waiting.longTail = new bool[](v.assets.length);
		for (uint256 i; i < v.assets.length; ++i) {
			_addHolding(v, waiting, i, costBasis, ctx, tolerant);
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
		_applyWaits(v, waiting, tolerant);
	}

	/// @dev One tracked token into the valuation.
	function _addHolding(
		Valuation memory v,
		Waiting memory waiting,
		uint256 i,
		mapping(address => uint256) storage costBasis,
		Context memory ctx,
		bool tolerant
	) private {
		address asset = v.assets[i];
		(, uint256 balance) = BalanceRead.tryRead(asset, ctx.vault);
		if (balance == 0) return;
		bool poolPriced = ctx.registrar.poolPricedAdapter(asset) != address(0);
		try ctx.valueInterpreter.calcCanonicalAssetValue(asset, balance, ctx.denominationAsset) returns (uint256 assetValue) {
			v.gav += assetValue;
			v.feeGav += poolPriced ? Math.min(assetValue, costBasis[asset]) : assetValue;
			// a drained token reads $0, so a long-tail holding also counts at what the fund paid for it
			_noteWaits(waiting, v, i, ctx, poolPriced, poolPriced ? Math.max(assetValue, costBasis[asset]) : assetValue);
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

	/// @dev Which waits this holding would rest on. A vault share has no cost on record and reads next to nothing once its pool
	///      drains, so its size can't be told: its pool stops the queue at any size too.
	function _noteWaits(Waiting memory waiting, Valuation memory v, uint256 i, Context memory ctx, bool poolPriced, uint256 size) private view {
		(bool closed, bool unsettled) = _priceFlags(ctx, v.assets[i]);
		if (poolPriced) {
			waiting.longTail[i] = true;
			waiting.longTailSize += size;
		}
		if (closed) {
			waiting.closed[i] = true;
			waiting.closedSize += size;
		}
		if (unsettled) {
			if (poolPriced) {
				waiting.unsettled = true;
				waiting.unsettledSize += size;
			} else {
				v.unsettled = true;
			}
		}
	}

	/// @dev Each exit's wait applies once its holdings add up to the line, so many small holdings can't hide a real one between them.
	///      A deposit waits on any unsettled pool (see MIN_WAITING_SHARE_BPS).
	function _applyWaits(Valuation memory v, Waiting memory waiting, bool tolerant) private pure {
		uint256 line = Math.mulDiv(v.gav, MIN_WAITING_SHARE_BPS, BPS);
		if (waiting.unsettled && (!tolerant || waiting.unsettledSize >= line)) v.unsettled = true;
		for (uint256 i; i < v.assets.length; ++i) {
			bool closed = waiting.closed[i] && waiting.closedSize >= line;
			if (closed) v.complete = false;
			if (closed || (waiting.longTail[i] && waiting.longTailSize >= line)) v.inKind[i] = true;
		}
	}

	event TrackedAssetRemoved(address indexed asset);

	/// @notice Keep long-tail cost bases in step with a trade: bought pool-priced units add what was spent on them, at
	///         most their value now; units that left the vault take their share of the basis. Booked at the value alone, a
	///         buy under a lagging 30-minute price read as an instant gain and paid the manager a fee on it (red-team
	///         V6FEES-01, 2026-10-27). Returns what left the vault: a deposit's refund was never spent.
	/// @dev A sold token the trade leaves at exactly 0 in the vault leaves the tracked list, USDC never (founder 2026-11-05,
	///      Melon v1's auto-prune): the limit counts what a fund holds, and a sold token can't be dusted into a full price read.
	///      A token moved into a position isn't a sale and stays; trackHeld lists what a position holds before it acts.
	function followTrade(
		EnumerableSet.AddressSet storage trackedAssets,
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
			if (left == 0 && spendAssets[i] != ctx.denominationAsset && trackedAssets.remove(spendAssets[i])) emit TrackedAssetRemoved(spendAssets[i]);
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

	/// @dev Also whether a held asset's price is a closed market's (a perp account's stock leg), or its pool unsettled.
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
			// a short's coin leg is owed: it reads a closed market's price just as a long's does
			(bool assetClosed,) = _priceFlags(ctx, debtAssets[i]);
			if (assetClosed) closed = true;
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
		(address aggregator, uint32 heartbeat,,) = ctx.valueInterpreter.getAssetInfo(asset);
		if (aggregator != address(0)) {
			if (ctx.registrar.poolPricedAdapter(asset) != address(0)) {
				(closed, unsettled) = _priceFlags(ctx, IPoolPriceAdapter(aggregator).config().quoteAsset);
				return (closed, unsettled || _poolUnsettled(aggregator));
			}
			// a Veranta-priced stock follows the same rule (founder 2026-11-04): Pyth keeps re-confirming a closed market's price, so
			// its feed time is never old. Only this adapter family answers maxFeedAge(), and its store holds the last trade
			(bool stored,) = aggregator.staticcall(abi.encodeWithSignature('maxFeedAge()'));
			if (stored) {
				IVerantaPriceFeed feed = IVerantaPriceFeed(aggregator);
				return (block.timestamp > feed.store().feedUpdatedUs(feed.pairIndex()) / 1e6 + MAX_SESSION_PRICE_AGE, false);
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
