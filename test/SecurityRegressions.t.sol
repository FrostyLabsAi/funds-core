// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {V6Host} from './utils/V6Host.sol';
import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {ComptrollerV6 as Comptroller} from '../src/core/ComptrollerV6.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {LimitOrderPosition, LimitOrderPositionFactory} from '../src/positions/LimitOrderPosition.sol';
import {UniswapV3LPPositionFactory} from '../src/positions/UniswapV3LPPosition.sol';
import {IUniswapV3NonfungiblePositionManager} from '../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {CumulativeSlippageTolerancePolicy} from '../src/policies/CumulativeSlippageTolerancePolicy.sol';
import {IPolicy} from '../src/interfaces/IPolicy.sol';
import {MockERC20, MockAggregator, MockExternalPositionFactory, MockUniV3PositionManager} from './utils/Mocks.sol';

/// @notice Exploit-regression tests for the 2026-09-22 security review criticals.
///         Written BEHAVIORALLY (no fix-specific symbols) so they compile against the
///         pre-fix code: red = the exploit reproduces, green = it is dead.
///         C-1 donation/share inflation · C-2 zero-GAV minting · C-3 limit-order self-fill.
contract SecurityRegressionsTest is Test {
	uint256 internal constant LIMIT_ORDER_TYPE_ID = 2;
	uint256 internal constant LP_TYPE_ID = 3;
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

		factory = new FundFactory(interpreter, V6Host.deployer(), new SharesVaultDeployer());
		factory.registerPositionType(LIMIT_ORDER_TYPE_ID, address(new LimitOrderPositionFactory()));
		factory.registerPositionType(
			LP_TYPE_ID,
			address(new UniswapV3LPPositionFactory(IUniswapV3NonfungiblePositionManager(address(new MockUniV3PositionManager()))))
		);
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

	// ─── C-3 · limit-order self-fill drain ──────────────────────────────────────

	function _fundWithInventory() internal returns (Comptroller comptroller, LimitOrderPosition position) {
		comptroller = _createFund();
		_deposit(comptroller, alice, 10_000e6);
		vm.prank(manager);
		position = LimitOrderPosition(comptroller.createExternalPosition(LIMIT_ORDER_TYPE_ID, ''));
	}

	function _place(
		Comptroller comptroller,
		LimitOrderPosition position,
		uint256 escrow,
		uint128 sellAmount,
		uint128 minBuyAmount
	) internal {
		address[] memory transferAssets = new address[](1);
		transferAssets[0] = address(usdc);
		uint256[] memory transferAmounts = new uint256[](1);
		transferAmounts[0] = escrow;
		address[] memory noAssets = new address[](0);

		bytes memory place = abi.encode(
			uint8(LimitOrderPosition.Action.PlaceOrder),
			abi.encode(address(usdc), address(gpux), sellAmount, minBuyAmount, uint64(block.timestamp + 1 days))
		);
		vm.prank(manager);
		comptroller.callOnExternalPosition(address(position), transferAssets, transferAmounts, noAssets, place);
	}

	/// The verified drain: sell 5,000 USDC for 1 wei of GPUx, self-fill from an EOA.
	/// Placement this far below the oracle cross-rate must revert.
	function test_c3_placeOrder_farBelowOracle_reverts() public {
		(Comptroller comptroller, LimitOrderPosition position) = _fundWithInventory();
		vm.expectRevert(); // pre-fix: places fine and eve fills 5,000 USDC for 1 wei
		this.placeExternal(comptroller, position, 5_000e6, 5_000e6, 1);
	}

	/// External wrapper so expectRevert cleanly targets the whole place call.
	function placeExternal(
		Comptroller comptroller,
		LimitOrderPosition position,
		uint256 escrow,
		uint128 sellAmount,
		uint128 minBuyAmount
	) external {
		_place(comptroller, position, escrow, sellAmount, minBuyAmount);
	}

	/// An order placed at oracle parity must not be fillable after the market moves so
	/// far that the fill underpays the fund beyond the band (stale-order self-fill).
	function test_c3_fill_afterMarketMove_underpayingFillReverts() public {
		(Comptroller comptroller, LimitOrderPosition position) = _fundWithInventory();
		_place(comptroller, position, 5_000e6, 5_000e6, 50e18); // parity: $100/GPUx

		gpuxFeed.setAnswer(50e8); // GPUx halves: 50 GPUx is now worth 2,500, not 5,000

		uint256 orderId = position.orderCount();
		gpux.mint(eve, 50e18);
		vm.startPrank(eve);
		gpux.approve(address(position), 50e18);
		vm.expectRevert(); // pre-fix: fills — 5,000 USDC out for 2,500 of value in
		position.fill(orderId, 50e18);
		vm.stopPrank();
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

	// ─── H-2 · LP position factories must reject unpriceable tokens ─────────────

	function test_h2_lpFactory_rejectsUnpriceableTokens() public {
		Comptroller comptroller = _createFund();
		MockERC20 junk = new MockERC20('Junk', 'JNK', 18);

		vm.prank(manager);
		vm.expectRevert(); // pre-fix: deploys fine and a 1-wei donation bricks calcGav forever
		comptroller.createExternalPosition(LP_TYPE_ID, abi.encode(address(junk), address(usdc), uint24(3000)));

		// a fully-priced pair still deploys
		vm.prank(manager);
		comptroller.createExternalPosition(LP_TYPE_ID, abi.encode(address(usdc), address(gpux), uint24(3000)));
	}

	/// The residual C-3 skim: place at the band edge (−1%), self-fill, flip the
	/// inventory, repeat — each cycle pockets the band. The in-position replenishing
	/// discount budget must stop cycle 2 and re-allow after the period.
	function test_h1_cycleSkim_budgetStopsTheBleed() public {
		(Comptroller comptroller, LimitOrderPosition position) = _fundWithInventory();

		// cycle 1: sell 5,000 USDC for GPUx worth 4,950 (exactly the 1% band) — fills
		_place(comptroller, position, 5_000e6, 5_000e6, 49.5e18);
		gpux.mint(eve, 100e18);
		vm.startPrank(eve);
		gpux.approve(address(position), type(uint256).max);
		usdc.approve(address(position), type(uint256).max);
		position.fill(1, 49.5e18);
		vm.stopPrank();
		assertEq(position.fillDiscountUsed(), 50e6, 'cycle 1 consumed its discount');

		// cycle 2: flip the inventory back (sell the GPUx at −1% again) — the budget
		// (2% of held value per week) is spent; the fill must revert
		bytes memory placeBack = abi.encode(
			uint8(LimitOrderPosition.Action.PlaceOrder),
			abi.encode(address(gpux), address(usdc), uint128(49.5e18), uint128(4_900_500_000), uint64(block.timestamp + 1 days))
		);
		address[] memory none = new address[](0);
		uint256[] memory noAmounts = new uint256[](0);
		vm.prank(manager);
		comptroller.callOnExternalPosition(address(position), none, noAmounts, none, placeBack);

		vm.prank(eve);
		vm.expectRevert(
			abi.encodeWithSelector(LimitOrderPosition.FillDiscountBudgetExceeded.selector, 99_500_000, 99_000_000)
		);
		position.fill(2, 4_900_500_000);

		// a week replenishes the budget — the same fill then clears (order re-placed
		// because the resting one expired with the wait; feeds refreshed like the real
		// pusher would)
		skip(7 days);
		usdcFeed.setAnswer(1e8);
		gpuxFeed.setAnswer(100e8);
		// the expired order still reserves its inventory — cancel before re-placing
		vm.prank(manager);
		comptroller.callOnExternalPosition(
			address(position), none, noAmounts, none,
			abi.encode(uint8(LimitOrderPosition.Action.CancelOrder), abi.encode(uint256(2)))
		);
		vm.prank(manager);
		comptroller.callOnExternalPosition(address(position), none, noAmounts, none, abi.encode(
			uint8(LimitOrderPosition.Action.PlaceOrder),
			abi.encode(address(gpux), address(usdc), uint128(49.5e18), uint128(4_900_500_000), uint64(block.timestamp + 1 days))
		));
		vm.prank(eve);
		position.fill(3, 4_900_500_000);
		assertEq(position.fillDiscountUsed(), 49_500_000, 'replenished, then consumed the new cycle');
	}

	/// Honest path regression guard: parity placement + parity fill still work.
	function test_c3_honestOrderAndFill_stillWork() public {
		(Comptroller comptroller, LimitOrderPosition position) = _fundWithInventory();
		_place(comptroller, position, 5_000e6, 5_000e6, 50e18);

		gpux.mint(eve, 50e18);
		vm.startPrank(eve);
		gpux.approve(address(position), 50e18);
		position.fill(position.orderCount(), 50e18);
		vm.stopPrank();

		assertEq(usdc.balanceOf(eve), 1_000_000e6 + 5_000e6, 'taker received inventory at the limit rate');
		assertEq(gpux.balanceOf(address(position)), 50e18, 'fund received proceeds');
	}
}
