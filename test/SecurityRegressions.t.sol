// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {FundHost} from './utils/FundHost.sol';
import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {SharesVaultDeployer} from '../src/core/SharesVaultDeployer.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {CumulativeSlippageTolerancePolicy} from '../src/policies/CumulativeSlippageTolerancePolicy.sol';
import {IPolicy} from '../src/interfaces/IPolicy.sol';
import {MockERC20, MockAggregator, MockExternalPositionFactory} from './utils/Mocks.sol';

/// @notice Exploit-regression tests for the 2026-09-22 security review criticals.
///         Written BEHAVIORALLY (no fix-specific symbols) so they compile against the
///         pre-fix code: red = the exploit reproduces, green = it is dead.
///         C-1 donation/share inflation · C-2 zero-GAV minting · H-1 measured position losses. (C-3, the limit-order
///         self-fill, and H-2, the LP factories, went with those position types, 2026-11-15.)
contract SecurityRegressionsTest is Test {
	uint256 internal constant MOCK_EP_TYPE_ID = 9;
	address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
	uint256 internal fundNonce;

	FundFactory internal factory;
	ValueInterpreter internal interpreter;
	MockERC20 internal usdc;
	MockERC20 internal gpux;
	MockAggregator internal usdcFeed;
	MockAggregator internal gpuxFeed;

	address internal admin = makeAddr('admin');
	address internal manager = makeAddr('manager');
	address internal eve = makeAddr('eve'); // attacker
	address internal bob = makeAddr('bob'); // victim depositor
	address internal alice = makeAddr('alice');

	function setUp() public {
		vm.warp(30 days);
		interpreter = new ValueInterpreter(admin);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		gpux = new MockERC20('GigaPU', 'GPUx', 18);
		gpuxFeed = new MockAggregator(8, 100e8); // $100
		usdcFeed = new MockAggregator(8, 1e8);
		vm.startPrank(admin);
		interpreter.addPrimitive(address(usdc), address(usdcFeed), 7 days);
		interpreter.addPrimitive(address(gpux), address(gpuxFeed), 7 days);
		vm.stopPrank();

		factory = new FundFactory(interpreter, FundHost.deployer(), new SharesVaultDeployer());
		factory.registerPositionType(MOCK_EP_TYPE_ID, address(new MockExternalPositionFactory()));

		usdc.mint(eve, 1_000_000e6);
		usdc.mint(bob, 1_000_000e6);
		usdc.mint(alice, 1_000_000e6);
	}

	function _createFund() internal returns (Comptroller comptroller) {
		comptroller = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Frosty Alpha',
					symbol: 'frALPHA',
					denominationAsset: IERC20(address(usdc)),
					fundOwner: manager,
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: 0,
					sharesActionTimelock: 0, // legal config — worst case for C-1
					minRequestDuration: 30 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				})
			)
		);
	}

	function _deposit(Comptroller comptroller, address depositor, uint256 assets) internal {
		vm.startPrank(depositor);
		usdc.approve(address(comptroller), assets);
		comptroller.requestDeposit(assets, type(uint256).max);
		vm.stopPrank();
		skip(30 minutes);
		comptroller.executeDepositRequest(depositor);
	}

	// ─── C-1 · donation / share-price inflation via supply dusting ──────────────

	/// The full verified exploit: eve bootstraps, dusts supply via redemption,
	/// then donates against bob's queued 10k deposit and executes it herself.
	/// Bob must keep ≥ 99.5% of his deposit's value; pre-fix he keeps ~75%.
	function test_c1_donationInflation_cannotStealFromNextDepositor() public {
		Comptroller comptroller = _createFund();
		_deposit(comptroller, eve, 10e6);

		// dust the supply: redeem everything eve holds but 1 wei
		uint256 eveShares = comptroller.shares().balanceOf(eve);
		vm.prank(eve);
		comptroller.redeemShares(eveShares - 1);

		// victim queues a 10,000 USDC deposit
		vm.startPrank(bob);
		usdc.approve(address(comptroller), 10_000e6);
		comptroller.requestDeposit(10_000e6, type(uint256).max);
		vm.stopPrank();
		skip(30 minutes);

		// eve donates against the queued deposit and executes it herself
		vm.startPrank(eve);
		usdc.transfer(address(comptroller.vault()), 5_001e6);
		comptroller.executeDepositRequest(bob);
		vm.stopPrank();

		uint256 supply = comptroller.shares().totalSupply();
		uint256 bobShares = comptroller.shares().balanceOf(bob);
		uint256 bobValue = (comptroller.calcGav() * bobShares) / supply;
		assertGe(bobValue, 9_950e6, 'victim deposit value stolen by donation inflation');
	}

	/// Bootstrap must seed unredeemable dead shares so supply can never be dusted below
	/// a floor, and the first depositor pays exactly that seed.
	function test_c1_bootstrapSeedsDeadShares() public {
		Comptroller comptroller = _createFund();
		_deposit(comptroller, alice, 10e6);

		uint256 deadShares = comptroller.shares().balanceOf(DEAD);
		assertEq(deadShares, 1e18, 'bootstrap must mint 1e18 dead shares');
		assertEq(
			comptroller.shares().balanceOf(alice) + deadShares,
			comptroller.shares().totalSupply(),
			'depositor + dead = supply'
		);
		// dead shares are exactly one whole denomination token at the bootstrap price
		assertEq(comptroller.shares().totalSupply(), 10e18, '10 USDC at 1e6 default price');
	}

	/// A bootstrap deposit that cannot cover the dead-share seed must revert instead of
	/// silently donating most of itself.
	function test_c1_bootstrapDepositTooSmall_reverts() public {
		Comptroller comptroller = _createFund();
		vm.startPrank(alice);
		usdc.approve(address(comptroller), 1e6);
		comptroller.requestDeposit(1e6, type(uint256).max); // exactly 1 USDC → sharesToMint == seed
		vm.stopPrank();
		skip(30 minutes);
		vm.expectRevert();
		comptroller.executeDepositRequest(alice);
	}

	// ─── C-2 · gav == 0 with supply outstanding must not mint at default price ──

	function test_c2_zeroGavWithSupply_depositExecutionReverts() public {
		Comptroller comptroller = _createFund();
		_deposit(comptroller, alice, 100e6);

		// simulate a fully side-pocketed / wiped fund: priced GAV hits zero, supply lives
		deal(address(usdc), address(comptroller.vault()), 0);
		assertEq(comptroller.calcGav(), 0, 'setup: gav must be zero');
		assertGt(comptroller.shares().totalSupply(), 0, 'setup: supply outstanding');

		vm.startPrank(bob);
		usdc.approve(address(comptroller), 1e6);
		comptroller.requestDeposit(1e6, type(uint256).max);
		vm.stopPrank();
		skip(30 minutes);

		vm.expectRevert(); // pre-fix: mints 1e18 shares at defaultSharePrice → majority of the fund for $1
		comptroller.executeDepositRequest(bob);

		// the incumbents keep their claim
		assertEq(comptroller.shares().balanceOf(bob), 0, 'no shares minted at zero gav');
	}

	function test_c2_zeroGavWithSupply_theExitStillWorks() public {
		Comptroller comptroller = _createFund();
		_deposit(comptroller, alice, 100e6);
		deal(address(usdc), address(comptroller.vault()), 0);

		uint256 aliceShares = comptroller.shares().balanceOf(alice);
		vm.prank(alice);
		comptroller.redeemShares(aliceShares);
		assertEq(comptroller.shares().balanceOf(alice), 0, 'the exit burned the shares');
	}

	// ─── H-1 · external-position path must feed MEASURED value loss to the mandate ──

	/// A fund whose ruleset registers the slippage policy on BOTH hooks.
	function _slippageGuardedFund(uint256 toleranceBps) internal returns (Comptroller comptroller) {
		CumulativeSlippageTolerancePolicy policy = new CumulativeSlippageTolerancePolicy(toleranceBps);
		FundFactory.PolicyReg[] memory regs = new FundFactory.PolicyReg[](2);
		regs[0] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnIntegration, policy: address(policy)});
		regs[1] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnExternalPosition, policy: address(policy)});
		comptroller = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: string.concat('Guarded Fund #', vm.toString(++fundNonce)),
					symbol: 'frGRD',
					denominationAsset: IERC20(address(usdc)),
					fundOwner: manager,
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: 0,
					sharesActionTimelock: 0,
					minRequestDuration: 30 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				}),
				regs
			)
		);
	}

	function _epTransferIn(Comptroller comptroller, address position, uint256 amount) internal {
		address[] memory transferAssets = new address[](1);
		transferAssets[0] = address(usdc);
		uint256[] memory transferAmounts = new uint256[](1);
		transferAmounts[0] = amount;
		address[] memory noAssets = new address[](0);
		vm.prank(manager);
		comptroller.callOnExternalPosition(position, transferAssets, transferAmounts, noAssets, abi.encode(uint8(0), ''));
	}

	/// The mock position reports NO managed assets — value moved into it is a measured
	/// 100% in-call loss. A 1%-slippage mandate must catch it via the EP hook.
	function test_h1_epValueLoss_hitsTheSlippageMandate() public {
		Comptroller comptroller = _slippageGuardedFund(100); // 1%
		_deposit(comptroller, alice, 10_000e6);
		vm.prank(manager);
		address position = comptroller.createExternalPosition(MOCK_EP_TYPE_ID, '');

		// 1,000 lost of a 10,000 fund = 1000bps vs the 100bps budget
		vm.expectRevert(
			abi.encodeWithSelector(CumulativeSlippageTolerancePolicy.CumulativeSlippageExceeded.selector, 1000, 100)
		);
		this.epTransferInExternal(comptroller, position, 1_000e6); // 10% of the fund, gone
	}

	/// Small in-call losses under the tolerance must accrue, not revert — and then a
	/// second loss that crosses the budget must trip it (same semantics as trades).
	function test_h1_epSmallLosses_accrueIntoTheSameBudget() public {
		Comptroller comptroller = _slippageGuardedFund(100); // 1%
		_deposit(comptroller, alice, 10_000e6);
		vm.prank(manager);
		address position = comptroller.createExternalPosition(MOCK_EP_TYPE_ID, '');

		_epTransferIn(comptroller, position, 50e6); // 0.5% — allowed, accrues

		// 50bps accrued + 80.4bps now (80 of the 9,950 left) = 130.4bps, shown rounded up, vs the 100bps budget
		// (whole-bps accrual read 130; red-team ADAPTERS-01, 2026-10-27)
		vm.expectRevert(
			abi.encodeWithSelector(CumulativeSlippageTolerancePolicy.CumulativeSlippageExceeded.selector, 131, 100)
		);
		this.epTransferInExternal(comptroller, position, 80e6); // cumulative ≈ 1.3% > 1%
	}

	/// External wrapper so expectRevert cleanly targets the whole EP call.
	function epTransferInExternal(Comptroller comptroller, address position, uint256 amount) external {
		_epTransferIn(comptroller, position, amount);
	}
}
