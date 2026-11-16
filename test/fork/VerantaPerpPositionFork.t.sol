// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {IExternalPosition} from '../../src/interfaces/IExternalPosition.sol';
import {
	IVerantaTradingRouter,
	IVerantaMulticall,
	IVerantaTradingStorage,
	IVerantaPairCosts
} from '../../src/interfaces/external/IVeranta.sol';
import {VerantaPerpConfig} from '../../src/positions/VerantaPerpConfig.sol';
import {VerantaPerpPosition} from '../../src/positions/VerantaPerpPosition.sol';
import {VerantaPerpPositionFactory} from '../../src/positions/VerantaPerpPositionFactory.sol';
import {BaseMainnet} from '../../script/release/BaseMainnet.sol';
import {ReleaseFork} from './utils/ReleaseFork.sol';
import {IVerantaOperatorRouter} from './utils/IVerantaOperatorRouter.sol';

/// @notice Veranta's coin-sized market open (TradingRouter.openTradeWithCoinExposure, verified source): the
///         order lands in TradingStorage's second pending mapping, which Multicall.getPendingOrder can't decode.
interface IVerantaCoinOpen {
	function openTradeWithCoinExposure(
		IVerantaTradingRouter.Trade calldata trade,
		uint8 orderType,
		uint256 coinExposure,
		uint256 minLeverage,
		uint256 maxLeverage,
		uint256 slippageP
	) external payable returns (uint256 orderId);
}

/// @dev The cost reads exactly as V4's valuation makes them: inside a static (view) call.
contract PairCostsReader {
	function read(IVerantaPairCosts costs, uint256 pairIndex)
		external
		view
		returns (uint256 closeMakerFeeP, uint256 closeTakerFeeP, uint256 spreadP)
	{
		(, closeMakerFeeP,, closeTakerFeeP) = costs.additionalPairParams2(pairIndex);
		(,,,,, spreadP) = costs.pairs(pairIndex);
	}
}

