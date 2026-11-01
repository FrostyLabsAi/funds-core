// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ComptrollerBlueprintDeployer} from '../src/core/FundComponentDeployers.sol';
import {ComptrollerV6} from '../src/core/ComptrollerV6.sol';
import {ComptrollerV3Lib} from '../src/core/ComptrollerV3Lib.sol';
import {ComptrollerV6Lib} from '../src/core/ComptrollerV6Lib.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {Shares} from '../src/fund/Shares.sol';
import {IExternalPosition} from '../src/interfaces/IExternalPosition.sol';
import {IExternalPositionTypeFactory} from '../src/interfaces/IExternalPositionTypeFactory.sol';
import {ComptrollerV6Base} from './ComptrollerV6Base.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';
import {MockUnwindPosition} from './utils/MockUnwindPosition.sol';
import {LimitOrderPosition, LimitOrderPositionFactory} from '../src/positions/LimitOrderPosition.sol';
import {SlipstreamLPPosition} from '../src/positions/SlipstreamLPPosition.sol';
import {SlipstreamLPPositionV2} from '../src/positions/SlipstreamLPPositionV2.sol';
import {UniswapV3LPPosition} from '../src/positions/UniswapV3LPPosition.sol';
import {VerantaPerpPositionV2} from '../src/positions/VerantaPerpPositionV2.sol';
import {VerantaPerpPositionV3} from '../src/positions/VerantaPerpPositionV3.sol';
import {VerantaPerpPositionV4} from '../src/positions/VerantaPerpPositionV4.sol';
import {MockRedemptionQueueV6, MockPerpAccount, MockPerpAccountFactory} from './utils/MockRedemptionQueueV6.sol';

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
		else if (action == 3) weth.transfer(address(ComptrollerV6(comptroller).vault()), amount); // an LP collect
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

