// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IValueInterpreter} from '../../src/interfaces/IValueInterpreter.sol';
import {IValueInterpreterAdmin} from '../../src/interfaces/IValueInterpreterAdmin.sol';
import {IPoolPriceAdapter} from '../../src/interfaces/IPoolPriceAdapter.sol';
import {IVerantaPerpConfig} from '../../src/interfaces/IVerantaPerpConfig.sol';
import {PoolKey} from '../../src/interfaces/external/IUniswapV4.sol';
import {VerantaPriceAdapter} from '../../src/pricing/VerantaPriceAdapter.sol';
import {B20VerantaPriceAdapter} from '../../src/pricing/B20VerantaPriceAdapter.sol';
import {Vm} from 'forge-std/Vm.sol';
import {Release} from './Release.sol';
import {BaseMainnet} from './BaseMainnet.sol';
import {ILiveRegistrar} from './interfaces/ILiveRegistrar.sol';

/// @title ReleaseListings
/// @notice Copies what today's system prices onto the release: every asset is read off the LIVE contracts at run time
///         (its feed, heartbeat and answer band; its pool; its Veranta pair and ages) and listed the same way on the
///         release, so nothing is typed in by hand. The only input is which assets: the ValueInterpreter can't enumerate
///         them, so they come from the subgraph (script/release/release-assets.sh). Run by the release's owner, after
///         Release.deploy, while the VI is still the owner's: the feeds and vaults are listed on it directly, then the
///         registrar takes it (Release.handOverValueInterpreter) and the pools follow. `register` is open to anyone from
///         the handover on, so everything a pool of someone's own could be registered in place of is listed before it
///         (review 2026-11-16: listed after, a vault share registered on a prepared pool made its listing revert).
/// @dev What is left out, on purpose:
///      - perp markers no pair maps (the UPSIDE pairs, founder 2026-11-15 "leave them removed", and three orphaned
///        duplicates), since a marker is only reachable through the pair map;
///      - the three quotes Release.deploy already lists;
///      - a Chainlink feed Chainlink has retired (its proxy answers nothing: STG's on 2026-11-15), which can't be listed
///        and prices nothing live either.
///      Order matters: Chainlink feeds before quotes (a quote must be priced), quotes and hooks before pools, the
///      underlyings before the derivatives priced from them (a CLM vault's two sides are feed-priced, never pool-priced).
library ReleaseListings {
	Vm private constant vm = Vm(address(uint160(uint256(keccak256('hevm cheat code')))));
	/// @dev Today's ValueInterpreter, registrar (windowed chain head) and perp config (deployments/base-mainnet*.json).
	IValueInterpreter internal constant LIVE_VI = IValueInterpreter(0x3CDbaBE5Bf4E6cfE10A2A326E0ad31b2d16398D4);
	ILiveRegistrar internal constant LIVE_REGISTRAR = ILiveRegistrar(0x1f77D419d8C5A709FC90D2ec56f2D187A5AcC466);
	IVerantaPerpConfig internal constant LIVE_PERP_CONFIG = IVerantaPerpConfig(0x6B15EC5B2D19f7D4625eEe0edaFfE357b599D8a9);
	/// @dev Today's derivative feeds (subgraph `feed`): two CLM feeds on the same strategy factory, the ERC-4626 feed and
	///      the exit-fee ERC-4626 feed.
	address internal constant LIVE_CLM_FEED_1 = 0xA57D9997a748f60b927d1A8b53FEdC6617e5C1c0;
	address internal constant LIVE_CLM_FEED_2 = 0xFEE1562EDA92DAFD4eAc2F9Cd9AC888D3eA09CfA;
	address internal constant LIVE_ERC4626_FEED = 0x6fAf4227478965EE848d71EbFa13cB1FbE9BE34f;
	address internal constant LIVE_ERC4626_EXIT_FEED = 0x40b5365fB490B30eC22F34d2a5E158141dF45884;
	/// @dev The three approved v4 hooks and the five launch pools (V4Pricing.sol, deployed-2026-11-15 tag); each is copied
	///      only if the live registrar still approves it.
	address internal constant STOCKIFY_HOOK = 0x47Ec48C74f3069e9Ae69406197821996d80200cC;
	address internal constant O1_HOOK_1 = 0x3b2b979DF21036CEe51B8debB13100e2CB8DeaCC;
	address internal constant O1_HOOK_2 = 0x1f91c998e7c2F4b690D75BDBf6502BDcD6e02AcC;
	/// @dev STFY's launch pool and its sale tax: StockifyFeeHook takes 3% of the ETH side of every swap (verified source;
	///      UniswapV4Fork measures it on a buy). On a sale that is 3% of the ETH out, ≈ 2.9% of what is sold, so 290:
	///      rounded down, the keeper's cap never runs ahead of the real tax. Recorded so the keeper can sell STFY for an
	///      overdue exit (founder 2026-11-15).
	bytes32 internal constant STFY_POOL_ID = 0xa6979745954ea4976d4c94a5957c225801de74b4ef6ab22d122854fb09405e06;
	uint16 internal constant STFY_SALE_TAX_BPS = 290;

	enum Kind {
		Skipped,
		DeadFeed,
		Chainlink,
		Pool,
		PoolV4,
		Perp,
		Stock
	}

	struct Counts {
		uint256 chainlink;
		uint256 quotes;
		uint256 pools;
		uint256 perps;
		uint256 stocks;
		uint256 derivatives;
		uint256 pairs;
		uint256 skipped;
		uint256 deadFeeds;
	}

	error UnknownDerivativeFeed(address asset, address feed);
	error NotPricedLive(address asset);
	error DerivativeFeedMismatch(address asset, address liveFeed, address listedFeed);

	/// @notice Lists `primitives` and the `derivatives` (with the live feed each one uses), copies the quotes, hooks and v4
	///         approvals, and the perp pair map.
	function list(
		Release.Deployed memory d,
		address[] memory primitives,
		address[] memory derivatives,
		address[] memory derivativeFeeds
	) internal returns (Counts memory c) {
		Kind[] memory kinds = new Kind[](primitives.length);
		for (uint256 i; i < primitives.length; ++i) {
			kinds[i] = kindOf(primitives[i]);
			if (kinds[i] == Kind.Skipped) ++c.skipped;
			if (kinds[i] == Kind.DeadFeed) ++c.deadFeeds;
		}
		// on the VI, by its owner: the feeds, the perp markers and stocks, the vaults
		for (uint256 i; i < primitives.length; ++i) {
			if (kinds[i] == Kind.Chainlink && _listChainlink(d, primitives[i])) ++c.chainlink;
		}
		for (uint256 i; i < primitives.length; ++i) {
			if (kinds[i] == Kind.Perp) {
				_listPerpMarker(d, primitives[i]);
				++c.perps;
			} else if (kinds[i] == Kind.Stock) {
				_listStock(d, primitives[i]);
				++c.stocks;
			}
		}
		for (uint256 i; i < derivatives.length; ++i) {
			_execute(d, abi.encodeCall(IValueInterpreterAdmin.addDerivative, (derivatives[i], _releaseFeed(d, derivatives[i], derivativeFeeds[i]))));
			++c.derivatives;
		}
		// the registrar takes the VI; from here anyone can register, and only what is left to list is pools
		if (d.valueInterpreter.owner() != address(d.registrar)) Release.handOverValueInterpreter(d);
		for (uint256 i; i < primitives.length; ++i) {
			if (kinds[i] == Kind.Chainlink && _copyQuote(d, primitives[i])) ++c.quotes;
		}
		_copyHooksAndApprovals(d);
		d.registrar.setPoolSaleTax(STFY_POOL_ID, STFY_SALE_TAX_BPS);
		for (uint256 i; i < primitives.length; ++i) {
			if (kinds[i] == Kind.Pool) {
				d.registrar.setPool(primitives[i], IPoolPriceAdapter(LIVE_REGISTRAR.poolPricedAdapter(primitives[i])).config().pool);
				++c.pools;
			} else if (kinds[i] == Kind.PoolV4) {
				d.registrar.setPoolV4(primitives[i], _liveV4Key(primitives[i]));
				++c.pools;
			}
		}
		c.pairs = _copyPairMap(d);
	}

	/// @notice How the live system prices `asset`, or Skipped for what the release leaves out.
	function kindOf(address asset) internal view returns (Kind) {
		(address aggregator,,,) = LIVE_VI.getAssetInfo(asset);
		if (aggregator == address(0)) revert NotPricedLive(asset);
		if (LIVE_REGISTRAR.poolPricedAdapter(asset) == aggregator) {
			// a v4 key's currency1 is never zero (native ETH sorts first); every other venue answers an empty key
			(, address currency1,,,) = LIVE_REGISTRAR.v4KeyOf(asset);
			return currency1 == address(0) ? Kind.Pool : Kind.PoolV4;
		}
		if (_hasAddress(aggregator, 'token()')) return Kind.Stock;
		(bool isPerp, uint256 pairIndex) = _uint(aggregator, 'pairIndex()');
		if (isPerp) return LIVE_PERP_CONFIG.pairAsset(pairIndex) == asset ? Kind.Perp : Kind.Skipped;
		(bool live,) = _uint(aggregator, 'decimals()');
		return live ? Kind.Chainlink : Kind.DeadFeed;
	}

	/// @dev The live feed, heartbeat and answer band; false for the three quotes Release.deploy listed. Those three by
	///      name, not "already listed": on a second run that would keep whatever a token got registered as meanwhile.
	function _listChainlink(Release.Deployed memory d, address asset) private returns (bool) {
		if (asset == BaseMainnet.USDC || asset == BaseMainnet.WETH || asset == BaseMainnet.CBBTC) return false;
		(address aggregator, uint32 heartbeat,,) = LIVE_VI.getAssetInfo(asset);
		_execute(d, abi.encodeCall(IValueInterpreterAdmin.addPrimitive, (asset, aggregator, heartbeat)));
		_copyBounds(d, asset);
		return true;
	}

	function _copyQuote(Release.Deployed memory d, address asset) private returns (bool) {
		if (!LIVE_REGISTRAR.isQuote(asset) || d.registrar.isQuote(asset)) return false;
		d.registrar.setQuote(asset, true);
		return true;
	}

	function _copyHooksAndApprovals(Release.Deployed memory d) private {
		address[3] memory hooks = [STOCKIFY_HOOK, O1_HOOK_1, O1_HOOK_2];
		for (uint256 i; i < hooks.length; ++i) {
			(bool approved, bytes memory hookData) = LIVE_REGISTRAR.hookOf(hooks[i]);
			if (approved) d.registrar.setHook(hooks[i], true, hookData);
		}
		bytes32[5] memory launchPools = [
			STFY_POOL_ID, // STFY
			0x41084f2d35b54dc0d070fbf76aa52c46f5d9c7e36c163252064b6b184d9429d9, // BLUECHIP
			0x69bbadafdb28b6952c2910bed1d49fb1b11a222cbf36143fc1aca3c26b35c28e, // RAWR
			0x63d8d458d63d18a7a5941575105f5c6521170854d85c141de96afdeaaa803776, // MOONBASE
			0x442f76f734fc93e2bd307b1a434574f99c3508eddb62b7719c3eac8f9eb1d460 // BASEASS
		];
		for (uint256 i; i < launchPools.length; ++i) {
			if (LIVE_REGISTRAR.isPoolApproved(launchPools[i])) d.registrar.setPoolApproved(launchPools[i], true);
		}
	}

	/// @dev A perp marker on the release's store, with the live adapter's pair, ages and heartbeat. The live crypto
	///      markers' adapters (the first store's) have one age, on the last trade; it becomes both ages here, which reads
	///      the same: a 24/7 pair's trade and its confirmation move together.
	function _listPerpMarker(Release.Deployed memory d, address marker) private {
		(address aggregator, uint32 heartbeat,,) = LIVE_VI.getAssetInfo(marker);
		(, uint256 pairIndex) = _uint(aggregator, 'pairIndex()');
		(, uint256 maxPushAge) = _uint(aggregator, 'maxPushAge()');
		(bool hasFeedAge, uint256 maxFeedAge) = _uint(aggregator, 'maxFeedAge()');
		if (!hasFeedAge) maxFeedAge = maxPushAge;
		VerantaPriceAdapter adapter = new VerantaPriceAdapter(
			d.verantaStore, pairIndex, uint32(maxPushAge), uint32(maxFeedAge), _description(aggregator)
		);
		_execute(d, abi.encodeCall(IValueInterpreterAdmin.addPrimitive, (marker, address(adapter), heartbeat)));
		_copyBounds(d, marker);
	}

	/// @dev A Coinbase B20 stock on the release's store, with the live adapter's pair, ages, heartbeat and answer band.
	function _listStock(Release.Deployed memory d, address token) private {
		(address aggregator, uint32 heartbeat,,) = LIVE_VI.getAssetInfo(token);
		(, uint256 pairIndex) = _uint(aggregator, 'pairIndex()');
		(, uint256 maxPushAge) = _uint(aggregator, 'maxPushAge()');
		(, uint256 maxFeedAge) = _uint(aggregator, 'maxFeedAge()');
		B20VerantaPriceAdapter adapter = new B20VerantaPriceAdapter(
			d.verantaStore, pairIndex, token, uint32(maxPushAge), uint32(maxFeedAge), _description(aggregator)
		);
		_execute(d, abi.encodeCall(IValueInterpreterAdmin.addPrimitive, (token, address(adapter), heartbeat)));
		_copyBounds(d, token);
	}

	function _copyBounds(Release.Deployed memory d, address asset) private {
		(int256 min, int256 max) = LIVE_VI.answerBounds(asset);
		if (min != 0 || max != 0) _execute(d, abi.encodeCall(IValueInterpreterAdmin.setAnswerBounds, (asset, min, max)));
	}

	/// @dev The release's feed of the kind today's VI values `asset` with. The asset list names that feed (`listedFeed`,
	///      the subgraph's); it must be the one the live VI holds, read from its storage since it has no getter:
	///      ValueInterpreter.derivativeInfo is slot 3 (after Ownable2Step's two and assetInfo), the feed its low 20 bytes.
	///      A vault the live VI doesn't list, or lists on another feed, stops the run (review 2026-11-16).
	function _releaseFeed(Release.Deployed memory d, address asset, address listedFeed) private view returns (address) {
		address liveFeed = address(uint160(uint256(vm.load(address(LIVE_VI), keccak256(abi.encode(asset, uint256(3)))))));
		if (liveFeed == address(0) || liveFeed != listedFeed) revert DerivativeFeedMismatch(asset, liveFeed, listedFeed);
		if (liveFeed == LIVE_CLM_FEED_1 || liveFeed == LIVE_CLM_FEED_2) return address(d.clmFeed);
		if (liveFeed == LIVE_ERC4626_FEED) return address(d.erc4626Feed);
		if (liveFeed == LIVE_ERC4626_EXIT_FEED) return address(d.erc4626ExitFeed);
		revert UnknownDerivativeFeed(asset, liveFeed);
	}

	/// @dev Every pair the live config maps, mapped the same (the UPSIDE pairs are unmapped there, so they stay so).
	function _copyPairMap(Release.Deployed memory d) private returns (uint256 mapped) {
		uint256 pairs = LIVE_PERP_CONFIG.pairStorage().pairsCount();
		for (uint256 i; i < pairs; ++i) {
			address asset = LIVE_PERP_CONFIG.pairAsset(i);
			if (asset == address(0)) continue;
			d.perpConfig.setPairAsset(i, asset);
			++mapped;
		}
	}

	function _liveV4Key(address asset) private view returns (PoolKey memory key) {
		(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks) = LIVE_REGISTRAR.v4KeyOf(asset);
	}

	/// @dev A call on the release's VI: straight from its owner while that is the deployer, through the registrar once
	///      it owns the VI (a second run, after the handover).
	function _execute(Release.Deployed memory d, bytes memory call) private {
		if (d.valueInterpreter.owner() == address(d.registrar)) {
			d.registrar.execute(call);
			return;
		}
		(bool ok, bytes memory ret) = address(d.valueInterpreter).call(call);
		if (!ok) {
			assembly ('memory-safe') {
				revert(add(ret, 32), mload(ret))
			}
		}
	}

	function _hasAddress(address target, string memory signature) private view returns (bool) {
		(bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(signature));
		return ok && ret.length == 32;
	}

	function _uint(address target, string memory signature) private view returns (bool ok, uint256 value) {
		bytes memory ret;
		(ok, ret) = target.staticcall(abi.encodeWithSignature(signature));
		ok = ok && ret.length == 32;
		if (ok) value = abi.decode(ret, (uint256));
	}

	function _description(address aggregator) private view returns (string memory) {
		(bool ok, bytes memory ret) = aggregator.staticcall(abi.encodeWithSignature('description()'));
		return ok && ret.length >= 64 ? abi.decode(ret, (string)) : '';
	}
}
