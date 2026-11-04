// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {VerantaPriceAdapterV2} from '../../src/pricing/VerantaPriceAdapterV2.sol';
import {VerantaPriceStore} from '../../src/pricing/VerantaPriceStore.sol';
import {VerantaPriceStoreV2} from '../../src/pricing/VerantaPriceStoreV2.sol';
import {VerantaListing} from '../../script/mainnet/VerantaListing.sol';
import {ListingModuleBook, ViAdmin} from '../../script/mainnet/ListingModuleBook.sol';

/// @notice The move of closing markets to the V2 store on live Base, through the real registrar chain as the deployer.
///         Run: BASE_MAINNET_RPC=<url> forge test --match-path test/fork/MoveClosingMarketsFork.t.sol -vv
contract MoveClosingMarketsForkTest is Test {
	uint256 internal constant SPCX = 105;
	uint256 internal constant SOL = 2;
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

	ValueInterpreter internal vi;
	VerantaPerpPositionV2Factory internal factory;
	VerantaPriceStore internal storeV1;
	VerantaPriceStoreV2 internal storeV2;
	ViAdmin internal admin;
	address internal deployer;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc);
		string memory json = vm.readFile('deployments/base-mainnet.json');
		deployer = vm.parseJsonAddress(json, '.deployer');
		vi = ValueInterpreter(vm.parseJsonAddress(json, '.valueInterpreter'));
		factory = VerantaPerpPositionV2Factory(vm.parseJsonAddress(json, '.verantaFactory'));
		storeV1 = VerantaPriceStore(vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-veranta.json'), '.store'));
		storeV2 = VerantaPriceStoreV2(vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-veranta-stocks.json'), '.store'));
		admin = ListingModuleBook.admin(vm, json);
	}

	function _move() internal returns (VerantaListing.MovedPair[] memory) {
		vm.startPrank(deployer);
		VerantaListing.MovedPair[] memory moved = VerantaListing.moveClosingMarkets(storeV1, storeV2, admin, factory, vi);
		vm.stopPrank();
		return moved;
	}

	/// The V2 store's one word for a pair: price bits 0-63, exponent 64-79, confirmed 80-143, last trade 144-207.
	function _storeV2Price(uint256 pair, int64 price, int16 exponent, uint256 confirmedAt, uint256 lastTradeAt) internal {
		uint256 word = uint256(uint64(price)) | (uint256(uint16(exponent)) << 64) | (uint256(uint64(confirmedAt * 1e6)) << 80)
			| (uint256(uint64(lastTradeAt * 1e6)) << 144);
		vm.store(address(storeV2), keccak256(abi.encode(pair, uint256(0))), bytes32(word));
	}

	function test_fork_everyClosingMarketMoves_andCryptoStays() public {
		if (address(vi) == address(0)) return;
		address solMarker = factory.pairAsset(SOL);
		(address solBefore, uint32 solHeartbeat,,) = vi.getAssetInfo(solMarker);

		VerantaListing.MovedPair[] memory moved = _move();
		assertGt(moved.length, 100, 'the stocks, indices, FX and metals');
		bool sawSpcx;
		for (uint256 k; k < moved.length; ++k) {
			(address aggregator, uint32 heartbeat,,) = vi.getAssetInfo(moved[k].marker);
			VerantaPriceAdapterV2 adapter = VerantaPriceAdapterV2(aggregator);
			assertEq(aggregator, moved[k].adapter);
			assertEq(factory.pairAsset(moved[k].pairIndex), moved[k].marker, 'the marker never changes');
			assertEq(heartbeat, 5 days);
			assertEq(address(adapter.store()), address(storeV2));
			assertEq(adapter.pairIndex(), moved[k].pairIndex);
			assertEq(adapter.maxPushAge(), 10 minutes);
			assertEq(adapter.maxFeedAge(), 5 days);
			if (moved[k].pairIndex == SPCX) sawSpcx = true;
		}
		assertTrue(sawSpcx, 'the test fund holds this one');

		(address solAfter, uint32 solHeartbeatAfter,,) = vi.getAssetInfo(solMarker);
		assertEq(solAfter, solBefore, 'crypto trades around the clock and stays on V1');
		assertEq(solHeartbeatAfter, solHeartbeat);
		assertEq(_move().length, 0, 'a second run is a no-op');
	}

	/// The bug: on V1 a closed market's perp can't be valued. After the move a re-confirmed close prices it.
	function test_fork_aClosedMarketsPerpIsPricedAtItsClose() public {
		if (address(vi) == address(0)) return;
		_move();
		address marker = factory.pairAsset(SPCX);
		_storeV2Price(SPCX, 14_200_000, -5, block.timestamp, block.timestamp - 2 days);
		// in USDC at its own oracle rate, so not exactly 142
		assertApproxEqRel(vi.calcCanonicalAssetValue(marker, 1e18, USDC), 142e6, 1e16, 'one SPCX at its close');

		vm.warp(block.timestamp + 11 minutes);
		(address aggregator,,,) = vi.getAssetInfo(marker);
		vm.expectRevert(abi.encodeWithSelector(VerantaPriceAdapterV2.StalePush.selector, block.timestamp - 11 minutes));
		VerantaPriceAdapterV2(aggregator).latestRoundData();
	}
}
