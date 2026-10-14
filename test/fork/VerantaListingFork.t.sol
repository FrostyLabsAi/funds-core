// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {AggregatorV3Interface} from '../../src/interfaces/AggregatorV3Interface.sol';
import {VerantaPriceStore, IPythLazerVerifier, IVerantaLazerPairs} from '../../src/pricing/VerantaPriceStore.sol';
import {VerantaPriceAdapter} from '../../src/pricing/VerantaPriceAdapter.sol';
import {MockERC20} from '../utils/Mocks.sol';
import {VerantaFundingFixture as Fx} from '../utils/VerantaFundingFixture.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {VerantaListing, IVerantaPairCatalog} from '../../script/mainnet/VerantaListing.sol';
import {IRegistrarV2Passthrough, IValueInterpreterAdmin, ViAdmin} from '../../script/mainnet/ListingModuleBook.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {FreshPoolPricing} from '../utils/FreshPoolPricing.sol';

/// @notice The Veranta listing batch on the genesis deployment, against Veranta's LIVE pair
///         catalog on Base mainnet: every listed, Lazer-priced pair that genesis left unmapped
///         gets a marker + adapter + VI primitive + setPairAsset; ETH and BTC keep their genesis
///         Chainlink mapping; crypto pairs get a 1-hour max age, closed-market classes 5 days;
///         after a real funding batch is relayed, the VI prices the listed markers.
///         Run: BASE_MAINNET_RPC=<url> forge test --match-path test/fork/VerantaListingFork.t.sol
contract VerantaListingForkTest is Test {
	address internal constant SAFE = 0xB0f37bE90a8BD82D991Bf694F960C67198778B8B;
	IVerantaPairCatalog internal constant CATALOG = IVerantaPairCatalog(FundsMainnet.VERANTA_PAIR_STORAGE);

	bool internal forked;
	address internal deployer = makeAddr('deployer');
	FundsMainnet.Deployed internal d;
	VerantaPriceStore internal store;
	PoolPriceRegistrar internal registrar;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, Fx.BLOCK);
		forked = true;
		MockERC20 frostStandIn = new MockERC20('FROST stand-in', 'FROST', 18);
		vm.startPrank(deployer);
		d = FundsMainnet.deploy(
			FundsMainnet.Config({deployer: deployer, safe: SAFE, frost: address(frostStandIn), autopilotKeeper: makeAddr('keeper'), protocolFeeBps: 25})
		);
		store = new VerantaPriceStore(
			IPythLazerVerifier(VerantaListing.PYTH_LAZER_VERIFIER), IVerantaLazerPairs(FundsMainnet.VERANTA_PAIR_STORAGE)
		);
		// as on mainnet since 2026-10-04: the PoolPriceRegistrar owns the VI
		registrar = FreshPoolPricing.takeOverVi(d, deployer).registrar;
		vm.stopPrank();
		assertEq(d.valueInterpreter.owner(), address(registrar), 'the registrar owns the VI');
	}

	function test_fork_listsEveryUnmappedLazerPair_withTheTenMinuteLifetime() public {
		vm.skip(!forked);
		vm.startPrank(deployer);
		uint256 listed = VerantaListing.listAll(store, ViAdmin(IValueInterpreterAdmin(address(registrar)), IRegistrarV2Passthrough(address(0))), d.verantaFactory);
		vm.stopPrank();

		uint256 expected;
		uint256 count = CATALOG.pairsCount();
		for (uint256 i; i < count; ++i) {
			(string memory from,,) = CATALOG.pairData(i);
			address asset = d.verantaFactory.pairAsset(i);
			if (i == FundsMainnet.VERANTA_ETH_PAIR || i == FundsMainnet.VERANTA_BTC_PAIR) {
				assertTrue(asset == FundsMainnet.WETH || asset == FundsMainnet.CBBTC, 'genesis mapping kept');
				continue;
			}
			bool lazer = bytes(from).length != 0 && CATALOG.getLazerFeedId(i) != 0;
			if (!lazer) {
				assertEq(asset, address(0), 'non-Lazer / delisted pair left alone');
				continue;
			}
			++expected;
			assertTrue(asset != address(0), 'every Lazer pair mapped');
			assertTrue(d.valueInterpreter.isSupportedAsset(asset), 'and priced by the VI');
			(address aggregator, uint32 heartbeat,,) = d.valueInterpreter.getAssetInfo(asset);
			VerantaPriceAdapter adapter = VerantaPriceAdapter(aggregator);
			assertEq(adapter.pairIndex(), i);
			// prices on demand (2026-10-05): every group, crypto or closed-market, 10 minutes
			assertEq(adapter.maxPushAge(), 10 minutes);
			assertEq(heartbeat, 10 minutes);
		}
		assertEq(listed, expected, 'listed exactly the Lazer pairs genesis left unmapped');
		assertGt(listed, 150, 'the long tail is covered');
	}

	function test_fork_afterARelay_theViPricesListedMarkersAtVerantasPrice() public {
		vm.skip(!forked);
		vm.startPrank(deployer);
		VerantaListing.listAll(store, ViAdmin(IValueInterpreterAdmin(address(registrar)), IRegistrarV2Passthrough(address(0))), d.verantaFactory);
		vm.stopPrank();
		store.relayFunding{value: 1 ether}(Fx.calldata_());

		(uint256[50] memory pairs, uint256[50] memory prices1e10) = Fx.verantaPrices();
		uint256 checked;
		for (uint256 i; i < Fx.PAIRS; ++i) {
			address marker = d.verantaFactory.pairAsset(pairs[i]);
			if (marker == FundsMainnet.WETH || marker == FundsMainnet.CBBTC) continue; // genesis Chainlink pairs
			uint256 rate = d.valueInterpreter.calcUsdRate(marker); // 18 decimals
			assertApproxEqAbs(rate, prices1e10[i] * 1e8, 1e10, 'VI rate == Veranta settlement price');
			++checked;
		}
		assertEq(checked, Fx.PAIRS - 2);
	}

	function test_fork_listingTwiceIsANoOp() public {
		vm.skip(!forked);
		vm.startPrank(deployer);
		VerantaListing.listAll(store, ViAdmin(IValueInterpreterAdmin(address(registrar)), IRegistrarV2Passthrough(address(0))), d.verantaFactory);
		assertEq(VerantaListing.listAll(store, ViAdmin(IValueInterpreterAdmin(address(registrar)), IRegistrarV2Passthrough(address(0))), d.verantaFactory), 0, 'already-mapped pairs are skipped');
		vm.stopPrank();
	}
}
