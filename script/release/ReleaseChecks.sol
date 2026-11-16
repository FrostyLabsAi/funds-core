// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Vm} from 'forge-std/Vm.sol';
import {IValueInterpreter} from '../../src/interfaces/IValueInterpreter.sol';
import {Release} from './Release.sol';
import {ReleaseListings} from './ReleaseListings.sol';
import {BaseMainnet} from './BaseMainnet.sol';

/// @notice Checks, in forge's local execution only, that the listed release prices as today's system does: shared by
///         ReleaseListingsFork and RehearseRelease. Never part of a broadcast: it writes the live store's words into
///         the release's store (vm.store) so their perp and stock prices can be compared.
library ReleaseChecks {
	Vm private constant vm = Vm(address(uint160(uint256(keccak256('hevm cheat code')))));
	/// @dev Today's Veranta store (stocks and the newer markers) and the first one (crypto markers): the first store's
	///      word layout differs, so its markers' rates aren't compared.
	address internal constant LIVE_VERANTA_STORE = 0xf9Ef795F17eC1007d859dDbdBe8C6bccE8554AA7;
	address internal constant LIVE_FIRST_STORE = 0xc65AC79F0D3be202F85765B8c0B7a055FA02C6a6;

	struct Rates {
		uint256 compared;
		uint256 unreadable;
		uint256 warmingUp;
	}

	error ListedMismatch(address asset, bool listed);
	error ReadableMismatch(address asset, bool live, bool release);
	error RateMismatch(address asset, uint256 live, uint256 release);
	error V4PricedBeforeSamples(address asset);
	error ValueMismatch(address asset, uint256 live, uint256 release);
	error PairMismatch(uint256 pair, address live, address release);

	/// @notice Every primitive is listed unless the release leaves it out, and every derivative is listed.
	function checkListed(Release.Deployed memory d, address[] memory primitives, address[] memory derivatives)
		internal
		view
	{
		for (uint256 i; i < primitives.length; ++i) {
			ReleaseListings.Kind kind = ReleaseListings.kindOf(primitives[i]);
			bool leftOut = kind == ReleaseListings.Kind.Skipped || kind == ReleaseListings.Kind.DeadFeed;
			bool listed = d.valueInterpreter.isSupportedAsset(primitives[i]);
			if (listed == leftOut) revert ListedMismatch(primitives[i], listed);
		}
		for (uint256 i; i < derivatives.length; ++i) {
			if (!d.valueInterpreter.isSupportedAsset(derivatives[i])) revert ListedMismatch(derivatives[i], false);
		}
	}

	/// @notice The same USD rate on the release as live for every primitive both can read now (a stale feed reverts on
	///         both). A v4 token reads nothing until the keeper has sampled the release's empty sampler.
	function compareRates(Release.Deployed memory d, address[] memory primitives) internal returns (Rates memory x) {
		IValueInterpreter release = IValueInterpreter(address(d.valueInterpreter));
		for (uint256 i; i < primitives.length; ++i) {
			address asset = primitives[i];
			ReleaseListings.Kind kind = ReleaseListings.kindOf(asset);
			if (kind == ReleaseListings.Kind.Skipped || kind == ReleaseListings.Kind.DeadFeed) continue;
			if (kind == ReleaseListings.Kind.Perp || kind == ReleaseListings.Kind.Stock) {
				if (!_copyStoredPrice(d, asset)) continue;
			}
			(bool liveOk, uint256 liveRate) = _rate(ReleaseListings.LIVE_VI, asset);
			(bool releaseOk, uint256 releaseRate) = _rate(release, asset);
			if (kind == ReleaseListings.Kind.PoolV4) {
				if (releaseOk) revert V4PricedBeforeSamples(asset);
				++x.warmingUp;
				continue;
			}
			if (releaseOk != liveOk) revert ReadableMismatch(asset, liveOk, releaseOk);
			if (!liveOk) {
				++x.unreadable;
				continue;
			}
			if (releaseRate != liveRate) revert RateMismatch(asset, liveRate, releaseRate);
			++x.compared;
		}
	}

	/// @notice The same USDC value for one whole share of every derivative the live system can value now.
	function compareValues(Release.Deployed memory d, address[] memory derivatives) internal returns (uint256 compared) {
		IValueInterpreter release = IValueInterpreter(address(d.valueInterpreter));
		for (uint256 i; i < derivatives.length; ++i) {
			(bool liveOk, uint256 liveValue) = _value(ReleaseListings.LIVE_VI, derivatives[i]);
			if (!liveOk) continue;
			(bool releaseOk, uint256 releaseValue) = _value(release, derivatives[i]);
			if (!releaseOk || releaseValue != liveValue) revert ValueMismatch(derivatives[i], liveValue, releaseValue);
			++compared;
		}
	}

	/// @notice The release maps every pair exactly as the live config does.
	function comparePairMap(Release.Deployed memory d) internal view returns (uint256 pairs) {
		pairs = ReleaseListings.LIVE_PERP_CONFIG.pairStorage().pairsCount();
		for (uint256 i; i < pairs; ++i) {
			address live = ReleaseListings.LIVE_PERP_CONFIG.pairAsset(i);
			address mapped = d.perpConfig.pairAsset(i);
			if (mapped != live) revert PairMismatch(i, live, mapped);
		}
	}

	/// @dev The live store's word for the asset's pair, written into the release's store; false for a first-store marker.
	function _copyStoredPrice(Release.Deployed memory d, address asset) private returns (bool) {
		(address aggregator,,,) = ReleaseListings.LIVE_VI.getAssetInfo(asset);
		(bool ok, bytes memory ret) = aggregator.staticcall(abi.encodeWithSignature('store()'));
		if (!ok || abi.decode(ret, (address)) == LIVE_FIRST_STORE) return false;
		(, ret) = aggregator.staticcall(abi.encodeWithSignature('pairIndex()'));
		bytes32 slot = keccak256(abi.encode(abi.decode(ret, (uint256)), uint256(0)));
		bytes32 word = vm.load(LIVE_VERANTA_STORE, slot);
		if (word != bytes32(0)) vm.store(address(d.verantaStore), slot, word);
		return true;
	}

	function _rate(IValueInterpreter vi, address asset) private view returns (bool ok, uint256 rate) {
		try vi.calcUsdRate(asset) returns (uint256 value) {
			return (true, value);
		} catch {
			return (false, 0);
		}
	}

	/// @dev calcCanonicalAssetValue isn't view: a feed may write.
	function _value(IValueInterpreter vi, address asset) private returns (bool ok, uint256 value) {
		(bool decOk, bytes memory ret) = asset.staticcall(abi.encodeWithSignature('decimals()'));
		uint256 unit = decOk && ret.length == 32 ? 10 ** abi.decode(ret, (uint8)) : 1e18;
		try vi.calcCanonicalAssetValue(asset, unit, BaseMainnet.USDC) returns (uint256 v) {
			return (true, v);
		} catch {
			return (false, 0);
		}
	}
}