/// @notice Fund version 6 = version 3 with a USDC-only exit (founder 2026-10-11, PLAN_CASH_ONLY_EXIT_2026-10-11.md).
///         The whole V3 suite runs here against V6; the tests whose behavior V6 changes are overridden below, then
///         V6's own: the instant exit, unreadable balances, the overdue USDC lock, the perp close of 0, liquidation.
contract ComptrollerV6Test is ComptrollerV6Base {
	uint256 internal constant PERP_TYPE = 98;
	uint256 internal constant LOSSY_TYPE = 97;
	uint256 internal constant LIMIT_TYPE = 95;
	uint256 internal constant UNREADABLE_TYPE = 94;
	MockRedemptionQueueV6 internal queueV6;
	MockPerpAccountFactory internal perpConfig;

	function setUp() public virtual override {
		super.setUp();
		queueV6 = new MockRedemptionQueueV6();
		queue = queueV6;
		perpConfig = new MockPerpAccountFactory(IERC20(address(usdc)));
		factory.registerPositionType(PERP_TYPE, address(perpConfig));
		factory.registerPositionType(LOSSY_TYPE, address(new MockLossyPositionFactory(IERC20(address(usdc)), IERC20(address(weth)))));
		factory.registerPositionType(LIMIT_TYPE, address(new LimitOrderPositionFactory()));
		factory.registerPositionType(UNREADABLE_TYPE, address(new MockUnreadablePositionFactory()));
		factory.setComptrollerDeployer(
			new ComptrollerBlueprintDeployer(type(ComptrollerV6).creationCode, abi.encode(registrar, queueV6, perpConfig))
		);
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	function _v6(ComptrollerV6 fund) internal pure returns (ComptrollerV6) {
		return ComptrollerV6(address(fund));
	}

	function _escrow(ComptrollerV6 fund, address who, uint256 shares) internal {
		Shares fundShares = fund.shares();
		vm.prank(who);
		fundShares.transfer(address(queue), shares);
	}

	/// @dev The keeper's sale of `amountIn` of `tokenIn` into USDC, filled at `usdcOut`.
	function _liquidate(ComptrollerV6 fund, MockERC20 tokenIn, uint256 amountIn, uint256 usdcOut) internal {
		router.setNextAmountOut(usdcOut);
		queueV6.liquidateTrade(
			_v6(fund), address(uniAdapter), abi.encode(address(tokenIn), address(usdc), uint24(3000), amountIn, uint256(0))
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

	function _lossyPosition(ComptrollerV6 fund, uint256 usdcIn, uint256 wethIn) internal returns (MockLossyPosition position) {
		vm.startPrank(manager);
		position = MockLossyPosition(fund.createExternalPosition(LOSSY_TYPE, ''));
		(address[] memory assets, uint256[] memory amounts) = _usdc(usdcIn);
		fund.callOnExternalPosition(address(position), assets, amounts, new address[](0), abi.encode(uint8(0), abi.encode(uint256(0))));
		vm.stopPrank();
		weth.mint(address(position), wethIn);
	}

	// ─── V3 behavior V6 changes ──────────────────────────────────────────────────

	/// V6 pays no token in kind: holding a long-tail token sends the exit through the queue; sold, it exits at once.
	function test_v6_aLongTailHoldingSendsTheExitToTheQueueUntilSold() public {
		ComptrollerV6 fund = _fund(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6); // 8,000 USDC + 2,000 TKN ($1)
		uint256 half = _sharesOf(fund, alice) / 2;
		vm.prank(alice);
		vm.expectRevert(ComptrollerV6.UseRedemptionQueue.selector);
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
		ComptrollerV6 fund = _fund(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		_setTknPriceTick(23028); // TKN's pool pumped to $10 for the whole window
		uint256 shares = _sharesOf(fund, alice) / 4;
		vm.prank(alice);
		vm.expectRevert(ComptrollerV6.UseRedemptionQueue.selector);
		fund.redeemShares(shares);
		assertEq(usdc.balanceOf(alice), 0);
	}

	/// A price that can't be read now sends the exit through the queue; once it reads, the exit pays it in USDC.
	function test_v6_anUnreadablePriceSendsTheExitToTheQueueUntilItReads() public {
		ComptrollerV6 fund = _fund(0);
		_swap(fund, usdc, weth, 2_000e6, 1e18); // 8,000 USDC + 1 WETH
		skip(2 hours); // WETH's 1-hour feed is now stale; USDC's 25-hour one is not
		uint256 half = _sharesOf(fund, alice) / 2;
		vm.prank(alice);
		vm.expectRevert(ComptrollerV6.UseRedemptionQueue.selector);
		fund.redeemShares(half);

		wethFeed.setAnswer(2000e8);
		vm.prank(alice);
		fund.redeemShares(half);
		assertApproxEqRel(usdc.balanceOf(alice), 5_000e6, 1e15, 'half of 10,000, all USDC');
		assertEq(weth.balanceOf(alice), 0);
	}

	/// Exits never pay a token, so a long-tail cost basis moves only with trades.
	function test_v6_costBasisFollowsBuysAndSalesOnly() public {
		ComptrollerV6 fund = _fund(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		assertEq(fund.costBasis(address(tkn)), 2_000e6);
		_swap(fund, tkn, usdc, 500e6, 500e6); // a quarter sold
		assertEq(fund.costBasis(address(tkn)), 1_500e6);
		uint256 shares = _sharesOf(fund, alice) / 2;
		vm.prank(alice);
		vm.expectRevert(ComptrollerV6.UseRedemptionQueue.selector);
		fund.redeemShares(shares);
		assertEq(fund.costBasis(address(tkn)), 1_500e6);
	}

	/// V6 has no in-kind exit (founder 2026-10-11: an investor leaves with USDC).
	function test_v6_thereIsNoInKindExit() public {
		ComptrollerV6 fund = _fund(0);
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

	function test_v6_thereIsNoInKindExitWithPositionsHeld() public {
		(ComptrollerV6 fund,) = _fundWithUnwindPosition();
		vm.prank(alice);
		(bool ok,) = address(fund).call(abi.encodeWithSignature('redeemSharesInKind(uint256)', uint256(1e18)));
		assertFalse(ok, 'no in-kind exit');
	}

	/// A price that can't be read sends the exit to the queue, whose settlement waits for it (the valuation is
	/// incomplete) and charges no performance fee meanwhile; once it reads, the fee settles.
	function test_v6_anUnreadablePriceQueuesTheExitAndDefersTheFee() public {
		ComptrollerV6 fund = _fund(2_000);
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		wethFeed.setAnswer(3000e8); // +$1,000
		skip(2 hours); // WETH's feed is now stale

		uint256 small = _sharesOf(fund, alice) / 100;
		vm.prank(alice);
		vm.expectRevert(ComptrollerV6.UseRedemptionQueue.selector);
		fund.redeemShares(small);
		(, bool complete) = queueV6.settleFeesV6(_v6(fund));
		assertFalse(complete, 'the queue waits for the price');
		assertEq(_sharesOf(fund, manager), 0, 'fee waits for a readable price');

		wethFeed.setAnswer(3000e8);
		fund.settleFees();
		assertGt(_sharesOf(fund, manager), 0, 'and settles once it reads');
	}

	function test_payOutRedemption_onlyTheQueue() public {
		ComptrollerV6 fund = _v6(_fund(0));
		vm.expectRevert(ComptrollerV6.OnlyRedemptionQueue.selector);
		fund.payOutRedemption(alice, 1, 1);
	}

	function test_payOutRedemption_burnsTheEscrowAndPaysTheAmounts() public {
		ComptrollerV6 fund = _fund(0);
		uint256 half = _sharesOf(fund, alice) / 2;
		_escrow(fund, alice, half);
		uint256 supply = fund.shares().totalSupply();
		queueV6.payOutV6(_v6(fund), alice, half, 5_000e6);
		assertEq(_sharesOf(fund, address(queue)), 0, 'escrow burned');
		assertEq(fund.shares().totalSupply(), supply - half);
		assertEq(usdc.balanceOf(alice), 5_000e6);
		assertEq(_held(fund, usdc), 5_000e6);
	}

	/// A payout is USDC only: the long-tail tokens and their cost basis stay.
	function test_v6_payOutRedemption_paysUsdcAndLeavesTheLongTailCostBasis() public {
		ComptrollerV6 fund = _fund(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		uint256 shares = _sharesOf(fund, alice) / 4;
		_escrow(fund, alice, shares);
		queueV6.payOutV6(_v6(fund), alice, shares, 500e6);
		assertEq(fund.costBasis(address(tkn)), 2_000e6);
		assertEq(_held(fund, tkn), 2_000e6);
		assertEq(tkn.balanceOf(alice), 0);
	}

	function test_v6_liquidatePosition_onlyTheQueue() public {
		(ComptrollerV6 fund, MockUnwindPosition position) = _fundWithUnwindPosition();
		vm.expectRevert(ComptrollerV6.OnlyRedemptionQueue.selector);
		_v6(fund).liquidatePosition(address(position), new address[](0), _one(abi.encode(uint8(1), abi.encode(uint256(1)))));
	}

	/// The keeper never opens risk (founder 2026-10-11): an action that is neither risk-reducing nor an LP pull-back
	/// reverts, alone or after a valid close in the same batch.
	function test_v6_liquidatePosition_refusesAnActionThatOpensRisk() public {
		(ComptrollerV6 fund, MockUnwindPosition position) = _fundWithUnwindPosition();
		vm.expectRevert(abi.encodeWithSelector(ComptrollerV6Lib.NotAPullBack.selector, uint8(0)));
		queueV6.liquidatePosition(_v6(fund), address(position), new address[](0), _one(abi.encode(uint8(0), abi.encode(uint256(1)))));

		bytes[] memory batch = new bytes[](2);
		batch[0] = abi.encode(uint8(1), abi.encode(uint256(400e6))); // a close
		batch[1] = abi.encode(uint8(0), abi.encode(uint256(1))); // then an open
		vm.expectRevert(abi.encodeWithSelector(ComptrollerV6Lib.NotAPullBack.selector, uint8(0)));
		queueV6.liquidatePosition(_v6(fund), address(position), new address[](0), batch);
	}

	/// On a perp account the keeper may close, cancel and return USDC; never open a trade, set an autopilot or add margin.
	function test_v6_liquidatePosition_refusesPerpOpensAutopilotAndMargin() public {
		ComptrollerV6 fund = _fund(0);
		vm.prank(manager);
		MockPerpAccount account = MockPerpAccount(fund.createExternalPosition(PERP_TYPE, ''));
		uint8[3] memory opening = [uint8(VerantaPerpPositionV4.Action.OpenTrade), uint8(VerantaPerpPositionV4.Action.SetAutopilot), uint8(VerantaPerpPositionV4.Action.AddMargin)];
		for (uint256 i; i < opening.length; ++i) {
			vm.expectRevert(abi.encodeWithSelector(ComptrollerV6Lib.NotAPullBack.selector, opening[i]));
			queueV6.liquidatePosition(_v6(fund), address(account), new address[](0), _one(abi.encode(opening[i], abi.encode(uint256(1)))));
		}
	}

	/// An LP's pull-back (unstake, decrease, collect; every live LP answers isRiskReducing false for them) runs priced.
	function test_v6_liquidatePosition_lpPullBacksRunPriced() public {
		ComptrollerV6 fund = _fund(0);
		MockLossyPosition position = _lossyPosition(fund, 1_000e6, 1e18);
		bytes[] memory batch = new bytes[](3);
		batch[0] = abi.encode(uint8(6), abi.encode(uint256(0))); // unstake
		batch[1] = abi.encode(uint8(2), abi.encode(uint256(10e6))); // a decrease that loses 10 USDC
		batch[2] = abi.encode(uint8(3), abi.encode(uint256(1e18))); // collect the WETH to the vault
		address[] memory receive_ = new address[](1);
		receive_[0] = address(weth);
		vm.expectEmit(address(fund));
		emit ComptrollerV6Lib.PositionLiquidated(address(position), 3, 10e6);
		queueV6.liquidatePosition(_v6(fund), address(position), receive_, batch);
		assertEq(_held(fund, weth), 1e18);
	}

	/// The pull-back ids (2, 3, 6) on every live position type: an LP's decrease, collect and unstake; a perp account's
	/// risk-reducing cancels and return; a limit-order position's return (3 and 6 don't exist there or on a Uniswap LP).
	function test_v6_pullBackIdsMatchEveryLivePositionType() public pure {
		assertEq(uint8(SlipstreamLPPositionV2.Action.DecreaseLiquidity), 2);
		assertEq(uint8(SlipstreamLPPositionV2.Action.Collect), 3);
		assertEq(uint8(SlipstreamLPPositionV2.Action.Unstake), 6);
		assertEq(uint8(SlipstreamLPPosition.Action.DecreaseLiquidity), 2);
		assertEq(uint8(SlipstreamLPPosition.Action.Collect), 3);
		assertEq(uint8(SlipstreamLPPosition.Action.Unstake), 6);
		assertEq(uint8(UniswapV3LPPosition.Action.DecreaseLiquidity), 2);
		assertEq(uint8(UniswapV3LPPosition.Action.Collect), 3);
		assertEq(uint8(type(UniswapV3LPPosition.Action).max), 5);

		assertEq(uint8(VerantaPerpPositionV4.Action.CancelLimitOrder), 2);
		assertEq(uint8(VerantaPerpPositionV4.Action.CancelPendingMarketOrder), 3);
		assertEq(uint8(VerantaPerpPositionV4.Action.ReturnToVault), 6);
		assertEq(uint8(VerantaPerpPositionV3.Action.CancelLimitOrder), 2);
		assertEq(uint8(VerantaPerpPositionV3.Action.CancelPendingMarketOrder), 3);
		assertEq(uint8(VerantaPerpPositionV3.Action.ReturnToVault), 6);
		assertEq(uint8(VerantaPerpPositionV2.Action.CancelLimitOrder), 2);
		assertEq(uint8(VerantaPerpPositionV2.Action.CancelPendingMarketOrder), 3);
		assertEq(uint8(VerantaPerpPositionV2.Action.ReturnToVault), 6);

		assertEq(uint8(LimitOrderPosition.Action.ReturnToVault), 2);
		assertEq(uint8(type(LimitOrderPosition.Action).max), 2);
	}

	function test_v6_liquidatePosition_refusesAPositionTheFundDoesNotHold() public {
		(ComptrollerV6 fund,) = _fundWithUnwindPosition();
		vm.expectRevert(abi.encodeWithSelector(ComptrollerV6.NotActiveExternalPosition.selector, address(0xbeef)));
		queueV6.liquidatePosition(_v6(fund), address(0xbeef), new address[](0), _one(abi.encode(uint8(1), abi.encode(uint256(1)))));
	}

	/// A risk-reducing batch (close, then return to the vault) runs unpriced, so stale feeds never stop it.
	function test_v6_liquidatePosition_closesAndReturnsTheUsdcToTheVault() public {
		(ComptrollerV6 fund, MockUnwindPosition position) = _fundWithUnwindPosition();
		uint256 vaultBefore = _held(fund, usdc);
		skip(26 hours); // every feed stale
		bytes[] memory batch = new bytes[](2);
		batch[0] = abi.encode(uint8(1), abi.encode(uint256(400e6)));
		batch[1] = abi.encode(uint8(6), abi.encode(uint256(400e6)));
		queueV6.liquidatePosition(_v6(fund), address(position), new address[](0), batch);
		assertEq(position.locked(), 3_600e6);
		assertEq(_held(fund, usdc), vaultBefore + 400e6);
		_refreshFeeds();
		assertEq(fund.calcGav(), 10_000e6, 'value only moved inside the fund');
	}

	/// The queue's one valuation per settlement: the GAV it pays from, and whether every price read.
	function test_settleFeesForRedemption_returnsTheSnapshotOfThatValuation() public {
		(ComptrollerV6 fund,) = _fundWithUnwindPosition(); // vault 6,000 USDC; position 4,000
		(uint256 gav, bool complete) = queueV6.settleFeesV6(_v6(fund));
		assertEq(gav, 10_000e6);
		assertTrue(complete);
	}

	// ─── V3 tests that don't apply to V6 (their names say what V3 does; each points to V6's own test) ────

	// ─── V6: the instant exit ────────────────────────────────────────────────────

	/// Short of USDC, the instant exit reverts and the shares stay: the queue is the way out.
	function test_v6_theInstantExitNeedsTheUsdcInTheVault() public {
		ComptrollerV6 fund = _fund(0);
		_swap(fund, usdc, weth, 9_000e6, 4.5e18); // 1,000 USDC + 4.5 WETH ($9,000)
		uint256 half = _sharesOf(fund, alice) / 2;
		vm.prank(alice);
		vm.expectRevert();
		fund.redeemShares(half);
		assertEq(_sharesOf(fund, alice), half * 2);
	}

	// ─── V6: a balance that can't be read (D2) ───────────────────────────────────

	/// A token whose balance can't be read counts as $0 instead of stopping every exit and deposit, and counts again
	/// once it reads. Leavers meanwhile aren't paid for it (the founder's accepted cost of D2).
	function test_v6_aTokenWhoseBalanceCannotBeReadCountsAsZero_untilItReads() public {
		ComptrollerV6 fund = _fund(0);
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

	// ─── V6: overdue ─────────────────────────────────────────────────────────────

	/// While a redemption is overdue the manager may sell into USDC, never spend it, by trade or into a position.
	function test_v6_whileOverdue_theManagerCantSpendTheVaultsUsdc() public {
		ComptrollerV6 fund = _fund(0);
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		queue.setOverdue(address(fund), true);

		router.setNextAmountOut(0.5e18);
		vm.prank(manager);
		vm.expectRevert(ComptrollerV6.UsdcSpentWhileOverdue.selector);
		fund.callOnIntegration(address(uniAdapter), abi.encode(address(usdc), address(weth), uint24(3000), 1_000e6, uint256(0)));

		_swap(fund, weth, usdc, 0.5e18, 1_000e6); // selling into USDC is fine

		vm.startPrank(manager);
		address position = fund.createExternalPosition(UNWIND_TYPE, '');
		(address[] memory assets, uint256[] memory amounts) = _usdc(100e6);
		vm.expectRevert(ComptrollerV6.UsdcSpentWhileOverdue.selector);
		fund.callOnExternalPosition(position, assets, amounts, new address[](0), abi.encode(uint8(0), abi.encode(uint256(100e6))));
		vm.stopPrank();

		queue.setOverdue(address(fund), false); // paid: the manager trades as before
		_swap(fund, usdc, weth, 1_000e6, 0.5e18);
		assertEq(_held(fund, usdc), 8_000e6); // 10,000 - 2,000 + 1,000 - 1,000
	}

	// ─── V6: a perp close of 0 ───────────────────────────────────────────────────

	/// Veranta takes a CloseTrade of 0, never fills it, and refuses the trade's other closes while it pends: refused
	/// from the manager and from a liquidation alike; a close of anything goes through.
	function test_v6_aPerpCloseOfNothingIsRefused() public {
		ComptrollerV6 fund = _fund(0);
		vm.prank(manager);
		MockPerpAccount account = MockPerpAccount(fund.createExternalPosition(PERP_TYPE, ''));

		vm.prank(manager);
		vm.expectRevert(ComptrollerV6Lib.CloseOfNothing.selector);
		fund.callOnExternalPosition(address(account), new address[](0), new uint256[](0), new address[](0), _close(0));
		vm.expectRevert(ComptrollerV6Lib.CloseOfNothing.selector);
		queueV6.liquidatePosition(_v6(fund), address(account), new address[](0), _one(_close(0)));

		vm.prank(manager);
		fund.callOnExternalPosition(address(account), new address[](0), new uint256[](0), new address[](0), _close(1));
		queueV6.liquidatePosition(_v6(fund), address(account), new address[](0), _one(_close(2)));
		assertEq(account.closes(), 2);
		assertEq(account.lastCloseAmount(), 2);
	}

	/// The check is for the fund's perp accounts only: another position's action 1 of 0 goes through.
	function test_v6_aCloseShapedActionOnAnotherPositionIsNotRefused() public {
		(ComptrollerV6 fund, MockUnwindPosition position) = _fundWithUnwindPosition();
		vm.prank(manager);
		fund.callOnExternalPosition(
			address(position), new address[](0), new uint256[](0), new address[](0),
			abi.encode(uint8(1), abi.encode(uint256(0), uint256(0), uint256(0), uint256(0)))
		);
		assertEq(position.locked(), 4_000e6);
	}

	// ─── V6: liquidation trades ──────────────────────────────────────────────────

	function test_v6_liquidateTrade_onlyTheQueue() public {
		ComptrollerV6 fund = _fund(0);
		vm.expectRevert(ComptrollerV6.OnlyRedemptionQueue.selector);
		_v6(fund).liquidateTrade(address(uniAdapter), '');
	}

	function test_v6_liquidateTrade_sellsIntoUsdc() public {
		ComptrollerV6 fund = _fund(0);
		_swap(fund, usdc, weth, 2_000e6, 1e18); // 8,000 USDC + 1 WETH ($2,000)
		_liquidate(fund, weth, 1e18, 1_970e6); // 1.5% under the oracle
		assertEq(_held(fund, weth), 0);
		assertEq(_held(fund, usdc), 9_970e6);
	}

	/// D5: the investors who stay absorb at most 3% of what a liquidation sells.
	function test_v6_liquidateTrade_losesAtMostThreePercent() public {
		ComptrollerV6 fund = _fund(0);
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		router.setNextAmountOut(1_939e6);
		vm.expectRevert(abi.encodeWithSelector(ComptrollerV6Lib.LiquidationLoss.selector, 61e6, 60e6));
		queueV6.liquidateTrade(_v6(fund), address(uniAdapter), abi.encode(address(weth), address(usdc), uint24(3000), 1e18, uint256(0)));
		_liquidate(fund, weth, 1e18, 1_940e6); // exactly 3%
		assertEq(_held(fund, usdc), 9_940e6);
	}

	function test_v6_liquidateTrade_onlySellsIntoTheDenomination() public {
		ComptrollerV6 fund = _fund(0);
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		vm.expectRevert(ComptrollerV6Lib.NotASale.selector);
		queueV6.liquidateTrade(_v6(fund), address(uniAdapter), abi.encode(address(usdc), address(weth), uint24(3000), 1_000e6, uint256(0)));
		vm.expectRevert(ComptrollerV6Lib.NotASale.selector);
		queueV6.liquidateTrade(_v6(fund), address(uniAdapter), abi.encode(address(weth), address(tkn), uint24(3000), 1e18, uint256(0)));
	}

	/// Every adapter is single-hop: a long-tail token on a WETH pool sells into WETH (tracked), then WETH into USDC,
	/// each hop under the cap. Only a long-tail token may stop at a feed-priced asset.
	function test_v6_liquidateTrade_aLongTailTokenSellsThroughItsPoolsQuote() public {
		ComptrollerV6 fund = _fund(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6); // 2,000 TKN ($1, pool-priced); WETH not tracked
		router.setNextAmountOut(0.99e18); // $1,980
		queueV6.liquidateTrade(_v6(fund), address(uniAdapter), abi.encode(address(tkn), address(weth), uint24(3000), 2_000e6, uint256(0)));
		assertEq(_held(fund, weth), 0.99e18);
		address[] memory tracked = fund.getTrackedAssets();
		assertEq(tracked[tracked.length - 1], address(weth), 'WETH tracked: the next sale can take it');
		assertEq(fund.costBasis(address(tkn)), 0, 'the long-tail basis left with it');
		_liquidate(fund, weth, 0.99e18, 1_970e6);
		assertEq(_held(fund, usdc), 9_970e6);

		// a feed-priced token never stops at another feed-priced one
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		vm.expectRevert(ComptrollerV6Lib.NotASale.selector);
		queueV6.liquidateTrade(_v6(fund), address(uniAdapter), abi.encode(address(weth), address(tkn), uint24(3000), 1e18, uint256(0)));
	}

	/// The hop into the quote is capped too, at the quote's oracle value.
	function test_v6_liquidateTrade_theHopIntoTheQuoteIsCapped() public {
		ComptrollerV6 fund = _fund(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		router.setNextAmountOut(0.96e18); // $1,920: 4% short
		vm.expectRevert(abi.encodeWithSelector(ComptrollerV6Lib.LiquidationLoss.selector, 80e6, 60e6));
		queueV6.liquidateTrade(_v6(fund), address(uniAdapter), abi.encode(address(tkn), address(weth), uint24(3000), 2_000e6, uint256(0)));
	}

	function test_v6_liquidateTrade_refusesAnUnregisteredAdapter() public {
		ComptrollerV6 fund = _fund(0);
		vm.expectRevert(abi.encodeWithSelector(ComptrollerV6.AdapterNotRegistered.selector, address(0xbeef)));
		queueV6.liquidateTrade(_v6(fund), address(0xbeef), '');
	}

	function test_v6_liquidateTrade_aSoldLongTailTokenTakesItsCostBasis() public {
		ComptrollerV6 fund = _fund(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		_liquidate(fund, tkn, 500e6, 500e6);
		assertEq(fund.costBasis(address(tkn)), 1_500e6);
	}

	/// A sale is checked against the oracle, so a token whose price can't be read now can't be sold until it reads.
	function test_v6_liquidateTrade_needsThePriceOfWhatItSells() public {
		ComptrollerV6 fund = _fund(0);
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		skip(2 hours); // WETH's feed stale
		router.setNextAmountOut(2_000e6);
		vm.expectRevert();
		queueV6.liquidateTrade(_v6(fund), address(uniAdapter), abi.encode(address(weth), address(usdc), uint24(3000), 1e18, uint256(0)));
	}

	// ─── V6: liquidation of positions ────────────────────────────────────────────

	/// A priced batch may lose at most 3% of the position's value.
	function test_v6_liquidatePosition_aPricedBatchLosesAtMostThreePercent() public {
		ComptrollerV6 fund = _fund(0);
		MockLossyPosition position = _lossyPosition(fund, 1_000e6, 0);
		vm.expectRevert(abi.encodeWithSelector(ComptrollerV6Lib.LiquidationLoss.selector, 31e6, 30e6));
		queueV6.liquidatePosition(_v6(fund), address(position), new address[](0), _one(abi.encode(uint8(2), abi.encode(uint256(31e6)))));
		queueV6.liquidatePosition(_v6(fund), address(position), new address[](0), _one(abi.encode(uint8(2), abi.encode(uint256(30e6)))));
		assertEq(usdc.balanceOf(address(position)), 970e6);
	}

	/// What a priced batch sends to the vault counts as kept, and the tokens listed to receive are tracked.
	function test_v6_liquidatePosition_tracksWhatReachesTheVault() public {
		ComptrollerV6 fund = _fund(0);
		MockLossyPosition position = _lossyPosition(fund, 1_000e6, 1e18);
		address[] memory receive_ = new address[](1);
		receive_[0] = address(weth);
		queueV6.liquidatePosition(_v6(fund), address(position), receive_, _one(abi.encode(uint8(3), abi.encode(uint256(1e18)))));
		assertEq(_held(fund, weth), 1e18);
		address[] memory tracked = fund.getTrackedAssets();
		assertEq(tracked[tracked.length - 1], address(weth), 'tracked: the keeper can sell it next');
	}

	// ─── V6: nothing a position returns drops out of GAV (review 2026-10-11) ────────

	/// @dev The attack's setup: 1 WETH ($2,000) rests in a limit order, and the manager untracks WETH (the vault holds none).
	function _wethInALimitOrder(ComptrollerV6 fund) internal returns (address order) {
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		vm.startPrank(manager);
		order = fund.createExternalPosition(LIMIT_TYPE, '');
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
	function test_v6_aManagersUnlistedReturnStillCountsInGav() public {
		ComptrollerV6 fund = _fund(0);
		address order = _wethInALimitOrder(fund);
		uint256 gavBefore = fund.calcGav();
		vm.startPrank(manager);
		fund.callOnExternalPosition(order, new address[](0), new uint256[](0), new address[](0), abi.encode(uint8(1), abi.encode(uint256(1))));
		fund.callOnExternalPosition(order, new address[](0), new uint256[](0), new address[](0), abi.encode(uint8(2), abi.encode(address(weth), uint256(1e18))));
		vm.stopPrank();
		assertEq(_held(fund, weth), 1e18, 'in the vault');
		assertEq(fund.calcGav(), gavBefore, 'and still counted');
	}

	/// The same through a liquidation: the keeper's unlisted return still counts.
	function test_v6_aKeepersUnlistedReturnStillCountsInGav() public {
		ComptrollerV6 fund = _fund(0);
		address order = _wethInALimitOrder(fund);
		uint256 gavBefore = fund.calcGav();
		bytes[] memory batch = new bytes[](2);
		batch[0] = abi.encode(uint8(1), abi.encode(uint256(1)));
		batch[1] = abi.encode(uint8(2), abi.encode(address(weth), uint256(1e18)));
		queueV6.liquidatePosition(_v6(fund), order, new address[](0), batch);
		assertEq(_held(fund, weth), 1e18, 'in the vault');
		assertEq(fund.calcGav(), gavBefore, 'and still counted');
	}

	/// A position whose holdings can't be read now (a perp account on a stale price) still closes, for the manager and
	/// the keeper: a cut in risk never waits on a price.
	function test_v6_aPositionWhoseHoldingsCantBeReadStillCloses() public {
		ComptrollerV6 fund = _fund(0);
		vm.prank(manager);
		MockUnreadablePosition position = MockUnreadablePosition(fund.createExternalPosition(UNREADABLE_TYPE, ''));
		position.setUnreadable(true);
		vm.prank(manager);
		fund.callOnExternalPosition(address(position), new address[](0), new uint256[](0), new address[](0), abi.encode(uint8(1), ''));
		queueV6.liquidatePosition(_v6(fund), address(position), new address[](0), _one(abi.encode(uint8(1), '')));
		assertEq(position.closes(), 2);
	}

	// ─── V6: a full tracked set never blocks a liquidation (red-team POSITIONS-01 / EXITADAPTERS-01, 2026-10-27) ──

	/// @dev Tracks fresh $1 primitives until the fund tracks MAX_TRACKED_ASSETS (20).
	function _fillTrackedSet(ComptrollerV6 fund) internal {
		while (fund.getTrackedAssets().length < _v6(fund).MAX_TRACKED_ASSETS()) {
			MockERC20 t = new MockERC20('T', 'T', 18);
			registrar.execute(
				abi.encodeCall(ValueInterpreter.addPrimitive, (address(t), address(new MockAggregator(8, 1e8)), uint32(25 hours)))
			);
			vm.prank(manager);
			fund.addTrackedAsset(address(t));
		}
	}

	/// @dev 1,000 USDC resting in a limit order for WETH (untracked), the set full, and 1 wei of WETH donated to the
	///      position (anyone can; a taker's fill does the same).
	function _fullSetWithADonatedOrder(ComptrollerV6 fund) internal returns (address order) {
		vm.startPrank(manager);
		order = fund.createExternalPosition(LIMIT_TYPE, '');
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
	function test_v6_aFullTrackedSetRefusesTheManagersNextTrack() public {
		ComptrollerV6 fund = _fund(0);
		_fillTrackedSet(fund);
		vm.prank(manager);
		vm.expectRevert(ComptrollerV3Lib.TrackedAssetsLimitReached.selector);
		fund.addTrackedAsset(address(weth));
	}

	/// The keeper cancels and returns the order at a full set: the donated WETH is tracked past the cap and counted.
	function test_v6_aFullTrackedSetDoesNotBlockTheKeepersPullBack() public {
		ComptrollerV6 fund = _fund(0);
		address order = _fullSetWithADonatedOrder(fund);
		uint256 vaultUsdc = _held(fund, usdc);
		queueV6.liquidatePosition(_v6(fund), order, new address[](0), _cancelAndReturn());
		assertEq(_held(fund, usdc), vaultUsdc + 1_000e6, 'the order came back to the vault');
		address[] memory tracked = fund.getTrackedAssets();
		assertEq(tracked.length, 21);
		assertEq(tracked[20], address(weth), 'what the position holds is tracked');
	}

	/// The manager's own action on the position isn't blocked either.
	function test_v6_aFullTrackedSetDoesNotBlockTheManagersPositionAction() public {
		ComptrollerV6 fund = _fund(0);
		address order = _fullSetWithADonatedOrder(fund);
		vm.prank(manager);
		fund.callOnExternalPosition(order, new address[](0), new uint256[](0), new address[](0), _cancelAndReturn()[0]);
		assertEq(fund.getTrackedAssets().length, 21);
		assertEq(LimitOrderPosition(order).committed(address(usdc)), 0, 'cancelled');
	}

	/// EXITADAPTERS-01: at a full set the keeper's sale of a long-tail token into its pool's WETH quote goes through
	/// (WETH is tracked past the cap), and the next sale takes the WETH to USDC.
	function test_v6_aFullTrackedSetStillTakesTheLongTailSaleIntoItsQuote() public {
		ComptrollerV6 fund = _fund(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6); // WETH not tracked
		_fillTrackedSet(fund);
		router.setNextAmountOut(0.99e18); // $1,980
		queueV6.liquidateTrade(_v6(fund), address(uniAdapter), abi.encode(address(tkn), address(weth), uint24(3000), 2_000e6, uint256(0)));
		assertEq(fund.getTrackedAssets().length, 21, 'WETH tracked past the cap');
		_liquidate(fund, weth, 0.99e18, 1_970e6);
		assertEq(_held(fund, usdc), 9_970e6);
	}
}
