// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {IValueInterpreterAdmin} from '../../src/interfaces/IValueInterpreterAdmin.sol';
import {AggregatorV3Interface} from '../../src/interfaces/AggregatorV3Interface.sol';
import {IB20Multiplier} from '../../src/interfaces/external/IB20Multiplier.sol';
import {VerantaPriceAdapter} from '../../src/pricing/VerantaPriceAdapter.sol';
import {B20VerantaPriceAdapter} from '../../src/pricing/B20VerantaPriceAdapter.sol';
import {PriceMarker} from '../../src/pricing/PriceMarker.sol';
import {Release} from '../release/Release.sol';

/// @title NewListings
/// @notice Lists assets on the release after its launch, each the way the release already lists that kind (the values
///         below are read off the live release: NVDAc, MUc and the WDC marker on 2026-11-19). Run by the registrar's
///         owner; every ValueInterpreter call goes through the registrar, which owns it.
/// @dev Every step skips what is already done, so a run that stopped half way can be run again. A step never
///      overwrites: an asset the VI already prices another way stops the run (`register` is open to anyone, so a
///      token can be pool-priced by someone else before its feed is listed here; the owner settles that by hand).
library NewListings {
	/// @dev A feed on a market that closes for the weekend: Chainlink's Coinbase stock feeds and Veranta's stock pairs.
	uint32 internal constant CLOSING_MARKET_HEARTBEAT = 5 days;
	/// @dev A Coinbase stock on Veranta's price: stored at most this long ago (B20VerantaPriceAdapter.maxPushAge and the
	///      VI heartbeat), because a v6 fund pays exits at it.
	uint32 internal constant STOCK_PUSH_AGE = 120;
	/// @dev A perp marker's stored price: the perp readers' 10 minutes.
	uint32 internal constant MARKER_PUSH_AGE = 600;
	/// @dev The answer band of a newly listed stock: a third to three times its price at listing.
	int256 internal constant BAND = 3;

	error PricedAnotherWay(address asset, address aggregator);
	error NoPrice(address asset);
	error PairAlreadyMapped(uint256 pairIndex, address asset);

	/// @notice A Coinbase stock on its own Chainlink feed, with an answer band around the feed's current answer.
	function chainlinkStock(Release.Deployed memory d, address token, address feed) internal returns (bool listed) {
		(address aggregator,,,) = d.valueInterpreter.getAssetInfo(token);
		if (aggregator == address(0)) {
			_execute(d, abi.encodeCall(IValueInterpreterAdmin.addPrimitive, (token, feed, CLOSING_MARKET_HEARTBEAT)));
			listed = true;
		} else if (aggregator != feed) {
			revert PricedAnotherWay(token, aggregator);
		}
		(, int256 answer,,,) = AggregatorV3Interface(feed).latestRoundData();
		_band(d, token, answer);
	}

	/// @notice A Coinbase stock with no Chainlink feed, on Veranta's price for its pair times the token's multiplier.
	/// @param referencePrice the share's USD price now, 8 decimals (Veranta's feed): the band's centre, since the store
	///        holds no price for a pair nobody has traded yet.
	function verantaStock(Release.Deployed memory d, address token, uint256 pairIndex, string memory symbol, uint256 referencePrice)
		internal
		returns (bool listed)
	{
		(address aggregator,,,) = d.valueInterpreter.getAssetInfo(token);
		if (aggregator == address(0)) {
			B20VerantaPriceAdapter adapter = new B20VerantaPriceAdapter(
				d.verantaStore,
				pairIndex,
				token,
				STOCK_PUSH_AGE,
				CLOSING_MARKET_HEARTBEAT,
				string.concat(symbol, ' / USD (Veranta x multiplier)')
			);
			_execute(d, abi.encodeCall(IValueInterpreterAdmin.addPrimitive, (token, address(adapter), STOCK_PUSH_AGE)));
			listed = true;
		} else if (!_isStockAdapter(d, aggregator, token, pairIndex)) {
			revert PricedAnotherWay(token, aggregator);
		}
		_band(d, token, SafeCast.toInt256(referencePrice * IB20Multiplier(token).multiplier() / 1e18));
	}

	/// @notice A Veranta perp market: a supply-less marker priced from the pair, mapped to it on the perp config.
	function perpMarket(Release.Deployed memory d, uint256 pairIndex, string memory base) internal returns (address marker) {
		address mapped = d.perpConfig.pairAsset(pairIndex);
		if (mapped != address(0)) {
			if (!d.valueInterpreter.isSupportedAsset(mapped)) revert PairAlreadyMapped(pairIndex, mapped);
			return mapped;
		}
		marker = address(new PriceMarker(string.concat('Veranta ', base, '/USD'), string.concat('vm', base)));
		VerantaPriceAdapter adapter = new VerantaPriceAdapter(
			d.verantaStore, pairIndex, MARKER_PUSH_AGE, CLOSING_MARKET_HEARTBEAT, string.concat(base, '/USD (Veranta)')
		);
		_execute(d, abi.encodeCall(IValueInterpreterAdmin.addPrimitive, (marker, address(adapter), CLOSING_MARKET_HEARTBEAT)));
		d.perpConfig.setPairAsset(pairIndex, marker);
	}

	/// @notice A token priced from its own pool, as anyone may register it (the registrar's own $25k and quote checks).
	function poolPriced(Release.Deployed memory d, address token, address pool) internal returns (bool listed) {
		(address aggregator,,,) = d.valueInterpreter.getAssetInfo(token);
		if (aggregator == address(0)) {
			d.registrar.register(token, pool);
			return true;
		}
		if (d.registrar.poolPricedAdapter(token) != aggregator) revert PricedAnotherWay(token, aggregator);
	}

	/// @notice A FrostyFi CLM vault share on the release's vault feed. Its two tokens must be feed-priced already.
	function clmVault(Release.Deployed memory d, address vault) internal returns (bool listed) {
		if (d.valueInterpreter.isSupportedAsset(vault)) return false;
		_execute(d, abi.encodeCall(IValueInterpreterAdmin.addDerivative, (vault, address(d.clmFeed))));
		return true;
	}

	/// @dev The band around `answer`, set once: a second run leaves a band alone, whatever the price did since.
	function _band(Release.Deployed memory d, address asset, int256 answer) private {
		(int256 min, int256 max) = d.valueInterpreter.answerBounds(asset);
		if (min != 0 || max != 0) return;
		if (answer <= 0) revert NoPrice(asset);
		_execute(d, abi.encodeCall(IValueInterpreterAdmin.setAnswerBounds, (asset, answer / BAND, answer * BAND)));
	}

	function _isStockAdapter(Release.Deployed memory d, address aggregator, address token, uint256 pairIndex)
		private
		view
		returns (bool)
	{
		try B20VerantaPriceAdapter(aggregator).token() returns (address adapterToken) {
			B20VerantaPriceAdapter adapter = B20VerantaPriceAdapter(aggregator);
			return adapterToken == token && adapter.pairIndex() == pairIndex && address(adapter.store()) == address(d.verantaStore);
		} catch {
			return false;
		}
	}

	function _execute(Release.Deployed memory d, bytes memory call) private {
		d.registrar.execute(call);
	}
}
