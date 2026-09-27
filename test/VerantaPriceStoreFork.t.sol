// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {IVerantaMulticall} from '../src/interfaces/external/IVeranta.sol';
import {VerantaPerpPositionV2} from '../src/positions/VerantaPerpPositionV2.sol';
import {PriceMarker} from '../src/pricing/PriceMarker.sol';
import {VerantaPriceStore, IPythLazerVerifier, IVerantaLazerPairs} from '../src/pricing/VerantaPriceStore.sol';
import {VerantaPriceAdapter} from '../src/pricing/VerantaPriceAdapter.sol';
import {MockERC20} from './utils/Mocks.sol';
import {VerantaFundingFixture as Fx} from './utils/VerantaFundingFixture.sol';
import {FundsMainnet} from '../script/mainnet/FundsMainnet.sol';

/// @notice The Veranta price store against REAL Base-mainnet data: a real funding-accumulator
///         transaction's calldata (50 Pyth-Lazer-signed packets), Pyth's real Lazer verifier and
///         Veranta's real pair→Lazer-feed mapping — forked at that transaction's block. Every
///         stored price must equal the price Veranta's own PriceAggregator validated for the
///         same pair in the same transaction.
///         Run: BASE_MAINNET_RPC=<url> forge test --match-path test/VerantaPriceStoreFork.t.sol
contract VerantaPriceStoreForkTest is Test {
	IPythLazerVerifier internal constant LAZER = IPythLazerVerifier(0xACeA761c27A909d4D3895128EBe6370FDE2dF481);
	IVerantaLazerPairs internal constant VERANTA_PAIRS = IVerantaLazerPairs(0x5db3772136e5557EFE028Db05EE95C84D76faEC4);

	bool internal forked;
	VerantaPriceStore internal store;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, Fx.BLOCK);
		forked = true;
		store = new VerantaPriceStore(LAZER, VERANTA_PAIRS);
	}

	/// Veranta's own conversion (PriceAggregator._parsePythLazerPrice) to 1e10 precision
	function _verantaPrecision(int64 price, int16 exponent) internal pure returns (uint256) {
		// Veranta multiplies by a uint256 constant, so the product is uint256 — widen first too
		if (exponent > 0) return uint256(uint64(price)) * 1e10 * 10 ** uint32(uint16(exponent));
		return (uint256(uint64(price)) * 1e10) / 10 ** uint32(uint16(-exponent));
	}

	function _decoded() internal pure returns (uint256[] memory pairs, bytes[][] memory updates, uint8[] memory sourcing) {
		bytes memory data = Fx.calldata_();
		bytes memory args = new bytes(data.length - 4);
		for (uint256 i; i < args.length; ++i) {
			args[i] = data[i + 4];
		}
		(pairs, updates, sourcing) = abi.decode(args, (uint256[], bytes[][], uint8[]));
	}

	function test_fork_relayStoresEveryPairAtVerantasOwnPrice() public {
		vm.skip(!forked);
		uint256 stored = store.relayFunding{value: 1 ether}(Fx.calldata_());
		assertEq(stored, Fx.PAIRS, 'every packet in the batch stored');

		(uint256[50] memory pairs, uint256[50] memory expected) = Fx.verantaPrices();
		for (uint256 i; i < Fx.PAIRS; ++i) {
			(int64 price, int16 exponent, uint64 timestampUs) = store.latest(pairs[i]);
			assertGt(timestampUs, 0);
			assertLe(timestampUs / 1e6, block.timestamp);
			assertEq(_verantaPrecision(price, exponent), expected[i], 'store price == Veranta validated price');
		}
	}

	function test_fork_adapterServesEightDecimals_andTheViPricesTheMarker() public {
		vm.skip(!forked);
		store.relayFunding{value: 1 ether}(Fx.calldata_());
		(uint256[50] memory pairs, uint256[50] memory expected) = Fx.verantaPrices();

		VerantaPriceAdapter adapter = new VerantaPriceAdapter(store, pairs[2], 1 hours, 'SOL / USD (Veranta)');
		assertEq(adapter.decimals(), 8);
		(, int256 answer,, uint256 updatedAt,) = adapter.latestRoundData();
		assertApproxEqAbs(uint256(answer), expected[2] / 100, 1, '8-dp answer == Veranta price');
		(,, uint64 timestampUs) = store.latest(pairs[2]);
		assertEq(updatedAt, timestampUs / 1e6);

		ValueInterpreter vi = new ValueInterpreter(address(this));
		PriceMarker marker = new PriceMarker('Veranta SOL', 'vmSOL');
		vi.addPrimitive(address(marker), address(adapter), 1 hours);
		assertEq(vi.calcUsdRate(address(marker)), uint256(answer) * 1e10, 'the VI prices the marker at the adapter');
	}

	function test_fork_aTamperedPacketIsRefused_andSkippedInABatch() public {
		vm.skip(!forked);
		(uint256[] memory pairs, bytes[][] memory updates, uint8[] memory sourcing) = _decoded();
		bytes memory packet = updates[0][0];
		packet[packet.length - 10] = bytes1(uint8(packet[packet.length - 10]) ^ 0x01); // inside the signed payload

		vm.expectRevert();
		store.submit{value: 1 ether}(pairs[0], packet);

		updates[0][0] = packet;
		bytes memory tampered = abi.encodeWithSelector(store.FUNDING_SELECTOR(), pairs, updates, sourcing);
		assertEq(store.relayFunding{value: 1 ether}(tampered), Fx.PAIRS - 1, 'only the tampered pair is skipped');
		(,, uint64 timestampUs) = store.latest(pairs[0]);
		assertEq(timestampUs, 0, 'nothing stored for the tampered pair');
	}

	function test_fork_aPacketForAnotherPairIsRefused() public {
		vm.skip(!forked);
		(uint256[] memory pairs, bytes[][] memory updates,) = _decoded();
		uint32 wanted = uint32(VERANTA_PAIRS.getLazerFeedId(pairs[1]));
		vm.expectRevert(abi.encodeWithSelector(VerantaPriceStore.FeedNotFound.selector, pairs[1], wanted));
		store.submit{value: 1 ether}(pairs[1], updates[0][0]);
	}

	function test_fork_aPacketNoNewerThanTheStoredOneIsNotStored() public {
		vm.skip(!forked);
		(uint256[] memory pairs, bytes[][] memory updates,) = _decoded();
		assertTrue(store.submit{value: 1 ether}(pairs[0], updates[0][0]));
		assertFalse(store.submit{value: 1 ether}(pairs[0], updates[0][0]), 'same packet again: not newer');
	}

	function test_fork_relayingTheSameBatchAgainReverts_soKeepersSkipItForFree() public {
		vm.skip(!forked);
		store.relayFunding{value: 1 ether}(Fx.calldata_());
		vm.expectRevert(VerantaPriceStore.NothingNewer.selector);
		store.relayFunding{value: 1 ether}(Fx.calldata_());
	}

	function test_fork_relayRefusesAnyOtherCalldata() public {
		vm.skip(!forked);
		vm.expectRevert(VerantaPriceStore.NotFundingCalldata.selector);
		store.relayFunding(abi.encodeWithSignature('transfer(address,uint256)', address(1), 1));
	}

	function test_fork_adapterRevertsWhenNeverPushedOrStale() public {
		vm.skip(!forked);
		VerantaPriceAdapter never = new VerantaPriceAdapter(store, 999, 1 hours, 'none');
		vm.expectRevert(abi.encodeWithSelector(VerantaPriceAdapter.NeverPushed.selector, uint256(999)));
		never.latestRoundData();

		store.relayFunding{value: 1 ether}(Fx.calldata_());
		(uint256[50] memory pairs,) = Fx.verantaPrices();
		VerantaPriceAdapter adapter = new VerantaPriceAdapter(store, pairs[0], 1 hours, 'ETH / USD (Veranta)');
		(,,, uint256 updatedAt,) = adapter.latestRoundData();
		vm.warp(updatedAt + 1 hours + 1);
		vm.expectRevert(abi.encodeWithSelector(VerantaPriceAdapter.StalePush.selector, updatedAt));
		adapter.latestRoundData();
	}
}

