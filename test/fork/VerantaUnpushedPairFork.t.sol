// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerV2} from '../../src/core/ComptrollerV2.sol';
import {IVerantaMulticall, IVerantaTradingStorage} from '../../src/interfaces/external/IVeranta.sol';
import {VerantaPerpPositionV3} from '../../src/positions/VerantaPerpPositionV3.sol';
import {VerantaPriceStore} from '../../src/pricing/VerantaPriceStore.sol';
import {VerantaPriceAdapter} from '../../src/pricing/VerantaPriceAdapter.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';

interface IVerantaOperator {
	struct OffChainSpreadParams {
		int256 spreadP;
		uint256 bookDepth;
		int256 impactParam;
		bool byPass;
		int256 maxSpreadP;
		bool slot1;
		int256 slot3;
	}

	function executeMarketOrder(
		uint256 orderId,
		bytes[] calldata priceUpdateData,
		uint8 priceSourcing,
		OffChainSpreadParams calldata spreadParams
	) external payable;
}

/// @notice A fund perp on a pair whose price was never pushed (perps review 2026-10-05, must-fix 3), on
///         a fork of Base 4 minutes before Veranta funding tx 0xfb9b4003…c8145 (block 52230444). That tx
///         carries a REAL signed Pyth Lazer packet for pair 129 (Lazer feed 1373, $73.06, published
///         1791250232.8): the fill below uses it the way Veranta's operator does, and the push uses
///         the same packet through the price store's permissionless `submit` (1 wei Lazer fee). Facts
///         read with `cast` at the pinned block: pair 129's marker 0x706C…E8Ac is supported by the VI and
///         its store price was never set (valuing it reverts NeverPushed(129)); type 6 is the V3
///         factory; 0xe8f6…C92 is a Veranta operator; new funds are ComptrollerV2.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/VerantaUnpushedPairFork.t.sol -vv
contract VerantaUnpushedPairForkTest is Test {
	string internal constant GENESIS_FILE = 'deployments/base-mainnet.json';
	uint256 internal constant FORK_BLOCK = 52_230_324;

	address internal constant USDC = FundsMainnet.USDC;
	address internal constant ROUTER = FundsMainnet.VERANTA_ROUTER;
	address internal constant MULTICALL = FundsMainnet.VERANTA_MULTICALL;
	address internal constant TRADING_STORAGE = FundsMainnet.VERANTA_STORAGE;
	uint256 internal constant PERP_TYPE = FundsMainnet.VERANTA_PERP_TYPE;
	VerantaPriceStore internal constant STORE = VerantaPriceStore(0xc65AC79F0D3be202F85765B8c0B7a055FA02C6a6);
	address internal constant VERANTA_OPERATOR = 0xe8f6E3281AAa99404003ecA9fb0653d751D4BC92;

	uint256 internal constant PAIR = 129;
	/// @dev pair 129's packet in funding tx 0xfb9b400386be2250e1901a392f29c7c03d8a37a970147e49d03c38eb78dc8145
	bytes internal constant PACKET =
		hex'2a22999aaf1341602a82157b55c523c737d5e5c4d90e619723a8b66395d136e675b6fd7745d0405770a1894b06ce2afceddf0260e82a3ccc7335d277767ae78e208578ad00003293c7d37500065d21f1d4730003010000055d040000000000006f7b100500000000000007d004fffb0c0100065d21f1d47300';
	uint256 internal constant PACKET_TS = 1_791_250_232;
	/// @dev 7306000 × 1e-5 = $73.06, at Veranta's 1e10 price scale
	uint256 internal constant PACKET_PRICE = 730_600_000_000;
	uint8 internal constant PYTH_LAZER = 1;

	bool internal forked;
	FundFactory internal factory;
	address internal manager = makeAddr('manager');
	address internal investor = makeAddr('investor');

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, FORK_BLOCK);
		forked = true;
		factory = FundFactory(vm.parseJsonAddress(vm.readFile(GENESIS_FILE), '.factory'));
	}

	/// Until the pair is pushed, NAV can't be computed: deposits can't execute and cash redemptions
	/// can't price, while in kind still pays the vault's assets and leaves the perp's value in the
	/// fund. One push of the pair's signed packet — permissionless, 1 wei — values it again.
	function test_fork_aFilledNeverPushedPairFreezesNavUntilPushed() public {
		vm.skip(!forked);
		(ComptrollerV2 fund, address account) = _fundWithPendingOpen();
		_fill(account);
		assertEq(IVerantaTradingStorage(TRADING_STORAGE).openTradesCount(account, PAIR), 1, 'a stored trade');
		(,, uint64 storedAt) = STORE.latest(PAIR);
		assertEq(storedAt, 0, 'pair 129 never pushed');

		vm.expectRevert(abi.encodeWithSelector(VerantaPriceAdapter.NeverPushed.selector, PAIR));
		fund.calcGrossShareValue();

		// a new deposit escrows fine but can't execute; a cash redemption can't price
		address late = makeAddr('late');
		deal(USDC, late, 1_000e6);
		vm.startPrank(late);
		IERC20(USDC).approve(address(fund), 1_000e6);
		fund.requestDeposit(1_000e6, type(uint256).max);
		vm.stopPrank();
		vm.warp(block.timestamp + 1 minutes);
		vm.expectRevert(abi.encodeWithSelector(VerantaPriceAdapter.NeverPushed.selector, PAIR));
		fund.executeDepositRequest(late);
		uint256 shares = IERC20(address(fund.shares())).balanceOf(investor);
		vm.prank(investor);
		vm.expectRevert(abi.encodeWithSelector(VerantaPriceAdapter.NeverPushed.selector, PAIR));
		fund.redeemShares(shares / 10);

		// in kind works, but the perp's 200 USDC of collateral stays behind
		uint256 snap = vm.snapshotState();
		uint256 usdc0 = IERC20(USDC).balanceOf(investor);
		vm.prank(investor);
		fund.redeemSharesInKind(shares / 10);
		uint256 paid = IERC20(USDC).balanceOf(investor) - usdc0;
		assertApproxEqAbs(paid, (10_000e6 - 200e6) / 10, 1e6, 'a tenth of the vault USDC only');
		vm.revertToState(snap);

		// anyone pushes the pair's signed packet: NAV prices the perp again
		vm.deal(address(this), 1 ether);
		assertTrue(STORE.submit{value: 1}(PAIR, PACKET));
		uint256 sharePrice = fund.calcGrossShareValue();
		// ≈ 1 USDC: the perp counts at its collateral less the open fee and the fill's spread
		assertApproxEqRel(sharePrice, 1e6, 0.002e18);
		fund.executeDepositRequest(late);
		emit log_named_decimal_uint('share price once pushed', sharePrice, 6);
	}

	/// What the keeper does since 2026-10-05 (funds-keeper verantaOrderLegs): it pushes every pair a
	/// fund has a pending or resting order on, so the fill finds a price and NAV never stops.
	function test_fork_pushingWhileTheOrderIsPendingLeavesNoGap() public {
		vm.skip(!forked);
		(ComptrollerV2 fund, address account) = _fundWithPendingOpen();
		vm.deal(address(this), 1 ether);
		assertTrue(STORE.submit{value: 1}(PAIR, PACKET));
		_fill(account);
		assertApproxEqRel(fund.calcGrossShareValue(), 1e6, 0.002e18);
	}

	/// @dev A ComptrollerV2 fund with 10,000 USDC in, a V3 perp account, and a pending 5× long market
	///      open on pair 129 (200 USDC) placed 20 s before the packet; time then moves to 2 s after it.
	function _fundWithPendingOpen() internal returns (ComptrollerV2 fund, address account) {
		fund = ComptrollerV2(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Unpushed pair',
					symbol: 'frUP',
					denominationAsset: IERC20(USDC),
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
		assertTrue(address(fund.registrar()) != address(0), 'new funds are v2');
		deal(USDC, investor, 10_000e6);
		vm.startPrank(investor);
		IERC20(USDC).approve(address(fund), 10_000e6);
		fund.requestDeposit(10_000e6, type(uint256).max);
		vm.stopPrank();
		vm.warp(block.timestamp + 1 minutes);
		vm.roll(block.number + 30);
		fund.executeDepositRequest(investor);

		vm.prank(manager);
		account = fund.createExternalPosition(PERP_TYPE, '');
		// open 20 s before the packet: Veranta expires a market open that waits too long (OrderExpired)
		vm.roll(block.number + (PACKET_TS - 20 - block.timestamp) / 2);
		vm.warp(PACKET_TS - 20);
		address[] memory assets = new address[](1);
		assets[0] = USDC;
		uint256[] memory amounts = new uint256[](1);
		amounts[0] = 200e6;
		bytes memory open = abi.encode(
			uint8(VerantaPerpPositionV3.Action.OpenTrade),
			abi.encode(PAIR, uint256(200e6), uint256(5e10), true, PACKET_PRICE, uint256(1e10), uint8(0), uint256(0), uint256(0))
		);
		vm.prank(manager);
		fund.callOnExternalPosition(account, assets, amounts, new address[](0), open);
		assertEq(IVerantaMulticall(MULTICALL).getPendingOrder(account).length, 1, 'a pending open');
		vm.roll(block.number + (PACKET_TS + 2 - block.timestamp) / 2);
		vm.warp(PACKET_TS + 2);
	}

	/// @dev Fill the account's pending open the way Veranta's operator does, at the real packet.
	function _fill(address account) internal {
		IVerantaMulticall.PendingOrder[] memory pending = IVerantaMulticall(MULTICALL).getPendingOrder(account);
		bytes[] memory update = new bytes[](1);
		update[0] = PACKET;
		vm.deal(VERANTA_OPERATOR, 1 ether);
		vm.prank(VERANTA_OPERATOR);
		IVerantaOperator(ROUTER).executeMarketOrder{value: 1}(
			pending[0].orderId,
			update,
			PYTH_LAZER,
			IVerantaOperator.OffChainSpreadParams({
				spreadP: 1e8, bookDepth: 0, impactParam: 0, byPass: true, maxSpreadP: 0, slot1: false, slot3: 0
			})
		);
		assertEq(IVerantaMulticall(MULTICALL).getPendingOrder(account).length, 0, 'filled');
	}
}
