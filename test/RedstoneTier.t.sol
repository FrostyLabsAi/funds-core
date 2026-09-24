// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {RedstonePriceStore} from '../src/pricing/RedstonePriceStore.sol';
import {RedstoneAggregatorAdapter} from '../src/pricing/RedstoneAggregatorAdapter.sol';
import {PriceMarker} from '../src/pricing/PriceMarker.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';
import {RedstoneFixtures} from './utils/RedstoneFixtures.sol';

/// @notice RedStone tier against REAL signed packages (RedstoneFixtures, captured from the
///         public redstone-primary-prod gateway) and the service's published signer set.
contract RedstoneTierTest is Test {
	// redstone-primary-prod signers + threshold as published in RedStone's
	// PrimaryProdDataServiceConsumerBase (read 2026-09-24) — independent of the fixture file
	address internal constant S0 = 0x8BB8F32Df04c8b654987DAaeD53D6B6091e3B774;
	address internal constant S1 = 0xdEB22f54738d54976C4c0fe5ce6d408E40d88499;
	address internal constant S2 = 0x51Ce04Be4b3E32572C4Ec9135221d0691Ba7d202;
	address internal constant S3 = 0xDD682daEC5A90dD295d14DA4b0bec9281017b5bE;
	address internal constant S4 = 0x9c5AE89C4Af6aA32cE58588DBaF90d18a855B6de;
	uint32 internal constant MAX_PUSH_AGE = 10 minutes;

	RedstonePriceStore internal store;

	function setUp() public {
		address[] memory signers = new address[](5);
		(signers[0], signers[1], signers[2], signers[3], signers[4]) = (S0, S1, S2, S3, S4);
		store = new RedstonePriceStore('redstone-primary-prod', signers, 3);
	}

	function _at(RedstoneFixtures.Snapshot memory s, int256 offsetSec) internal {
		vm.warp(uint256(int256(uint256(s.timestampMs / 1000)) + offsetSec));
	}

	function _push(RedstoneFixtures.Snapshot memory s) internal {
		store.update(s.feedId, s.timestampMs, s.values, s.signatures);
	}

	function _expectSelector(bytes memory callData, bytes4 selector) internal {
		(bool ok, bytes memory err) = address(store).call(callData);
		assertFalse(ok, 'must revert');
		assertEq(bytes4(err), selector);
	}

	function _updateCall(RedstoneFixtures.Snapshot memory s) internal pure returns (bytes memory) {
		return abi.encodeCall(RedstonePriceStore.update, (s.feedId, s.timestampMs, s.values, s.signatures));
	}

	// ─── genuine packages ────────────────────────────────────────────────────────

	function test_fixtureSignersAreThePublishedSet() public view {
		address[] memory fromGateway = RedstoneFixtures.signers();
		for (uint256 i; i < fromGateway.length; ++i) assertTrue(store.isAuthorisedSigner(fromGateway[i]));
		assertEq(store.signerCount(), 5);
		assertEq(store.threshold(), 3);
	}

	function test_realPackages_storeTheMedian() public {
		RedstoneFixtures.Snapshot memory eth = RedstoneFixtures.ethA();
		RedstoneFixtures.Snapshot memory amd = RedstoneFixtures.amdA();
		_at(eth, 5);
		_push(eth);
		_push(amd);

		(uint256 ethValue, uint64 ethTs) = store.latest(bytes32('ETH'));
		assertEq(ethValue, 269175969913); // median of the five signed values ($2,691.76)
		assertEq(ethTs, eth.timestampMs);
		(uint256 amdValue,) = store.latest(bytes32('AMD'));
		assertEq(amdValue, 62851295003); // $628.51
	}

	function test_updateMany_andAdapterServesAggregatorV3() public {
		RedstoneFixtures.Snapshot memory arb = RedstoneFixtures.arbA();
		RedstoneFixtures.Snapshot memory eth = RedstoneFixtures.ethA();
		_at(arb, 2);
		RedstonePriceStore.FeedUpdate[] memory batch = new RedstonePriceStore.FeedUpdate[](2);
		batch[0] = RedstonePriceStore.FeedUpdate(arb.feedId, arb.timestampMs, arb.values, arb.signatures);
		batch[1] = RedstonePriceStore.FeedUpdate(eth.feedId, eth.timestampMs, eth.values, eth.signatures);
		store.updateMany(batch);

		RedstoneAggregatorAdapter adapter = new RedstoneAggregatorAdapter(store, bytes32('ARB'), MAX_PUSH_AGE, 'ARB/USD (RedStone)');
		(uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = adapter.latestRoundData();
		assertEq(adapter.decimals(), 8);
		assertEq(answer, 21927256); // $0.21927256
		assertEq(updatedAt, arb.timestampMs / 1000);
		assertEq(startedAt, updatedAt);
		assertEq(roundId, answeredInRound);
	}

	function test_threeOfFiveSignersSuffice_twoDoNot() public {
		RedstoneFixtures.Snapshot memory amd = RedstoneFixtures.amdA();
		_at(amd, 1);
		RedstoneFixtures.Snapshot memory two = _firstN(amd, 2);
		(bool ok, bytes memory err) = address(store).call(_updateCall(two));
		assertFalse(ok);
		assertEq(err, abi.encodeWithSelector(RedstonePriceStore.NotEnoughSigners.selector, 2, 3));

		_push(_firstN(amd, 3));
		(uint256 value,) = store.latest(bytes32('AMD'));
		// first three by signer address: 62853818680, 62851295003, 62847643934 → median
		assertEq(value, 62851295003);
	}

	function test_tamperedValue_failsSignature() public {
		RedstoneFixtures.Snapshot memory eth = RedstoneFixtures.ethA();
		_at(eth, 1);
		eth.values[2] += 1; // one cent-of-a-cent moves the recovered signer
		_expectSelector(_updateCall(eth), RedstonePriceStore.SignerNotAuthorised.selector);
	}

	function test_packagesReplayedUnderAnotherFeed_fail() public {
		RedstoneFixtures.Snapshot memory eth = RedstoneFixtures.ethA();
		_at(eth, 1);
		eth.feedId = bytes32('ARB');
		_expectSelector(_updateCall(eth), RedstonePriceStore.SignerNotAuthorised.selector);
	}

	function test_timestampIsSigned() public {
		RedstoneFixtures.Snapshot memory eth = RedstoneFixtures.ethA();
		_at(eth, 1);
		eth.timestampMs += 10_000; // pretend it is fresher
		_expectSelector(_updateCall(eth), RedstonePriceStore.SignerNotAuthorised.selector);
	}

	function test_oneSignerCountedOnce() public {
		RedstoneFixtures.Snapshot memory amd = RedstoneFixtures.amdA();
		_at(amd, 1);
		RedstoneFixtures.Snapshot memory dup = _firstN(amd, 3);
		dup.values[1] = amd.values[0];
		dup.signatures[1] = amd.signatures[0];
		(bool ok, bytes memory err) = address(store).call(_updateCall(dup));
		assertFalse(ok);
		assertEq(err, abi.encodeWithSelector(RedstonePriceStore.DuplicateSigner.selector, RedstoneFixtures.signers()[0]));
	}

	function test_noRewinding() public {
		RedstoneFixtures.Snapshot memory a = RedstoneFixtures.ethA();
		RedstoneFixtures.Snapshot memory b = RedstoneFixtures.ethB();
		_at(b, 1);
		_push(b);
		(bool ok, bytes memory err) = address(store).call(_updateCall(a)); // older, still < 3 min old
		assertFalse(ok);
		assertEq(err, abi.encodeWithSelector(RedstonePriceStore.NotNewer.selector, bytes32('ETH'), a.timestampMs, b.timestampMs));
		// the same print twice is not "newer" either
		(ok,) = address(store).call(_updateCall(b));
		assertFalse(ok);

		// forward in time is fine: A then B
		RedstoneFixtures.Snapshot memory arbA = RedstoneFixtures.arbA();
		_push(arbA);
		_push(RedstoneFixtures.arbB());
		(uint256 value, uint64 ts) = store.latest(bytes32('ARB'));
		assertEq(value, 21920000);
		assertGt(ts, arbA.timestampMs);
	}

	function test_packageAgeWindow() public {
		RedstoneFixtures.Snapshot memory eth = RedstoneFixtures.ethA();
		_at(eth, 181); // 3 min + 1 s after signing — gateway history is off limits
		(bool ok, bytes memory err) = address(store).call(_updateCall(eth));
		assertFalse(ok);
		assertEq(err, abi.encodeWithSelector(RedstonePriceStore.PackageTooOld.selector, eth.timestampMs));
		_at(eth, 180);
		_push(eth);
	}

	function test_futureWindow() public {
		RedstoneFixtures.Snapshot memory eth = RedstoneFixtures.ethA();
		_at(eth, -61);
		(bool ok, bytes memory err) = address(store).call(_updateCall(eth));
		assertFalse(ok);
		assertEq(err, abi.encodeWithSelector(RedstonePriceStore.PackageFromFuture.selector, eth.timestampMs));
		_at(eth, -60);
		_push(eth);
	}

	function test_adapter_neverPushed_thenStale() public {
		RedstoneAggregatorAdapter adapter = new RedstoneAggregatorAdapter(store, bytes32('AMD'), MAX_PUSH_AGE, 'AMD/USD (RedStone)');
		vm.expectRevert(abi.encodeWithSelector(RedstoneAggregatorAdapter.NeverPushed.selector, bytes32('AMD')));
		adapter.latestRoundData();

		RedstoneFixtures.Snapshot memory amd = RedstoneFixtures.amdA();
		_at(amd, 1);
		_push(amd);
		_at(amd, int256(uint256(MAX_PUSH_AGE)));
		adapter.latestRoundData(); // exactly maxPushAge old — still served
		_at(amd, int256(uint256(MAX_PUSH_AGE)) + 1);
		vm.expectRevert(abi.encodeWithSelector(RedstoneAggregatorAdapter.StaleRedstonePush.selector, amd.timestampMs / 1000));
		adapter.latestRoundData();
	}

	function test_adapter_rejectsZeroArguments() public {
		vm.expectRevert(RedstoneAggregatorAdapter.ZeroArgument.selector);
		new RedstoneAggregatorAdapter(RedstonePriceStore(address(0)), bytes32('ETH'), 1, 'x');
		vm.expectRevert(RedstoneAggregatorAdapter.ZeroArgument.selector);
		new RedstoneAggregatorAdapter(store, bytes32(0), 1, 'x');
		vm.expectRevert(RedstoneAggregatorAdapter.ZeroArgument.selector);
		new RedstoneAggregatorAdapter(store, bytes32('ETH'), 0, 'x');
	}

	// ─── signer-set config ───────────────────────────────────────────────────────

	function test_badSignerConfigs() public {
		address[] memory none = new address[](0);
		vm.expectRevert(RedstonePriceStore.BadSignerConfig.selector);
		new RedstonePriceStore('x', none, 1);

		address[] memory two = new address[](2);
		(two[0], two[1]) = (S0, S1);
		vm.expectRevert(RedstonePriceStore.BadSignerConfig.selector);
		new RedstonePriceStore('x', two, 0);
		vm.expectRevert(RedstonePriceStore.BadSignerConfig.selector);
		new RedstonePriceStore('x', two, 3);

		two[1] = S0;
		vm.expectRevert(RedstonePriceStore.BadSignerConfig.selector);
		new RedstonePriceStore('x', two, 1);
		two[1] = address(0);
		vm.expectRevert(RedstonePriceStore.BadSignerConfig.selector);
		new RedstonePriceStore('x', two, 1);
	}

	/// Even signer counts take the mean of the middle two (RedStone's own aggregation) —
	/// exercised with fresh keys signing the same package layout
	function test_evenCountMedian_withOwnKeys() public {
		uint256[4] memory keys = [uint256(0xA11), 0xB22, 0xC33, 0xD44];
		address[] memory signers = new address[](4);
		for (uint256 i; i < 4; ++i) signers[i] = vm.addr(keys[i]);
		RedstonePriceStore own = new RedstonePriceStore('test', signers, 2);

		vm.warp(1_790_000_000);
		uint64 ts = uint64(block.timestamp) * 1000;
		uint256[] memory values = new uint256[](4);
		bytes[] memory sigs = new bytes[](4);
		uint256[4] memory prices = [uint256(400e8), 100e8, 300e8, 200e8];
		for (uint256 i; i < 4; ++i) {
			values[i] = prices[i];
			bytes32 digest = keccak256(abi.encodePacked(bytes32('XYZ'), prices[i], uint48(ts), uint32(32), uint24(1)));
			(uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], digest);
			sigs[i] = abi.encodePacked(r, s, v);
		}
		own.update(bytes32('XYZ'), ts, values, sigs);
		(uint256 value,) = own.latest(bytes32('XYZ'));
		assertEq(value, 250e8);

		// the primary-prod store refuses these keys
		vm.expectRevert(abi.encodeWithSelector(RedstonePriceStore.SignerNotAuthorised.selector, signers[0]));
		store.update(bytes32('XYZ'), ts, values, sigs);
	}

	// ─── through the ValueInterpreter, via a PriceMarker ─────────────────────────

	function test_priceMarker_valuesAPerpLegThroughTheVi() public {
		address admin = makeAddr('admin');
		RedstoneFixtures.Snapshot memory amd = RedstoneFixtures.amdA();
		_at(amd, 1);
		_push(amd);

		ValueInterpreter interpreter = new ValueInterpreter(admin);
		MockERC20 usdc = new MockERC20('USD Coin', 'USDC', 6);
		PriceMarker amdMarker = new PriceMarker('AMD price marker', 'pmAMD');
		RedstoneAggregatorAdapter adapter = new RedstoneAggregatorAdapter(store, bytes32('AMD'), MAX_PUSH_AGE, 'AMD/USD (RedStone)');
		vm.startPrank(admin);
		interpreter.addPrimitive(address(usdc), address(new MockAggregator(8, 1e8)), 1 days);
		interpreter.addPrimitive(address(amdMarker), address(adapter), 4 hours);
		vm.stopPrank();

		// 2 AMD of perp exposure at $628.51295003 → 1257.02590006 USDC (6 dp, floored)
		assertEq(interpreter.calcCanonicalAssetValue(address(amdMarker), 2e18, address(usdc)), 1257_025900);
		assertEq(amdMarker.totalSupply(), 0);
		assertEq(amdMarker.decimals(), 18);
	}

	function _firstN(RedstoneFixtures.Snapshot memory s, uint256 n) internal pure returns (RedstoneFixtures.Snapshot memory out) {
		out.feedId = s.feedId;
		out.timestampMs = s.timestampMs;
		out.values = new uint256[](n);
		out.signatures = new bytes[](n);
		for (uint256 i; i < n; ++i) {
			out.values[i] = s.values[i];
			out.signatures[i] = s.signatures[i];
		}
	}
}