/// @notice VerantaPerpPositionV4 against the LIVE Veranta contracts on a Base fork (spec
///         docs/superpowers/specs/2026-10-08-perp-account-v4-design.md §6), at VerantaPerpPositionV3Fork's
///         pinned block and with its real ETH Lazer packet (Veranta operator tx 0xd18f6433…ba60, ETH
///         $2,685.28631153, published 1790818690). Type 6 is re-pointed to a fresh V4 factory over the
///         live V2 config, as the founder's rollout step does. Veranta's operator doesn't run on a fork, so
///         market orders are filled here the way it fills them (an operator address, the real packet,
///         that tx's spread params and 1 wei Lazer fee).
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/VerantaPerpPositionV4Fork.t.sol -vv
contract VerantaPerpPositionForkTest is ReleaseFork {
	uint256 internal constant PINNED_BLOCK = 52014634;

	address internal constant ROUTER = BaseMainnet.VERANTA_ROUTER;
	address internal constant TRADING_STORAGE = BaseMainnet.VERANTA_STORAGE;
	address internal constant MULTICALL = BaseMainnet.VERANTA_MULTICALL;
	address internal constant PAIR_STORAGE = BaseMainnet.VERANTA_PAIR_STORAGE;
	uint256 internal constant PERP_TYPE = BaseMainnet.VERANTA_PERP_TYPE;
	uint256 internal constant ETH_PAIR = 0;

	address internal constant VERANTA_OPERATOR = 0xe8f6E3281AAa99404003ecA9fb0653d751D4BC92;
	bytes internal constant ETH_LAZER_PACKET =
		hex'2a22999a8d1af8074fe03346a450526acd9efd7255fdd0011ee5b81b35ee7e141394ff1d3ce318786081e862d3f15b5a6cb91e23d116612faecbcd50c0e406ae77f05fae01003293c7d37500065cbd77e90c4003010000000204000000003e858dbd7104fff805000000000924390f0c0100065cbd77e90c40';
	uint256 internal constant ETH_PACKET_TS = 1790818690;
	uint256 internal constant ETH_PACKET_PRICE = 26_852_863_115_300;
	uint8 internal constant PYTH_LAZER = 1;
	uint256 internal constant BTC_PAIR = 1;
	/// @dev cbBTC/USD (Chainlink 0x07DA…9f9D) at the pinned block, $83,542.71493967, at Veranta's 1e10 scale
	uint256 internal constant BTC_PRICE = 835_427_149_396_700;

	VerantaPerpConfig internal perpCfg;
	VerantaPerpPositionFactory internal accountFactory;

	/// @dev The block its real Lazer packet is from.
	function _forkBlock() internal pure override returns (uint256) {
		return PINNED_BLOCK;
	}

	function setUp() public override {
		super.setUp();
		if (!forked) return;
		_copyPairAsset(ETH_PAIR);
		_copyPairAsset(BTC_PAIR);
		perpCfg = r.perpConfig;
		accountFactory = r.perpFactory;
	}

	/// spec §3.3: Veranta's cost rates are plain PairStorage getters and return the live ETH costs.
	function test_fork_closeCostReadsWorkInAStaticCall() public {
		vm.skip(!forked);
		PairCostsReader reader = new PairCostsReader();
		(uint256 makerP, uint256 takerP, uint256 spreadP) = reader.read(IVerantaPairCosts(PAIR_STORAGE), ETH_PAIR);
		assertEq(makerP, 1e8, 'ETH close maker fee 0.01%');
		assertEq(takerP, 4.5e8, 'ETH close taker fee 0.045%');
		assertEq(spreadP, 1e8, 'ETH base spread 0.01%');
	}

	/// spec §3.3 against a real close: V3 read 0.194573 USDC above the payout of a 5× ETH long of
	/// 199.5725 collateral (test_fork_navIsAboveTheRealClosePayoutByTheCloseCosts). V4 deducts the higher of
	/// the close maker and taker rates (0.045%, skew-proof) and the base spread, so NAV sits BELOW the
	/// payout: this close got the maker rate (0.01%), so by (taker − maker) × 997.86 ≈ 0.349. The release links
	/// 'frostydao', which isn't registered yet at this block (codeOwners answers 0), so this close earns no referral
	/// discount: it pays 0.027456 USDC less than V3's measured close, which had one.
	function test_fork_navAfterCloseCostsVsRealClosePayout() public {
		vm.skip(!forked);
		(Comptroller fund, address p) = _fundWithFilledLong(200e6);
		uint256 collateral = _collateral(p);
		int256 value = _valueAt(p, ETH_PACKET_PRICE);
		(bool ok, uint256 payout) = _close(fund, p, collateral);
		assertTrue(ok, 'the operator executed the close');
		assertEq(IVerantaTradingStorage(TRADING_STORAGE).openTradesCount(p, ETH_PAIR), 0, 'fully closed');

		int256 gap = value - int256(payout);
		emit log_named_decimal_int('V4 NAV at the close price', value, 6);
		emit log_named_decimal_uint('close payout', payout, 6);
		emit log_named_decimal_int('NAV minus payout', gap, 6);
		assertLe(value, int256(payout), 'NAV no longer reads above what a close pays');
		assertLt(-gap, 360_000, 'and below it by no more than (taker - maker) (< 0.36 USDC)');
		assertEq(payout, 199_250_695, 'the close, with no referral discount at this block');
	}

	/// spec §4: the manager's AddMargin with Veranta's real signed packet and its 1 wei fee.
	function test_fork_addMarginWithTheRealPacket() public {
		vm.skip(!forked);
		(Comptroller fund, address p) = _fundWithFilledLong(200e6);
		uint256 collateral0 = _collateral(p);
		vm.deal(p, 1);

		uint256 snap = vm.snapshotState();
		vm.warp(ETH_PACKET_TS + 29);
		assertTrue(_addMargin(fund, p, 50e6), '29 s old: deposits');
		assertEq(_collateral(p), collateral0 + 50e6, 'collateral +50 USDC');
		assertEq(IERC20(USDC).balanceOf(p), 0, 'all of it from the vault, through the account');
		assertEq(p.balance, 0, 'the 1 wei fee paid from the account');
		vm.revertToState(snap);

		vm.warp(ETH_PACKET_TS + 30);
		assertFalse(_addMargin(fund, p, 50e6), '30 s old: Veranta refuses it');
		assertEq(_collateral(p), collateral0);
	}

	/// spec §1 item 1: list mode reads one pair; a keeper delegation switches to the V3-style full walk.
	/// Each mode is measured warm (after one warm-up call, so neither number carries the other's first
	/// touches) and cooled (vm.cool on the account and Veranta's proxies, closer to a real transaction).
	function test_fork_listModeGasVsFullWalk() public {
		vm.skip(!forked);
		(Comptroller fund, address p) = _fundWithFilledLong(200e6);
		_act(fund, p, abi.encode(uint8(VerantaPerpPosition.Action.SetAutopilot), abi.encode(block.timestamp + 30 days)));
		uint256 fullCooled = _cooledValuationGas(p);
		_valuationGas(p);
		uint256 fullWarm = _valuationGas(p);
		_act(fund, p, abi.encode(uint8(VerantaPerpPosition.Action.RemoveAutopilot), bytes('')));
		uint256 listCooled = _cooledValuationGas(p);
		_valuationGas(p);
		uint256 listWarm = _valuationGas(p);
		emit log_named_uint('pairs on Veranta', IVerantaPairCountLive(PAIR_STORAGE).pairsCount());
		emit log_named_uint('getManagedAssets gas, full walk (keeper delegated), cooled', fullCooled);
		emit log_named_uint('getManagedAssets gas, full walk (keeper delegated), warm', fullWarm);
		emit log_named_uint('getManagedAssets gas, list mode (1 held pair), cooled', listCooled);
		emit log_named_uint('getManagedAssets gas, list mode (1 held pair), warm', listWarm);
		// measured 2026-10-08 at 174 pairs: full walk 1,836,012 cooled / 986,051 warm; list mode with one held
		// pair 347,366 / 187,407 — most of which is valuing the trade itself, which both modes pay
		assertLt(listWarm * 5, fullWarm, 'list mode costs under a fifth of the full walk');
		assertLt(listCooled * 5, fullCooled);
	}

	/// spec §3.1: a trade the keeper opens through Veranta's delegation (the account never sees it) is
	/// valued by the full walk, and RemoveAutopilot's sync lists it so list mode keeps valuing it.
	function test_fork_keeperOpenCountedThenSynced() public {
		vm.skip(!forked);
		Comptroller fund = _fund('V4 keeper');
		address p = _create(fund);
		address[] memory assets = new address[](1);
		assets[0] = USDC;
		uint256[] memory amounts = new uint256[](1);
		amounts[0] = 100e6;
		vm.prank(manager);
		fund.callOnExternalPosition(
			p, assets, amounts, new address[](0),
			abi.encode(uint8(VerantaPerpPosition.Action.SetAutopilot), abi.encode(block.timestamp + 30 days))
		);
		address keeper = perpCfg.autopilotKeeper();
		bytes memory openCall = abi.encodeCall(
			IVerantaTradingRouter.openTrade,
			(
				IVerantaTradingRouter.Trade({
					trader: p, pairIndex: ETH_PAIR, index: 0, initialPosToken: 0, positionSizeUSDC: 100e6,
					openPrice: ETH_PACKET_PRICE, buy: false, leverage: 5e10, tp: 0, sl: 0, timestamp: 0
				}),
				0,
				1e10
			)
		);
		vm.prank(keeper);
		(bool ok,) = ROUTER.call(abi.encodeWithSignature('delegatedAction(address,bytes)', p, openCall));
		assertTrue(ok, 'the keeper opened a short through its delegation');
		vm.roll(block.number + (ETH_PACKET_TS + 2 - block.timestamp) / 2);
		vm.warp(ETH_PACKET_TS + 2);
		_fill(p);
		assertEq(VerantaPerpPosition(payable(p)).heldPairs().length, 0, 'the account never saw it');
		int256 delegatedValue = _valueAt(p, ETH_PACKET_PRICE);
		assertGt(delegatedValue, 99e6, 'the full walk values the keeper trade');

		vm.prank(manager);
		fund.callOnExternalPosition(
			p, new address[](0), new uint256[](0), new address[](0),
			abi.encode(uint8(VerantaPerpPosition.Action.RemoveAutopilot), bytes(''))
		);
		uint256[] memory held = VerantaPerpPosition(payable(p)).heldPairs();
		assertEq(held.length, 1);
		assertEq(held[0], ETH_PAIR, 'synced into the list');
		assertEq(_valueAt(p, ETH_PACKET_PRICE), delegatedValue, 'list mode values it the same');
	}

	/// Final review 2026-10-08 (Important 1): a keeper's coin-sized market open sits in TradingStorage's
	/// second pending mapping, which Multicall.getPendingOrder returns zeroed (trader 0, pair 0, size 0). Its
	/// escrow must still count, and RemoveAutopilot's sync must list ITS pair, or the fill drops out of
	/// list-mode NAV.
	function test_fork_keeperCoinExposureOpen_escrowCountedAndPairSynced() public {
		vm.skip(!forked);
		Comptroller fund = _fund('V4 coin open');
		address p = _create(fund);
		address[] memory assets = new address[](1);
		assets[0] = USDC;
		uint256[] memory amounts = new uint256[](1);
		amounts[0] = 100e6;
		_actFunded(fund, p, assets, amounts, abi.encode(uint8(VerantaPerpPosition.Action.SetAutopilot), abi.encode(block.timestamp + 30 days)));
		// $500 of BTC (100 USDC at 5×), sized in coin
		uint256 coinExposure = (500e6 * 1e10 * 1e10) / BTC_PRICE / 1e6;
		bytes memory openCall = abi.encodeCall(
			IVerantaCoinOpen.openTradeWithCoinExposure,
			(
				IVerantaTradingRouter.Trade({
					trader: p, pairIndex: BTC_PAIR, index: 0, initialPosToken: 0, positionSizeUSDC: 100e6,
					openPrice: BTC_PRICE, buy: false, leverage: 5e10, tp: 0, sl: 0, timestamp: 0
				}),
				uint8(0),
				coinExposure,
				2e10,
				10e10,
				1e10
			)
		);
		vm.prank(perpCfg.autopilotKeeper());
		(bool ok, bytes memory ret) = ROUTER.call(abi.encodeWithSignature('delegatedAction(address,bytes)', p, openCall));
		if (!ok) emit log_named_bytes('coin open revert', ret);
		assertTrue(ok, 'the keeper placed a coin-sized open');
		assertEq(IERC20(USDC).balanceOf(p), 0, 'escrowed with Veranta');
		assertEq(_valueAt(p, ETH_PACKET_PRICE), 100e6, 'the escrow counts while the order is pending');

		_act(fund, p, abi.encode(uint8(VerantaPerpPosition.Action.RemoveAutopilot), bytes('')));
		uint256[] memory held = VerantaPerpPosition(payable(p)).heldPairs();
		assertEq(held.length, 1);
		assertEq(held[0], BTC_PAIR, 'the sync lists the order\'s own pair');
		assertEq(_valueAt(p, ETH_PACKET_PRICE), 100e6, 'and list mode still counts the escrow');
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	function _actFunded(Comptroller fund, address p, address[] memory assets, uint256[] memory amounts, bytes memory data) internal {
		vm.prank(manager);
		fund.callOnExternalPosition(p, assets, amounts, new address[](0), data);
	}

	function _fundWithFilledLong(uint256 collateral) internal returns (Comptroller fund, address p) {
		fund = _fund('V4 fork');
		p = _create(fund);
		assertEq(address(VerantaPerpPosition(payable(p)).perpConfig()), address(perpCfg), 'a V4 account');
		address[] memory assets = new address[](1);
		assets[0] = USDC;
		uint256[] memory amounts = new uint256[](1);
		amounts[0] = collateral;
		bytes memory open = abi.encode(
			uint8(VerantaPerpPosition.Action.OpenTrade),
			abi.encode(ETH_PAIR, collateral, uint256(5e10), true, ETH_PACKET_PRICE, uint256(1e10), uint8(0), uint256(0), uint256(0))
		);
		vm.prank(manager);
		fund.callOnExternalPosition(p, assets, amounts, new address[](0), open);
		vm.roll(block.number + (ETH_PACKET_TS + 2 - block.timestamp) / 2);
		vm.warp(ETH_PACKET_TS + 2);
		_fill(p);
	}

	function _addMargin(Comptroller fund, address p, uint256 amount) internal returns (bool ok) {
		address[] memory assets = new address[](1);
		assets[0] = USDC;
		uint256[] memory amounts = new uint256[](1);
		amounts[0] = amount;
		bytes[] memory update = new bytes[](1);
		update[0] = ETH_LAZER_PACKET;
		bytes memory data = abi.encode(
			uint8(VerantaPerpPosition.Action.AddMargin), abi.encode(ETH_PAIR, uint256(0), amount, update, PYTH_LAZER, uint256(1))
		);
		vm.prank(manager);
		(ok,) = address(fund).call(
			abi.encodeCall(Comptroller.callOnExternalPosition, (p, assets, amounts, new address[](0), data))
		);
	}

	function _act(Comptroller fund, address p, bytes memory data) internal {
		vm.prank(manager);
		fund.callOnExternalPosition(p, new address[](0), new uint256[](0), new address[](0), data);
	}

	function _cooledValuationGas(address p) internal returns (uint256) {
		vm.cool(p);
		vm.cool(TRADING_STORAGE);
		vm.cool(MULTICALL);
		vm.cool(PAIR_STORAGE);
		vm.cool(address(perpCfg));
		vm.cool(USDC);
		vm.cool(WETH);
		return _valuationGas(p);
	}

	function _valuationGas(address p) internal returns (uint256 used) {
		uint256 before = gasleft();
		IExternalPosition(p).getManagedAssets();
		used = before - gasleft();
	}

	/// @dev The account as NAV counts it, with its WETH leg at `price` (1e10) instead of the VI's.
	function _valueAt(address position, uint256 price) internal returns (int256 value) {
		(address[] memory m, uint256[] memory ma) = IExternalPosition(position).getManagedAssets();
		(address[] memory d, uint256[] memory da) = IExternalPosition(position).getDebtAssets();
		for (uint256 i; i < m.length; ++i) {
			if (m[i] == USDC) value += int256(ma[i]);
			else if (m[i] == WETH) value += int256(ma[i] * price / 1e10 / 1e12);
		}
		for (uint256 i; i < d.length; ++i) {
			if (d[i] == USDC) value -= int256(da[i]);
			else if (d[i] == WETH) value -= int256(da[i] * price / 1e10 / 1e12);
		}
	}

	/// @dev Close `amount` of the account's ETH trade through the fund, then fill it as Veranta's operator
	///      does, at the real packet; returns the USDC the close paid the account.
	function _close(Comptroller fund, address position, uint256 amount) internal returns (bool ok, uint256 payout) {
		uint256 usdc0 = IERC20(USDC).balanceOf(position);
		bytes memory close = abi.encode(
			uint8(VerantaPerpPosition.Action.CloseTrade), abi.encode(ETH_PAIR, uint256(0), amount, ETH_PACKET_PRICE)
		);
		vm.prank(manager);
		fund.callOnExternalPosition(position, new address[](0), new uint256[](0), new address[](0), close);
		IVerantaMulticall.PendingOrder[] memory pending = IVerantaMulticall(MULTICALL).getPendingOrder(position);
		if (pending.length == 0) return (false, 0);
		vm.deal(VERANTA_OPERATOR, 1 ether);
		vm.prank(VERANTA_OPERATOR);
		bytes memory ret;
		(ok, ret) = ROUTER.call{value: 1}(
			abi.encodeCall(IVerantaOperatorRouter.executeMarketOrder, (pending[0].orderId, _packet(), PYTH_LAZER, _spread()))
		);
		if (!ok) emit log_named_bytes('close revert', ret);
		payout = IERC20(USDC).balanceOf(position) - usdc0;
	}

	/// @dev Fill the account's one pending market open the way Veranta's operator does.
	function _fill(address position) internal {
		IVerantaMulticall.PendingOrder[] memory pending = IVerantaMulticall(MULTICALL).getPendingOrder(position);
		assertEq(pending.length, 1);
		vm.deal(VERANTA_OPERATOR, 1 ether);
		vm.prank(VERANTA_OPERATOR);
		IVerantaOperatorRouter(ROUTER).executeMarketOrder{value: 1}(pending[0].orderId, _packet(), PYTH_LAZER, _spread());
		assertEq(IVerantaMulticall(MULTICALL).getPendingOrder(position).length, 0, 'filled');
		assertEq(IVerantaTradingStorage(TRADING_STORAGE).openTradesCount(position, ETH_PAIR), 1, 'a stored trade');
	}

	function _packet() internal pure returns (bytes[] memory update) {
		update = new bytes[](1);
		update[0] = ETH_LAZER_PACKET;
	}

	/// @dev The spread params of Veranta's real open tx (0xd18f6433…ba60).
	function _spread() internal pure returns (IVerantaOperatorRouter.OffChainSpreadParams memory) {
		return IVerantaOperatorRouter.OffChainSpreadParams({
			spreadP: 1e8, bookDepth: 0, impactParam: 0, byPass: true, maxSpreadP: 0, slot1: false, slot3: 0
		});
	}

	function _collateral(address position) internal view returns (uint256) {
		return IVerantaTradingStorage(TRADING_STORAGE).openTrades(position, ETH_PAIR, 0).initialPosToken;
	}

	/// @dev A fresh non-degen USDC fund on the release with 10,000 USDC deposited.
	function _fund(string memory) internal returns (Comptroller fund) {
		fund = _fundWithDeposit(10_000e6);
	}

	function _create(Comptroller fund) internal returns (address position) {
		vm.prank(manager);
		position = fund.createExternalPosition(PERP_TYPE, '');
	}
}

interface IVerantaPairCountLive {
	function pairsCount() external view returns (uint256);
}
