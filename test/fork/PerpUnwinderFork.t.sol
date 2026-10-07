// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {ComptrollerV3} from '../../src/core/ComptrollerV3.sol';
import {IVerantaMulticall, IVerantaTradingStorage, IVerantaTradingRouter} from '../../src/interfaces/external/IVeranta.sol';
import {VerantaPerpPositionV3} from '../../src/positions/VerantaPerpPositionV3.sol';
import {VerantaPriceStore} from '../../src/pricing/VerantaPriceStore.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {RedemptionQueue} from '../../src/redemption/RedemptionQueue.sol';
import {PerpUnwinder} from '../../src/redemption/PerpUnwinder.sol';
import {RedemptionQueueShortDeadline} from '../utils/RedemptionQueueShortDeadline.sol';

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

/// @notice PerpUnwinder against real Veranta on a Base fork (spec 2026-10-06 §3.3, §6), at the block and
///         pair-129 Lazer packet of VerantaUnpushedPairFork (funding tx 0xfb9b4003…c8145, $73.06,
///         published 1791250232): a real V3 fund holding a real filled trade, unwound by the queue
///         and filled by Veranta's operator. The queue here has a 1-second deadline (test-only
///         subclass) so the whole fallback fits in the seconds the packet stays fresh.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/PerpUnwinderFork.t.sol -vv
contract PerpUnwinderForkTest is Test {
	uint256 internal constant FORK_BLOCK = 52_230_324;
	address internal constant USDC = FundsMainnet.USDC;
	address internal constant ROUTER = FundsMainnet.VERANTA_ROUTER;
	address internal constant MULTICALL = FundsMainnet.VERANTA_MULTICALL;
	address internal constant TRADING_STORAGE = FundsMainnet.VERANTA_STORAGE;
	address internal constant PAIR_STORAGE = FundsMainnet.VERANTA_PAIR_STORAGE;
	uint256 internal constant PERP_TYPE = FundsMainnet.VERANTA_PERP_TYPE;
	VerantaPriceStore internal constant STORE = VerantaPriceStore(0xc65AC79F0D3be202F85765B8c0B7a055FA02C6a6);
	address internal constant VERANTA_OPERATOR = 0xe8f6E3281AAa99404003ecA9fb0653d751D4BC92;
	uint256 internal constant PAIR = 129;
	bytes internal constant PACKET =
		hex'2a22999aaf1341602a82157b55c523c737d5e5c4d90e619723a8b66395d136e675b6fd7745d0405770a1894b06ce2afceddf0260e82a3ccc7335d277767ae78e208578ad00003293c7d37500065d21f1d4730003010000055d040000000000006f7b100500000000000007d004fffb0c0100065d21f1d47300';
	uint256 internal constant PACKET_TS = 1_791_250_232;
	uint256 internal constant PACKET_PRICE = 730_600_000_000; // $73.06 at 1e10

	bool internal forked;
	FundFactory internal factory;
	address internal perpConfig;
	RedemptionQueue internal queue;
	PerpUnwinder internal unwinder;
	address internal manager = makeAddr('manager');
	address internal investor = makeAddr('investor');
	address internal guardian;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, FORK_BLOCK);
		forked = true;
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		perpConfig = vm.parseJsonAddress(genesis, '.verantaFactory');
		PoolPriceRegistrar registrar =
			PoolPriceRegistrar(vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-pool-pricing.json'), '.registrar'));

		queue = new RedemptionQueueShortDeadline(address(this));
		ComptrollerBlueprintDeployer v3Deployer =
			new ComptrollerBlueprintDeployer(type(ComptrollerV3).creationCode, abi.encode(registrar, queue));
		vm.prank(Ownable(address(factory)).owner());
		factory.setComptrollerDeployer(v3Deployer);
		queue.setFactory(address(factory));
		guardian = factory.guardian();
		unwinder = new PerpUnwinder(perpConfig, STORE, IVerantaTradingStorage(TRADING_STORAGE), IVerantaMulticall(MULTICALL), PAIR_STORAGE, IERC20(USDC));
		queue.approveUnwinder(address(unwinder), true);
	}

	function test_fork_canUnwind_aPerpAccountOnly() public {
		vm.skip(!forked);
		(ComptrollerV3 fund, address account) = _fundWithFilledTrade(200e6);
		assertTrue(unwinder.canUnwind(account));
		assertFalse(unwinder.canUnwind(address(fund.vault())), 'not a perp account');
		assertFalse(unwinder.canUnwind(USDC));
	}

	function test_fork_closeActions_halfOfEveryTrade_atTheStoredPrice() public {
		vm.skip(!forked);
		(, address account) = _fundWithFilledTrade(200e6);
		_push();
		uint256 collateral = _collateral(account);
		bytes[] memory actions = unwinder.closeActions(account, 0.5e18);
		assertEq(actions.length, 1);
		(uint8 action, bytes memory args) = abi.decode(actions[0], (uint8, bytes));
		(uint256 pair, uint256 index, uint256 amount, uint256 wantedPrice) = abi.decode(args, (uint256, uint256, uint256, uint256));
		assertEq(action, uint8(VerantaPerpPositionV3.Action.CloseTrade));
		assertEq(pair, PAIR);
		assertEq(index, 0);
		assertEq(amount, collateral / 2);
		assertEq(wantedPrice, PACKET_PRICE);
	}

	function test_fork_closeActions_closeTheWholeTradeUnderThePairMinimum() public {
		vm.skip(!forked);
		(, address account) = _fundWithFilledTrade(30e6); // ~150 of size; half would leave ~75 < 100
		_push();
		bytes[] memory actions = unwinder.closeActions(account, 0.5e18);
		(, bytes memory args) = abi.decode(actions[0], (uint8, bytes));
		(,, uint256 amount,) = abi.decode(args, (uint256, uint256, uint256, uint256));
		assertEq(amount, _collateral(account), 'the whole trade');
	}

	function test_fork_closeActions_refuseAPriceOlderThanTwoMinutes() public {
		vm.skip(!forked);
		(, address account) = _fundWithFilledTrade(200e6);
		_push();
		vm.warp(PACKET_TS + 121);
		vm.expectRevert(abi.encodeWithSelector(PerpUnwinder.StalePrice.selector, PAIR));
		unwinder.closeActions(account, 0.5e18);
	}

	function test_fork_collectAndPending() public {
		vm.skip(!forked);
		(, address account) = _fundWithFilledTrade(200e6);
		assertEq(unwinder.collectAction(account).length, 0, 'no idle USDC yet');
		assertFalse(unwinder.hasPending(account));
		deal(USDC, account, 7e6);
		(uint8 action, bytes memory args) = abi.decode(unwinder.collectAction(account), (uint8, bytes));
		assertEq(action, uint8(VerantaPerpPositionV3.Action.ReturnToVault));
		assertEq(abi.decode(args, (uint256)), 7e6);
	}

	/// The whole fallback on real Veranta: an overdue request, the unwind's close filled by Veranta's
	/// operator, the USDC collected and the redeemer paid full value; the trade halved.
	function test_fork_fullFallback_withARealFill() public {
		vm.skip(!forked);
		(ComptrollerV3 fund, address account) = _fundWithFilledTrade(200e6);
		uint256 shares = IERC20(address(fund.shares())).balanceOf(investor) / 2;
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(address(queue), shares);
		queue.requestRedeem(address(fund), shares, RedemptionQueue.Mode.InKind);
		vm.stopPrank();
		vm.warp(block.timestamp + 2); // past the test queue's 1-second deadline
		vm.prank(guardian);
		queue.setUnwinderOn(address(unwinder), true);

		_push();
		uint256 collateral = _collateral(account);
		uint256 supply = fund.shares().totalSupply();
		uint256 gav = fund.calcGav();
		queue.unwindOverdue(address(fund), 50);
		_fillPending(account);
		assertApproxEqAbs(_collateral(account), collateral - Math.mulDiv(collateral, Math.mulDiv(shares, 1e18, supply), 1e18), 1, 'half the trade closed');

		queue.settle(address(fund), 10);
		uint256 paid = IERC20(USDC).balanceOf(investor);
		assertApproxEqRel(paid, Math.mulDiv(gav, shares, supply), 0.005e18, 'full value within the close costs');
		assertFalse(queue.requestAt(address(fund), 0).open);
		assertEq(IERC20(USDC).balanceOf(account), 0, 'the close proceeds were collected');
	}

	/// With a stored price older than two minutes the unwind reverts as a whole: nothing closes,
	/// the request is not marked, and the investor can still cancel (final review 2026-10-06, C2).
	function test_fork_unwindWithAStalePriceReverts_andTheRequestStaysCancellable() public {
		vm.skip(!forked);
		(ComptrollerV3 fund, address account) = _fundWithFilledTrade(200e6);
		uint256 shares = IERC20(address(fund.shares())).balanceOf(investor) / 2;
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(address(queue), shares);
		queue.requestRedeem(address(fund), shares, RedemptionQueue.Mode.InKind);
		vm.stopPrank();
		vm.prank(guardian);
		queue.setUnwinderOn(address(unwinder), true);
		_push();
		vm.warp(PACKET_TS + 121); // overdue on the test queue, and the stored price is now too old
		uint256 collateral = _collateral(account);

		vm.expectRevert(abi.encodeWithSelector(PerpUnwinder.StalePrice.selector, PAIR));
		queue.unwindOverdue(address(fund), 50);
		assertFalse(queue.requestAt(address(fund), 0).unwound);
		assertEq(_collateral(account), collateral, 'nothing closed');
		assertEq(IVerantaMulticall(MULTICALL).getPendingOrder(account).length, 0, 'no close pending');
		vm.prank(investor);
		queue.cancel(address(fund));
		assertEq(IERC20(address(fund.shares())).balanceOf(investor), shares * 2);
	}

	/// Six real perp accounts (175 Veranta pairs, ~2.2M gas each to value) settle within Base's
	/// 2^24 per-transaction cap (2026-10-07: valuing twice, five already took 19M).
	function test_fork_settleFitsATransaction_withSixPerpAccounts() public {
		vm.skip(!forked);
		(ComptrollerV3 fund,) = _fundWithFilledTrade(200e6);
		for (uint256 i; i < 5; ++i) {
			vm.prank(manager);
			fund.createExternalPosition(PERP_TYPE, '');
		}
		uint256 shares = IERC20(address(fund.shares())).balanceOf(investor) / 100;
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(address(queue), shares);
		queue.requestRedeem(address(fund), shares, RedemptionQueue.Mode.InKind);
		vm.stopPrank();
		_push();
		vm.cool(address(fund));
		(bool ok,) = address(queue).call{gas: 16_777_216}(abi.encodeCall(RedemptionQueue.settle, (address(fund), 10)));
		assertTrue(ok, 'settled under the cap');
		assertGt(IERC20(USDC).balanceOf(investor), 0);
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	function _fundWithFilledTrade(uint256 collateral) internal returns (ComptrollerV3 fund, address account) {
		fund = ComptrollerV3(
			factory.createFund(
				FundFactory.FundConfig({
					name: string.concat('Unwind ', vm.toString(collateral)),
					symbol: 'frUW',
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
		assertEq(address(fund.redemptionQueue()), address(queue), 'a V3 fund on this queue');
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
		vm.roll(block.number + (PACKET_TS - 20 - block.timestamp) / 2);
		vm.warp(PACKET_TS - 20);
		address[] memory assets = new address[](1);
		assets[0] = USDC;
		uint256[] memory amounts = new uint256[](1);
		amounts[0] = collateral;
		bytes memory open = abi.encode(
			uint8(VerantaPerpPositionV3.Action.OpenTrade),
			abi.encode(PAIR, collateral, uint256(5e10), true, PACKET_PRICE, uint256(1e10), uint8(0), uint256(0), uint256(0))
		);
		vm.prank(manager);
		fund.callOnExternalPosition(account, assets, amounts, new address[](0), open);
		vm.roll(block.number + 11);
		vm.warp(PACKET_TS + 2);
		_fillPending(account);
	}

	function _push() internal {
		vm.deal(address(this), 1 ether);
		STORE.submit{value: 1}(PAIR, PACKET);
	}

	function _fillPending(address account) internal {
		IVerantaMulticall.PendingOrder[] memory pending = IVerantaMulticall(MULTICALL).getPendingOrder(account);
		require(pending.length == 1, 'one pending order');
		bytes[] memory update = new bytes[](1);
		update[0] = PACKET;
		vm.deal(VERANTA_OPERATOR, 1 ether);
		vm.prank(VERANTA_OPERATOR);
		IVerantaOperator(ROUTER).executeMarketOrder{value: 1}(
			pending[0].orderId,
			update,
			1,
			IVerantaOperator.OffChainSpreadParams({
				spreadP: 1e8, bookDepth: 0, impactParam: 0, byPass: true, maxSpreadP: 0, slot1: false, slot3: 0
			})
		);
		assertEq(IVerantaMulticall(MULTICALL).getPendingOrder(account).length, 0, 'filled');
	}

	function _collateral(address account) internal view returns (uint256) {
		return IVerantaTradingStorage(TRADING_STORAGE).openTrades(account, PAIR, 0).initialPosToken;
	}
}
