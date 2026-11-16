// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {IVerantaMulticall, IVerantaTradingStorage} from '../../src/interfaces/external/IVeranta.sol';
import {VerantaPerpPosition} from '../../src/positions/VerantaPerpPosition.sol';
import {VerantaPriceStore} from '../../src/pricing/VerantaPriceStore.sol';
import {RedemptionQueue} from '../../src/redemption/RedemptionQueue.sol';
import {AggregatorV3Interface} from '../../src/interfaces/AggregatorV3Interface.sol';
import {BaseMainnet} from '../../script/release/BaseMainnet.sol';
import {ReleaseFork} from './utils/ReleaseFork.sol';
import {IVerantaOperatorRouter} from './utils/IVerantaOperatorRouter.sol';

/// @notice A short perp on a closed market holds a fund v6's redemption queue on live Base (founder 2026-11-14: the YAFT
///         weekend test can't be set up while every stock perp market is shut, and Veranta refuses to fill an order on a
///         closed market's packet: StaleFeedUpdateTimestamp). The release on Base, its queue and price store (holding the
///         price the live store held at the block), pair 105's marker priced as the live VI prices closing markets, and
///         Veranta. Two real SPCX (pair 105) packets:
///         - Monday 2026-11-09 13:55:39 UTC, market open: the keeper stored it (tx 0xdf938f4e…046f, block 55,210,883). A
///           new fund opens a short and Veranta's operator fills it with this packet.
///         - Sunday 2026-11-15 00:30:19 UTC, market closed: Veranta's feed answer (feed-v3.veranta.xyz
///           /v2/pairs/105/price-update-data), signed then and carrying Friday's last trade. The keeper's store takes it.
///         The queue then refuses to settle; once the store holds a fresh trade (Monday's first, written here), it pays.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/ShortPerpClosedMarketFork.t.sol -vv
contract ShortPerpClosedMarketForkTest is ReleaseFork {
	address internal constant ROUTER = BaseMainnet.VERANTA_ROUTER;
	address internal constant MULTICALL = BaseMainnet.VERANTA_MULTICALL;
	address internal constant TRADING_STORAGE = BaseMainnet.VERANTA_STORAGE;
	uint256 internal constant PERP_TYPE = BaseMainnet.VERANTA_PERP_TYPE;
	address internal constant VERANTA_OPERATOR = 0xe8f6E3281AAa99404003ecA9fb0653d751D4BC92;
	uint256 internal constant PAIR = 105; // SPCX
	uint256 internal constant SESSION_AGE = 4 hours; // FundValuation.MAX_SESSION_PRICE_AGE

	bytes internal constant OPEN_PACKET =
		hex'2a22999a08b7fc9c4d4b485087b6188aec46db72e74cce693f4be09c37c0fb64ec233d7e220aff82a463bd7f379f727421e2ec98c5d18bd38748c766523bb61c9cfe8d7301003293c7d37500065fd8512f6860020100000cf204000000000000d1448904fffb0500000000000011d90c0100065fd8512f6860';
	uint256 internal constant OPEN_TS = 1_794_232_539;
	uint256 internal constant OPEN_PRICE = 1_371_456_900_000; // $137.14569 at 1e10

	bytes internal constant WEEKEND_PACKET =
		hex'2a22999aea3385c46e02a97924365ba1bd6add52d5ba87973eae43706a14634a9d8ea5f344448a010f56d22845b135dadc69c9d720221222372a5548362828686ecb0dd800003293c7d37500066045c41a93f0020100000cf204000000000000cfe91604fffb05000000000000026e0c0100066032106500b0';
	uint256 internal constant WEEKEND_TS = 1_794_702_619;

	VerantaPriceStore internal store;

	/// @dev 2026-11-09 13:54:00 UTC.
	function _forkBlock() internal pure override returns (uint256) {
		return 55_210_325;
	}

	function setUp() public override {
		super.setUp();
		if (!forked) return;
		store = r.verantaStore;
		_listClosingMarketPair(PAIR);
		_copyStoredPrice(PAIR);
	}

	function test_fork_aShortOnAClosedMarketHoldsTheQueue_untilATradeIsStored() public {
		vm.skip(!forked);
		(Comptroller fund, address account) = _fundWithFilledShort(1_000e6, 800e6); // vault 200, short 800
		RedemptionQueue queue = RedemptionQueue(address(fund.redemptionQueue()));

		// the weekend: the keeper stores Sunday's packet, whose last trade is Friday's
		_advanceTo(WEEKEND_TS + 2);
		_restamp(fund, USDC);
		vm.deal(address(this), 1 ether);
		assertTrue(store.submit{value: 0.01 ether}(PAIR, WEEKEND_PACKET), 'the weekend packet is stored');
		assertLt(store.feedUpdatedUs(PAIR) / 1e6 + SESSION_AGE, block.timestamp, 'last trade over 4 hours old');
		assertGt(store.feedUpdatedUs(PAIR) / 1e6, OPEN_TS, "Friday's trade, after Monday's");
		uint256 gav = fund.calcGav();
		assertApproxEqRel(gav, 1_000e6, 0.05e18, 'the fund stays priced');

		uint256 shares = fund.shares().balanceOf(investor) / 10; // about $100: the vault's $200 covers it
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(address(queue), shares);
		uint256 id = queue.requestRedeem(address(fund), shares);
		vm.stopPrank();

		vm.prank(manager);
		vm.expectRevert(RedemptionQueue.PriceUnreadable.selector);
		queue.settle(address(fund), 1);
		assertTrue(queue.requestAt(address(fund), id).open, 'waits for the market');

		// Monday's first trade reaches the store: the same price, a last trade of now
		_storeFreshTrade();
		uint256 owed = Math.mulDiv(fund.calcGav(), shares, fund.shares().totalSupply());
		vm.prank(manager);
		queue.settle(address(fund), 1);
		assertFalse(queue.requestAt(address(fund), id).open, 'paid');
		assertApproxEqRel(IERC20(USDC).balanceOf(investor), owed, 0.001e18, 'its share in USDC');
		assertGt(_collateral(account), 0, 'the short stays open');
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	function _fundWithFilledShort(uint256 deposit, uint256 collateral) internal returns (Comptroller fund, address account) {
		fund = _fundWithDeposit(deposit);

		vm.prank(manager);
		account = fund.createExternalPosition(PERP_TYPE, '');
		_advanceTo(OPEN_TS - 20);
		address[] memory assets = new address[](1);
		assets[0] = USDC;
		uint256[] memory amounts = new uint256[](1);
		amounts[0] = collateral;
		bytes memory open = abi.encode(
			uint8(VerantaPerpPosition.Action.OpenTrade),
			abi.encode(PAIR, collateral, uint256(5e10), false, OPEN_PRICE, uint256(1e10), uint8(0), uint256(0), uint256(0))
		);
		vm.prank(manager);
		fund.callOnExternalPosition(account, assets, amounts, new address[](0), open);
		_advanceTo(OPEN_TS + 2);
		_fillPending(account);
		assertFalse(IVerantaTradingStorage(TRADING_STORAGE).openTrades(account, PAIR, 0).buy, 'a short');
		assertGt(_collateral(account), 0, 'filled');
	}

	/// @dev Base blocks are 0.2 s apart since 2026-11-05.
	function _advanceTo(uint256 timestamp) internal {
		vm.roll(block.number + (timestamp - block.timestamp) * 5);
		vm.warp(timestamp);
	}

	function _fillPending(address account) internal {
		IVerantaMulticall.PendingOrder[] memory pending = IVerantaMulticall(MULTICALL).getPendingOrder(account);
		require(pending.length == 1, 'one pending order');
		bytes[] memory update = new bytes[](1);
		update[0] = OPEN_PACKET;
		vm.deal(VERANTA_OPERATOR, 1 ether);
		vm.prank(VERANTA_OPERATOR);
		IVerantaOperatorRouter(ROUTER).executeMarketOrder{value: 1}(
			pending[0].orderId,
			update,
			1,
			IVerantaOperatorRouter.OffChainSpreadParams({
				spreadP: 1e8, bookDepth: 0, impactParam: 0, byPass: true, maxSpreadP: 0, slot1: false, slot3: 0
			})
		);
		assertEq(IVerantaMulticall(MULTICALL).getPendingOrder(account).length, 0, 'filled');
	}

	/// @dev `asset`'s VI feed answers its last real report again, stamped now (5.4 days skipped on the fork; the real
	///      feed kept reporting). GovernanceHandoffFork's pattern.
	function _restamp(Comptroller fund, address asset) internal {
		(address feed,,,) = fund.valueInterpreter().getAssetInfo(asset);
		(uint80 round, int256 answer,,, uint80 answeredIn) = AggregatorV3Interface(feed).latestRoundData();
		vm.mockCall(
			feed,
			abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
			abi.encode(round, answer, block.timestamp, block.timestamp, answeredIn)
		);
	}

	/// @dev The store's word for a pair (slot 0 mapping): price bits 0-63, exponent 64-79, confirmed 80-143, last trade
	///      144-207, all times in microseconds (MoveClosingMarketsFork's layout). Keeps the price, moves both times to now.
	function _storeFreshTrade() internal {
		bytes32 slot = keccak256(abi.encode(PAIR, uint256(0)));
		uint256 word = uint256(vm.load(address(store), slot));
		uint256 nowUs = block.timestamp * 1e6;
		word = (word & ((1 << 80) - 1)) | (nowUs << 80) | (nowUs << 144);
		vm.store(address(store), slot, bytes32(word));
		assertEq(store.feedUpdatedUs(PAIR), nowUs, 'a trade of now');
	}

	function _collateral(address account) internal view returns (uint256) {
		return IVerantaTradingStorage(TRADING_STORAGE).openTrades(account, PAIR, 0).initialPosToken;
	}
}
