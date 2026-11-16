// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {FundHost} from './utils/FundHost.sol';
import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {SharesVaultDeployer} from '../src/core/SharesVaultDeployer.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {ProtocolFeeReserve} from '../src/core/ProtocolFeeReserve.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';

/// @notice Protocol AUM fee + FROST-burn buyback: factory-set bps/yr of share supply minted
///         to the protocol recipient at every fee settlement, with an optional manager-triggered
///         buyback that burns FROST worth HALF the shares' value and destroys the shares.
contract ProtocolFeeTest is Test {
	uint256 internal constant SECONDS_IN_YEAR = 31_557_600;
	address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

	FundFactory internal factory;
	ValueInterpreter internal interpreter;
	MockERC20 internal usdc;
	MockERC20 internal frost;
	MockAggregator internal usdcFeed;
	MockAggregator internal frostFeed;
	ProtocolFeeReserve internal reserve;
	Comptroller internal comptroller;

	address internal admin = makeAddr('admin');
	address internal manager = makeAddr('manager');
	address internal treasury = makeAddr('treasury');
	address internal alice = makeAddr('alice');

	function setUp() public {
		vm.warp(30 days);
		interpreter = new ValueInterpreter(admin);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		frost = new MockERC20('Frosty', 'FROST', 18);
		usdcFeed = new MockAggregator(8, 1e8); // $1.00
		frostFeed = new MockAggregator(8, 5e7); // $0.50
		vm.startPrank(admin);
		interpreter.addPrimitive(address(usdc), address(usdcFeed), 7 days);
		interpreter.addPrimitive(address(frost), address(frostFeed), 7 days);
		vm.stopPrank();

		factory = new FundFactory(interpreter, FundHost.deployer(), new SharesVaultDeployer()); // this test = factory owner
		reserve = new ProtocolFeeReserve(address(frost), admin);

		comptroller = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Protocol Fee Fund',
					symbol: 'frPFEE',
					denominationAsset: IERC20(address(usdc)),
					fundOwner: manager,
					mgmtScaledPerSecondRate: 0, // isolate the protocol fee
					perfFeeBps: 0,
					sharesActionTimelock: 0,
					minRequestDuration: 30 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				})
			)
		);

		usdc.mint(alice, 100_000e6);
	}

	function _depositFor(address depositor, uint256 assets) internal {
		vm.startPrank(depositor);
		usdc.approve(address(comptroller), assets);
		comptroller.requestDeposit(assets, type(uint256).max);
		vm.stopPrank();
		skip(30 minutes);
		comptroller.executeDepositRequest(depositor);
	}

	function _refreshFeeds() internal {
		usdcFeed.setAnswer(1e8);
		frostFeed.setAnswer(5e7);
	}

	// ─── Accrual ─────────────────────────────────────────────────────────────────

	function test_protocolFee_accruesStraightDilution_toRecipient() public {
		factory.setProtocolFee(25, treasury);
		_depositFor(alice, 1000e6); // supply = 1000e18 (999 alice + 1 bootstrap sink)

		skip(SECONDS_IN_YEAR);
		_refreshFeeds();
		comptroller.settleFees();

		// Straight-dilution mint, same convention as the management fee: exactly
		// 25 bps of the pre-mint supply after one year.
		assertEq(comptroller.shares().balanceOf(treasury), 2.5e18, 'one year at 25 bps of 1000e18');
		// Investors paid it via dilution: gross share price dropped below $1.
		assertEq(comptroller.calcGrossShareValue(), Math.mulDiv(1000e6, 1e18, 1002.5e18));
	}

	function test_protocolFee_disabled_mintsNothing_butClockAdvances() public {
		_depositFor(alice, 1000e6);
		skip(SECONDS_IN_YEAR);
		_refreshFeeds();
		comptroller.settleFees();

		assertEq(comptroller.shares().balanceOf(treasury), 0);
		assertEq(comptroller.lastProtocolFeeSettled(), block.timestamp, 'clock advances even while disabled');
	}

	function test_protocolFee_enablingLater_neverBackCharges() public {
		_depositFor(alice, 1000e6);

		// A dormant fee-free year, settled at its end (clock catches up at 0 bps)...
		skip(SECONDS_IN_YEAR);
		_refreshFeeds();
		comptroller.settleFees();

		// ...then the fee turns on: only time SINCE the last settlement is charged.
		factory.setProtocolFee(25, treasury);
		skip(1 days);
		_refreshFeeds();
		comptroller.settleFees();

		uint256 supply = 1000e18;
		uint256 expected = (supply * 25 * 1 days) / (SECONDS_IN_YEAR * 10_000);
		assertEq(comptroller.shares().balanceOf(treasury), expected, 'one day of fee, not one year');
	}

	function test_protocolFee_redemption_settlesBeforeProrata() public {
		factory.setProtocolFee(25, treasury);
		_depositFor(alice, 1000e6);
		skip(30 days);
		usdcFeed.setAnswer(1e8);

		vm.prank(alice);
		comptroller.redeemShares(999e18);

		uint256 expectedFee = (1000e18 * 25 * 30 days) / (SECONDS_IN_YEAR * 10_000);
		assertEq(comptroller.shares().balanceOf(treasury), expectedFee, 'fee settled');
		// Alice's prorata slice was computed AGAINST the diluted supply.
		assertEq(usdc.balanceOf(alice), 99_000e6 + Math.mulDiv(1000e6, 999e18, 1000e18 + expectedFee));
	}

	// ─── Governance bounds ───────────────────────────────────────────────────────

	function test_setProtocolFee_bytecodeCapAndZeroRecipient() public {
		vm.expectRevert(FundFactory.ProtocolFeeAboveMax.selector);
		factory.setProtocolFee(101, treasury);

		vm.expectRevert(FundFactory.ProtocolFeeRecipientZero.selector);
		factory.setProtocolFee(25, address(0));

		factory.setProtocolFee(100, treasury); // the cap itself is legal
		(uint256 feeBps, address recipient) = factory.getProtocolFeeConfig();
		assertEq(feeBps, 100);
		assertEq(recipient, treasury);

		factory.setProtocolFee(0, address(0)); // full disable is legal
		(feeBps, recipient) = factory.getProtocolFeeConfig();
		assertEq(feeBps, 0);
	}

	function test_setProtocolFee_onlyFactoryOwner() public {
		vm.prank(alice);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
		factory.setProtocolFee(25, treasury);
	}

	// ─── FROST buyback ───────────────────────────────────────────────────────────

	function _accrueReserveShares() internal returns (uint256 reserveShares) {
		factory.setProtocolFee(100, address(reserve));
		_depositFor(alice, 1000e6);
		skip(SECONDS_IN_YEAR);
		_refreshFeeds();
		comptroller.settleFees();
		reserveShares = comptroller.shares().balanceOf(address(reserve));
		assertEq(reserveShares, 10e18, 'one year at 100 bps of 1000e18');
	}

	function test_buyback_burnsSharesAndFrost_atHalfValue() public {
		uint256 reserveShares = _accrueReserveShares();
		frost.mint(address(comptroller.vault()), 100e18); // untracked inventory is fine

		uint256 supplyBefore = comptroller.shares().totalSupply();
		uint256 priceBefore = comptroller.calcGrossShareValue();
		uint256 shareValue = Math.mulDiv(reserveShares, priceBefore, 1e18);
		uint256 frostValue = interpreter.calcCanonicalAssetValue(address(usdc), shareValue, address(frost));
		uint256 expectedBurn = frostValue / 2; // the reserve's 50% discount

		vm.prank(manager);
		factory.buyBackProtocolFeeShares(address(comptroller), reserveShares);

		assertEq(comptroller.shares().balanceOf(address(reserve)), 0, 'fee shares burned');
		assertEq(comptroller.shares().totalSupply(), supplyBefore - reserveShares);
		assertEq(frost.balanceOf(DEAD), expectedBurn, 'FROST destroyed, not transferred');
		assertEq(frost.balanceOf(address(comptroller.vault())), 100e18 - expectedBurn);
		// Holders reclaimed value: burning $X of shares cost only $X/2 of FROST.
		assertGt(comptroller.calcGrossShareValue(), priceBefore);
	}

	function test_buyback_onlyFundOwner() public {
		uint256 reserveShares = _accrueReserveShares();
		vm.prank(alice);
		vm.expectRevert(FundFactory.OnlyFundOwner.selector);
		factory.buyBackProtocolFeeShares(address(comptroller), reserveShares);
	}

	function test_buyback_zeroAmountReverts() public {
		_accrueReserveShares();
		vm.prank(manager);
		vm.expectRevert(FundFactory.ZeroBuyBack.selector);
		factory.buyBackProtocolFeeShares(address(comptroller), 0);
	}

	function test_buyback_unknownFundReverts() public {
		vm.expectRevert(abi.encodeWithSelector(FundFactory.UnknownFund.selector, address(0xBEEF)));
		factory.buyBackProtocolFeeShares(address(0xBEEF), 1e18);
	}

	function test_buyback_plainTreasuryRecipient_reverts() public {
		// A treasury EOA never implements IProtocolFeeReserve — no consent, no buyback.
		factory.setProtocolFee(100, treasury);
		_depositFor(alice, 1000e6);
		skip(SECONDS_IN_YEAR);
		_refreshFeeds();
		comptroller.settleFees();

		vm.prank(manager);
		vm.expectRevert();
		factory.buyBackProtocolFeeShares(address(comptroller), 1e18);
	}

	function test_buyback_executorIsFactoryOnly() public {
		_accrueReserveShares();
		vm.prank(manager); // not even the fund owner may call the raw executor
		vm.expectRevert(Comptroller.OnlyFactory.selector);
		comptroller.executeProtocolFeeBuyBack(address(reserve), address(frost), 1e18, 1e18);
	}

	// ─── Reserve unit behavior ───────────────────────────────────────────────────

	function test_reserve_discountIsHalf() public {
		assertEq(reserve.buyBackShares(10e18, 7e18), 3.5e18);
		assertEq(reserve.burnAsset(), address(frost));
	}

	function test_reserve_withdrawToken_ownerOnly() public {
		frost.mint(address(reserve), 5e18);

		vm.prank(alice);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
		reserve.withdrawToken(address(frost), alice, 5e18);

		vm.prank(admin);
		reserve.withdrawToken(address(frost), treasury, 5e18);
		assertEq(frost.balanceOf(treasury), 5e18);
	}
}
