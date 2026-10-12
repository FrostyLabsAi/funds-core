// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {ComptrollerV6} from '../../src/core/ComptrollerV6.sol';
import {ComptrollerV6Lib} from '../../src/core/ComptrollerV6Lib.sol';
import {IVerantaMulticall, IVerantaTradingStorage} from '../../src/interfaces/external/IVeranta.sol';
import {VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {VerantaPerpPositionV4, VerantaPerpPositionV4Factory} from '../../src/positions/VerantaPerpPositionV4.sol';
import {VerantaPriceStore} from '../../src/pricing/VerantaPriceStore.sol';
import {RedemptionQueueV2} from '../../src/redemption/RedemptionQueueV2.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {RedemptionQueueV2ShortDeadline} from '../utils/RedemptionQueueV2ShortDeadline.sol';
import {IVerantaOperatorUnwindV4} from './PerpUnwinderV4Fork.t.sol';

/// @notice A ghosted fund v6 holding a real Veranta perp (founder 2026-10-11, USDC-only exit): PerpUnwinderV4Fork's
///         block, pair-129 Lazer packet and operator fill, with fund v6 on a 1-second-deadline RedemptionQueueV2. The
///         keeper settles what the vault covers, closes the rest of the request's need on Veranta, collects the USDC
///         once Veranta's operator fills the close, and settles the rest; the investor is paid in USDC.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/FundV6PerpFork.t.sol -vv
contract FundV6PerpForkTest is Test {
	uint256 internal constant FORK_BLOCK = 52_230_324;
	address internal constant USDC = FundsMainnet.USDC;
	address internal constant ROUTER = FundsMainnet.VERANTA_ROUTER;
	address internal constant MULTICALL = FundsMainnet.VERANTA_MULTICALL;
	address internal constant TRADING_STORAGE = FundsMainnet.VERANTA_STORAGE;
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
	RedemptionQueueV2 internal queue;
	address internal manager = makeAddr('manager');
	address internal investor = makeAddr('investor');
	address internal keeper = makeAddr('keeper');

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, FORK_BLOCK);
		forked = true;
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		perpConfig = vm.parseJsonAddress(genesis, '.verantaFactory');
		// registrar V2 isn't live at this block (the packet's); fund v6 only asks its registrar poolPricedAdapter
		address registrar = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-pool-pricing.json'), '.registrar');

		queue = new RedemptionQueueV2ShortDeadline(address(this));
		queue.setFactory(address(factory));
		queue.setKeeper(keeper, true);
		ComptrollerBlueprintDeployer v6Deployer =
			new ComptrollerBlueprintDeployer(type(ComptrollerV6).creationCode, abi.encode(registrar, queue, perpConfig));
		VerantaPerpPositionV4Factory v4 = new VerantaPerpPositionV4Factory(VerantaPerpPositionV2Factory(perpConfig));
		vm.startPrank(Ownable(address(factory)).owner());
		factory.setComptrollerDeployer(v6Deployer);
		factory.registerPositionType(PERP_TYPE, address(v4)); // the V4 rollout step at this block
		vm.stopPrank();
	}

	function test_fork_aGhostedPerpFund_isClosedOnVeranta_andTheLeaverPaidInUsdc() public {
		vm.skip(!forked);
		(ComptrollerV6 fund, address account) = _fundWithFilledTrade(1_000e6, 800e6); // vault 200, trade 800
		uint256 shares = fund.shares().balanceOf(investor) / 2;
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(address(queue), shares);
		uint256 id = queue.requestRedeem(address(fund), shares);
		vm.stopPrank();
		vm.warp(block.timestamp + 2); // overdue under the test queue's 1-second deadline
		_push();
		uint256 supply = fund.shares().totalSupply();
		uint256 gav = fund.calcGav();

		// what the vault covers now, in part
		vm.prank(keeper);
		queue.settle(address(fund), 1);
		uint256 firstPaid = IERC20(USDC).balanceOf(investor);
		assertApproxEqAbs(firstPaid, 200e6, 1, 'the vault had 200');
		assertTrue(queue.requestAt(address(fund), id).open, 'the rest waits');

		// a close of nothing is refused; half the trade closes on Veranta, the operator fills it
		vm.prank(keeper);
		vm.expectRevert(ComptrollerV6Lib.CloseOfNothing.selector);
		queue.liquidatePosition(address(fund), account, new address[](0), _one(_closeTrade(0)));
		uint256 collateral = _collateral(account);
		vm.prank(keeper);
		queue.liquidatePosition(address(fund), account, new address[](0), _one(_closeTrade(collateral / 2)));
		_fillPending(account);
		assertApproxEqAbs(_collateral(account), collateral - collateral / 2, 1, 'half the trade closed');

		// the close's USDC back to the vault, then the rest of the request settles
		uint256 idle = IERC20(USDC).balanceOf(account);
		assertGt(idle, 0);
		address[] memory back = new address[](1);
		back[0] = USDC;
		vm.prank(keeper);
		queue.liquidatePosition(
			address(fund), account, back, _one(abi.encode(uint8(VerantaPerpPositionV4.Action.ReturnToVault), abi.encode(idle)))
		);
		_push();
		vm.prank(keeper);
		queue.settle(address(fund), 1);
		assertFalse(queue.requestAt(address(fund), id).open, 'paid');
		assertApproxEqRel(IERC20(USDC).balanceOf(investor), Math.mulDiv(gav, shares, supply), 0.005e18, 'its share, within the close costs');
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	function _one(bytes memory action) internal pure returns (bytes[] memory actions) {
		actions = new bytes[](1);
		actions[0] = action;
	}

	function _closeTrade(uint256 amount) internal pure returns (bytes memory) {
		return abi.encode(uint8(VerantaPerpPositionV4.Action.CloseTrade), abi.encode(PAIR, uint256(0), amount, PACKET_PRICE));
	}

	function _fundWithFilledTrade(uint256 deposit, uint256 collateral) internal returns (ComptrollerV6 fund, address account) {
		fund = ComptrollerV6(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'V6 perp liquidation',
					symbol: 'frV6',
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
		deal(USDC, investor, deposit);
		vm.startPrank(investor);
		IERC20(USDC).approve(address(fund), deposit);
		fund.requestDeposit(deposit, type(uint256).max);
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
			uint8(VerantaPerpPositionV4.Action.OpenTrade),
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
		IVerantaOperatorUnwindV4(ROUTER).executeMarketOrder{value: 1}(
			pending[0].orderId,
			update,
			1,
			IVerantaOperatorUnwindV4.OffChainSpreadParams({
				spreadP: 1e8, bookDepth: 0, impactParam: 0, byPass: true, maxSpreadP: 0, slot1: false, slot3: 0
			})
		);
		assertEq(IVerantaMulticall(MULTICALL).getPendingOrder(account).length, 0, 'filled');
	}

	function _collateral(address account) internal view returns (uint256) {
		return IVerantaTradingStorage(TRADING_STORAGE).openTrades(account, PAIR, 0).initialPosToken;
	}
}
