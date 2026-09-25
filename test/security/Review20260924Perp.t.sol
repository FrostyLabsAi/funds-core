// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../../src/core/FundComponentDeployers.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {VerantaPerpPositionV2, VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {
	IVerantaTradingRouter,
	IVerantaMulticall,
	IVerantaPairStorage,
	IVerantaReferral
} from '../../src/interfaces/external/IVeranta.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {MockERC20, MockAggregator} from '../utils/Mocks.sol';
import {MockVeranta} from '../utils/MockVeranta.sol';

/// @notice V1's full suite, run against VerantaPerpPositionV2 — the bounded read must value
///         every case exactly as V1 did — plus V2-only cases below.
/// @notice Security review 2026-09-24 — RED until fixed:
///         H-1 a perp cannot be closed through the fund while any price its valuation needs
///             is unavailable (here: the new L2 sequencer check, down then in its grace period;
///             equally a stale feed) — callOnExternalPosition values the position before and
///             after every action, so the manager cannot de-risk exactly when markets are wild.
///         M-3 V2 valuation FAILS OPEN — a trade whose slot read reverts is skipped and GAV
///             silently drops it instead of refusing to price.
contract Review20260924PerpTest is Test {
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


	function _close(VerantaPerpPositionV2 position) internal {
		_call(
			position,
			abi.encode(uint8(VerantaPerpPositionV2.Action.CloseTrade), abi.encode(ETH_PAIR, uint256(0), uint256(1_000e6), uint256(2_500e10)))
		);
	}

	function test_h1_cannotCloseThePerpWhileTheSequencerIsDown() public {
		VerantaPerpPositionV2 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);

		MockAggregator sequencer = new MockAggregator(0, 0);
		skip(2 hours);
		tethFeed.setAnswer(2_500e8);
		vm.prank(admin);
		interpreter.setSequencerUptimeFeed(address(sequencer), 1 hours);
		sequencer.setAnswer(1); // sequencer down

		// the manager's risk-reducing close must still go through
		_close(position);
		assertEq(usdc.balanceOf(address(position)), 1_000e6, 'H-1: close refused while the sequencer is down');
	}

	function test_h1_cannotCloseThePerpWhileItsFeedIsStale() public {
		VerantaPerpPositionV2 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		skip(8 days); // tETH feed (7-day heartbeat) goes stale — e.g. a missed pull-oracle push

		_close(position);
		assertEq(usdc.balanceOf(address(position)), 1_000e6, 'H-1: close refused while the pair price is stale');
	}

	function test_h1_nonRiskReducingActionIsStillPricedWhileStale() public {
		VerantaPerpPositionV2 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		skip(8 days); // tETH stale — the filled trade's coin leg cannot be priced
		vm.expectRevert(); // SetAutopilot is not risk-reducing: priced like anything else
		_call(position, abi.encode(uint8(VerantaPerpPositionV2.Action.SetAutopilot), abi.encode(block.timestamp + 1 days)));
	}

	function test_h1_riskReducingActionWithVaultOutflow_isStillPriced() public {
		VerantaPerpPositionV2 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		skip(8 days);
		// a "close" that also pulls USDC out of the vault is priced like anything else
		address[] memory transferAssets = new address[](1);
		transferAssets[0] = address(usdc);
		uint256[] memory transferAmounts = new uint256[](1);
		transferAmounts[0] = 1e6;
		(address[] memory noAssets,) = _none();
		bytes memory close =
			abi.encode(uint8(VerantaPerpPositionV2.Action.CloseTrade), abi.encode(ETH_PAIR, uint256(0), uint256(1_000e6), uint256(2_500e10)));
		vm.prank(manager);
		vm.expectRevert();
		comptroller.callOnExternalPosition(address(position), transferAssets, transferAmounts, noAssets, close);
	}

	function test_m3_unreadableTradeSlotMustNotVanishFromGav() public {
		VerantaPerpPositionV2 position = _createPosition();
		_openStandardTrade(position, true); // long 2x ETH, $1,000 collateral
		veranta.fillPending(2_500e10);
		tethFeed.setAnswer(3_000e8); // +20% → the long is worth $1,400
		uint256 gavWithTrade = comptroller.calcGav();

		// Veranta's slot read for the (counted) trade starts reverting — e.g. an upgrade
		vm.mockCallRevert(
			address(veranta),
			abi.encodeWithSignature('openTrades(address,uint256,uint256)', address(position), ETH_PAIR, uint256(0)),
			'upgraded'
		);
		try comptroller.calcGav() returns (uint256 gav) {
			assertEq(gav, gavWithTrade, 'M-3: an unreadable open trade silently disappeared from GAV');
		} catch {
			// failing closed (refusing to price) is the correct behaviour
		}
	}
}
