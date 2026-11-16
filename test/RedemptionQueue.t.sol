// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {RedemptionQueue} from '../src/redemption/RedemptionQueue.sol';
import {Shares} from '../src/fund/Shares.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';
import {Test} from 'forge-std/Test.sol';
import {ComptrollerLib} from '../src/core/ComptrollerLib.sol';
import {UniswapV3SwapAdapter} from '../src/adapters/UniswapV3SwapAdapter.sol';
import {IUniswapV3SwapRouter} from '../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {MockUnwindPosition} from './utils/MockUnwindPosition.sol';
import {RedemptionFixture} from './utils/RedemptionFixture.sol';
import {IShares} from '../src/interfaces/IShares.sol';

/// @dev A denomination asset that refuses transfers to a blocked address (USDC's blacklist).
contract BlockingUsdc is MockERC20 {
	mapping(address => bool) public blocked;

	constructor() MockERC20('Blocking USD', 'bUSD', 6) {}

	function block_(address who) external {
		blocked[who] = true;
	}

	function _update(address from, address to, uint256 value) internal override {
		require(!blocked[to], 'blocked');
		super._update(from, to, value);
	}
}

/// @dev A router that moves the pool's quote side as a real swap would: the token sold goes to `pool` and the pool's
///      quote balance drops to `poolQuoteAfter` (final review 2026-10-11, I1 PoC).
contract DrainingRouter is Test {
	address public pool;
	address public quote;
	uint256 public poolQuoteAfter;
	uint256 public amountOut;

	function set(address pool_, address quote_, uint256 poolQuoteAfter_, uint256 amountOut_) external {
		pool = pool_;
		quote = quote_;
		poolQuoteAfter = poolQuoteAfter_;
		amountOut = amountOut_;
	}

	function exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams calldata p) external payable returns (uint256) {
		IERC20(p.tokenIn).transferFrom(msg.sender, pool, p.amountIn);
		deal(quote, pool, poolQuoteAfter);
		MockERC20(p.tokenOut).mint(p.recipient, amountOut);
		return amountOut;
	}
}

