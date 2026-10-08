// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {VerantaPerpPositionV2Factory} from '../src/positions/VerantaPerpPositionV2.sol';
import {VerantaPerpPositionV4, VerantaPerpPositionV4Factory} from '../src/positions/VerantaPerpPositionV4.sol';
import {
	IVerantaTradingRouter,
	IVerantaMulticall,
	IVerantaPairStorage,
	IVerantaReferral
} from '../src/interfaces/external/IVeranta.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';
import {MockVeranta} from './utils/MockVeranta.sol';

/// @notice VerantaPerpPositionV4 (spec docs/superpowers/specs/2026-10-08-perp-account-v4-design.md): V2/V3's
///         valuation, custody and referral cases ported, plus the held-pairs list and its two modes, the
///         unmapped-pair revert, the refused zero-fee order type, close costs and AddMargin.
contract VerantaPerpV4Test is Test {
	uint256 internal constant VERANTA_TYPE_ID = 6;
	uint256 internal constant ETH_PAIR = 1;
	uint256 internal constant OTHER_PAIR = 3;

	FundFactory internal factory;
	ValueInterpreter internal interpreter;
	Comptroller internal comptroller;
	MockERC20 internal usdc;
	MockERC20 internal teth; // $2,500 feed price
	MockAggregator internal tethFeed;
	MockVeranta internal veranta;
	VerantaPerpPositionV2Factory internal positionFactory;
	VerantaPerpPositionV4Factory internal v4Factory;

	address internal admin = makeAddr('admin');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');
	address internal keeper = makeAddr('autopilotKeeper');

	function setUp() public {
		vm.warp(30 days);
		interpreter = new ValueInterpreter(admin);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		teth = new MockERC20('Test ETH', 'tETH', 18);
		tethFeed = new MockAggregator(8, 2_500e8);
		vm.startPrank(admin);
		interpreter.addPrimitive(address(usdc), address(new MockAggregator(8, 1e8)), 7 days);
		interpreter.addPrimitive(address(teth), address(tethFeed), 7 days);
		vm.stopPrank();

		veranta = new MockVeranta(IERC20(address(usdc)));
		positionFactory = new VerantaPerpPositionV2Factory(
			IERC20(address(usdc)),
			IVerantaTradingRouter(address(veranta)),
			IVerantaMulticall(address(veranta)),
			address(veranta), // the mock is also the USDC spender (TradingStorage stand-in)
			IVerantaPairStorage(address(veranta)),
			keeper
		);
		positionFactory.setPairAsset(ETH_PAIR, address(teth));
		v4Factory = new VerantaPerpPositionV4Factory(positionFactory);

		factory = new FundFactory(interpreter, new ComptrollerDeployer(), new SharesVaultDeployer());
		factory.registerPositionType(VERANTA_TYPE_ID, address(v4Factory));

		comptroller = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Veranta Hedge Fund',
					symbol: 'frVH',
					denominationAsset: IERC20(address(usdc)),
					fundOwner: manager,
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: 0,
					sharesActionTimelock: 0,
					minRequestDuration: 30 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				})
			)
		);

		usdc.mint(alice, 10_000e6);
		vm.startPrank(alice);
		usdc.approve(address(comptroller), 10_000e6);
		comptroller.requestDeposit(10_000e6);
		vm.stopPrank();
		skip(30 minutes);
		comptroller.executeDepositRequest(alice);
	}

	// ─── helpers ────────────────────────────────────────────────────────────────

	function _createPosition() internal returns (VerantaPerpPositionV4 position) {
		vm.prank(manager);
		position = VerantaPerpPositionV4(payable(comptroller.createExternalPosition(VERANTA_TYPE_ID, '')));
	}

	function _none() internal pure returns (address[] memory a, uint256[] memory b) {
		a = new address[](0);
		b = new uint256[](0);
	}

	function _usdc(uint256 amount) internal view returns (address[] memory assets, uint256[] memory amounts) {
		assets = new address[](1);
		assets[0] = address(usdc);
		amounts = new uint256[](1);
		amounts[0] = amount;
	}

	function _call(VerantaPerpPositionV4 position, bytes memory actionData) internal {
		(address[] memory noAssets, uint256[] memory noAmounts) = _none();
		vm.prank(manager);
		comptroller.callOnExternalPosition(address(position), noAssets, noAmounts, noAssets, actionData);
	}

	/// @dev Move `amount` USDC vault → position along with `actionData`.
	function _callFunded(VerantaPerpPositionV4 position, uint256 amount, bytes memory actionData) internal {
		(address[] memory assets, uint256[] memory amounts) = _usdc(amount);
		(address[] memory noAssets,) = _none();
		vm.prank(manager);
		comptroller.callOnExternalPosition(address(position), assets, amounts, noAssets, actionData);
	}

	function _open(uint256 pairIndex, bool buy, uint8 orderType) internal pure returns (bytes memory) {
		return abi.encode(
			uint8(VerantaPerpPositionV4.Action.OpenTrade),
			abi.encode(pairIndex, uint256(1_000e6), uint256(2e10), buy, uint256(2_500e10), uint256(1e10), orderType, uint256(0), uint256(0))
		);
	}

	/// @dev Move 1,000 USDC vault → position and open: pair ETH, 2x, `buy`, ref price $2,500.
	function _openStandardTrade(VerantaPerpPositionV4 position, bool buy) internal {
		_callFunded(position, 1_000e6, _open(ETH_PAIR, buy, 0));
	}

	function _setAutopilot(VerantaPerpPositionV4 position) internal {
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.SetAutopilot), abi.encode(block.timestamp + 30 days)));
	}

	/// @dev The keeper's path: opt in with 1,000 USDC parked at the account, then the keeper opens a
	///      2× trade on `pairIndex` through Veranta's delegatedAction — the account never sees it.
	function _keeperOpen(VerantaPerpPositionV4 position, uint256 pairIndex, bool buy) internal {
		_callFunded(
			position, 1_000e6, abi.encode(uint8(VerantaPerpPositionV4.Action.SetAutopilot), abi.encode(block.timestamp + 90 days))
		);
		bytes memory openCall = abi.encodeCall(
			IVerantaTradingRouter.openTrade,
			(
				IVerantaTradingRouter.Trade({
					trader: address(position), pairIndex: pairIndex, index: 0, initialPosToken: 0,
					positionSizeUSDC: 1_000e6, openPrice: 2_500e10, buy: buy, leverage: 2e10,
					tp: 0, sl: 0, timestamp: 0
				}),
				0,
				1e10
			)
		);
		vm.prank(keeper);
		veranta.delegatedAction(address(position), openCall);
	}

	function _closeAll(VerantaPerpPositionV4 position) internal {
		_call(
			position,
			abi.encode(uint8(VerantaPerpPositionV4.Action.CloseTrade), abi.encode(ETH_PAIR, uint256(0), uint256(1_000e6), uint256(2_500e10)))
		);
	}

	// ─── open + pending state (ported) ──────────────────────────────────────────

	function test_openTrade_pendingOrderValuedAtCollateral() public {
		VerantaPerpPositionV4 position = _createPosition();
		assertEq(comptroller.calcGav(), 10_000e6);
		_openStandardTrade(position, false);
		assertEq(usdc.balanceOf(address(position)), 0);
		assertEq(usdc.balanceOf(address(veranta)), 1_000e6);
		assertEq(comptroller.calcGav(), 10_000e6);
	}

	function test_cancelPendingMarketOrder_refundsPosition() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.CancelPendingMarketOrder), abi.encode(uint256(1))));
		assertEq(usdc.balanceOf(address(position)), 1_000e6);
		assertEq(comptroller.calcGav(), 10_000e6);
	}

	function test_openTrade_rejectsUnmappedPair() public {
		VerantaPerpPositionV4 position = _createPosition();
		(address[] memory assets, uint256[] memory amounts) = _usdc(1_000e6);
		(address[] memory noAssets,) = _none();
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(VerantaPerpPositionV4.PairNotConfigured.selector, 99));
		comptroller.callOnExternalPosition(address(position), assets, amounts, noAssets, _open(99, false, 0));
	}

	function test_openTrade_rejectsUnsupportedUnderlying() public {
		MockERC20 rogue = new MockERC20('Rogue', 'RGE', 18);
		positionFactory.setPairAsset(7, address(rogue)); // mapped but not VI-priceable
		VerantaPerpPositionV4 position = _createPosition();
		(address[] memory assets, uint256[] memory amounts) = _usdc(1_000e6);
		(address[] memory noAssets,) = _none();
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(VerantaPerpPositionV4.UnsupportedAsset.selector, address(rogue)));
		comptroller.callOnExternalPosition(address(position), assets, amounts, noAssets, _open(7, false, 0));
	}

	/// spec 2026-10-08 §3.4: Veranta's zero-fee "PnL" trades pay a profit share valuation doesn't model
	function test_openTrade_refusesTheZeroFeePnlOrderType() public {
		VerantaPerpPositionV4 position = _createPosition();
		(address[] memory assets, uint256[] memory amounts) = _usdc(1_000e6);
		(address[] memory noAssets,) = _none();
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(VerantaPerpPositionV4.UnsupportedOrderType.selector, uint8(3)));
		comptroller.callOnExternalPosition(address(position), assets, amounts, noAssets, _open(ETH_PAIR, false, 3));
	}

	function test_openTrade_acceptsMarketStopAndLimitTypes() public {
		VerantaPerpPositionV4 position = _createPosition();
		for (uint8 orderType; orderType <= 2; ++orderType) {
			_callFunded(position, 1_000e6, _open(ETH_PAIR, false, orderType));
		}
		assertEq(veranta.getPendingOrder(address(position)).length, 3);
	}

	// ─── valuation: the linear decomposition (ported) ───────────────────────────

	function test_shortHedge_gavFlatAtEntry_thenTracksPriceInverse() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10); // coinExposure = 1000×2 / 2500 = 0.8 ETH
		assertEq(comptroller.calcGav(), 10_000e6);
		tethFeed.setAnswer(3_000e8);
		assertEq(comptroller.calcGav(), 9_600e6);
		tethFeed.setAnswer(2_000e8);
		assertEq(comptroller.calcGav(), 10_400e6);
	}

	function test_longTrade_gavTracksPrice() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, true);
		veranta.fillPending(2_500e10);
		assertEq(comptroller.calcGav(), 10_000e6);
		tethFeed.setAnswer(3_000e8);
		assertEq(comptroller.calcGav(), 10_400e6);
		tethFeed.setAnswer(2_000e8);
		assertEq(comptroller.calcGav(), 9_600e6);
	}

	function test_accruedFeesReduceValue_fundingCreditIncreasesIt() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		veranta.setRolloverFee(0, 50e6);
		veranta.setFundingFee(ETH_PAIR, 0, int256(10e6));
		assertEq(comptroller.calcGav(), 9_940e6);
		veranta.setFundingFee(ETH_PAIR, 0, int256(-30e6));
		assertEq(comptroller.calcGav(), 9_980e6);
	}

	function test_delta_neutral_pairIsFlatThroughPriceMoves() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		teth.mint(address(comptroller.vault()), 0.8e18);
		vm.prank(manager);
		comptroller.addTrackedAsset(address(teth));
		uint256 gavAt2500 = comptroller.calcGav();
		tethFeed.setAnswer(3_000e8);
		assertEq(comptroller.calcGav(), gavAt2500);
		tethFeed.setAnswer(2_000e8);
		assertEq(comptroller.calcGav(), gavAt2500);
	}

	function test_shortBeyondLiquidation_floorsAtZero_spotLegKeepsGains() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		teth.mint(address(comptroller.vault()), 0.8e18);
		vm.prank(manager);
		comptroller.addTrackedAsset(address(teth));
		tethFeed.setAnswer(4_000e8);
		assertEq(comptroller.calcGav(), 12_200e6);
	}

	function test_closeTrade_refundsAndGavHolds() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		_closeAll(position);
		assertEq(usdc.balanceOf(address(position)), 1_000e6);
		assertEq(comptroller.calcGav(), 10_000e6);
	}

	function test_twoTradesOnOnePair_bothValued() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10); // slot 0
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10); // slot 1
		assertEq(comptroller.calcGav(), 10_000e6);
		tethFeed.setAnswer(3_000e8); // 2 × 0.8 ETH short → −800
		assertEq(comptroller.calcGav(), 9_200e6);
	}

	/// Pre-flight ruling: a resting order can only come from the account (or a delegate, valued by the
	/// full walk), so the pair is listed first by an open through the account.
	function test_restingLimitOrder_valuedAtEscrow() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		_callFunded(position, 600e6, abi.encode(uint8(VerantaPerpPositionV4.Action.ReturnToVault), abi.encode(uint256(0))));
		veranta.pushLimitOrder(address(position), ETH_PAIR, 0, 600e6);
		assertEq(usdc.balanceOf(address(position)), 0);
		assertEq(comptroller.calcGav(), 10_000e6);
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.CancelLimitOrder), abi.encode(ETH_PAIR, uint256(0))));
		assertEq(usdc.balanceOf(address(position)), 600e6);
		assertEq(comptroller.calcGav(), 10_000e6);
	}

	// ─── held pairs: list mode, full walk, sync, prune (spec §3.1) ──────────────

	function test_openTrade_listsThePairBeforeTheFill() public {
		VerantaPerpPositionV4 position = _createPosition();
		vm.expectEmit(address(position));
		emit VerantaPerpPositionV4.HeldPairAdded(ETH_PAIR);
		_openStandardTrade(position, false);
		uint256[] memory held = position.heldPairs();
		assertEq(held.length, 1);
		assertEq(held[0], ETH_PAIR);
		assertEq(comptroller.calcGav(), 10_000e6, 'pending escrow valued');
		veranta.fillPending(2_500e10);
		assertEq(position.heldPairs().length, 1);
		assertEq(comptroller.calcGav(), 10_000e6);
	}

	function test_listMode_readsOnlyListedPairs() public {
		veranta.setPairsCount(135);
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		vm.expectCall(address(veranta), abi.encodeWithSelector(veranta.openTradesCount.selector), 1);
		vm.expectCall(address(veranta), abi.encodeWithSelector(veranta.openTrades.selector), 1);
		position.getManagedAssets();
	}

	function test_fullWalkMode_whileAKeeperIsDelegated() public {
		veranta.setPairsCount(135);
		VerantaPerpPositionV4 position = _createPosition();
		_setAutopilot(position);
		vm.expectCall(address(veranta), abi.encodeWithSelector(veranta.openTradesCount.selector), 135);
		position.getManagedAssets();
	}

	function test_keeperOpenedTrade_valuedInFullWalk_thenSyncedOnRemove() public {
		positionFactory.setPairAsset(OTHER_PAIR, address(teth));
		VerantaPerpPositionV4 position = _createPosition();
		_keeperOpen(position, OTHER_PAIR, false);
		veranta.fillPending(2_500e10);
		assertEq(position.heldPairs().length, 0, 'the account never saw it');
		assertEq(comptroller.calcGav(), 10_000e6, 'the full walk values it');

		vm.expectEmit(address(position));
		emit VerantaPerpPositionV4.SyncedHeldPairs(1);
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.RemoveAutopilot), ''));
		assertEq(position.activeDelegate(), address(0));
		assertEq(position.heldPairs().length, 1);
		assertEq(position.heldPairs()[0], OTHER_PAIR, 'synced into the list');
		assertEq(comptroller.calcGav(), 10_000e6);
		tethFeed.setAnswer(3_000e8);
		assertEq(comptroller.calcGav(), 9_600e6, 'list mode still values it');
	}

	function test_removeAutopilot_syncListsAPendingKeeperOrder() public {
		positionFactory.setPairAsset(OTHER_PAIR, address(teth));
		VerantaPerpPositionV4 position = _createPosition();
		_keeperOpen(position, OTHER_PAIR, false); // still pending
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.RemoveAutopilot), ''));
		assertEq(position.heldPairs().length, 1);
		assertEq(position.heldPairs()[0], OTHER_PAIR, 'a pending order lists its pair');
		veranta.fillPending(2_500e10);
		tethFeed.setAnswer(3_000e8);
		assertEq(comptroller.calcGav(), 9_600e6, 'the fill is valued in list mode');
	}

	/// Review focus 1: a rotated-out keeper must lose its Veranta delegation, or list mode (entered only
	/// through RemoveAutopilot's sync) could miss a trade it opens later.
	function test_setAutopilot_rotationRemovesTheOldKeeper() public {
		VerantaPerpPositionV4 position = _createPosition();
		_setAutopilot(position);
		address keeper2 = makeAddr('keeper2');
		positionFactory.setAutopilotKeeper(keeper2);
		vm.expectEmit(address(position));
		emit VerantaPerpPositionV4.AutopilotRemoved(keeper);
		_setAutopilot(position);
		(bool oldEnabled,) = veranta.multipleDelegations(address(position), keeper);
		(bool newEnabled,) = veranta.multipleDelegations(address(position), keeper2);
		assertFalse(oldEnabled, 'one keeper at most');
		assertTrue(newEnabled);
		assertEq(position.activeDelegate(), keeper2);
	}

	function test_setAutopilot_sameKeeperJustRenews() public {
		VerantaPerpPositionV4 position = _createPosition();
		_setAutopilot(position);
		uint256 expiry = block.timestamp + 60 days;
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.SetAutopilot), abi.encode(expiry)));
		(bool enabled, uint256 storedExpiry) = veranta.multipleDelegations(address(position), keeper);
		assertTrue(enabled);
		assertEq(storedExpiry, expiry);
		assertEq(position.activeDelegate(), keeper);
	}

	function test_prune_dropsAnEmptyPairAfterCancel() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		vm.expectEmit(address(position));
		emit VerantaPerpPositionV4.HeldPairRemoved(ETH_PAIR);
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.CancelPendingMarketOrder), abi.encode(uint256(1))));
		assertEq(position.heldPairs().length, 0);
	}

	/// Review focus 3: a pair with only a resting limit order stays listed.
	function test_prune_keepsAPairWithALimitOrderOnly() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		_callFunded(position, 600e6, abi.encode(uint8(VerantaPerpPositionV4.Action.ReturnToVault), abi.encode(uint256(0))));
		veranta.pushLimitOrder(address(position), ETH_PAIR, 0, 600e6);
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.CancelPendingMarketOrder), abi.encode(uint256(1))));
		assertEq(position.heldPairs().length, 1, 'kept: a limit order rests on it');
		assertEq(comptroller.calcGav(), 10_000e6);
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.CancelLimitOrder), abi.encode(ETH_PAIR, uint256(0))));
		assertEq(position.heldPairs().length, 0, 'pruned once empty');
	}

	function test_prune_keepsAPairWithAnOpenTrade() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.ReturnToVault), abi.encode(uint256(0)))); // any action prunes
		assertEq(position.heldPairs().length, 1);
	}

	// ─── a held pair without a mapping (spec §3.2) ──────────────────────────────

	function test_unmappedHeldPair_revertsValuation_closeStillWorks() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		positionFactory.setPairAsset(ETH_PAIR, address(0));
		vm.expectRevert(abi.encodeWithSelector(VerantaPerpPositionV4.PairUnmapped.selector, ETH_PAIR));
		position.getManagedAssets();
		vm.expectRevert(abi.encodeWithSelector(VerantaPerpPositionV4.PairUnmapped.selector, ETH_PAIR));
		comptroller.calcGav();
		// closing is risk-reducing and moves nothing out of the vault: unpriced, so it still works
		_closeAll(position);
		assertEq(usdc.balanceOf(address(position)), 1_000e6);
		assertEq(comptroller.calcGav(), 10_000e6);
	}

	/// Review focus 4: the full walk reads every pair, mapped or not; one holding nothing must not revert.
	function test_unmappedPair_withNothingHeld_doesNotRevert() public {
		VerantaPerpPositionV4 position = _createPosition();
		_setAutopilot(position);
		positionFactory.setPairAsset(ETH_PAIR, address(0));
		position.getManagedAssets();
		assertEq(comptroller.calcGav(), 10_000e6);
	}

	function test_unmappedPair_withOnlyALimitOrder_revertsToo() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		_callFunded(position, 600e6, abi.encode(uint8(VerantaPerpPositionV4.Action.ReturnToVault), abi.encode(uint256(0))));
		veranta.pushLimitOrder(address(position), ETH_PAIR, 0, 600e6);
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.CancelPendingMarketOrder), abi.encode(uint256(1))));
		positionFactory.setPairAsset(ETH_PAIR, address(0));
		vm.expectRevert(abi.encodeWithSelector(VerantaPerpPositionV4.PairUnmapped.selector, ETH_PAIR));
		position.getManagedAssets();
	}

	// ─── close costs in NAV (spec §3.3) ─────────────────────────────────────────

	/// 2× short of 1,000 USDC = 2,000 size. Close fee: the higher of Veranta's close maker (0.01%) and taker
	/// (0.045%) rates, so open-interest skew can't move it (2026-10-08); plus the 0.05% spread → 0.095% → 1.9 USDC
	function test_closeCost_higherOfMakerAndTakerPlusSpread() public {
		veranta.setCloseFees(ETH_PAIR, 1e8, 4.5e8);
		veranta.setSpreadP(ETH_PAIR, 5e8);
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		assertEq(comptroller.calcGav(), 10_000e6 - 1.9e6);
		tethFeed.setAnswer(3_000e8); // the deduction stays put while the price moves
		assertEq(comptroller.calcGav(), 9_600e6 - 1.9e6);
	}

	function test_closeCost_makerAboveTaker_takesTheMaker() public {
		veranta.setCloseFees(ETH_PAIR, 3e8, 1e8);
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		assertEq(comptroller.calcGav(), 10_000e6 - 0.6e6, '0.03% of 2,000');
	}

	function test_closeCost_longsPayItToo() public {
		veranta.setCloseFees(ETH_PAIR, 1e8, 1e8);
		veranta.setSpreadP(ETH_PAIR, 1e8);
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, true);
		veranta.fillPending(2_500e10);
		assertEq(comptroller.calcGav(), 10_000e6 - 0.4e6);
	}

	function test_closeCost_perTrade() public {
		veranta.setCloseFees(ETH_PAIR, 1e8, 1e8);
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		_openStandardTrade(position, true);
		veranta.fillPending(2_500e10);
		assertEq(comptroller.calcGav(), 10_000e6 - 0.4e6, 'two trades of 2,000 size at 0.01% each');
	}

	/// Gas (2026-10-08): the pair's cost rates are read once per pair, not once per trade.
	function test_closeCost_ratesReadOncePerPair() public {
		veranta.setCloseFees(ETH_PAIR, 1e8, 4.5e8);
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		_openStandardTrade(position, true);
		veranta.fillPending(2_500e10);
		vm.expectCall(address(veranta), abi.encodeWithSelector(veranta.pairs.selector), 1);
		vm.expectCall(address(veranta), abi.encodeWithSelector(veranta.additionalPairParams2.selector), 1);
		position.getManagedAssets();
	}

	function test_closeCost_pendingOrderPaysNone() public {
		veranta.setCloseFees(ETH_PAIR, 1e8, 1e8);
		veranta.setSpreadP(ETH_PAIR, 1e8);
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		assertEq(comptroller.calcGav(), 10_000e6, 'escrow at face value until the fill');
	}

	/// Review focus 5: a trade past liquidation stays signed math; the position floors at zero.
	function test_closeCost_deepLoser_floorsAtZero() public {
		veranta.setCloseFees(ETH_PAIR, 1e8, 1e8);
		veranta.setSpreadP(ETH_PAIR, 1e8);
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		tethFeed.setAnswer(5_000e8); // the 2× short lost 2,000 on 1,000 collateral
		// the legs still carry the deduction: managed USDC = 1,000 + 2,000 − 0.4 (0.02% of 2,000); debt 0.8 tETH
		(address[] memory assets, uint256[] memory amounts) = position.getManagedAssets();
		assertEq(assets.length, 1);
		assertEq(amounts[0], 2_999.6e6);
		(assets, amounts) = position.getDebtAssets();
		assertEq(assets[0], address(teth));
		assertEq(amounts[0], 0.8e18);
		assertEq(comptroller.calcGav(), 9_000e6, 'position floors at zero, nothing reverts');
	}

	// ─── add margin (spec §4) ───────────────────────────────────────────────────

	function _addMargin(VerantaPerpPositionV4 position, uint256 amount, uint256 fee) internal {
		bytes[] memory packets = new bytes[](1);
		packets[0] = hex'beef';
		_callFunded(
			position,
			amount,
			abi.encode(uint8(VerantaPerpPositionV4.Action.AddMargin), abi.encode(ETH_PAIR, uint256(0), amount, packets, uint8(1), fee))
		);
	}

	function test_addMargin_movesVaultUsdcIntoTheTrade_andPaysTheFee() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		vm.deal(address(position), 10);
		vm.expectEmit(address(position));
		emit VerantaPerpPositionV4.MarginAdded(ETH_PAIR, 0, 100e6);
		_addMargin(position, 100e6, 1);
		uint256 venueFee = (uint256(100e6) * 3) / 10_000; // the mock's deposit fee
		assertEq(veranta.openTrades(address(position), ETH_PAIR, 0).initialPosToken, 1_100e6 - venueFee);
		assertEq(usdc.balanceOf(address(position)), 0, 'all of it went into the trade');
		assertEq(veranta.marginFeesPaid(), 1, 'the verification fee, in ETH');
		assertEq(address(position).balance, 9);
		assertEq(comptroller.calcGav(), 10_000e6 - venueFee);
	}

	function test_addMargin_withoutEthForTheFee_reverts() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		(address[] memory assets, uint256[] memory amounts) = _usdc(100e6);
		(address[] memory noAssets,) = _none();
		bytes memory data = abi.encode(
			uint8(VerantaPerpPositionV4.Action.AddMargin), abi.encode(ETH_PAIR, uint256(0), uint256(100e6), new bytes[](0), uint8(1), uint256(1))
		);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(VerantaPerpPositionV4.FeeBalanceTooLow.selector, uint256(1), uint256(0)));
		comptroller.callOnExternalPosition(address(position), assets, amounts, noAssets, data);
	}

	function test_addMargin_zeroFeeNeedsNoEth() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, true);
		veranta.fillPending(2_500e10);
		_addMargin(position, 50e6, 0);
		assertGt(veranta.openTrades(address(position), ETH_PAIR, 0).initialPosToken, 1_000e6);
	}

	function test_receive_acceptsEth_andItStaysOutOfNav() public {
		VerantaPerpPositionV4 position = _createPosition();
		(bool ok,) = address(position).call{value: 1 ether}('');
		assertTrue(ok);
		assertEq(comptroller.calcGav(), 10_000e6);
	}

	/// The fee float isn't stuck (2026-10-08): ReturnEth sends all of the account's ETH to the fund owner,
	/// who paid it in (the terminal's top-up); it was never part of NAV.
	function test_returnEth_sendsTheFeeFloatToTheFundOwner() public {
		VerantaPerpPositionV4 position = _createPosition();
		vm.deal(address(position), 1 ether + 7);
		uint256 before = manager.balance;
		vm.expectEmit(address(position));
		emit VerantaPerpPositionV4.EthReturned(manager, 1 ether + 7);
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.ReturnEth), ''));
		assertEq(address(position).balance, 0);
		assertEq(manager.balance, before + 1 ether + 7);
		assertEq(comptroller.calcGav(), 10_000e6);
	}

	// ─── autopilot, custody, referral (ported) ──────────────────────────────────

	function test_setAutopilot_delegatesPinnedKeeper() public {
		VerantaPerpPositionV4 position = _createPosition();
		uint256 expiry = block.timestamp + 90 days;
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.SetAutopilot), abi.encode(expiry)));
		(bool enabled, uint256 storedExpiry) = veranta.multipleDelegations(address(position), keeper);
		assertTrue(enabled);
		assertEq(storedExpiry, expiry);
		assertEq(position.activeDelegate(), keeper);
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.RemoveAutopilot), ''));
		(enabled,) = veranta.multipleDelegations(address(position), keeper);
		assertFalse(enabled);
		assertEq(position.activeDelegate(), address(0));
	}

	function test_removeAutopilot_revertsWhenInactive() public {
		VerantaPerpPositionV4 position = _createPosition();
		(address[] memory noAssets, uint256[] memory noAmounts) = _none();
		vm.prank(manager);
		vm.expectRevert(VerantaPerpPositionV4.AutopilotNotActive.selector);
		comptroller.callOnExternalPosition(
			address(position), noAssets, noAmounts, noAssets, abi.encode(uint8(VerantaPerpPositionV4.Action.RemoveAutopilot), '')
		);
	}

	function test_returnToVault_onlyDestinationIsVault() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.CancelPendingMarketOrder), abi.encode(uint256(1))));
		uint256 vaultBefore = usdc.balanceOf(address(comptroller.vault()));
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.ReturnToVault), abi.encode(uint256(1_000e6))));
		assertEq(usdc.balanceOf(address(comptroller.vault())), vaultBefore + 1_000e6);
		assertEq(usdc.balanceOf(address(position)), 0);
	}

	function test_receiveCallFromFund_onlyComptroller() public {
		VerantaPerpPositionV4 position = _createPosition();
		vm.prank(manager);
		vm.expectRevert(VerantaPerpPositionV4.OnlyComptroller.selector);
		position.receiveCallFromFund(abi.encode(uint8(VerantaPerpPositionV4.Action.ReturnToVault), abi.encode(uint256(1))));
	}

	function test_linkReferral_linksTheProtocolCodeAsThePosition() public {
		VerantaPerpPositionV4 position = _createPosition();
		positionFactory.setReferral(IVerantaReferral(address(veranta)), bytes32('frostyfi'));
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.LinkReferral), ''));
		assertEq(veranta.traderReferralCodes(address(position)), bytes32('frostyfi'));
	}

	function test_creation_linksTheConfigCode() public {
		positionFactory.setReferral(IVerantaReferral(address(veranta)), bytes32('frostydao'));
		VerantaPerpPositionV4 position = _createPosition();
		assertEq(veranta.traderReferralCodes(address(position)), bytes32('frostydao'));
	}

	function test_unknownAction_reverts() public {
		VerantaPerpPositionV4 position = _createPosition();
		(address[] memory noAssets, uint256[] memory noAmounts) = _none();
		vm.prank(manager);
		vm.expectRevert(VerantaPerpPositionV4.UnknownAction.selector);
		comptroller.callOnExternalPosition(address(position), noAssets, noAmounts, noAssets, abi.encode(uint8(42), ''));
	}

	/// PerpUnwinder builds CloseTrade (1) and ReturnToVault (6) and needs both risk-reducing; V3's set exactly.
	function test_isRiskReducing_sameSetAsV3() public {
		VerantaPerpPositionV4 position = _createPosition();
		bool[10] memory expected = [false, true, true, true, false, true, true, false, false, false];
		for (uint8 action; action < 10; ++action) {
			assertEq(position.isRiskReducing(abi.encode(action, '')), expected[action]);
		}
		assertEq(uint8(VerantaPerpPositionV4.Action.CloseTrade), 1);
		assertEq(uint8(VerantaPerpPositionV4.Action.ReturnToVault), 6);
		assertEq(uint8(VerantaPerpPositionV4.Action.AddMargin), 8);
		assertEq(uint8(VerantaPerpPositionV4.Action.ReturnEth), 9);
	}

	function test_factory_deploysV4BoundToTheSharedConfig() public {
		VerantaPerpPositionV4 position = _createPosition();
		assertEq(address(position.positionFactory()), address(positionFactory));
		assertEq(address(v4Factory.config()), address(positionFactory));
		assertEq(position.comptroller(), address(comptroller));
	}
}
