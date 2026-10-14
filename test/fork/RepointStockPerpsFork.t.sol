// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {AggregatorV3Interface} from '../../src/interfaces/AggregatorV3Interface.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {VerantaPriceStore} from '../../src/pricing/VerantaPriceStore.sol';
import {VerantaPriceAdapter} from '../../src/pricing/VerantaPriceAdapter.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {VerantaListing, IVerantaPairCatalog} from '../../script/mainnet/VerantaListing.sol';
import {IRegistrarV2Passthrough, IValueInterpreterAdmin, ViAdmin} from '../../script/mainnet/ListingModuleBook.sol';
import {RepointStockPerps} from '../../script/mainnet/RepointStockPerps.s.sol';

/// @notice Rehearsal of script/mainnet/RepointStockPerps.s.sol on the LIVE Base deployment (founder
///         2026-10-06): the 13 stock perps move from their Coinbase tokens' Chainlink feeds to
///         Veranta-priced markers on the store, exactly as the other 156 pairs are listed. Prices are two
///         real signed Lazer packets fetched in US market hours (13:54 UTC): GOOG and NVDA.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/RepointStockPerpsFork.t.sol
contract RepointStockPerpsForkTest is Test {
	uint256 internal constant FORK_BLOCK = 52_252_744; // 2026-10-06 13:53:55 UTC
	VerantaPriceStore internal constant STORE = VerantaPriceStore(0xc65AC79F0D3be202F85765B8c0B7a055FA02C6a6);
	IVerantaPairCatalog internal constant CATALOG = IVerantaPairCatalog(FundsMainnet.VERANTA_PAIR_STORAGE);

	uint256 internal constant GOOG = 87;
	uint256 internal constant NVDA = 81;
	address internal constant GOOGL_TOKEN = 0xb2000000000000000000002D0BA3164cc74f58B7;
	/// @dev feed-v3 /v2/pairs/87/price-update-data, published 1791294838.2 s: 341.82002
	bytes internal constant GOOG_PACKET =
		hex'2a22999a8ce5adc38e323483ed9cfd48ce9825f0f050e2c1fe7873113932fa7ba9aef8d326e897eeeeae7cb7f80e1512565eb47d5043b23c26635485f0aab36484f7df0401003293c7d37500065d2c5484d6c003010000048a0400000000000209937204fffb0500000000000013850c0100065d2c5484d6c0';
	/// @dev feed-v3 /v2/pairs/81/price-update-data, published 1791294840 s: 242.1425
	bytes internal constant NVDA_PACKET =
		hex'2a22999a4daa16a41bd570d42df6bec00320fedd516b937b8d0a1f75483f25d89382d1b07ce4689827f11fe8ced4c01a2a798098ad555dcef030c4738eae2b12534de21d01003293c7d37500065d2c54a04e0003010000052204000000000001717aea04fffb0500000000000008ca0c0100065d2c54a04e00';
	uint256 internal constant PACKETS_TS = 1_791_294_840; // the later of the two

	bool internal forked;
	VerantaPerpPositionV2Factory internal factory;
	ValueInterpreter internal vi;
	ViAdmin internal admin;
	address internal owner;
	RepointStockPerps internal script;
	string internal hedges;
	uint256[] internal pairs;
	address[] internal tokens;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, FORK_BLOCK);
		forked = true;

		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		factory = VerantaPerpPositionV2Factory(vm.parseJsonAddress(genesis, '.verantaFactory'));
		vi = ValueInterpreter(vm.parseJsonAddress(genesis, '.valueInterpreter'));
		admin = ViAdmin(IValueInterpreterAdmin(vi.owner()), IRegistrarV2Passthrough(address(0))); // the pool-pricing registrar, its owner calling
		owner = Ownable(address(admin.owner)).owner(); // the deployer until the governance handoff
		assertEq(Ownable(address(factory)).owner(), owner, 'the deployer owns both');
		script = new RepointStockPerps();
		hedges = vm.readFile('deployments/base-mainnet-stock-hedges.json');
		(pairs, tokens) = script.readHedges(hedges);
	}

	function test_fork_theTableMatchesTheChain() public {
		vm.skip(!forked);
		assertEq(pairs.length, 13);
		for (uint256 k; k < pairs.length; ++k) {
			assertEq(factory.pairAsset(pairs[k]), tokens[k], 'the perp is on its token today');
			(string memory from,,) = CATALOG.pairData(pairs[k]);
			assertEq(from, vm.parseJsonString(hedges, string.concat('.hedges[', vm.toString(k), '].perp')), 'Veranta pair symbol');
			(address feed, uint32 heartbeat,,) = vi.getAssetInfo(tokens[k]);
			assertTrue(feed != address(0), 'the token is a VI primitive');
			assertEq(heartbeat, 5 days, 'on its Chainlink feed, 5-day limit');
		}
	}

	function test_fork_repointsAllThirteen_andASecondRunIsANoOp() public {
		vm.skip(!forked);
		address[] memory feedsBefore = new address[](pairs.length);
		for (uint256 k; k < pairs.length; ++k) {
			(feedsBefore[k],,,) = vi.getAssetInfo(tokens[k]);
		}
		address eth = factory.pairAsset(FundsMainnet.VERANTA_ETH_PAIR);
		address amd = factory.pairAsset(98); // a stock perp already on a marker since 2026-10-01

		vm.startPrank(owner);
		assertEq(VerantaListing.repointToStore(STORE, admin, factory, vi, pairs, tokens), 13);
		assertEq(VerantaListing.repointToStore(STORE, admin, factory, vi, pairs, tokens), 0, 'already on markers');
		vm.stopPrank();

		for (uint256 k; k < pairs.length; ++k) {
			address marker = factory.pairAsset(pairs[k]);
			assertTrue(marker != tokens[k] && marker != address(0), 'on a new marker');
			(address aggregator, uint32 heartbeat,,) = vi.getAssetInfo(marker);
			VerantaPriceAdapter adapter = VerantaPriceAdapter(aggregator);
			assertEq(address(adapter.store()), address(STORE), 'priced by the store');
			assertEq(adapter.pairIndex(), pairs[k], 'for this pair');
			assertEq(adapter.maxPushAge(), 10 minutes);
			assertEq(heartbeat, 10 minutes, 'prices on demand, like every store pair');
			// spot trading of the token is untouched
			(address tokenFeed,,,) = vi.getAssetInfo(tokens[k]);
			assertEq(tokenFeed, feedsBefore[k], 'the token keeps its Chainlink primitive');
		}
		assertEq(factory.pairAsset(FundsMainnet.VERANTA_ETH_PAIR), eth, 'ETH untouched');
		assertEq(factory.pairAsset(98), amd, 'pairs outside the table untouched');
	}

	/// The GOOG fix: pair 87 is Veranta's GOOG (class C). On the GOOGL token's Chainlink feed it read
	/// ~0.9% high at this block; on its marker it reads Veranta's own GOOG price.
	function test_fork_googAndNvdaAreValuedAtVerantasPrice() public {
		vm.skip(!forked);
		(address googlFeed,,,) = vi.getAssetInfo(GOOGL_TOKEN);
		(, int256 googl,,,) = AggregatorV3Interface(googlFeed).latestRoundData(); // 1e8

		vm.startPrank(owner);
		VerantaListing.repointToStore(STORE, admin, factory, vi, pairs, tokens);
		vm.stopPrank();
		vm.warp(PACKETS_TS + 2);
		vm.deal(address(this), 1 ether);
		assertTrue(STORE.submit{value: 1}(GOOG, GOOG_PACKET));
		assertTrue(STORE.submit{value: 1}(NVDA, NVDA_PACKET));

		uint256 goog = vi.calcUsdRate(factory.pairAsset(GOOG)); // 1e18
		assertEq(goog, 341.82002e18, "Veranta's GOOG price");
		assertEq(vi.calcUsdRate(factory.pairAsset(NVDA)), 242.1425e18, "Veranta's NVDA price");
		uint256 gapBps = (uint256(googl) * 1e10 - goog) * 10_000 / goog;
		assertGe(gapBps, 50, 'the GOOGL feed sat well above GOOG');
		assertLe(gapBps, 150);
		emit log_named_decimal_uint('GOOGL token feed', uint256(googl), 8);
		emit log_named_decimal_uint('GOOG perp, Veranta', goog, 18);
		emit log_named_uint('gap (bps)', gapBps);

		// and like every store pair, a price is good for 10 minutes only
		address nvda = factory.pairAsset(NVDA);
		vm.warp(PACKETS_TS + 601);
		// the new adapter's own 10-minute limit refuses first (the VI's heartbeat is the same)
		vm.expectRevert(abi.encodeWithSelector(VerantaPriceAdapter.StalePush.selector, PACKETS_TS));
		vi.calcUsdRate(nvda);
	}

	/// A table that no longer matches the chain stops the run before anything is sent for that pair.
	function test_fork_refusesAPairNotOnItsToken() public {
		vm.skip(!forked);
		uint256[] memory one = new uint256[](1);
		address[] memory token = new address[](1);
		one[0] = NVDA;
		token[0] = 0xb20000000000000000000078ee7ce2fE4908108C; // NVDAc

		vm.prank(owner);
		factory.setPairAsset(NVDA, address(0xdead));
		vm.expectRevert(bytes('pair 81 is not mapped to its stock token'));
		this.repoint(one, token);

		vm.prank(owner);
		factory.setPairAsset(NVDA, address(0));
		vm.expectRevert(bytes('pair 81 is not mapped to its stock token'));
		this.repoint(one, token);
	}

	/// @dev External, so expectRevert sees the library's revert (it refuses before any owner-only call).
	function repoint(uint256[] memory p, address[] memory t) external returns (uint256) {
		return VerantaListing.repointToStore(STORE, admin, factory, vi, p, t);
	}
}
