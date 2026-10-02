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
import {TwapListingV2} from '../../script/mainnet/TwapListingV2.sol';
import {PriceListingModule} from '../../src/pricing/PriceListingModule.sol';

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
	PriceListingModule internal module;

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
		// as on mainnet since 2026-10-01: TWAP listing v2 hands the VI to its PriceListingModule
		module = _deployTwapV2();
		vm.stopPrank();
		assertEq(d.valueInterpreter.owner(), address(module), 'the module owns the VI');
	}

	function _deployTwapV2() internal returns (PriceListingModule) {
		return TwapListingV2.deploy(
			TwapListingV2.Config({
				deployer: deployer,
				valueInterpreter: d.valueInterpreter,
				factory: d.factory,
				twapPolicyV1: address(d.twapPolicy),
				keeper: address(0)
			})
		).module;
	}

	function test_fork_listsEveryUnmappedLazerPair_withTheRightMaxAge() public {
		vm.skip(!forked);
		vm.startPrank(deployer);
		uint256 listed = VerantaListing.listAll(store, module, d.verantaFactory);
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
			bool crypto = VerantaListing.isCryptoGroup(CATALOG.pairGroupIndex(i));
			assertEq(adapter.maxPushAge(), crypto ? 1 hours : 5 days);
			assertEq(heartbeat, adapter.maxPushAge());
		}
		assertEq(listed, expected, 'listed exactly the Lazer pairs genesis left unmapped');
		assertGt(listed, 150, 'the long tail is covered');
	}

	function test_fork_afterARelay_theViPricesListedMarkersAtVerantasPrice() public {
		vm.skip(!forked);
		vm.startPrank(deployer);
		VerantaListing.listAll(store, module, d.verantaFactory);
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
		VerantaListing.listAll(store, module, d.verantaFactory);
		assertEq(VerantaListing.listAll(store, module, d.verantaFactory), 0, 'already-mapped pairs are skipped');
		vm.stopPrank();
	}
}
