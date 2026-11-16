// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ComptrollerBlueprintDeployer} from '../src/core/ComptrollerBlueprintDeployer.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ComptrollerLib} from '../src/core/ComptrollerLib.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {Shares} from '../src/fund/Shares.sol';
import {IExternalPosition} from '../src/interfaces/IExternalPosition.sol';
import {IExternalPositionTypeFactory} from '../src/interfaces/IExternalPositionTypeFactory.sol';
import {ComptrollerBase} from './ComptrollerBase.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';
import {MockUnwindPosition} from './utils/MockUnwindPosition.sol';
import {MockEscrowPosition, MockEscrowPositionFactory} from './utils/MockEscrowPosition.sol';
import {VerantaPerpPosition} from '../src/positions/VerantaPerpPosition.sol';
import {MockRedemptionQueue, MockPerpAccount, MockPerpAccountFactory} from './utils/MockRedemptionQueue.sol';
import {MockSaleTaxAdapter} from './utils/MockSaleTaxAdapter.sol';
import {IUniswapV3SwapRouter} from '../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {IShares} from '../src/interfaces/IShares.sol';

/// @dev A priced token whose balanceOf reverts while `broken` (a paused or hostile token).
contract BrokenBalanceToken is MockERC20 {
	bool public broken;

	constructor() MockERC20('Broken', 'BRK', 18) {}

	function setBroken(bool broken_) external {
		broken = broken_;
	}

	function balanceOf(address account) public view override returns (uint256) {
		require(!broken, 'broken');
		return super.balanceOf(account);
	}
}

/// @dev A position no action of which is risk-reducing: 0 burns `amount` of the USDC it holds (value lost), 1 sends
///      `amount` of the WETH it holds to the fund's vault (value moved).
contract MockLossyPosition is IExternalPosition {
	address public immutable comptroller;
	IERC20 public immutable usdc;
	IERC20 public immutable weth;

	constructor(address comptroller_, IERC20 usdc_, IERC20 weth_) {
		comptroller = comptroller_;
		usdc = usdc_;
		weth = weth_;
	}

	function getManagedAssets() external view returns (address[] memory assets, uint256[] memory amounts) {
		assets = new address[](2);
		amounts = new uint256[](2);
		assets[0] = address(usdc);
		assets[1] = address(weth);
		amounts[0] = usdc.balanceOf(address(this));
		amounts[1] = weth.balanceOf(address(this));
	}

	function getDebtAssets() external pure returns (address[] memory assets, uint256[] memory amounts) {
		assets = new address[](0);
		amounts = new uint256[](0);
	}

	function isRiskReducing(bytes calldata) external pure returns (bool) {
		return false;
	}

	function receiveCallFromFund(bytes calldata actionData) external {
		require(msg.sender == comptroller, 'only comptroller');
		(uint8 action, bytes memory args) = abi.decode(actionData, (uint8, bytes));
		uint256 amount = abi.decode(args, (uint256));
		if (action == 2) usdc.transfer(address(0xdead), amount); // an LP decrease that loses value
		else if (action == 3) weth.transfer(address(Comptroller(comptroller).vault()), amount); // an LP collect
	}
}

/// @dev A position whose holdings can't be read while `unreadable` (as a perp account on a stale price); action 1 is a
///      risk-reducing close.
contract MockUnreadablePosition is IExternalPosition {
	address public immutable comptroller;
	bool public unreadable;
	uint256 public closes;

	constructor(address comptroller_) {
		comptroller = comptroller_;
	}

	function setUnreadable(bool on) external {
		unreadable = on;
	}

	function getManagedAssets() external view returns (address[] memory assets, uint256[] memory amounts) {
		require(!unreadable, 'stale price');
		assets = new address[](0);
		amounts = new uint256[](0);
	}

	function getDebtAssets() external pure returns (address[] memory assets, uint256[] memory amounts) {
		assets = new address[](0);
		amounts = new uint256[](0);
	}

	function isRiskReducing(bytes calldata actionData) external pure returns (bool) {
		(uint8 action,) = abi.decode(actionData, (uint8, bytes));
		return action == 1;
	}

	function receiveCallFromFund(bytes calldata actionData) external {
		require(msg.sender == comptroller, 'only comptroller');
		(uint8 action,) = abi.decode(actionData, (uint8, bytes));
		if (action == 1) ++closes;
	}
}

contract MockUnreadablePositionFactory is IExternalPositionTypeFactory {
	function deployPosition(address comptroller, bytes calldata) external returns (address) {
		return address(new MockUnreadablePosition(comptroller));
	}
}

contract MockLossyPositionFactory is IExternalPositionTypeFactory {
	IERC20 public immutable usdc;
	IERC20 public immutable weth;

	constructor(IERC20 usdc_, IERC20 weth_) {
		usdc = usdc_;
		weth = weth_;
	}

	function deployPosition(address comptroller, bytes calldata) external returns (address) {
		return address(new MockLossyPosition(comptroller, usdc, weth));
	}
}