/// @notice RedemptionQueue (fund v6, USDC-only exit; founder 2026-10-11, PLAN_CASH_ONLY_EXIT_2026-10-11.md) with
///         real fund v6 funds: requests, the manager's or keeper's settlement in USDC at NAV, the 4-day deadline, the
///         keeper's liquidation, and cancels.
contract RedemptionQueueTest is RedemptionFixture {
	function _liquidate(Comptroller fund, MockERC20 tokenIn, uint256 amountIn, uint256 usdcOut) internal {
		router.setNextAmountOut(usdcOut);
		vm.prank(keeper);
		queue.liquidate(address(fund), address(uniAdapter), abi.encode(address(tokenIn), address(usdc), uint24(3000), amountIn, uint256(0)));
	}

	function _closeAndReturn(Comptroller fund, MockUnwindPosition position, uint256 amount) internal {
		bytes[] memory batch = new bytes[](2);
		batch[0] = abi.encode(uint8(1), abi.encode(amount));
		batch[1] = abi.encode(uint8(6), abi.encode(amount));
		address[] memory back = new address[](1);
		back[0] = address(usdc);
		vm.prank(keeper);
		queue.liquidatePosition(address(fund), address(position), back, batch);
	}

	function _settle(Comptroller fund) internal returns (uint256) {
		vm.prank(keeper);
		return queue.settle(address(fund), 10);
	}

	// ─── requests ────────────────────────────────────────────────────────────────

	function test_aRequestEscrowsTheShares() public {
		Comptroller fund = _fund();
		uint256 shares = _sharesOf(fund, alice) / 2;
		uint256 id = _request(fund, alice, shares);
		assertEq(_sharesOf(fund, address(queue)), shares);
		RedemptionQueue.Request memory request = queue.requestAt(address(fund), id);
		assertEq(request.investor, alice);
		assertEq(request.shares, shares);
		assertTrue(request.open);
	}

	/// Any fund v6 queues, positions or not: the instant exit refuses long-tail tokens too.
	function test_aFundWithoutPositionsQueuesToo() public {
		Comptroller fund = _fund();
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		_request(fund, alice, 1e18);
		assertEq(_sharesOf(fund, address(queue)), 1e18);
	}

	function test_oneOpenRequestPerInvestor_andNeverZero() public {
		Comptroller fund = _fund();
		_request(fund, alice, 1e18);
		IShares fundShares = fund.shares();
		vm.startPrank(alice);
		fundShares.approve(address(queue), 2e18);
		vm.expectRevert(RedemptionQueue.RequestExists.selector);
		queue.requestRedeem(address(fund), 1e18);
		vm.stopPrank();
		vm.prank(bob);
		vm.expectRevert(RedemptionQueue.ZeroShares.selector);
		queue.requestRedeem(address(fund), 0);
	}

	function test_aRequestForAFundNotOursIsRefused() public {
		vm.expectRevert(abi.encodeWithSelector(RedemptionQueue.NotOurFund.selector, address(0xbeef)));
		queue.requestRedeem(address(0xbeef), 1);
	}

	// ─── settlement ──────────────────────────────────────────────────────────────

	/// D1: only the manager or a keeper settles, so no leaver picks the moment a pool price is wrong.
	function test_settle_onlyTheManagerOrAKeeper() public {
		Comptroller fund = _fund();
		_request(fund, alice, 1e18);
		vm.prank(alice);
		vm.expectRevert(RedemptionQueue.NotManagerOrKeeper.selector);
		queue.settle(address(fund), 1);
		vm.prank(manager);
		assertEq(queue.settle(address(fund), 1), 1);
		_request(fund, alice, 1e18);
		assertEq(_settle(fund), 1);
	}

	function test_settle_paysUsdcAtNav_oldestFirst() public {
		Comptroller fund = _fund();
		_deposit(fund, bob, 10_000e6);
		_swap(fund, usdc, weth, 4_000e6, 2e18); // 16,000 USDC + 2 WETH ($4,000)
		uint256 aliceShares = _sharesOf(fund, alice) / 2;
		uint256 bobShares = _sharesOf(fund, bob) / 4;
		_request(fund, alice, aliceShares);
		_request(fund, bob, bobShares);
		uint256 supply = fund.shares().totalSupply();

		assertEq(_settle(fund), 2);
		assertEq(usdc.balanceOf(alice), 20_000e6 * aliceShares / supply);
		assertEq(usdc.balanceOf(bob), 20_000e6 * bobShares / supply);
		assertEq(weth.balanceOf(alice) + weth.balanceOf(bob), 0, 'never a token');
		assertEq(_sharesOf(fund, address(queue)), 0, 'escrow burned');
	}

	/// The oldest request the USDC can't cover is paid in part, the rest stays queued (still the oldest), and nothing
	/// newer is paid ahead of it.
	function test_settle_paysTheOldestInPart_andNothingNewerAheadOfIt() public {
		Comptroller fund = _fund();
		_deposit(fund, bob, 10_000e6);
		_swap(fund, usdc, weth, 17_000e6, 8.5e18); // 3,000 USDC + 8.5 WETH ($17,000)
		uint256 aliceShares = _sharesOf(fund, alice) / 2; // ~5,000 owed
		uint256 id = _request(fund, alice, aliceShares);
		_request(fund, bob, 1e18);
		uint256 supply = fund.shares().totalSupply();

		assertEq(_settle(fund), 1);
		uint256 paidShares = 3_000e6 * supply / 20_000e6;
		assertEq(usdc.balanceOf(alice), 20_000e6 * paidShares / supply, 'all 3,000 the vault had');
		assertEq(queue.requestAt(address(fund), id).shares, aliceShares - paidShares, 'the rest stays queued');
		assertEq(usdc.balanceOf(bob), 0, 'bob waits behind alice');
		(uint256 head,) = queue.queueBounds(address(fund));
		assertEq(head, id, 'alice still first');

		_swap(fund, weth, usdc, 8.5e18, 17_000e6);
		assertEq(_settle(fund), 2);
		assertApproxEqAbs(usdc.balanceOf(alice), 20_000e6 * aliceShares / supply, 1, 'alice whole');
		assertGt(usdc.balanceOf(bob), 0);
	}

	/// Every price must read: a holding at $0 would pay the leaver short.
	function test_settle_waitsForAPriceThatCannotBeRead() public {
		Comptroller fund = _fund();
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		_request(fund, alice, 1e18);
		skip(26 hours); // WETH's 25-hour feed stale (USDC's too)
		vm.prank(keeper);
		vm.expectRevert(RedemptionQueue.PriceUnreadable.selector);
		queue.settle(address(fund), 1);
		_refreshFeeds();
		assertEq(_settle(fund), 1);
	}

	function test_settle_nothingPayableReverts() public {
		Comptroller fund = _fund();
		_swap(fund, usdc, weth, 10_000e6, 5e18); // no USDC left
		_request(fund, alice, 1e18);
		vm.prank(keeper);
		vm.expectRevert(RedemptionQueue.NothingSettled.selector);
		queue.settle(address(fund), 1);
	}

	/// Fees settle first: the escrowed shares bear the management fee like everyone's.
	function test_settle_feesSettleFirst() public {
		Comptroller fund = Comptroller(factory.createFund(_config(1_000_000_000_627_507_379_616_874_496, 0, 0)));
		_deposit(fund, alice, 10_000e6);
		uint256 half = _sharesOf(fund, alice) / 2;
		_request(fund, alice, half);
		skip(1 days);
		uint256 supplyBefore = fund.shares().totalSupply();
		_settle(fund);
		assertGt(_sharesOf(fund, manager), 0, 'the fee minted first');
		assertEq(usdc.balanceOf(alice), 10_000e6 * half / (supplyBefore + _sharesOf(fund, manager)));
	}

	/// A payout USDC refuses (a blacklisted investor) bounces: the shares go back, the queue goes on.
	function test_aRefusedPayoutBouncesTheRequest_andTheQueueGoesOn() public {
		BlockingUsdc busd = new BlockingUsdc();
		registrar.execute(
			abi.encodeCall(ValueInterpreter.addPrimitive, (address(busd), address(new MockAggregator(8, 1e8)), uint32(25 hours)))
		);
		FundFactory.FundConfig memory config = _config(0, 0, 0);
		config.denominationAsset = IERC20(address(busd));
		Comptroller fund = Comptroller(factory.createFund(config));
		address[2] memory who = [alice, bob];
		for (uint256 i; i < 2; ++i) {
			busd.mint(who[i], 10_000e6);
			vm.startPrank(who[i]);
			busd.approve(address(fund), 10_000e6);
			fund.requestDeposit(10_000e6, type(uint256).max);
			vm.stopPrank();
			skip(1 minutes);
			fund.executeDepositRequest(who[i]);
		}
		uint256 aliceShares = _sharesOf(fund, alice);
		_request(fund, alice, aliceShares);
		_request(fund, bob, 1e18);
		busd.block_(alice);

		assertEq(_settle(fund), 2);
		assertEq(_sharesOf(fund, alice), aliceShares, 'alice bounced: her shares back');
		assertGt(busd.balanceOf(bob), 0, 'bob paid behind her');
	}

	// ─── deadline, cancel ────────────────────────────────────────────────────────

	function test_theFundIsOverdueAfterTheDeadline() public {
		Comptroller fund = _fund();
		_request(fund, alice, 1e18);
		skip(4 days);
		assertFalse(queue.isOverdue(address(fund)));
		skip(1);
		assertTrue(queue.isOverdue(address(fund)));
	}

	function test_cancel_returnsTheShares() public {
		Comptroller fund = _fund();
		uint256 shares = _sharesOf(fund, alice);
		_request(fund, alice, 1e18);
		vm.prank(alice);
		queue.cancel(address(fund));
		assertEq(_sharesOf(fund, alice), shares);
		vm.prank(alice);
		vm.expectRevert(RedemptionQueue.NoRequest.selector);
		queue.cancel(address(fund));
	}

	/// Giving up while overdue doesn't hand the manager the overdue period: fees settle (and stop) first.
	function test_cancel_whileOverdue_settlesTheFeesFirst() public {
		Comptroller fund = Comptroller(factory.createFund(_config(1_000_000_000_627_507_379_616_874_496, 0, 0)));
		_deposit(fund, alice, 10_000e6);
		_request(fund, alice, 1e18);
		skip(5 days);
		vm.prank(alice);
		queue.cancel(address(fund));
		assertEq(fund.lastMgmtFeeSettled(), block.timestamp);
		assertEq(_sharesOf(fund, manager), 0, 'no fee for the overdue period');
	}

	/// Once the keeper liquidated the fund for a request, it can't be cancelled; a request made since can.
	function test_cancel_refusedOnceTheFundWasLiquidatedForIt() public {
		Comptroller fund = _fund();
		_deposit(fund, bob, 10_000e6);
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		_request(fund, alice, 1e18);
		skip(4 days + 1);
		_refreshFeeds();
		_liquidate(fund, weth, 0.5e18, 1_000e6);
		assertEq(queue.liquidatedAt(address(fund)), block.timestamp);
		vm.prank(alice);
		vm.expectRevert(RedemptionQueue.BeingLiquidated.selector);
		queue.cancel(address(fund));

		_request(fund, bob, 1e18);
		vm.prank(bob);
		queue.cancel(address(fund));
	}

	// ─── liquidation ─────────────────────────────────────────────────────────────

	/// The keeper simulates a sale and sends it with what arrived, less its slack, as the minimum (founder 2026-11-15):
	/// liquidate returns what reached the vault, and a minimum above it is refused.
	function test_liquidate_returnsWhatReachedTheVault() public {
		Comptroller fund = _fund();
		_swap(fund, usdc, weth, 2_000e6, 1e18); // 1 WETH ($2,000)
		_request(fund, alice, 1e18);
		skip(4 days + 1);
		_refreshFeeds();
		address vault = address(fund.vault());
		uint256 usdcBefore = usdc.balanceOf(vault);
		router.setNextAmountOut(1_985e6);
		uint256 snap = vm.snapshotState();
		vm.prank(keeper);
		uint256 received = queue.liquidate(address(fund), address(uniAdapter), abi.encode(address(weth), address(usdc), uint24(3000), 1e18, uint256(0)));
		assertEq(received, 1_985e6, 'the sale, as a simulation reads it');
		assertEq(usdc.balanceOf(vault) - usdcBefore, received);

		vm.revertToState(snap); // the real send, with the simulated amount less 0.5% as its minimum
		uint256 minOut = received * 9_950 / 10_000;
		vm.prank(keeper);
		assertEq(queue.liquidate(address(fund), address(uniAdapter), abi.encode(address(weth), address(usdc), uint24(3000), 1e18, minOut)), received);
		vm.revertToState(snap); // a fill under the minimum is refused, by the Comptroller's own check of what arrived
		router.setNextAmountOut(minOut - 1);
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(ComptrollerLib.MinIncomingAmountNotMet.selector, address(usdc), minOut - 1, minOut));
		queue.liquidate(address(fund), address(uniAdapter), abi.encode(address(weth), address(usdc), uint24(3000), 1e18, minOut));
	}

	function test_liquidate_onlyAKeeper_onlyOverdue() public {
		Comptroller fund = _fund();
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		_request(fund, alice, 1e18);
		bytes memory sale = abi.encode(address(weth), address(usdc), uint24(3000), 1e18, uint256(0));
		vm.prank(keeper);
		vm.expectRevert(RedemptionQueue.NotOverdue.selector);
		queue.liquidate(address(fund), address(uniAdapter), sale);
		skip(4 days + 1);
		vm.prank(manager);
		vm.expectRevert(RedemptionQueue.NotKeeper.selector);
		queue.liquidate(address(fund), address(uniAdapter), sale);
		vm.prank(stranger);
		vm.expectRevert(RedemptionQueue.NotKeeper.selector);
		queue.liquidatePosition(address(fund), address(0), new address[](0), new bytes[](0));
	}

	/// The manager ghosts: past the deadline the keeper closes the position, sells the tokens and settles. The leaver
	/// gets their share of the NAV after the sales, in USDC; the investors who stay keep the same value per share.
	function test_aGhostedFund_isLiquidatedAndTheLeaverPaidInUsdc() public {
		(Comptroller fund, MockUnwindPosition position) = _fundWithPosition(5_000e6);
		_deposit(fund, bob, 10_000e6);
		_swap(fund, usdc, weth, 8_000e6, 4e18); // vault 7,000 USDC + 4 WETH ($8,000); position 5,000
		uint256 aliceShares = _sharesOf(fund, alice);
		_request(fund, alice, aliceShares);
		skip(4 days + 1);
		_refreshFeeds();

		_closeAndReturn(fund, position, 5_000e6);
		_liquidate(fund, weth, 4e18, 7_920e6); // 1% under the oracle
		assertEq(_held(fund, usdc), 19_920e6);
		uint256 supply = fund.shares().totalSupply();
		assertEq(_settle(fund), 1);

		assertEq(usdc.balanceOf(alice), 19_920e6 * aliceShares / supply);
		assertEq(_sharesOf(fund, alice), 0);
		assertFalse(queue.isOverdue(address(fund)), 'paid: no longer overdue');
		uint256 bobValue = fund.calcGav() * _sharesOf(fund, bob) / fund.shares().totalSupply();
		assertApproxEqAbs(bobValue * aliceShares, usdc.balanceOf(alice) * _sharesOf(fund, bob), 1e18 * 2, 'same per share');
	}

	/// Past the deadline the manager can still sell and settle themselves, but can't spend the USDC.
	function test_whileOverdue_theManagerSellsAndSettles_butCantSpend() public {
		Comptroller fund = _fund();
		_swap(fund, usdc, weth, 9_000e6, 4.5e18); // 1,000 USDC left
		_request(fund, alice, _sharesOf(fund, alice) / 2);
		skip(4 days + 1);
		_refreshFeeds();
		router.setNextAmountOut(0.25e18);
		vm.prank(manager);
		vm.expectRevert(Comptroller.UsdcSpentWhileOverdue.selector);
		fund.callOnIntegration(address(uniAdapter), abi.encode(address(usdc), address(weth), uint24(3000), 500e6, uint256(0)));
		_swap(fund, weth, usdc, 4.5e18, 9_000e6);
		vm.prank(manager);
		assertEq(queue.settle(address(fund), 1), 1);
	}

	// ─── final review 2026-10-11 ─────────────────────────────────────────────────

	/// C1: a reconfiguration would leave the queue book with the old comptroller (unregistered): its requests could no
	/// longer be settled, liquidated for or made overdue. It waits until no request is open.
	function test_aReconfigurationWaitsUntilNoRequestIsOpen() public {
		Comptroller fund = _fund();
		_request(fund, alice, 1e18);
		vm.prank(manager);
		factory.createReconfigurationRequest(address(fund), _config(0, 0, 0));
		skip(2 days);
		_refreshFeeds();
		vm.prank(manager);
		vm.expectRevert(Comptroller.OpenRedemptions.selector);
		factory.executeReconfiguration(address(fund));

		vm.prank(alice);
		queue.cancel(address(fund));
		vm.prank(manager);
		factory.executeReconfiguration(address(fund));
		(address registered,,,,) = factory.funds(address(fund));
		assertEq(registered, address(0), 'moved once nothing was queued');
	}

	/// @dev 10,000 USDC + 10,000 TKN ($1, pool-priced) with alice's request overdue; the pool holds $9,000 of USDC.
	function _tknFundOverdue(DrainingRouter drainer) internal returns (Comptroller fund, address drainAdapter) {
		drainAdapter = address(new UniswapV3SwapAdapter(IUniswapV3SwapRouter(address(drainer)), address(0xFEE), 0, address(this)));
		factory.registerAdapter(drainAdapter);
		fund = _fund();
		_deposit(fund, bob, 10_000e6);
		_swap(fund, usdc, tkn, 10_000e6, 10_000e6);
		_request(fund, alice, _sharesOf(fund, alice));
		skip(4 days + 1);
		_refreshFeeds();
		deal(address(usdc), address(pool), 9_000e6);
		assertEq(fund.calcGav(), 20_000e6);
	}

	/// I1: the cap prices what is sold BEFORE the sale. A pool-priced token's price reads its pool, which the sale moves:
	/// priced after, a sale pushing the pool's USDC under $5,000 read the token at ~$0 and passed at any price.
	function test_theCapPricesTheSaleBeforeIt_evenWhenItDrainsThePool() public {
		DrainingRouter drainer = new DrainingRouter();
		(Comptroller fund, address drainAdapter) = _tknFundOverdue(drainer);
		bytes memory sale = abi.encode(address(tkn), address(usdc), uint24(3000), 10_000e6, uint256(0));
		drainer.set(address(pool), address(usdc), 6_000e6, 3_000e6); // leaves the pool above $5,000
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(ComptrollerLib.LiquidationLoss.selector, 7_000e6, 300e6));
		queue.liquidate(address(fund), drainAdapter, sale);
		drainer.set(address(pool), address(usdc), 4_999e6, 1_000e6); // drains it under $5,000
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(ComptrollerLib.LiquidationLoss.selector, 9_000e6, 300e6));
		queue.liquidate(address(fund), drainAdapter, sale);
		assertEq(fund.calcGav(), 20_000e6, 'nothing sold');
	}

	// ─── governance ──────────────────────────────────────────────────────────────

	function test_onlyTheOwnerSetsKeepers_andTheFactoryOnce() public {
		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		queue.setKeeper(stranger, true);
		queue.setKeeper(stranger, true);
		assertTrue(queue.isKeeper(stranger));
		queue.setKeeper(stranger, false);
		assertFalse(queue.isKeeper(stranger));
		vm.expectRevert(RedemptionQueue.FactoryAlreadySet.selector);
		queue.setFactory(address(1));
	}
}
