// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {Shares} from '../src/fund/Shares.sol';
import {Vault} from '../src/fund/Vault.sol';
import {MathHelpers} from '../src/libraries/MathHelpers.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';

contract FundFlowsTest is Test {
	uint256 internal constant RATE_SCALE = 1e27;
	// ≈2% annual management fee as a per-second compounding rate (1e27 scale).
	uint128 internal constant MGMT_RATE_2PCT = 1_000_000_000_640_000_000_000_000_000;

	FundFactory internal factory;
	ValueInterpreter internal interpreter;
	MockERC20 internal usdc;
	MockAggregator internal usdcFeed;

	address internal admin = makeAddr('admin');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');
	address internal bob = makeAddr('bob');

	function setUp() public {
		vm.warp(30 days);
		interpreter = new ValueInterpreter(admin);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		usdcFeed = new MockAggregator(8, 1e8);
		vm.prank(admin);
		interpreter.addPrimitive(address(usdc), address(usdcFeed), 7 days);

		factory = new FundFactory(interpreter, new ComptrollerDeployer(), new SharesVaultDeployer());

		usdc.mint(alice, 1_000_000e6);
		usdc.mint(bob, 1_000_000e6);
	}

	function _createFund(uint128 mgmtRate, uint16 perfBps) internal returns (Comptroller comptroller) {
		address comptrollerAddress = factory.createFund(
			FundFactory.FundConfig({
				name: 'Frosty Alpha',
				symbol: 'frALPHA',
				denominationAsset: IERC20(address(usdc)),
				fundOwner: manager,
				mgmtScaledPerSecondRate: mgmtRate,
				perfFeeBps: perfBps,
				sharesActionTimelock: 1 days,
				minRequestDuration: 30 minutes,
				executionWindow: 1 days,
				allowRiskyAssets: false
			})
		);
		comptroller = Comptroller(comptrollerAddress);
	}

	function _depositFor(Comptroller comptroller, address depositor, uint256 assets) internal {
		vm.startPrank(depositor);
		usdc.approve(address(comptroller), assets);
		comptroller.requestDeposit(assets);
		vm.stopPrank();
		skip(30 minutes);
		comptroller.executeDepositRequest(depositor);
	}

	// ─── Creation & caps ─────────────────────────────────────────────────────────

	function test_createFund_wiring() public {
		Comptroller comptroller = _createFund(0, 1500);
		assertEq(comptroller.fundOwner(), manager);
		assertEq(comptroller.defaultSharePrice(), 1e6);
		assertEq(comptroller.highWaterMark(), 1e6);
		assertEq(comptroller.shares().comptroller(), address(comptroller));
		assertEq(comptroller.vault().comptroller(), address(comptroller));
		address[] memory tracked = comptroller.getTrackedAssets();
		assertEq(tracked.length, 1);
		assertEq(tracked[0], address(usdc));
	}

	function test_createFund_enforcesBytecodeCaps() public {
		FundFactory.FundConfig memory config = FundFactory.FundConfig({
			name: 'X',
			symbol: 'X',
			denominationAsset: IERC20(address(usdc)),
			fundOwner: manager,
			mgmtScaledPerSecondRate: 0,
			perfFeeBps: 3001,
			sharesActionTimelock: 1 days,
			minRequestDuration: 30 minutes,
			executionWindow: 1 days,
			allowRiskyAssets: false
		});
		vm.expectRevert(FundFactory.PerfFeeAboveMax.selector);
		factory.createFund(config);

		config.perfFeeBps = 1500;
		config.mgmtScaledPerSecondRate = 1_100_000_000_000_000_000_000_000_000; // way above 10%/yr cap
		vm.expectRevert(FundFactory.MgmtFeeAboveMax.selector);
		factory.createFund(config);

		config.mgmtScaledPerSecondRate = 0;
		config.sharesActionTimelock = 31 days;
		vm.expectRevert(FundFactory.TimelockAboveMax.selector);
		factory.createFund(config);

		config.sharesActionTimelock = 1 days;
		config.minRequestDuration = 30 seconds; // below the 1-minute floor
		vm.expectRevert(FundFactory.RequestDurationOutOfBounds.selector);
		factory.createFund(config);
	}

	// ─── Deposit lifecycle ───────────────────────────────────────────────────────

	function test_firstDeposit_bootstrapsAtDefaultSharePrice() public {
		Comptroller comptroller = _createFund(0, 0);
		_depositFor(comptroller, alice, 1000e6);

		// 1000 USDC at default price (1 USDC per share-unit) = 1000e18 shares minted,
		// of which 1e18 seeds the unredeemable bootstrap sink (donation-inflation defense)
		assertEq(comptroller.shares().balanceOf(alice), 999e18);
		assertEq(comptroller.shares().balanceOf(comptroller.BOOTSTRAP_SHARES_SINK()), 1e18);
		assertEq(comptroller.shares().totalSupply(), 1000e18);
		assertEq(usdc.balanceOf(address(comptroller.vault())), 1000e6);
		assertEq(comptroller.calcGrossShareValue(), 1e6);
	}

	function test_secondDeposit_pricedAtCurrentNav() public {
		Comptroller comptroller = _createFund(0, 0);
		_depositFor(comptroller, alice, 1000e6);

		// Fund doubles (simulated PnL): 1000 → 2000 USDC in vault
		usdc.mint(address(comptroller.vault()), 1000e6);
		assertEq(comptroller.calcGrossShareValue(), 2e6);

		_depositFor(comptroller, bob, 1000e6);
		// Bob pays 2 USDC per share-unit → 500e18 shares
		assertEq(comptroller.shares().balanceOf(bob), 500e18);
	}

	function test_executeDepositRequest_timingWindows() public {
		Comptroller comptroller = _createFund(0, 0);
		vm.startPrank(alice);
		usdc.approve(address(comptroller), 1000e6);
		comptroller.requestDeposit(1000e6);
		vm.stopPrank();

		// Too young
		vm.expectRevert(Comptroller.RequestTooYoung.selector);
		comptroller.executeDepositRequest(alice);

		// Expired after TTL — execution blocked, cancel still works
		skip(2 days);
		vm.expectRevert(Comptroller.RequestExpired.selector);
		comptroller.executeDepositRequest(alice);

		uint256 balanceBefore = usdc.balanceOf(alice);
		vm.prank(alice);
		comptroller.cancelDepositRequest();
		assertEq(usdc.balanceOf(alice), balanceBefore + 1000e6);
	}

	// ─── Fees ────────────────────────────────────────────────────────────────────

	function test_managementFee_continuousCompounding() public {
		Comptroller comptroller = _createFund(MGMT_RATE_2PCT, 0);
		_depositFor(comptroller, alice, 1000e6);
		assertEq(comptroller.shares().balanceOf(manager), 0);

		skip(365.25 days);

		// Trigger settlement via a second deposit; compute expectation at execution time
		vm.startPrank(bob);
		usdc.approve(address(comptroller), 100e6);
		comptroller.requestDeposit(100e6);
		vm.stopPrank();
		skip(30 minutes);

		uint256 actualElapsed = block.timestamp - comptroller.lastMgmtFeeSettled();
		uint256 supplyBefore = comptroller.shares().totalSupply();
		uint256 expectedFeeShares =
			Math.mulDiv(MathHelpers.rpow(MGMT_RATE_2PCT, actualElapsed, RATE_SCALE) - RATE_SCALE, supplyBefore, RATE_SCALE);

		comptroller.executeDepositRequest(bob);

		uint256 managerShares = comptroller.shares().balanceOf(manager);
		assertEq(managerShares, expectedFeeShares);
		// ~2% annual: 1000e18 supply → ~20.4e18 fee shares (effective rate k = x/(1-x))
		assertApproxEqRel(managerShares, 20.4e18, 0.02e18);
	}

	function test_performanceFee_hwmAccrual() public {
		uint16 perfBps = 1500; // 15%, the flagship config
		Comptroller comptroller = _createFund(0, perfBps);
		_depositFor(comptroller, alice, 1000e6);

		// +1000 USDC of PnL → gross share price 2e6 > HWM 1e6
		usdc.mint(address(comptroller.vault()), 1000e6);

		// Expected per spec/fee-formulas/performance-fee.md:
		// W = (2e6 - 1e6) * 1000e18 / 1e18 = 1000e6; F = 150e6;
		// feeShares = 150e6 * 1000e18 / (2000e6 - 150e6)
		uint256 expectedFeeShares = Math.mulDiv(150e6, 1000e18, 1850e6);

		_depositFor(comptroller, bob, 1000e6);

		assertEq(comptroller.shares().balanceOf(manager), expectedFeeShares);

		// HWM updated to the post-dilution share price (pre-bob supply: alice + fee shares)
		uint256 expectedHwm = Math.mulDiv(2000e6, 1e18, 1000e18 + expectedFeeShares);
		assertEq(comptroller.highWaterMark(), expectedHwm);

		// No double-charge: another deposit at the same share price mints no new fee shares
		uint256 managerSharesBefore = comptroller.shares().balanceOf(manager);
		_depositFor(comptroller, alice, 100e6);
		assertEq(comptroller.shares().balanceOf(manager), managerSharesBefore);
	}

	function test_performanceFee_notChargedBelowHwm() public {
		Comptroller comptroller = _createFund(0, 1500);
		_depositFor(comptroller, alice, 1000e6);

		// Fund loses 20%: vault 1000 → 800
		Vault vault = comptroller.vault();
		vm.prank(address(comptroller));
		vault.withdraw(address(usdc), makeAddr('sink'), 200e6);

		_depositFor(comptroller, bob, 100e6);
		assertEq(comptroller.shares().balanceOf(manager), 0);
	}

	// ─── Redemptions ─────────────────────────────────────────────────────────────

	function test_redeemForDenominationAsset() public {
		Comptroller comptroller = _createFund(0, 0);
		_depositFor(comptroller, alice, 1000e6);

		skip(1 days); // timelock

		vm.prank(alice);
		comptroller.redeemSharesForDenominationAsset(400e18);

		assertEq(comptroller.shares().balanceOf(alice), 599e18); // 999e18 after the bootstrap seed − 400e18
		assertEq(usdc.balanceOf(alice), 1_000_000e6 - 1000e6 + 400e6);
		assertEq(usdc.balanceOf(address(comptroller.vault())), 600e6);
	}

	function test_redeemInKind_worksWithStaleEquityFeeds() public {
		Comptroller comptroller = _createFund(0, 0);
		_depositFor(comptroller, alice, 1000e6);

		// Fund also holds a tokenized stock (4h heartbeat = market-hours gate)
		MockERC20 nvdax = new MockERC20('NVDA Wrapper', 'NVDAx', 18);
		MockAggregator nvdaxFeed = new MockAggregator(8, 180e8);
		vm.prank(admin);
		interpreter.addPrimitive(address(nvdax), address(nvdaxFeed), 4 hours);
		vm.prank(manager);
		comptroller.addTrackedAsset(address(nvdax));
		nvdax.mint(address(comptroller.vault()), 10e18);

		// Weekend: equity feed stops updating; timelock also passes
		skip(1 days);
		usdcFeed.setAnswer(1e8); // crypto feed stays fresh

		// Value-based redemption is blocked by the stale equity feed…
		uint256 staleUpdatedAt = nvdaxFeed.updatedAt();
		vm.prank(alice);
		vm.expectRevert(abi.encodeWithSelector(ValueInterpreter.StalePrice.selector, address(nvdax), staleUpdatedAt));
		comptroller.redeemSharesForDenominationAsset(100e18);

		// …but the guaranteed 24/7 exit works, paying out BOTH assets prorata.
		vm.prank(alice);
		comptroller.redeemSharesInKind(500e18);
		assertEq(comptroller.shares().balanceOf(alice), 499e18); // 999e18 after the bootstrap seed − 500e18
		assertEq(usdc.balanceOf(address(comptroller.vault())), 500e6);
		assertEq(usdc.balanceOf(alice), 1_000_000e6 - 1000e6 + 500e6);
		assertEq(nvdax.balanceOf(alice), 5e18);
	}

	function test_redeemInKindWithSkips_forfeitsBrokenAsset() public {
		Comptroller comptroller = _createFund(0, 0);
		_depositFor(comptroller, alice, 1000e6);

		// Fund also holds a second asset (imagine its transfers are frozen)
		MockERC20 frozen = new MockERC20('Frozen Wrapper', 'FRZx', 18);
		MockAggregator frozenFeed = new MockAggregator(8, 10e8);
		vm.prank(admin);
		interpreter.addPrimitive(address(frozen), address(frozenFeed), 7 days);
		vm.prank(manager);
		comptroller.addTrackedAsset(address(frozen));
		frozen.mint(address(comptroller.vault()), 100e18);

		skip(1 days);

		// Redeem half, skipping the frozen asset: USDC pays out, frozen stays (forfeited)
		address[] memory skips = new address[](1);
		skips[0] = address(frozen);
		vm.prank(alice);
		comptroller.redeemSharesInKindWithSkips(500e18, skips);

		assertEq(usdc.balanceOf(address(comptroller.vault())), 500e6);
		assertEq(frozen.balanceOf(address(comptroller.vault())), 100e18); // untouched
		assertEq(frozen.balanceOf(alice), 0);

		// Holdings views
		(address[] memory assets, uint256[] memory balances) = comptroller.getFundHoldings();
		assertEq(assets.length, 2);
		assertEq(balances[0], 500e6);
		assertEq(comptroller.calcAssetGav(address(frozen)), 1000e6); // 100 FRZx * $10
	}

	function test_sharesActionTimelock_blocksEarlyRedeemAndTransfer() public {
		Comptroller comptroller = _createFund(0, 0);
		_depositFor(comptroller, alice, 1000e6);

		Shares fundShares = comptroller.shares();

		vm.startPrank(alice);
		vm.expectRevert(abi.encodeWithSelector(Comptroller.SharesActionTimelocked.selector, alice));
		comptroller.redeemSharesForDenominationAsset(100e18);

		vm.expectRevert(abi.encodeWithSelector(Comptroller.SharesActionTimelocked.selector, alice));
		fundShares.transfer(bob, 100e18);

		skip(1 days);
		fundShares.transfer(bob, 100e18);
		assertEq(fundShares.balanceOf(bob), 100e18);
		vm.stopPrank();
	}
}