/// @notice The Comptroller, with a USDC-only exit (founder 2026-10-11, PLAN_CASH_ONLY_EXIT_2026-10-11.md). ComptrollerBase's
///         suite runs here; the tests whose behavior the USDC-only exit changes are overridden below, then its own: the
///         instant exit, unreadable balances, the overdue USDC lock, the perp close of 0, liquidation.
contract ComptrollerTest is ComptrollerBase {
	uint256 internal constant PERP_TYPE = 98;
	uint256 internal constant LOSSY_TYPE = 97;
	uint256 internal constant ESCROW_TYPE = 95;
	uint256 internal constant UNREADABLE_TYPE = 94;
	MockRedemptionQueue internal mockQueue;
	MockPerpAccountFactory internal perpConfig;

	function setUp() public virtual override {
		super.setUp();
		mockQueue = new MockRedemptionQueue();
		queue = mockQueue;
		perpConfig = new MockPerpAccountFactory(IERC20(address(usdc)));
		factory.registerPositionType(PERP_TYPE, address(perpConfig));
		factory.registerPositionType(LOSSY_TYPE, address(new MockLossyPositionFactory(IERC20(address(usdc)), IERC20(address(weth)))));
		factory.registerPositionType(ESCROW_TYPE, address(new MockEscrowPositionFactory()));
		factory.registerPositionType(UNREADABLE_TYPE, address(new MockUnreadablePositionFactory()));
		factory.setComptrollerDeployer(
			new ComptrollerBlueprintDeployer(type(Comptroller).creationCode, abi.encode(registrar, mockQueue, perpConfig))
		);
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	function _escrow(Comptroller fund, address who, uint256 shares) internal {
		IShares fundShares = fund.shares();
		vm.prank(who);
		fundShares.transfer(address(queue), shares);
	}

	/// @dev The keeper's sale of `amountIn` of `tokenIn` into USDC, filled at `usdcOut`.
	function _liquidate(Comptroller fund, MockERC20 tokenIn, uint256 amountIn, uint256 usdcOut) internal {
		router.setNextAmountOut(usdcOut);
		mockQueue.liquidateTrade(
			fund, address(uniAdapter), abi.encode(address(tokenIn), address(usdc), uint24(3000), amountIn, uint256(0))
		);
	}

	function _close(uint256 amount) internal pure returns (bytes memory) {
		return abi.encode(uint8(1), abi.encode(uint256(0), uint256(0), amount, uint256(180e10)));
	}

	function _one(bytes memory action) internal pure returns (bytes[] memory actions) {
		actions = new bytes[](1);
		actions[0] = action;
	}

	function _brokenToken() internal returns (BrokenBalanceToken brk) {
		brk = new BrokenBalanceToken();
		registrar.execute(
			abi.encodeCall(ValueInterpreter.addPrimitive, (address(brk), address(new MockAggregator(8, 1_000e8)), uint32(25 hours)))
		);
	}

	function _lossyPosition(Comptroller fund, uint256 usdcIn, uint256 wethIn) internal returns (MockLossyPosition position) {
		vm.startPrank(manager);
		position = MockLossyPosition(fund.createExternalPosition(LOSSY_TYPE, ''));
		(address[] memory assets, uint256[] memory amounts) = _usdc(usdcIn);
		fund.callOnExternalPosition(address(position), assets, amounts, new address[](0), abi.encode(uint8(0), abi.encode(uint256(0))));
		vm.stopPrank();
		weth.mint(address(position), wethIn);
	}

	// ─── Behavior the USDC-only exit changes ──────────────────────────────────────────────────

	/// No token is paid in kind: holding a long-tail token sends the exit through the queue; sold, it exits at once.
	function test_aLongTailHoldingSendsTheExitToTheQueueUntilSold() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6); // 8,000 USDC + 2,000 TKN ($1)
		uint256 half = _sharesOf(fund, alice) / 2;
		vm.prank(alice);
		vm.expectRevert(Comptroller.UseRedemptionQueue.selector);
		fund.redeemShares(half);
		assertEq(_sharesOf(fund, alice), half * 2, 'shares untouched');

		_swap(fund, tkn, usdc, 2_000e6, 2_000e6);
		vm.prank(alice);
		fund.redeemShares(half);
		assertApproxEqRel(usdc.balanceOf(alice), 5_000e6, 1e15);
		assertEq(tkn.balanceOf(alice), 0, 'never a token');
	}

	/// D1: the redeemer picks this moment, so a pool price never sets it, pumped or not.
	function test_aPumpedLongTailPriceAddsNoCashToARedemption() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		_setTknPriceTick(23028); // TKN's pool pumped to $10 for the whole window
		uint256 shares = _sharesOf(fund, alice) / 4;
		vm.prank(alice);
		vm.expectRevert(Comptroller.UseRedemptionQueue.selector);
		fund.redeemShares(shares);
		assertEq(usdc.balanceOf(alice), 0);
	}

	/// A price that can't be read now sends the exit through the queue; once it reads, the exit pays it in USDC.
	function test_anUnreadablePriceSendsTheExitToTheQueueUntilItReads() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, weth, 2_000e6, 1e18); // 8,000 USDC + 1 WETH
		skip(2 hours); // WETH's 1-hour feed is now stale; USDC's 25-hour one is not
		uint256 half = _sharesOf(fund, alice) / 2;
		vm.prank(alice);
		vm.expectRevert(Comptroller.UseRedemptionQueue.selector);
		fund.redeemShares(half);

		wethFeed.setAnswer(2000e8);
		vm.prank(alice);
		fund.redeemShares(half);
		assertApproxEqRel(usdc.balanceOf(alice), 5_000e6, 1e15, 'half of 10,000, all USDC');
		assertEq(weth.balanceOf(alice), 0);
	}

	/// Exits never pay a token, so a long-tail cost basis moves only with trades.
	function test_costBasisFollowsBuysAndSalesOnly() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		assertEq(fund.costBasis(address(tkn)), 2_000e6);
		_swap(fund, tkn, usdc, 500e6, 500e6); // a quarter sold
		assertEq(fund.costBasis(address(tkn)), 1_500e6);
		uint256 shares = _sharesOf(fund, alice) / 2;
		vm.prank(alice);
		vm.expectRevert(Comptroller.UseRedemptionQueue.selector);
		fund.redeemShares(shares);
		assertEq(fund.costBasis(address(tkn)), 1_500e6);
	}

	/// There is no in-kind exit (founder 2026-10-11: an investor leaves with USDC).
	function test_thereIsNoInKindExit() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		uint256 shares = _sharesOf(fund, alice) / 2;
		vm.startPrank(alice);
		(bool ok,) = address(fund).call(abi.encodeWithSignature('redeemSharesInKind(uint256)', shares));
		assertFalse(ok, 'no redeemSharesInKind');
		(ok,) = address(fund).call(
			abi.encodeWithSignature('redeemSharesInKindWithSkips(uint256,address[])', shares, new address[](0))
		);
		assertFalse(ok, 'no redeemSharesInKindWithSkips');
		vm.stopPrank();
		assertEq(_sharesOf(fund, alice), shares * 2);
		assertEq(fund.costBasis(address(tkn)), 2_000e6);
	}

	function test_thereIsNoInKindExitWithPositionsHeld() public {
		(Comptroller fund,) = _fundWithUnwindPosition();
		vm.prank(alice);
		(bool ok,) = address(fund).call(abi.encodeWithSignature('redeemSharesInKind(uint256)', uint256(1e18)));
		assertFalse(ok, 'no in-kind exit');
	}

	/// A price that can't be read sends the exit to the queue, whose settlement waits for it (the valuation is
	/// incomplete) and charges no performance fee meanwhile; once it reads, the fee settles.
	function test_anUnreadablePriceQueuesTheExitAndDefersTheFee() public {
		Comptroller fund = _fund(2_000);
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		wethFeed.setAnswer(3000e8); // +$1,000
		skip(2 hours); // WETH's feed is now stale

		uint256 small = _sharesOf(fund, alice) / 100;
		vm.prank(alice);
		vm.expectRevert(Comptroller.UseRedemptionQueue.selector);
		fund.redeemShares(small);
		(, bool complete) = mockQueue.settleFees(fund);
		assertFalse(complete, 'the queue waits for the price');
		assertEq(_sharesOf(fund, manager), 0, 'fee waits for a readable price');

		wethFeed.setAnswer(3000e8);
		fund.settleFees();
		assertGt(_sharesOf(fund, manager), 0, 'and settles once it reads');
	}

	function test_payOutRedemption_onlyTheQueue() public {
		Comptroller fund = _fund(0);
		vm.expectRevert(Comptroller.OnlyRedemptionQueue.selector);
		fund.payOutRedemption(alice, 1, 1);
	}

	function test_payOutRedemption_burnsTheEscrowAndPaysTheAmounts() public {
		Comptroller fund = _fund(0);
		uint256 half = _sharesOf(fund, alice) / 2;
		_escrow(fund, alice, half);
		uint256 supply = fund.shares().totalSupply();
		mockQueue.payOut(fund, alice, half, 5_000e6);
		assertEq(_sharesOf(fund, address(queue)), 0, 'escrow burned');
		assertEq(fund.shares().totalSupply(), supply - half);
		assertEq(usdc.balanceOf(alice), 5_000e6);
		assertEq(_held(fund, usdc), 5_000e6);
	}

	/// A payout is USDC only: the long-tail tokens and their cost basis stay.
	function test_payOutRedemption_paysUsdcAndLeavesTheLongTailCostBasis() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		uint256 shares = _sharesOf(fund, alice) / 4;
		_escrow(fund, alice, shares);
		mockQueue.payOut(fund, alice, shares, 500e6);
		assertEq(fund.costBasis(address(tkn)), 2_000e6);
		assertEq(_held(fund, tkn), 2_000e6);
		assertEq(tkn.balanceOf(alice), 0);
	}

	function test_liquidatePosition_onlyTheQueue() public {
		(Comptroller fund, MockUnwindPosition position) = _fundWithUnwindPosition();
		vm.expectRevert(Comptroller.OnlyRedemptionQueue.selector);
		fund.liquidatePosition(address(position), new address[](0), _one(abi.encode(uint8(1), abi.encode(uint256(1)))));
	}

	/// The keeper never opens risk (founder 2026-10-11): an action that isn't risk-reducing reverts, alone or after a valid close in the same batch.
	function test_liquidatePosition_refusesAnActionThatOpensRisk() public {
		(Comptroller fund, MockUnwindPosition position) = _fundWithUnwindPosition();
		vm.expectRevert(abi.encodeWithSelector(ComptrollerLib.NotRiskReducing.selector, uint8(0)));
		mockQueue.liquidatePosition(fund, address(position), new address[](0), _one(abi.encode(uint8(0), abi.encode(uint256(1)))));

		bytes[] memory batch = new bytes[](2);
		batch[0] = abi.encode(uint8(1), abi.encode(uint256(400e6))); // a close
		batch[1] = abi.encode(uint8(0), abi.encode(uint256(1))); // then an open
		vm.expectRevert(abi.encodeWithSelector(ComptrollerLib.NotRiskReducing.selector, uint8(0)));
		mockQueue.liquidatePosition(fund, address(position), new address[](0), batch);
	}

	/// On a perp account the keeper may close, cancel and return USDC; never open a trade, set an autopilot or add margin.
	function test_liquidatePosition_refusesPerpOpensAutopilotAndMargin() public {
		Comptroller fund = _fund(0);
		vm.prank(manager);
		MockPerpAccount account = MockPerpAccount(fund.createExternalPosition(PERP_TYPE, ''));
		uint8[3] memory opening = [uint8(VerantaPerpPosition.Action.OpenTrade), uint8(VerantaPerpPosition.Action.SetAutopilot), uint8(VerantaPerpPosition.Action.AddMargin)];
		for (uint256 i; i < opening.length; ++i) {
			vm.expectRevert(abi.encodeWithSelector(ComptrollerLib.NotRiskReducing.selector, opening[i]));
			mockQueue.liquidatePosition(fund, address(account), new address[](0), _one(abi.encode(opening[i], abi.encode(uint256(1)))));
		}
	}

	/// The keeper runs risk-reducing actions only: what isn't risk-reducing (here an LP-style unstake, decrease and collect)
	/// is refused, however the batch is ordered (2026-11-15: no priced pull-backs once LP positions were dropped).
	function test_liquidatePosition_refusesANonRiskReducingPullBack() public {
		Comptroller fund = _fund(0);
		MockLossyPosition position = _lossyPosition(fund, 1_000e6, 1e18);
		uint8[3] memory pullBacks = [uint8(6), uint8(2), uint8(3)];
		for (uint256 i; i < pullBacks.length; ++i) {
			vm.expectRevert(abi.encodeWithSelector(ComptrollerLib.NotRiskReducing.selector, pullBacks[i]));
			mockQueue.liquidatePosition(fund, address(position), new address[](0), _one(abi.encode(pullBacks[i], abi.encode(uint256(1)))));
		}
	}

	/// The perp account's ids the liquidation relies on: CloseTrade is 1 (the close of 0 check); the cancels and the
	/// return are risk-reducing.
	function test_perpActionIdsTheLiquidationRelies() public pure {
		assertEq(uint8(VerantaPerpPosition.Action.CloseTrade), 1);
		assertEq(uint8(VerantaPerpPosition.Action.CancelLimitOrder), 2);
		assertEq(uint8(VerantaPerpPosition.Action.CancelPendingMarketOrder), 3);
		assertEq(uint8(VerantaPerpPosition.Action.ReturnToVault), 6);
	}

	function test_liquidatePosition_refusesAPositionTheFundDoesNotHold() public {
		(Comptroller fund,) = _fundWithUnwindPosition();
		vm.expectRevert(abi.encodeWithSelector(Comptroller.NotActiveExternalPosition.selector, address(0xbeef)));
		mockQueue.liquidatePosition(fund, address(0xbeef), new address[](0), _one(abi.encode(uint8(1), abi.encode(uint256(1)))));
	}

	/// A risk-reducing batch (close, then return to the vault) runs unpriced, so stale feeds never stop it.
	function test_liquidatePosition_closesAndReturnsTheUsdcToTheVault() public {
		(Comptroller fund, MockUnwindPosition position) = _fundWithUnwindPosition();
		uint256 vaultBefore = _held(fund, usdc);
		skip(26 hours); // every feed stale
		bytes[] memory batch = new bytes[](2);
		batch[0] = abi.encode(uint8(1), abi.encode(uint256(400e6)));
		batch[1] = abi.encode(uint8(6), abi.encode(uint256(400e6)));
		mockQueue.liquidatePosition(fund, address(position), new address[](0), batch);
		assertEq(position.locked(), 3_600e6);
		assertEq(_held(fund, usdc), vaultBefore + 400e6);
		_refreshFeeds();
		assertEq(fund.calcGav(), 10_000e6, 'value only moved inside the fund');
	}

	/// The queue's one valuation per settlement: the GAV it pays from, and whether every price read.
	function test_settleFeesForRedemption_returnsTheSnapshotOfThatValuation() public {
		(Comptroller fund,) = _fundWithUnwindPosition(); // vault 6,000 USDC; position 4,000
		(uint256 gav, bool complete) = mockQueue.settleFees(fund);
		assertEq(gav, 10_000e6);
		assertTrue(complete);
	}


	// ─── the instant exit ────────────────────────────────────────────────────

	/// Short of USDC, the instant exit reverts and the shares stay: the queue is the way out.
	function test_theInstantExitNeedsTheUsdcInTheVault() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, weth, 9_000e6, 4.5e18); // 1,000 USDC + 4.5 WETH ($9,000)
		uint256 half = _sharesOf(fund, alice) / 2;
		vm.prank(alice);
		vm.expectRevert();
		fund.redeemShares(half);
		assertEq(_sharesOf(fund, alice), half * 2);
	}

	// ─── a balance that can't be read (D2) ───────────────────────────────────

	/// A token whose balance can't be read counts as $0 instead of stopping every exit and deposit, and counts again
	/// once it reads. Leavers meanwhile aren't paid for it (the founder's accepted cost of D2).
	function test_aTokenWhoseBalanceCannotBeReadCountsAsZero_untilItReads() public {
		Comptroller fund = _fund(0);
		BrokenBalanceToken brk = _brokenToken();
		_swap(fund, usdc, MockERC20(address(brk)), 1_000e6, 1e18); // 9,000 USDC + 1 BRK ($1,000)
		assertEq(fund.calcGav(), 10_000e6);

		brk.setBroken(true);
		assertEq(fund.calcGav(), 9_000e6, 'counted at $0, nothing reverts');
		_deposit(fund, bob, 900e6, type(uint256).max); // prices on it too
		uint256 tenth = _sharesOf(fund, alice) / 10;
		uint256 supply = fund.shares().totalSupply();
		vm.prank(alice);
		fund.redeemShares(tenth);
		assertEq(usdc.balanceOf(alice), 9_900e6 * tenth / supply, 'paid on the 9,900 that reads');

		brk.setBroken(false);
		assertEq(fund.calcGav(), 9_900e6 - usdc.balanceOf(alice) + 1_000e6, 'counted again');
	}

	// ─── overdue ─────────────────────────────────────────────────────────────

	/// While a redemption is overdue the manager may sell into USDC, never spend it, by trade or into a position.
	function test_whileOverdue_theManagerCantSpendTheVaultsUsdc() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		queue.setOverdue(address(fund), true);

		router.setNextAmountOut(0.5e18);
		vm.prank(manager);
		vm.expectRevert(Comptroller.UsdcSpentWhileOverdue.selector);
		fund.callOnIntegration(address(uniAdapter), abi.encode(address(usdc), address(weth), uint24(3000), 1_000e6, uint256(0)));

		_swap(fund, weth, usdc, 0.5e18, 1_000e6); // selling into USDC is fine

		vm.startPrank(manager);
		address position = fund.createExternalPosition(UNWIND_TYPE, '');
		(address[] memory assets, uint256[] memory amounts) = _usdc(100e6);
		vm.expectRevert(Comptroller.UsdcSpentWhileOverdue.selector);
		fund.callOnExternalPosition(position, assets, amounts, new address[](0), abi.encode(uint8(0), abi.encode(uint256(100e6))));
		vm.stopPrank();

		queue.setOverdue(address(fund), false); // paid: the manager trades as before
		_swap(fund, usdc, weth, 1_000e6, 0.5e18);
		assertEq(_held(fund, usdc), 8_000e6); // 10,000 - 2,000 + 1,000 - 1,000
	}

	// ─── a perp close of 0 ───────────────────────────────────────────────────

	/// Veranta takes a CloseTrade of 0, never fills it, and refuses the trade's other closes while it pends: refused
	/// from the manager and from a liquidation alike; a close of anything goes through.
	function test_aPerpCloseOfNothingIsRefused() public {
		Comptroller fund = _fund(0);
		vm.prank(manager);
		MockPerpAccount account = MockPerpAccount(fund.createExternalPosition(PERP_TYPE, ''));

		vm.prank(manager);
		vm.expectRevert(ComptrollerLib.CloseOfNothing.selector);
		fund.callOnExternalPosition(address(account), new address[](0), new uint256[](0), new address[](0), _close(0));
		vm.expectRevert(ComptrollerLib.CloseOfNothing.selector);
		mockQueue.liquidatePosition(fund, address(account), new address[](0), _one(_close(0)));

		vm.prank(manager);
		fund.callOnExternalPosition(address(account), new address[](0), new uint256[](0), new address[](0), _close(1));
		mockQueue.liquidatePosition(fund, address(account), new address[](0), _one(_close(2)));
		assertEq(account.closes(), 2);
		assertEq(account.lastCloseAmount(), 2);
	}

	/// The check is for the fund's perp accounts only: another position's action 1 of 0 goes through.
	function test_aCloseShapedActionOnAnotherPositionIsNotRefused() public {
		(Comptroller fund, MockUnwindPosition position) = _fundWithUnwindPosition();
		vm.prank(manager);
		fund.callOnExternalPosition(
			address(position), new address[](0), new uint256[](0), new address[](0),
			abi.encode(uint8(1), abi.encode(uint256(0), uint256(0), uint256(0), uint256(0)))
		);
		assertEq(position.locked(), 4_000e6);
	}

	// ─── liquidation trades ──────────────────────────────────────────────────

	function test_liquidateTrade_onlyTheQueue() public {
		Comptroller fund = _fund(0);
		vm.expectRevert(Comptroller.OnlyRedemptionQueue.selector);
		fund.liquidateTrade(address(uniAdapter), '');
	}

	function test_liquidateTrade_sellsIntoUsdc() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, weth, 2_000e6, 1e18); // 8,000 USDC + 1 WETH ($2,000)
		_liquidate(fund, weth, 1e18, 1_970e6); // 1.5% under the oracle
		assertEq(_held(fund, weth), 0);
		assertEq(_held(fund, usdc), 9_970e6);
	}

	/// D5: the investors who stay absorb at most 3% of what a liquidation sells.
	function test_liquidateTrade_losesAtMostThreePercent() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		router.setNextAmountOut(1_939e6);
		vm.expectRevert(abi.encodeWithSelector(ComptrollerLib.LiquidationLoss.selector, 61e6, 60e6));
		mockQueue.liquidateTrade(fund, address(uniAdapter), abi.encode(address(weth), address(usdc), uint24(3000), 1e18, uint256(0)));
		_liquidate(fund, weth, 1e18, 1_940e6); // exactly 3%
		assertEq(_held(fund, usdc), 9_940e6);
	}

	function test_liquidateTrade_onlySellsIntoTheDenomination() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		vm.expectRevert(ComptrollerLib.NotASale.selector);
		mockQueue.liquidateTrade(fund, address(uniAdapter), abi.encode(address(usdc), address(weth), uint24(3000), 1_000e6, uint256(0)));
		vm.expectRevert(ComptrollerLib.NotASale.selector);
		mockQueue.liquidateTrade(fund, address(uniAdapter), abi.encode(address(weth), address(tkn), uint24(3000), 1e18, uint256(0)));
	}

	/// Every adapter is single-hop: a long-tail token on a WETH pool sells into WETH (tracked), then WETH into USDC,
	/// each hop under the cap. Only a long-tail token may stop at a feed-priced asset.
	function test_liquidateTrade_aLongTailTokenSellsThroughItsPoolsQuote() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6); // 2,000 TKN ($1, pool-priced); WETH not tracked
		router.setNextAmountOut(0.99e18); // $1,980
		mockQueue.liquidateTrade(fund, address(uniAdapter), abi.encode(address(tkn), address(weth), uint24(3000), 2_000e6, uint256(0)));
		assertEq(_held(fund, weth), 0.99e18);
		address[] memory tracked = fund.getTrackedAssets();
		assertEq(tracked[tracked.length - 1], address(weth), 'WETH tracked: the next sale can take it');
		assertEq(fund.costBasis(address(tkn)), 0, 'the long-tail basis left with it');
		_liquidate(fund, weth, 0.99e18, 1_970e6);
		assertEq(_held(fund, usdc), 9_970e6);

		// a feed-priced token never stops at another feed-priced one
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		vm.expectRevert(ComptrollerLib.NotASale.selector);
		mockQueue.liquidateTrade(fund, address(uniAdapter), abi.encode(address(weth), address(tkn), uint24(3000), 1e18, uint256(0)));
	}

	/// The hop into the quote is capped too, at the quote's oracle value.
	function test_liquidateTrade_theHopIntoTheQuoteIsCapped() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		router.setNextAmountOut(0.96e18); // $1,920: 4% short
		vm.expectRevert(abi.encodeWithSelector(ComptrollerLib.LiquidationLoss.selector, 80e6, 60e6));
		mockQueue.liquidateTrade(fund, address(uniAdapter), abi.encode(address(tkn), address(weth), uint24(3000), 2_000e6, uint256(0)));
	}

	/// A sale through a pool with a recorded tax may lose that much more (founder 2026-11-15); the same sale on an untaxed
	/// route keeps 3%. With 2.9% recorded for the route: 7% short is refused at the 5.9% cap, 4% short goes through, and
	/// the same 4%-short sale through the plain adapter is refused.
	function test_liquidateTrade_aRoutesRecordedTaxRaisesTheCapForThatRouteOnly() public {
		Comptroller fund = _fund(0);
		MockSaleTaxAdapter taxed = _taxedAdapter(290);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6); // 2,000 TKN ($1, pool-priced)
		bytes memory sellTkn = abi.encode(address(tkn), address(weth), uint24(3000), 2_000e6, uint256(0));

		router.setNextAmountOut(0.93e18); // $1,860: 7% short
		vm.expectRevert(abi.encodeWithSelector(ComptrollerLib.LiquidationLoss.selector, 140e6, 118e6));
		mockQueue.liquidateTrade(fund, address(taxed), sellTkn);
		router.setNextAmountOut(0.96e18); // $1,920: 4% short
		vm.expectRevert(abi.encodeWithSelector(ComptrollerLib.LiquidationLoss.selector, 80e6, 60e6));
		mockQueue.liquidateTrade(fund, address(uniAdapter), sellTkn);
		mockQueue.liquidateTrade(fund, address(taxed), sellTkn);
		assertEq(_held(fund, weth), 0.96e18);
	}

	/// Whatever an adapter reports, the cap rises by at most 5% (MAX_SALE_TAX_BPS): reporting 9% still caps at 8%.
	function test_liquidateTrade_theTaxRaisesTheCapByAtMostFivePercent() public {
		Comptroller fund = _fund(0);
		MockSaleTaxAdapter taxed = _taxedAdapter(900);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		bytes memory sellTkn = abi.encode(address(tkn), address(weth), uint24(3000), 2_000e6, uint256(0));

		router.setNextAmountOut(0.9195e18); // $1,839: 8.05% short
		vm.expectRevert(abi.encodeWithSelector(ComptrollerLib.LiquidationLoss.selector, 161e6, 160e6));
		mockQueue.liquidateTrade(fund, address(taxed), sellTkn);
		router.setNextAmountOut(0.92e18); // $1,840: exactly 8%
		mockQueue.liquidateTrade(fund, address(taxed), sellTkn);
		assertEq(_held(fund, weth), 0.92e18);
	}

	function _taxedAdapter(uint256 taxBps) internal returns (MockSaleTaxAdapter taxed) {
		taxed = new MockSaleTaxAdapter(IUniswapV3SwapRouter(address(router)));
		taxed.setTax(taxBps);
		factory.registerAdapter(address(taxed));
	}

	function test_liquidateTrade_refusesAnUnregisteredAdapter() public {
		Comptroller fund = _fund(0);
		vm.expectRevert(abi.encodeWithSelector(Comptroller.AdapterNotRegistered.selector, address(0xbeef)));
		mockQueue.liquidateTrade(fund, address(0xbeef), '');
	}

	function test_liquidateTrade_aSoldLongTailTokenTakesItsCostBasis() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		_liquidate(fund, tkn, 500e6, 500e6);
		assertEq(fund.costBasis(address(tkn)), 1_500e6);
	}

	/// A sale is checked against the oracle, so a token whose price can't be read now can't be sold until it reads.
	function test_liquidateTrade_needsThePriceOfWhatItSells() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		skip(2 hours); // WETH's feed stale
		router.setNextAmountOut(2_000e6);
		vm.expectRevert();
		mockQueue.liquidateTrade(fund, address(uniAdapter), abi.encode(address(weth), address(usdc), uint24(3000), 1e18, uint256(0)));
	}

	// ─── liquidation of positions ────────────────────────────────────────────

	/// What a batch returns to the vault counts as kept, and the tokens listed to receive are tracked.
	function test_liquidatePosition_tracksWhatReachesTheVault() public {
		Comptroller fund = _fund(0);
		address order = _wethInAnEscrow(fund);
		address[] memory receive_ = new address[](1);
		receive_[0] = address(weth);
		bytes[] memory batch = new bytes[](2);
		batch[0] = abi.encode(uint8(1), abi.encode(uint256(1)));
		batch[1] = abi.encode(uint8(2), abi.encode(address(weth), uint256(1e18)));
		mockQueue.liquidatePosition(fund, order, receive_, batch);
		assertEq(_held(fund, weth), 1e18);
		address[] memory tracked = fund.getTrackedAssets();
		assertEq(tracked[tracked.length - 1], address(weth), 'tracked: the keeper can sell it next');
	}

	// ─── nothing a position returns drops out of GAV (review 2026-10-11) ────────

	/// @dev The attack's setup: 1 WETH ($2,000) rests in an escrow position (an order), and the manager untracks WETH (the vault holds none).
	function _wethInAnEscrow(Comptroller fund) internal returns (address order) {
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		vm.startPrank(manager);
		order = fund.createExternalPosition(ESCROW_TYPE, '');
		address[] memory assets = new address[](1);
		uint256[] memory amounts = new uint256[](1);
		assets[0] = address(weth);
		amounts[0] = 1e18;
		fund.callOnExternalPosition(order, assets, amounts, new address[](0),
			abi.encode(uint8(0), abi.encode(address(weth), address(usdc), uint128(1e18), uint128(2_000e6), uint64(block.timestamp + 1 days))));
		fund.removeTrackedAsset(address(weth));
		vm.stopPrank();
	}

	/// A manager returning the WETH without listing it can't drop it out of GAV (and so can't settle the queue lower).
	function test_aManagersUnlistedReturnStillCountsInGav() public {
		Comptroller fund = _fund(0);
		address order = _wethInAnEscrow(fund);
		uint256 gavBefore = fund.calcGav();
		vm.startPrank(manager);
		fund.callOnExternalPosition(order, new address[](0), new uint256[](0), new address[](0), abi.encode(uint8(1), abi.encode(uint256(1))));
		fund.callOnExternalPosition(order, new address[](0), new uint256[](0), new address[](0), abi.encode(uint8(2), abi.encode(address(weth), uint256(1e18))));
		vm.stopPrank();
		assertEq(_held(fund, weth), 1e18, 'in the vault');
		assertEq(fund.calcGav(), gavBefore, 'and still counted');
	}

	/// The same through a liquidation: the keeper's unlisted return still counts.
	function test_aKeepersUnlistedReturnStillCountsInGav() public {
		Comptroller fund = _fund(0);
		address order = _wethInAnEscrow(fund);
		uint256 gavBefore = fund.calcGav();
		bytes[] memory batch = new bytes[](2);
		batch[0] = abi.encode(uint8(1), abi.encode(uint256(1)));
		batch[1] = abi.encode(uint8(2), abi.encode(address(weth), uint256(1e18)));
		mockQueue.liquidatePosition(fund, order, new address[](0), batch);
		assertEq(_held(fund, weth), 1e18, 'in the vault');
		assertEq(fund.calcGav(), gavBefore, 'and still counted');
	}

	/// A position whose holdings can't be read now (a perp account on a stale price) still closes, for the manager and
	/// the keeper: a cut in risk never waits on a price.
	function test_aPositionWhoseHoldingsCantBeReadStillCloses() public {
		Comptroller fund = _fund(0);
		vm.prank(manager);
		MockUnreadablePosition position = MockUnreadablePosition(fund.createExternalPosition(UNREADABLE_TYPE, ''));
		position.setUnreadable(true);
		vm.prank(manager);
		fund.callOnExternalPosition(address(position), new address[](0), new uint256[](0), new address[](0), abi.encode(uint8(1), ''));
		mockQueue.liquidatePosition(fund, address(position), new address[](0), _one(abi.encode(uint8(1), '')));
		assertEq(position.closes(), 2);
	}

	// ─── a full tracked set never blocks a liquidation (red-team POSITIONS-01 / EXITADAPTERS-01, 2026-10-27) ──

	/// @dev Tracks fresh $1 primitives until the fund tracks MAX_TRACKED_ASSETS.
	function _fillTrackedSet(Comptroller fund) internal {
		while (fund.getTrackedAssets().length < fund.MAX_TRACKED_ASSETS()) {
			MockERC20 t = new MockERC20('T', 'T', 18);
			registrar.execute(
				abi.encodeCall(ValueInterpreter.addPrimitive, (address(t), address(new MockAggregator(8, 1e8)), uint32(25 hours)))
			);
			vm.prank(manager);
			fund.addTrackedAsset(address(t));
		}
	}

	/// @dev 1,000 USDC resting in an escrow position (an order for WETH) (untracked), the set full, and 1 wei of WETH donated to the
	///      position (anyone can; a taker's fill does the same).
	function _fullSetWithADonatedOrder(Comptroller fund) internal returns (address order) {
		vm.startPrank(manager);
		order = fund.createExternalPosition(ESCROW_TYPE, '');
		(address[] memory assets, uint256[] memory amounts) = _usdc(1_000e6);
		fund.callOnExternalPosition(order, assets, amounts, new address[](0),
			abi.encode(uint8(0), abi.encode(address(usdc), address(weth), uint128(1_000e6), uint128(0.5e18), uint64(block.timestamp + 1 days))));
		vm.stopPrank();
		_fillTrackedSet(fund);
		weth.mint(order, 1);
	}

	function _cancelAndReturn() internal view returns (bytes[] memory batch) {
		batch = new bytes[](2);
		batch[0] = abi.encode(uint8(1), abi.encode(uint256(1))); // CancelOrder(1)
		batch[1] = abi.encode(uint8(2), abi.encode(address(usdc), uint256(1_000e6))); // ReturnToVault
	}

	/// What the manager tracks keeps the cap.
	function test_aFullTrackedSetRefusesTheManagersNextTrack() public {
		Comptroller fund = _fund(0);
		_fillTrackedSet(fund);
		vm.prank(manager);
		vm.expectRevert(ComptrollerLib.TrackedAssetsLimitReached.selector);
		fund.addTrackedAsset(address(weth));
	}

	/// The keeper cancels and returns the order at a full set: the donated WETH is tracked past the cap and counted.
	function test_aFullTrackedSetDoesNotBlockTheKeepersPullBack() public {
		Comptroller fund = _fund(0);
		address order = _fullSetWithADonatedOrder(fund);
		uint256 vaultUsdc = _held(fund, usdc);
		mockQueue.liquidatePosition(fund, order, new address[](0), _cancelAndReturn());
		assertEq(_held(fund, usdc), vaultUsdc + 1_000e6, 'the order came back to the vault');
		address[] memory tracked = fund.getTrackedAssets();
		uint256 max = fund.MAX_TRACKED_ASSETS();
		assertEq(tracked.length, max + 1);
		assertEq(tracked[max], address(weth), 'what the position holds is tracked');
	}

	/// The manager's own action on the position isn't blocked either.
	function test_aFullTrackedSetDoesNotBlockTheManagersPositionAction() public {
		Comptroller fund = _fund(0);
		address order = _fullSetWithADonatedOrder(fund);
		vm.prank(manager);
		fund.callOnExternalPosition(order, new address[](0), new uint256[](0), new address[](0), _cancelAndReturn()[0]);
		assertEq(fund.getTrackedAssets().length, fund.MAX_TRACKED_ASSETS() + 1);
		assertEq(MockEscrowPosition(order).committed(address(usdc)), 0, 'cancelled');
	}

	/// EXITADAPTERS-01: at a full set the keeper's sale of a long-tail token into its pool's WETH quote goes through
	/// (WETH is tracked past the cap), and the next sale takes the WETH to USDC. It sells half the token, so the token
	/// stays listed and WETH is the one past the cap (a sale that empties a token takes it off, founder 2026-11-05).
	function test_aFullTrackedSetStillTakesTheLongTailSaleIntoItsQuote() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6); // WETH not tracked
		_fillTrackedSet(fund);
		router.setNextAmountOut(0.495e18); // $990
		mockQueue.liquidateTrade(fund, address(uniAdapter), abi.encode(address(tkn), address(weth), uint24(3000), 1_000e6, uint256(0)));
		assertEq(fund.getTrackedAssets().length, fund.MAX_TRACKED_ASSETS() + 1, 'WETH tracked past the cap');
		_liquidate(fund, weth, 0.495e18, 985e6);
		assertEq(_held(fund, usdc), 8_985e6);
	}

	// ─── a sale that empties a token takes it off the tracked list (founder 2026-11-05, Melon v1's auto-prune) ──

	event TrackedAssetRemoved(address indexed asset);

	function _isTracked(Comptroller fund, address asset) internal view returns (bool) {
		address[] memory tracked = fund.getTrackedAssets();
		for (uint256 i; i < tracked.length; ++i) {
			if (tracked[i] == asset) return true;
		}
		return false;
	}

	/// The manager sells all of a token: it leaves the list in that trade, with the event a manual removal emits, from the fund.
	function test_aSaleThatEmptiesATokenTakesItOffTheList() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		router.setNextAmountOut(2_000e6);
		vm.expectEmit(address(fund));
		emit TrackedAssetRemoved(address(weth));
		vm.prank(manager);
		fund.callOnIntegration(address(uniAdapter), abi.encode(address(weth), address(usdc), uint24(3000), 1e18, uint256(0)));
		assertFalse(_isTracked(fund, address(weth)));
	}

	/// A sale that leaves even 1 wei keeps the token, as a manual removal would.
	function test_aSaleThatLeavesAWeiKeepsTheToken() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		_swap(fund, weth, usdc, 1e18 - 1, 2_000e6);
		assertTrue(_isTracked(fund, address(weth)));
	}

	/// USDC never leaves, even when a buy spends all of it.
	function test_aBuyThatSpendsAllTheUsdcKeepsItListed() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, weth, _held(fund, usdc), 5e18);
		assertEq(_held(fund, usdc), 0);
		assertTrue(_isTracked(fund, address(usdc)));
	}

	/// The keeper's sale for the queue does the same.
	function test_aKeeperSaleThatEmptiesATokenTakesItOffTheList() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		_liquidate(fund, weth, 1e18, 1_990e6);
		assertFalse(_isTracked(fund, address(weth)));
	}

	/// What anyone sends to a sold token afterwards isn't counted and doesn't put the token back on the list.
	function test_whatIsSentToASoldTokenIsNotCounted() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		_swap(fund, weth, usdc, 1e18, 2_000e6);
		uint256 gavBefore = fund.calcGav();
		weth.mint(address(fund.vault()), 1e18);
		assertEq(fund.calcGav(), gavBefore);
		assertFalse(_isTracked(fund, address(weth)));
	}

	/// A token moved into a position isn't sold: it stays listed, so it counts when it comes back.
	function test_aTokenMovedIntoAPositionStaysListed() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		address[] memory assets = new address[](1);
		uint256[] memory amounts = new uint256[](1);
		assets[0] = address(weth);
		amounts[0] = 1e18;
		vm.startPrank(manager);
		address order = fund.createExternalPosition(ESCROW_TYPE, '');
		fund.callOnExternalPosition(order, assets, amounts, new address[](0),
			abi.encode(uint8(0), abi.encode(address(weth), address(usdc), uint128(1e18), uint128(2_000e6), uint64(block.timestamp + 1 days))));
		vm.stopPrank();
		assertEq(_held(fund, weth), 0);
		assertTrue(_isTracked(fund, address(weth)));
	}

	/// A sold token bought again is tracked again.
	function test_aSoldTokenBoughtAgainIsTrackedAgain() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		_swap(fund, weth, usdc, 1e18, 2_000e6);
		assertFalse(_isTracked(fund, address(weth)), 'sold');
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		assertTrue(_isTracked(fund, address(weth)), 'bought again');
	}

	/// The NVDA case (founder 2026-11-04): a fund that has traded through more tokens than the limit can still buy, because
	/// only what it holds counts.
	function test_aFundThatTradedThroughMoreTokensThanTheLimitCanStillBuy() public {
		Comptroller fund = _fund(0);
		uint256 rounds = fund.MAX_TRACKED_ASSETS() + 5;
		for (uint256 i; i < rounds; ++i) {
			MockERC20 t = new MockERC20('T', 'T', 18);
			registrar.execute(
				abi.encodeCall(ValueInterpreter.addPrimitive, (address(t), address(new MockAggregator(8, 1e8)), uint32(25 hours)))
			);
			_swap(fund, usdc, t, 100e6, 100e18);
			_swap(fund, t, usdc, 100e18, 100e6);
		}
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		assertEq(fund.getTrackedAssets().length, 2, 'USDC and WETH');
	}

	/// The limit is 30 (founder 2026-11-05), USDC included; the 31st is refused (test_aFullTrackedSetRefusesTheManagersNextTrack).
	function test_aFundTracksThirtyTokens() public {
		Comptroller fund = _fund(0);
		_fillTrackedSet(fund);
		assertEq(fund.getTrackedAssets().length, 30);
	}
}
