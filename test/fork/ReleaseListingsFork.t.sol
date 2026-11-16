// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {ReleaseListings} from '../../script/release/ReleaseListings.sol';
import {ReleaseChecks} from '../../script/release/ReleaseChecks.sol';
import {B20LocalStandIns} from '../../script/release/B20LocalStandIn.sol';
import {ReleaseFork} from './utils/ReleaseFork.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IPoolPriceAdapter} from '../../src/interfaces/IPoolPriceAdapter.sol';

/// @notice The listings on live Base: the release deployed at the block the asset list was read at
///         (deployments/release-assets.json, script/release/release-assets.sh), then ReleaseListings copies everything
///         today's system prices. Every listed asset must price on the release exactly as it prices live
///         (ReleaseChecks): the same Chainlink feed, a clone of the same pool, the same Veranta pair from a store holding
///         the live store's word, the same vault feed logic. What the release leaves out is checked too.
///         Run: BASE_MAINNET_RPC=<url> forge test --match-path test/fork/ReleaseListingsFork.t.sol -vv
contract ReleaseListingsForkTest is ReleaseFork {
	address[] internal primitives;
	address[] internal derivatives;
	address[] internal derivativeFeeds;
	ReleaseListings.Counts internal counts;
	/// @dev What an outsider's `register` of a live pool-priced token on its live pool answered before the listings ran.
	bytes internal registerBeforeListings;

	function _forkBlock() internal view override returns (uint256) {
		return vm.parseJsonUint(vm.readFile('deployments/release-assets.json'), '.block');
	}

	function setUp() public override {
		super.setUp();
		if (!forked) return;
		string memory assets = vm.readFile('deployments/release-assets.json');
		primitives = vm.parseJsonAddressArray(assets, '.primitives');
		derivatives = vm.parseJsonAddressArray(assets, '.derivatives');
		derivativeFeeds = vm.parseJsonAddressArray(assets, '.derivativeFeeds');
		B20LocalStandIns.standIn(primitives);
		registerBeforeListings = _outsiderRegistersALivePool();
		counts = ReleaseListings.list(r, primitives, derivatives, derivativeFeeds);
	}

	/// @dev As DeployRelease leaves it: the VI with the deployer until the listings hand it over.
	function _handOver() internal override {}

	/// @dev Anyone registering a pool-priced token of the asset list on the pool it is priced on today: the first one the
	///      registrar's own checks let through (an approved quote, $25k) and so reaches the VI. The call's revert data,
	///      empty if it went through.
	function _outsiderRegistersALivePool() private returns (bytes memory) {
		for (uint256 i; i < primitives.length; ++i) {
			if (ReleaseListings.kindOf(primitives[i]) != ReleaseListings.Kind.Pool) continue;
			address pool = IPoolPriceAdapter(ReleaseListings.LIVE_REGISTRAR.poolPricedAdapter(primitives[i])).config().pool;
			vm.prank(investor);
			try r.registrar.register(primitives[i], pool) {
				return '';
			} catch (bytes memory reason) {
				if (bytes4(reason) == Ownable.OwnableUnauthorizedAccount.selector) return reason;
			}
		}
		revert('no pool-priced token of the asset list passes the registrar\'s checks');
	}

	/// The feeds and vaults go on the VI while it is the deployer's, so nobody can register a pool of their own in place
	/// of one while the listings run: `register` only works once the registrar owns the VI, and by then only pools are
	/// left, which the owner's setPool sets whatever was registered (review 2026-11-16: with the VI handed over first, a
	/// vault share registered on a prepared pool made its own listing revert).
	function test_fork_nobodyRegistersUntilTheFeedsAreListed() public {
		vm.skip(!forked);
		assertEq(
			registerBeforeListings,
			abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(r.registrar)),
			'register is refused while the VI is the deployer\'s'
		);
		assertEq(r.valueInterpreter.owner(), address(r.registrar), 'the listings hand the VI to the registrar');
		assertEq(r.valueInterpreter.pendingOwner(), address(0));
	}

	function test_fork_listsEverythingButTheLeftOuts() public {
		vm.skip(!forked);
		emit log_named_uint('chainlink', counts.chainlink);
		emit log_named_uint('quotes', counts.quotes);
		emit log_named_uint('pools', counts.pools);
		emit log_named_uint('perp markers', counts.perps);
		emit log_named_uint('B20 stocks', counts.stocks);
		emit log_named_uint('derivatives', counts.derivatives);
		emit log_named_uint('pairs mapped', counts.pairs);
		emit log_named_uint('left out', counts.skipped);
		emit log_named_uint('retired Chainlink feeds', counts.deadFeeds);
		// the three quotes Release.deploy listed are counted in neither chainlink nor skipped
		assertEq(
			counts.chainlink + counts.pools + counts.perps + counts.stocks + counts.skipped + counts.deadFeeds + 3, primitives.length
		);
		assertEq(counts.derivatives, derivatives.length);
		assertEq(counts.skipped, 8, 'the 5 UPSIDE markers and 3 orphaned duplicates');
		ReleaseChecks.checkListed(r, primitives, derivatives);
		assertEq(r.registrar.poolSaleTaxBps(ReleaseListings.STFY_POOL_ID), 290, "STFY's hook tax recorded for the keeper");
	}

	/// The asset list is one subgraph answer. A vault it names on a feed other than the one the live VI holds for it, or
	/// one the live VI doesn't list as a vault at all, stops the run (review 2026-11-16: the feed kind was taken from the
	/// file unchecked, and any ERC-4626-shaped contract in it would have been listed at its own word).
	function test_fork_aVaultNotOnItsLiveFeedStopsTheListings() public {
		vm.skip(!forked);
		address[] memory vault = new address[](1);
		address[] memory feed = new address[](1);
		vault[0] = derivatives[0];
		feed[0] = derivativeFeeds[0] == ReleaseListings.LIVE_ERC4626_FEED ? ReleaseListings.LIVE_CLM_FEED_1 : ReleaseListings.LIVE_ERC4626_FEED;
		vm.expectRevert(abi.encodeWithSelector(ReleaseListings.DerivativeFeedMismatch.selector, vault[0], derivativeFeeds[0], feed[0]));
		this.listVaults(vault, feed);

		vault[0] = USDC;
		vm.expectRevert(abi.encodeWithSelector(ReleaseListings.DerivativeFeedMismatch.selector, USDC, address(0), feed[0]));
		this.listVaults(vault, feed);
	}

	/// @dev ReleaseListings.list for vaults alone, behind a call so its revert can be expected.
	function listVaults(address[] memory vaults, address[] memory feeds) external {
		ReleaseListings.list(r, new address[](0), vaults, feeds);
	}

	function test_fork_everyPrimitivePricesAsItDoesLive() public {
		vm.skip(!forked);
		ReleaseChecks.Rates memory x = ReleaseChecks.compareRates(r, primitives);
		emit log_named_uint('rates compared', x.compared);
		emit log_named_uint('unreadable on both (stale now)', x.unreadable);
		emit log_named_uint('v4 tokens waiting for samples', x.warmingUp);
		// 198 at block 57,964,048: Chainlink, pool and stored Veranta prices; on-demand perp prices are mostly stale, which
		// both read alike
		assertGt(x.compared, 150);
	}

	function test_fork_everyDerivativeValuesAsItDoesLive() public {
		vm.skip(!forked);
		uint256 compared = ReleaseChecks.compareValues(r, derivatives);
		emit log_named_uint('derivatives compared', compared);
		assertGt(compared, 40);
	}

	function test_fork_thePairMapMatchesLive_withoutTheUpsidePairs() public {
		vm.skip(!forked);
		ReleaseChecks.comparePairMap(r);
		for (uint256 i = 115; i <= 119; ++i) {
			assertEq(r.perpConfig.pairAsset(i), address(0), 'UPSIDE stays removed');
		}
	}
}