/// @notice End to end on the genesis deployment: a pair genesis does NOT map (priced only by
///         Veranta's Lazer packets) is listed through the store — marker + adapter + VI primitive
///         + setPairAsset — and a real fund opens a real Veranta perp on it.
contract VerantaListedPerpForkTest is Test {
	address internal constant SAFE = 0xB0f37bE90a8BD82D991Bf694F960C67198778B8B;

	bool internal forked;
	address internal deployer = makeAddr('deployer');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');
	FundsMainnet.Deployed internal d;
	VerantaPriceStore internal store;

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
		vm.stopPrank();
		store = new VerantaPriceStore(
			IPythLazerVerifier(0xACeA761c27A909d4D3895128EBe6370FDE2dF481),
			IVerantaLazerPairs(FundsMainnet.VERANTA_PAIR_STORAGE)
		);
		store.relayFunding{value: 1 ether}(Fx.calldata_());
	}

	function test_fork_aFundOpensAVerantaPerpOnAStorePricedPair() public {
		vm.skip(!forked);
		(uint256[50] memory pairs, uint256[50] memory prices1e10) = Fx.verantaPrices();
		uint256 pair = pairs[2];
		assertEq(d.verantaFactory.pairAsset(pair), address(0), 'genesis leaves this pair unmapped');

		PriceMarker marker = new PriceMarker('Veranta pair', 'vmPAIR');
		VerantaPriceAdapter adapter = new VerantaPriceAdapter(store, pair, 1 hours, 'pair / USD (Veranta)');
		vm.startPrank(deployer);
		d.valueInterpreter.addPrimitive(address(marker), address(adapter), 1 hours);
		d.verantaFactory.setPairAsset(pair, address(marker));
		vm.stopPrank();

		Comptroller fund = _fundWithDeposit(10_000e6);
		vm.prank(manager);
		VerantaPerpPositionV2 position =
			VerantaPerpPositionV2(fund.createExternalPosition(FundsMainnet.VERANTA_PERP_TYPE, ''));
		address[] memory assets = new address[](1);
		assets[0] = FundsMainnet.USDC;
		uint256[] memory amounts = new uint256[](1);
		amounts[0] = 200e6;
		bytes memory open = abi.encode(
			uint8(VerantaPerpPositionV2.Action.OpenTrade),
			abi.encode(pair, uint256(200e6), uint256(2e10), true, prices1e10[2], uint256(5e10), uint8(0), uint256(0), uint256(0))
		);
		vm.prank(manager);
		fund.callOnExternalPosition(address(position), assets, amounts, new address[](0), open);

		IVerantaMulticall.PendingOrder[] memory pending =
			IVerantaMulticall(FundsMainnet.VERANTA_MULTICALL).getPendingOrder(address(position));
		assertEq(pending.length, 1, 'the order reached Veranta');
		assertEq(fund.calcGav(), 10_000e6, 'the escrow stays valued while Veranta fills');
	}

	function _fundWithDeposit(uint256 amount) internal returns (Comptroller fund) {
		fund = Comptroller(
			d.factory.createFund(
				FundFactory.FundConfig({
					name: 'Veranta Store Fund',
					symbol: 'frVS',
					denominationAsset: IERC20(FundsMainnet.USDC),
					fundOwner: manager,
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: 0,
					sharesActionTimelock: 0,
					minRequestDuration: 1 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				})
			)
		);
		deal(FundsMainnet.USDC, alice, amount);
		vm.startPrank(alice);
		IERC20(FundsMainnet.USDC).approve(address(fund), amount);
		fund.requestDeposit(amount);
		vm.stopPrank();
		skip(1 minutes);
		fund.executeDepositRequest(alice);
	}
}
