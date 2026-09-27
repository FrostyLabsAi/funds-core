// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {MinMaxDepositPolicy} from '../src/policies/MinMaxDepositPolicy.sol';
import {IPolicy} from '../src/interfaces/IPolicy.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';

/// @notice Regression tests for the 2026-09-22 review MEDIUMS:
///         M-1 reconfiguration cannot revive suspended funds (a guardian pause carries over) · M-2 exit window ≥ holder
///         timelock · M-3 policies only attach to implemented hooks · M-6 no
///         unexecutable deposit windows · M-7 Chainlink answer-bounds clamp detection.
contract MediumRegressionsTest is Test {
	FundFactory internal factory;
	ValueInterpreter internal interpreter;
	MockERC20 internal usdc;
	MockAggregator internal usdcFeed;

	address internal admin = makeAddr('admin');
	address internal manager = makeAddr('manager');
	address internal guardian = makeAddr('guardian');
	address internal alice = makeAddr('alice');
	address internal bob = makeAddr('bob');
	uint256 internal fundNonce;

	function setUp() public {
		vm.warp(30 days);
		interpreter = new ValueInterpreter(admin);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		usdcFeed = new MockAggregator(8, 1e8);
		vm.prank(admin);
		interpreter.addPrimitive(address(usdc), address(usdcFeed), 7 days);

		factory = new FundFactory(interpreter, new ComptrollerDeployer(), new SharesVaultDeployer());
		factory.setGuardian(guardian);
		usdc.mint(alice, 100_000e6);
	}

	function _config(uint64 timelock, uint64 minRequestDuration) internal returns (FundFactory.FundConfig memory) {
		return FundFactory.FundConfig({
			name: string.concat('Medium Fund #', vm.toString(++fundNonce)),
			symbol: 'frMED',
			denominationAsset: IERC20(address(usdc)),
			fundOwner: manager,
			mgmtScaledPerSecondRate: 0,
			perfFeeBps: 0,
			sharesActionTimelock: timelock,
			minRequestDuration: minRequestDuration,
			executionWindow: 1 days,
			allowRiskyAssets: false
		});
	}

	function _seededFund(uint64 timelock) internal returns (Comptroller comptroller) {
		comptroller = Comptroller(factory.createFund(_config(timelock, 30 minutes)));
		vm.startPrank(alice);
		usdc.approve(address(comptroller), 1_000e6);
		comptroller.requestDeposit(1_000e6);
		vm.stopPrank();
		skip(30 minutes);
		comptroller.executeDepositRequest(alice);
	}

	// ─── M-1 · reconfiguration must not revive suspended funds ──────────────────
	// A guardian pause may reconfigure (the bug-fix path: pause, then move to the fixed
	// build) but the pause CARRIES OVER — the fresh Comptroller never starts open.

	function _assertStillPausedAfterSwap(Comptroller oldComptroller, address newComptroller) internal {
		assertTrue(Comptroller(newComptroller).guardianDepositsPaused(), 'the swap reopened deposits');
		assertTrue(oldComptroller.guardianDepositsPaused());

		usdc.mint(bob, 100e6);
		vm.startPrank(bob);
		usdc.approve(newComptroller, 100e6);
		vm.expectRevert(Comptroller.DepositsSuspended.selector);
		Comptroller(newComptroller).requestDeposit(100e6);
		vm.stopPrank();

		// Neither the fund owner nor the guardian can reopen — only the factory owner
		vm.prank(manager);
		vm.expectRevert();
		factory.unpauseFundDeposits(newComptroller);
		vm.prank(guardian);
		vm.expectRevert();
		factory.unpauseFundDeposits(newComptroller);
		factory.unpauseFundDeposits(newComptroller); // this test contract = factory owner
		assertFalse(Comptroller(newComptroller).guardianDepositsPaused());
	}

	function test_m1_guardianPausedFund_reconfiguresStillPaused() public {
		Comptroller comptroller = _seededFund(0);
		vm.prank(guardian);
		factory.pauseFundDeposits(address(comptroller));

		vm.prank(manager);
		address newComptroller = factory.createReconfigurationRequest(address(comptroller), _config(0, 30 minutes));
		skip(2 days);
		vm.prank(manager);
		factory.executeReconfiguration(address(comptroller));

		_assertStillPausedAfterSwap(comptroller, newComptroller);
	}

	function test_m1_pauseDuringWindow_carriesOver() public {
		Comptroller comptroller = _seededFund(0);
		vm.prank(manager);
		address newComptroller = factory.createReconfigurationRequest(address(comptroller), _config(0, 30 minutes));

		vm.prank(guardian);
		factory.pauseFundDeposits(address(comptroller)); // emergency lands mid-window
		skip(2 days);

		vm.prank(manager);
		factory.executeReconfiguration(address(comptroller));

		_assertStillPausedAfterSwap(comptroller, newComptroller);
	}

	function test_m1_shutDownDuringWindow_blocksExecution() public {
		Comptroller comptroller = _seededFund(0);
		vm.prank(manager);
		factory.createReconfigurationRequest(address(comptroller), _config(0, 30 minutes));
		vm.prank(manager);
		comptroller.shutDownFund();
		skip(2 days);

		vm.prank(manager);
		vm.expectRevert(FundFactory.FundSuspended.selector);
		factory.executeReconfiguration(address(comptroller));
	}

	function test_m1_shutDownFund_cannotReconfigure() public {
		Comptroller comptroller = _seededFund(0);
		vm.prank(manager);
		comptroller.shutDownFund();

		vm.prank(manager);
		vm.expectRevert(FundFactory.FundSuspended.selector);
		factory.createReconfigurationRequest(address(comptroller), _config(0, 30 minutes));
	}

	// ─── M-2 · the exit window covers the holder timelock ───────────────────────

	function test_m2_exitWindowAtLeastTheSharesTimelock() public {
		Comptroller comptroller = _seededFund(10 days);
		vm.prank(manager);
		factory.createReconfigurationRequest(address(comptroller), _config(10 days, 30 minutes));
		(, uint64 executableAt) = factory.reconfigurationRequests(address(comptroller));
		assertEq(executableAt, block.timestamp + 10 days, 'window must cover the 10-day holder timelock');

		Comptroller quickFund = _seededFund(1 days);
		vm.prank(manager);
		factory.createReconfigurationRequest(address(quickFund), _config(1 days, 30 minutes));
		(, uint64 quickAt) = factory.reconfigurationRequests(address(quickFund));
		assertEq(quickAt, block.timestamp + 2 days, 'short timelocks keep the 2-day floor');
	}

	// ─── M-3 · policies attach only to hooks they implement ─────────────────────

	function test_m3_stockPolicyOnForeignHook_refusedAtCreation() public {
		MinMaxDepositPolicy policy = new MinMaxDepositPolicy(0, 0);
		FundFactory.PolicyReg[] memory regs = new FundFactory.PolicyReg[](1);
		// the redemption-brick rug kit: MinMax(0,0) on the redemption hook reverts forever
		regs[0] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.RedeemSharesForSpecificAssets, policy: address(policy)});
		vm.expectRevert(
			abi.encodeWithSelector(
				Comptroller.HookNotImplemented.selector, IPolicy.PolicyHook.RedeemSharesForSpecificAssets, address(policy)
			)
		);
		factory.createFund(_config(0, 30 minutes), regs);
	}

	function test_m3_policyOnItsOwnHook_stillAttaches() public {
		MinMaxDepositPolicy policy = new MinMaxDepositPolicy(1e6, 1_000_000e6);
		FundFactory.PolicyReg[] memory regs = new FundFactory.PolicyReg[](1);
		regs[0] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostDepositRequest, policy: address(policy)});
		Comptroller comptroller = Comptroller(factory.createFund(_config(0, 30 minutes), regs));
		assertEq(comptroller.getPolicies(IPolicy.PolicyHook.PostDepositRequest).length, 1);
	}

	// ─── M-6 · deposit windows must be executable ───────────────────────────────

	function test_m6_executionWindowBounds_enforced() public {
		// long request durations are now VALID — expiry is maturity + window by
		// construction, so the old empty-TTL-window failure mode no longer exists
		factory.createFund(_config(0, 2 days));

		vm.expectRevert(FundFactory.ExecutionWindowOutOfBounds.selector);
		factory.createFund(_configWindow(30 minutes, 10 minutes)); // below the 15-min floor

		vm.expectRevert(FundFactory.ExecutionWindowOutOfBounds.selector);
		factory.createFund(_configWindow(30 minutes, 8 days)); // above the 7-day cap

		factory.createFund(_configWindow(30 minutes, 15 minutes)); // at the floor works
	}

	function _configWindow(uint64 minRequestDuration, uint64 window)
		internal
		returns (FundFactory.FundConfig memory config)
	{
		config = _config(0, minRequestDuration);
		config.executionWindow = window;
	}

	// ─── M-7 · Chainlink min/maxAnswer clamp detection ──────────────────────────

	function test_m7_answerBounds_catchClampedFeeds() public {
		// cross-quote so the usdc feed is actually read (identity quotes short-circuit)
		MockERC20 teth = new MockERC20('Test ETH', 'tETH', 18);
		MockAggregator tethFeed = new MockAggregator(8, 2_500e8);
		vm.prank(admin);
		interpreter.addPrimitive(address(teth), address(tethFeed), 7 days);

		// unset bounds: prices as before
		assertEq(interpreter.calcCanonicalAssetValue(address(teth), 1e18, address(usdc)), 2_500e6);

		vm.prank(admin);
		interpreter.setAnswerBounds(address(usdc), 1e6, 1e10);

		// healthy answer inside the band still prices
		assertEq(interpreter.calcCanonicalAssetValue(address(teth), 1e18, address(usdc)), 2_500e6);

		// LUNA-class: the aggregator pins AT its minAnswer — refuse instead of mispricing
		usdcFeed.setAnswer(1e6);
		vm.expectRevert(abi.encodeWithSelector(ValueInterpreter.AnswerOutOfBounds.selector, address(usdc), int256(1e6)));
		interpreter.calcCanonicalAssetValue(address(teth), 1e18, address(usdc));

		usdcFeed.setAnswer(1e10); // pinned at maxAnswer
		vm.expectRevert(abi.encodeWithSelector(ValueInterpreter.AnswerOutOfBounds.selector, address(usdc), int256(1e10)));
		interpreter.calcCanonicalAssetValue(address(teth), 1e18, address(usdc));
	}

	function test_m7_boundsValidation_andOwnerGate() public {
		vm.prank(admin);
		vm.expectRevert(ValueInterpreter.BadBounds.selector);
		interpreter.setAnswerBounds(address(usdc), 10, 5);

		vm.expectRevert(); // non-owner
		interpreter.setAnswerBounds(address(usdc), 1, 2);
	}
}
