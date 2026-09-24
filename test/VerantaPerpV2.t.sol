// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {VerantaPerpPositionV2, VerantaPerpPositionV2Factory} from '../src/positions/VerantaPerpPositionV2.sol';
import {
	IVerantaTradingRouter,
	IVerantaMulticall,
	IVerantaPairStorage,
	IVerantaReferral
} from '../src/interfaces/external/IVeranta.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';
import {MockVeranta} from './utils/MockVeranta.sol';

/// @notice V1's full suite, run against VerantaPerpPositionV2 — the bounded read must value
///         every case exactly as V1 did — plus V2-only cases below.
contract VerantaPerpV2Test is Test {
	uint256 internal constant VERANTA_TYPE_ID = 6;
	uint256 internal constant ETH_PAIR = 1;

	FundFactory internal factory;
	ValueInterpreter internal interpreter;
	Comptroller internal comptroller;
	MockERC20 internal usdc;
	MockERC20 internal teth; // $2,500 feed price
	MockAggregator internal tethFeed;
	MockVeranta internal veranta;
	VerantaPerpPositionV2Factory internal positionFactory;

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

		factory = new FundFactory(interpreter, new ComptrollerDeployer(), new SharesVaultDeployer());
		factory.registerPositionType(VERANTA_TYPE_ID, address(positionFactory));

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

	function _createPosition() internal returns (VerantaPerpPositionV2 position) {
		vm.prank(manager);
		position = VerantaPerpPositionV2(comptroller.createExternalPosition(VERANTA_TYPE_ID, ''));
	}

	function _none() internal pure returns (address[] memory a, uint256[] memory b) {
		a = new address[](0);
		b = new uint256[](0);
	}

	function _call(VerantaPerpPositionV2 position, bytes memory actionData) internal {
		(address[] memory noAssets, uint256[] memory noAmounts) = _none();
		vm.prank(manager);
		comptroller.callOnExternalPosition(address(position), noAssets, noAmounts, noAssets, actionData);
	}

	/// @dev Move 1,000 USDC vault → position and open: pair ETH, 2x, `buy`, ref price $2,500.
	function _openStandardTrade(VerantaPerpPositionV2 position, bool buy) internal {
		address[] memory transferAssets = new address[](1);
		transferAssets[0] = address(usdc);
		uint256[] memory transferAmounts = new uint256[](1);
		transferAmounts[0] = 1_000e6;
		(address[] memory noAssets,) = _none();

		bytes memory open = abi.encode(
			uint8(VerantaPerpPositionV2.Action.OpenTrade),
			abi.encode(ETH_PAIR, uint256(1_000e6), uint256(2e10), buy, uint256(2_500e10), uint256(1e10), uint8(0), uint256(0), uint256(0))
		);
		vm.prank(manager);
		comptroller.callOnExternalPosition(address(position), transferAssets, transferAmounts, noAssets, open);
	}

	// ─── open + pending state ───────────────────────────────────────────────────

	function test_openTrade_pendingOrderValuedAtCollateral() public {
		VerantaPerpPositionV2 position = _createPosition();
		assertEq(comptroller.calcGav(), 10_000e6);

		_openStandardTrade(position, false);

		// Two-step open: collateral escrowed with Veranta, order pending the operator
		assertEq(usdc.balanceOf(address(position)), 0);
		assertEq(usdc.balanceOf(address(veranta)), 1_000e6);
		assertEq(comptroller.calcGav(), 10_000e6);
	}

	function test_cancelPendingMarketOrder_refundsPosition() public {
		VerantaPerpPositionV2 position = _createPosition();
		_openStandardTrade(position, false);

		_call(position, abi.encode(uint8(VerantaPerpPositionV2.Action.CancelPendingMarketOrder), abi.encode(uint256(1))));
		assertEq(usdc.balanceOf(address(position)), 1_000e6);
		assertEq(comptroller.calcGav(), 10_000e6);
	}

	function test_openTrade_rejectsUnmappedPair() public {
		VerantaPerpPositionV2 position = _createPosition();
		address[] memory transferAssets = new address[](1);
		transferAssets[0] = address(usdc);
		uint256[] memory transferAmounts = new uint256[](1);
		transferAmounts[0] = 1_000e6;
		(address[] memory noAssets,) = _none();

		bytes memory open = abi.encode(
			uint8(VerantaPerpPositionV2.Action.OpenTrade),
			abi.encode(uint256(99), uint256(1_000e6), uint256(2e10), false, uint256(2_500e10), uint256(1e10), uint8(0), uint256(0), uint256(0))
		);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(VerantaPerpPositionV2.PairNotConfigured.selector, 99));
		comptroller.callOnExternalPosition(address(position), transferAssets, transferAmounts, noAssets, open);
	}

	function test_openTrade_rejectsUnsupportedUnderlying() public {
		MockERC20 rogue = new MockERC20('Rogue', 'RGE', 18);
		positionFactory.setPairAsset(7, address(rogue)); // mapped but not VI-priceable

		VerantaPerpPositionV2 position = _createPosition();
		address[] memory transferAssets = new address[](1);
		transferAssets[0] = address(usdc);
		uint256[] memory transferAmounts = new uint256[](1);
		transferAmounts[0] = 1_000e6;
		(address[] memory noAssets,) = _none();

		bytes memory open = abi.encode(
			uint8(VerantaPerpPositionV2.Action.OpenTrade),
			abi.encode(uint256(7), uint256(1_000e6), uint256(2e10), false, uint256(2_500e10), uint256(1e10), uint8(0), uint256(0), uint256(0))
		);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(VerantaPerpPositionV2.UnsupportedAsset.selector, address(rogue)));
		comptroller.callOnExternalPosition(address(position), transferAssets, transferAmounts, noAssets, open);
	}

	// ─── valuation: the linear decomposition ────────────────────────────────────

	function test_shortHedge_gavFlatAtEntry_thenTracksPriceInverse() public {
		VerantaPerpPositionV2 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10); // coinExposure = 1000×2 / 2500 = 0.8 ETH

		// managed USDC = 1000 (collateral) + 0.8×2500 (short notional at open) = 3400... 3000e6? -> 1000+2000
		// debt = 0.8 tETH; GAV = 9000 + 3000 − 0.8×2500 = 10,000
		assertEq(comptroller.calcGav(), 10_000e6);

		// ETH +20% → short loses 0.8×500 = 400
		tethFeed.setAnswer(3_000e8);
		assertEq(comptroller.calcGav(), 9_600e6);

		// ETH −20% → short gains 0.8×500 = 400
		tethFeed.setAnswer(2_000e8);
		assertEq(comptroller.calcGav(), 10_400e6);
	}

	function test_longTrade_gavTracksPrice() public {
		VerantaPerpPositionV2 position = _createPosition();
		_openStandardTrade(position, true);
		veranta.fillPending(2_500e10);

		// managed = 0.8 tETH; USDC leg = 1000 − 2000 = −1000 → debt
		// GAV = 9000 + 0.8×2500 − 1000 = 10,000
		assertEq(comptroller.calcGav(), 10_000e6);

		tethFeed.setAnswer(3_000e8);
		assertEq(comptroller.calcGav(), 10_400e6);

		tethFeed.setAnswer(2_000e8);
		assertEq(comptroller.calcGav(), 9_600e6);
	}

	function test_accruedFeesReduceValue_fundingCreditIncreasesIt() public {
		VerantaPerpPositionV2 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);

		veranta.setRolloverFee(0, 50e6);
		veranta.setFundingFee(ETH_PAIR, 0, int256(10e6));
		assertEq(comptroller.calcGav(), 9_940e6);

		// Short side being PAID funding: a credit
		veranta.setFundingFee(ETH_PAIR, 0, int256(-30e6));
		assertEq(comptroller.calcGav(), 9_980e6);
	}

	function test_delta_neutral_pairIsFlatThroughPriceMoves() public {
		// The flagship shape: vault holds 0.8 tETH spot, position shorts 0.8 tETH
		VerantaPerpPositionV2 position = _createPosition();
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
		// Same delta-neutral shape, but ETH +60%: the 2x short's loss (0.8×1500 = 1200)
		// exceeds its 1000 collateral. Veranta would have liquidated it; calcGav's
		// per-position zero floor models exactly that — the position contributes 0,
		// never a negative, and the spot leg keeps its gains.
		VerantaPerpPositionV2 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		teth.mint(address(comptroller.vault()), 0.8e18);
		vm.prank(manager);
		comptroller.addTrackedAsset(address(teth));

		tethFeed.setAnswer(4_000e8);
		// 9,000 USDC + 0.8×4,000 spot + 0 (wiped hedge) = 12,200
		assertEq(comptroller.calcGav(), 12_200e6);
	}

	function test_closeTrade_refundsAndGavHolds() public {
		VerantaPerpPositionV2 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);

		_call(
			position,
			abi.encode(uint8(VerantaPerpPositionV2.Action.CloseTrade), abi.encode(ETH_PAIR, uint256(0), uint256(1_000e6), uint256(2_500e10)))
		);
		assertEq(usdc.balanceOf(address(position)), 1_000e6);
		assertEq(comptroller.calcGav(), 10_000e6);
	}

	// ─── autopilot delegation ───────────────────────────────────────────────────

	function test_setAutopilot_delegatesPinnedKeeper() public {
		VerantaPerpPositionV2 position = _createPosition();
		uint256 expiry = block.timestamp + 90 days;

		_call(position, abi.encode(uint8(VerantaPerpPositionV2.Action.SetAutopilot), abi.encode(expiry)));
		(bool enabled, uint256 storedExpiry) = veranta.multipleDelegations(address(position), keeper);
		assertTrue(enabled);
		assertEq(storedExpiry, expiry);
		assertEq(position.activeDelegate(), keeper);

		_call(position, abi.encode(uint8(VerantaPerpPositionV2.Action.RemoveAutopilot), ''));
		(enabled,) = veranta.multipleDelegations(address(position), keeper);
		assertFalse(enabled);
		assertEq(position.activeDelegate(), address(0));
	}

	function test_removeAutopilot_revertsWhenInactive() public {
		VerantaPerpPositionV2 position = _createPosition();
		(address[] memory noAssets, uint256[] memory noAmounts) = _none();
		vm.prank(manager);
		vm.expectRevert(VerantaPerpPositionV2.AutopilotNotActive.selector);
		comptroller.callOnExternalPosition(
			address(position), noAssets, noAmounts, noAssets, abi.encode(uint8(VerantaPerpPositionV2.Action.RemoveAutopilot), '')
		);
	}

	function test_autopilot_keeperRotationOnlyAffectsNewOptIns() public {
		VerantaPerpPositionV2 position = _createPosition();
		_call(position, abi.encode(uint8(VerantaPerpPositionV2.Action.SetAutopilot), abi.encode(block.timestamp + 30 days)));

		address keeper2 = makeAddr('keeper2');
		positionFactory.setAutopilotKeeper(keeper2);

		// Old delegation still stands until the fund re-opts-in
		(bool oldEnabled,) = veranta.multipleDelegations(address(position), keeper);
		assertTrue(oldEnabled);

		_call(position, abi.encode(uint8(VerantaPerpPositionV2.Action.SetAutopilot), abi.encode(block.timestamp + 30 days)));
		(bool newEnabled,) = veranta.multipleDelegations(address(position), keeper2);
		assertTrue(newEnabled);
		assertEq(position.activeDelegate(), keeper2);
	}

	function test_delegatedAction_keeperOpensHedgeInPositionContext() public {
		// The KEEPER PATH end to end on the mock (the path the live keeper drives):
		// manager opts in → keeper EOA opens a short via delegatedAction → collateral
		// pulled from the POSITION, order pending with the position as trader.
		VerantaPerpPositionV2 position = _createPosition();
		address[] memory transferAssets = new address[](1);
		transferAssets[0] = address(usdc);
		uint256[] memory transferAmounts = new uint256[](1);
		transferAmounts[0] = 1_500e6;
		(address[] memory noAssets,) = _none();
		vm.prank(manager);
		comptroller.callOnExternalPosition(
			address(position), transferAssets, transferAmounts, noAssets,
			abi.encode(uint8(VerantaPerpPositionV2.Action.SetAutopilot), abi.encode(block.timestamp + 90 days))
		);

		bytes memory openCall = abi.encodeCall(
			IVerantaTradingRouter.openTrade,
			(
				IVerantaTradingRouter.Trade({
					trader: address(position), pairIndex: ETH_PAIR, index: 0, initialPosToken: 0,
					positionSizeUSDC: 1_000e6, openPrice: 2_500e10, buy: false, leverage: 2e10,
					tp: 0, sl: 0, timestamp: 0
				}),
				0,
				1e10
			)
		);

		// A stranger (not delegated) is rejected
		vm.prank(alice);
		vm.expectRevert(bytes('MockVeranta: not delegated'));
		veranta.delegatedAction(address(position), openCall);

		// The delegated keeper succeeds — collateral escrowed FROM THE POSITION
		vm.prank(keeper);
		veranta.delegatedAction(address(position), openCall);
		assertEq(usdc.balanceOf(address(position)), 500e6);
		IVerantaMulticall.PendingOrder[] memory pending = veranta.getPendingOrder(address(position));
		assertEq(pending.length, 1);
		assertEq(pending[0].orderInfo.trade.trader, address(position));

		// GAV carries the pending escrow — still whole
		assertEq(comptroller.calcGav(), 10_000e6);
	}

	function test_updateMargin_keeperTopUpViaDelegation() public {
		// KEEPER-V2 AUTO TOP-UP (fork-proven semantics): the delegate deposits margin from
		// the POSITION's idle USDC via delegatedAction — collateral (initialPosToken) rises
		// by amount minus the ~3bps venue fee, the dummy positionSizeUSDC is untouched, and
		// GAV loses only the fee. The keeper never touches the money itself.
		VerantaPerpPositionV2 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);

		// opt in autopilot and park idle USDC at the position as the top-up reserve
		address[] memory transferAssets = new address[](1);
		transferAssets[0] = address(usdc);
		uint256[] memory transferAmounts = new uint256[](1);
		transferAmounts[0] = 200e6;
		(address[] memory noAssets,) = _none();
		vm.prank(manager);
		comptroller.callOnExternalPosition(
			address(position), transferAssets, transferAmounts, noAssets,
			abi.encode(uint8(VerantaPerpPositionV2.Action.SetAutopilot), abi.encode(block.timestamp + 90 days))
		);

		uint256 gavBefore = comptroller.calcGav();
		bytes memory topUp =
			abi.encodeCall(IVerantaTradingRouter.updateMargin, (ETH_PAIR, 0, 0, 100e6, new bytes[](0), 0));
		vm.prank(keeper);
		veranta.delegatedAction(address(position), topUp);

		(IVerantaMulticall.AggregatedTrade[] memory trades,) = veranta.getPositions(address(position));
		uint256 venueFee = (uint256(100e6) * 3) / 10_000;
		assertEq(trades[0].trade.initialPosToken, 1_000e6 + 100e6 - venueFee);
		// The dummy field must never read as collateral (the bug this probe run caught)
		assertEq(trades[0].trade.positionSizeUSDC, block.timestamp);
		assertEq(usdc.balanceOf(address(position)), 100e6);
		assertEq(comptroller.calcGav(), gavBefore - venueFee);
	}

	// ─── custody ────────────────────────────────────────────────────────────────

	function test_returnToVault_onlyDestinationIsVault() public {
		VerantaPerpPositionV2 position = _createPosition();
		_openStandardTrade(position, false);
		_call(position, abi.encode(uint8(VerantaPerpPositionV2.Action.CancelPendingMarketOrder), abi.encode(uint256(1))));

		uint256 vaultBefore = usdc.balanceOf(address(comptroller.vault()));
		_call(position, abi.encode(uint8(VerantaPerpPositionV2.Action.ReturnToVault), abi.encode(uint256(1_000e6))));
		assertEq(usdc.balanceOf(address(comptroller.vault())), vaultBefore + 1_000e6);
		assertEq(usdc.balanceOf(address(position)), 0);
	}

	function test_receiveCallFromFund_onlyComptroller() public {
		VerantaPerpPositionV2 position = _createPosition();
		vm.prank(manager);
		vm.expectRevert(VerantaPerpPositionV2.OnlyComptroller.selector);
		position.receiveCallFromFund(abi.encode(uint8(VerantaPerpPositionV2.Action.ReturnToVault), abi.encode(uint256(1))));
	}

	/// M-8 (security review 2026-09-22): zeroing a pair's asset mapping with a live
	/// trade must DEGRADE valuation (USDC leg only), never brick fund-wide GAV.
	function test_m8_zeroedPairAsset_degradesValuationInsteadOfBricking() public {
		VerantaPerpPositionV2 position = _createPosition();
		_openStandardTrade(position, false);

		positionFactory.setPairAsset(ETH_PAIR, address(0)); // owner disables new opens

		(address[] memory assets, uint256[] memory amounts) = position.getManagedAssets();
		// the coin leg is unpriceable and dropped; the USDC leg survives
		for (uint256 i; i < assets.length; ++i) {
			assertTrue(assets[i] != address(0), 'no zero-address asset reported');
		}
		assertGt(comptroller.calcGav(), 0, 'GAV must stay alive');
		amounts; // silence unused warning when the mock reports only the USDC leg
	}

	// ─── TP/SL at open ──────────────────────────────────────────────────────────

	function test_openTrade_carriesTpSlToVeranta_andKeepsThemThroughTheFill() public {
		VerantaPerpPositionV2 position = _createPosition();
		address[] memory transferAssets = new address[](1);
		transferAssets[0] = address(usdc);
		uint256[] memory transferAmounts = new uint256[](1);
		transferAmounts[0] = 1_000e6;
		(address[] memory noAssets,) = _none();

		// short at $2,500: take profit $2,200, stop $2,700
		bytes memory open = abi.encode(
			uint8(VerantaPerpPositionV2.Action.OpenTrade),
			abi.encode(ETH_PAIR, uint256(1_000e6), uint256(2e10), false, uint256(2_500e10), uint256(1e10), uint8(0), uint256(2_200e10), uint256(2_700e10))
		);
		vm.expectEmit(address(position));
		emit VerantaPerpPositionV2.TpSlRequested(ETH_PAIR, 2_200e10, 2_700e10);
		vm.prank(manager);
		comptroller.callOnExternalPosition(address(position), transferAssets, transferAmounts, noAssets, open);

		IVerantaMulticall.PendingOrder[] memory pending = veranta.getPendingOrder(address(position));
		assertEq(pending.length, 1);
		assertEq(pending[0].orderInfo.trade.tp, 2_200e10);
		assertEq(pending[0].orderInfo.trade.sl, 2_700e10);

		veranta.fillPending(2_500e10);
		IVerantaTradingRouter.Trade memory t = veranta.openTrades(address(position), ETH_PAIR, 0);
		assertEq(t.tp, 2_200e10);
		assertEq(t.sl, 2_700e10);
	}

	/// The pre-TP/SL 7-field encoding must fail loudly, never open a trade without the
	/// levels the manager set.
	function test_openTrade_legacyEncodingWithoutTpSlReverts() public {
		VerantaPerpPositionV2 position = _createPosition();
		address[] memory transferAssets = new address[](1);
		transferAssets[0] = address(usdc);
		uint256[] memory transferAmounts = new uint256[](1);
		transferAmounts[0] = 1_000e6; // funded, so only the args decode can revert
		(address[] memory noAssets,) = _none();
		bytes memory legacy = abi.encode(
			uint8(VerantaPerpPositionV2.Action.OpenTrade),
			abi.encode(ETH_PAIR, uint256(1_000e6), uint256(2e10), false, uint256(2_500e10), uint256(1e10), uint8(0))
		);
		vm.prank(manager);
		vm.expectRevert();
		comptroller.callOnExternalPosition(address(position), transferAssets, transferAmounts, noAssets, legacy);
		assertEq(veranta.getPendingOrder(address(position)).length, 0);
	}

	// ─── referral link ──────────────────────────────────────────────────────────

	function test_linkReferral_linksTheProtocolCodeAsThePosition() public {
		VerantaPerpPositionV2 position = _createPosition();
		positionFactory.setReferral(IVerantaReferral(address(veranta)), bytes32('frostyfi'));

		_call(position, abi.encode(uint8(VerantaPerpPositionV2.Action.LinkReferral), ''));
		assertEq(veranta.traderReferralCodes(address(position)), bytes32('frostyfi'), 'the position is the referred trader');
		assertEq(veranta.traderReferralCodes(address(comptroller)), bytes32(0));
	}

	function test_linkReferral_revertsUntilConfigured() public {
		VerantaPerpPositionV2 position = _createPosition();
		(address[] memory noAssets, uint256[] memory noAmounts) = _none();
		bytes memory link = abi.encode(uint8(VerantaPerpPositionV2.Action.LinkReferral), '');

		vm.prank(manager);
		vm.expectRevert(VerantaPerpPositionV2.ReferralNotConfigured.selector);
		comptroller.callOnExternalPosition(address(position), noAssets, noAmounts, noAssets, link);

		positionFactory.setReferral(IVerantaReferral(address(veranta)), bytes32(0)); // contract but no code
		vm.prank(manager);
		vm.expectRevert(VerantaPerpPositionV2.ReferralNotConfigured.selector);
		comptroller.callOnExternalPosition(address(position), noAssets, noAmounts, noAssets, link);
	}

	function test_setReferral_onlyOwner() public {
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
		positionFactory.setReferral(IVerantaReferral(address(veranta)), bytes32('managercode'));
	}

	function test_unknownAction_reverts() public {
		VerantaPerpPositionV2 position = _createPosition();
		(address[] memory noAssets, uint256[] memory noAmounts) = _none();
		vm.prank(manager);
		vm.expectRevert(VerantaPerpPositionV2.UnknownAction.selector);
		comptroller.callOnExternalPosition(
			address(position), noAssets, noAmounts, noAssets, abi.encode(uint8(42), '')
		);
	}

	function test_restingLimitOrder_valuedAtEscrow() public {
		VerantaPerpPositionV2 position = _createPosition();
		// Fund the position, then simulate a resting limit order escrowing 600 USDC
		address[] memory transferAssets = new address[](1);
		transferAssets[0] = address(usdc);
		uint256[] memory transferAmounts = new uint256[](1);
		transferAmounts[0] = 600e6;
		(address[] memory noAssets,) = _none();
		vm.prank(manager);
		comptroller.callOnExternalPosition(
			address(position), transferAssets, transferAmounts, noAssets,
			abi.encode(uint8(VerantaPerpPositionV2.Action.ReturnToVault), abi.encode(uint256(0)))
		);
		vm.prank(address(position));
		usdc.approve(address(veranta), 600e6);
		veranta.pushLimitOrder(address(position), ETH_PAIR, 0, 600e6);

		assertEq(usdc.balanceOf(address(position)), 0);
		assertEq(comptroller.calcGav(), 10_000e6);

		_call(position, abi.encode(uint8(VerantaPerpPositionV2.Action.CancelLimitOrder), abi.encode(ETH_PAIR, uint256(0))));
		assertEq(usdc.balanceOf(address(position)), 600e6);
		assertEq(comptroller.calcGav(), 10_000e6);
	}

	// ─── V2-only: the bounded read ──────────────────────────────────────────────

	/// A hedge the autopilot keeper opens THROUGH VERANTA'S DELEGATION never passes through
	/// this contract — valuation must still see it (a "pairs we traded" set would miss it).
	function test_v2_keeperOpenedTradeOnUntouchedPair_isValued() public {
		uint256 otherPair = 3;
		positionFactory.setPairAsset(otherPair, address(teth));
		VerantaPerpPositionV2 position = _createPosition();
		address[] memory transferAssets = new address[](1);
		transferAssets[0] = address(usdc);
		uint256[] memory transferAmounts = new uint256[](1);
		transferAmounts[0] = 1_000e6;
		(address[] memory noAssets,) = _none();
		vm.prank(manager);
		comptroller.callOnExternalPosition(
			address(position), transferAssets, transferAmounts, noAssets,
			abi.encode(uint8(VerantaPerpPositionV2.Action.SetAutopilot), abi.encode(block.timestamp + 90 days))
		);
		bytes memory openCall = abi.encodeCall(
			IVerantaTradingRouter.openTrade,
			(
				IVerantaTradingRouter.Trade({
					trader: address(position), pairIndex: otherPair, index: 0, initialPosToken: 0,
					positionSizeUSDC: 1_000e6, openPrice: 2_500e10, buy: false, leverage: 2e10,
					tp: 0, sl: 0, timestamp: 0
				}),
				0,
				1e10
			)
		);
		vm.prank(keeper);
		veranta.delegatedAction(address(position), openCall);
		veranta.fillPending(2_500e10);

		assertEq(comptroller.calcGav(), 10_000e6, 'keeper hedge valued at entry');
		tethFeed.setAnswer(3_000e8); // short 0.8 ETH loses 400
		assertEq(comptroller.calcGav(), 9_600e6, 'keeper hedge tracks price');
	}

	/// Several trades on one pair sit in distinct slots — every one is valued.
	function test_v2_twoTradesOnOnePair_bothValued() public {
		VerantaPerpPositionV2 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10); // slot 0
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10); // slot 1

		assertEq(comptroller.calcGav(), 10_000e6);
		tethFeed.setAnswer(3_000e8); // 2 × 0.8 ETH short → −800
		assertEq(comptroller.calcGav(), 9_200e6);
	}

	/// The regression guard for the mainnet gas blowup: with 135 listed pairs and one
	/// trade, valuation reads ONE trade slot (V1's getPositions reads 135 × 40 of each).
	function test_v2_readsOnlyOccupiedSlots() public {
		veranta.setPairsCount(135);
		VerantaPerpPositionV2 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);

		vm.expectCall(address(veranta), abi.encodeWithSelector(veranta.openTrades.selector), 1);
		vm.expectCall(address(veranta), abi.encodeWithSelector(veranta.getOpenLimitOrder.selector), 0);
		vm.expectCall(address(veranta), abi.encodeWithSelector(veranta.openTradesCount.selector), 135);
		vm.expectCall(address(veranta), abi.encodeWithSelector(veranta.getPositions.selector), 0);
		position.getManagedAssets();
	}
}
