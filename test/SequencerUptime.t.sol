// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {V6Host} from './utils/V6Host.sol';
import {Test} from 'forge-std/Test.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {ComptrollerV6 as Comptroller} from '../src/core/ComptrollerV6.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';

/// @notice L2 Sequencer Uptime check (Chainlink docs: L2 consumers "must" check it).
///         The uptime feed is modelled by MockAggregator exactly like the real one:
///         answer 0 = up / 1 = down, startedAt = when the status last changed.
contract SequencerUptimeTest is Test {
	uint32 internal constant GRACE = 1 hours;

	ValueInterpreter internal interpreter;
	MockERC20 internal usdc;
	MockERC20 internal gpux;
	MockAggregator internal usdcFeed;
	MockAggregator internal gpuxFeed;
	MockAggregator internal sequencer;

	address internal admin = makeAddr('admin');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');
	address internal bob = makeAddr('bob');

	function setUp() public {
		vm.warp(30 days);
		interpreter = new ValueInterpreter(admin);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		gpux = new MockERC20('GigaPU', 'GPUx', 18);
		usdcFeed = new MockAggregator(8, 1e8);
		gpuxFeed = new MockAggregator(8, 100e8);
		sequencer = new MockAggregator(0, 0); // up since deployment
		skip(2 hours); // … and past any grace period
		usdcFeed.setAnswer(1e8);
		gpuxFeed.setAnswer(100e8);

		vm.startPrank(admin);
		interpreter.addPrimitive(address(usdc), address(usdcFeed), 7 days);
		interpreter.addPrimitive(address(gpux), address(gpuxFeed), 7 days);
		interpreter.setSequencerUptimeFeed(address(sequencer), GRACE);
		vm.stopPrank();
	}

	function _sequencerDown() internal {
		sequencer.setAnswer(1);
	}

	function _sequencerUp() internal {
		sequencer.setAnswer(0);
	}

	// ─── ValueInterpreter ────────────────────────────────────────────────────────

	function test_pricesWhileUpPastGrace() public view {
		assertEq(interpreter.calcCanonicalAssetValue(address(gpux), 1e18, address(usdc)), 100e6);
		assertEq(interpreter.calcUsdRate(address(gpux)), 100e18);
	}

	function test_down_refusesEveryPrice() public {
		_sequencerDown();
		vm.expectRevert(ValueInterpreter.SequencerDown.selector);
		interpreter.calcCanonicalAssetValue(address(gpux), 1e18, address(usdc));
		vm.expectRevert(ValueInterpreter.SequencerDown.selector);
		interpreter.calcUsdRate(address(gpux));
	}

	function test_down_sameAssetNeedsNoPrice() public {
		_sequencerDown();
		assertEq(interpreter.calcCanonicalAssetValue(address(usdc), 5e6, address(usdc)), 5e6);
	}

	function test_backUp_refusesThroughGrace_thenPrices() public {
		_sequencerDown();
		skip(3 hours);
		_sequencerUp();
		uint256 upSince = block.timestamp;

		vm.expectRevert(abi.encodeWithSelector(ValueInterpreter.SequencerGracePeriodNotOver.selector, upSince));
		interpreter.calcUsdRate(address(gpux));

		skip(GRACE); // exactly at the edge: still refused (Chainlink's reference uses <=)
		vm.expectRevert(abi.encodeWithSelector(ValueInterpreter.SequencerGracePeriodNotOver.selector, upSince));
		interpreter.calcUsdRate(address(gpux));

		skip(1);
		gpuxFeed.setAnswer(100e8);
		usdcFeed.setAnswer(1e8);
		assertEq(interpreter.calcCanonicalAssetValue(address(gpux), 2e18, address(usdc)), 200e6);
	}

	function test_anyNonZeroAnswerCountsAsDown() public {
		sequencer.setAnswer(2);
		vm.expectRevert(ValueInterpreter.SequencerDown.selector);
		interpreter.calcUsdRate(address(gpux));
	}

	function test_unset_noCheck() public {
		vm.prank(admin);
		interpreter.setSequencerUptimeFeed(address(0), 0);
		_sequencerDown();
		assertEq(interpreter.calcUsdRate(address(gpux)), 100e18);
		assertEq(interpreter.sequencerGracePeriod(), 0);
	}

	function test_setter_onlyOwner() public {
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
		interpreter.setSequencerUptimeFeed(address(0), 0);
	}

	function test_setter_gracePeriodBounds() public {
		vm.startPrank(admin);
		vm.expectRevert(abi.encodeWithSelector(ValueInterpreter.BadGracePeriod.selector, uint32(0)));
		interpreter.setSequencerUptimeFeed(address(sequencer), 0);
		uint32 tooLong = interpreter.MAX_SEQUENCER_GRACE_PERIOD() + 1;
		vm.expectRevert(abi.encodeWithSelector(ValueInterpreter.BadGracePeriod.selector, tooLong));
		interpreter.setSequencerUptimeFeed(address(sequencer), tooLong);
		interpreter.setSequencerUptimeFeed(address(sequencer), 1 days);
		vm.stopPrank();
		assertEq(interpreter.sequencerGracePeriod(), 1 days);
		assertEq(address(interpreter.sequencerUptimeFeed()), address(sequencer));
	}

	// ─── Fund level ──────────────────────────────────────────────────────────────

	function _fundHoldingGpux() internal returns (Comptroller comptroller) {
		FundFactory factory = new FundFactory(interpreter, V6Host.deployer(), new SharesVaultDeployer());
		comptroller = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Frosty Alpha',
					symbol: 'frALPHA',
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
		usdc.mint(alice, 1_000e6);
		vm.startPrank(alice);
		usdc.approve(address(comptroller), 1_000e6);
		comptroller.requestDeposit(1_000e6, type(uint256).max);
		vm.stopPrank();
		skip(30 minutes);
		comptroller.executeDepositRequest(alice);

		vm.prank(manager);
		comptroller.addTrackedAsset(address(gpux));
		gpux.mint(address(comptroller.vault()), 5e18); // $500 of GPUx next to $1,000 USDC
		usdcFeed.setAnswer(1e8);
		gpuxFeed.setAnswer(100e8);
	}

	function test_fund_downBlocksDepositExecution_andSendsTheInstantExitToTheQueue() public {
		Comptroller comptroller = _fundHoldingGpux();
		usdc.mint(bob, 100e6);
		vm.startPrank(bob);
		usdc.approve(address(comptroller), 100e6);
		comptroller.requestDeposit(100e6, type(uint256).max);
		vm.stopPrank();
		skip(30 minutes);
		usdcFeed.setAnswer(1e8);
		gpuxFeed.setAnswer(100e8);

		_sequencerDown();
		vm.expectRevert(ValueInterpreter.SequencerDown.selector);
		comptroller.executeDepositRequest(bob); // no shares minted against an untrusted NAV

		uint256 aliceShares = comptroller.shares().balanceOf(alice);
		vm.prank(alice);
		vm.expectRevert(Comptroller.UseRedemptionQueue.selector);
		comptroller.redeemShares(aliceShares); // no price, no instant exit: the queue takes it
	}

	function test_fund_afterGrace_depositExecutes() public {
		Comptroller comptroller = _fundHoldingGpux();
		_sequencerDown();
		skip(1 hours);
		_sequencerUp();

		usdc.mint(bob, 150e6);
		vm.startPrank(bob);
		usdc.approve(address(comptroller), 150e6);
		comptroller.requestDeposit(150e6, type(uint256).max);
		vm.stopPrank();
		skip(30 minutes); // matured, but still inside the 1h grace
		usdcFeed.setAnswer(1e8);
		gpuxFeed.setAnswer(100e8);
		vm.expectRevert();
		comptroller.executeDepositRequest(bob);

		skip(31 minutes);
		usdcFeed.setAnswer(1e8);
		gpuxFeed.setAnswer(100e8);
		uint256 supplyBefore = comptroller.shares().totalSupply();
		comptroller.executeDepositRequest(bob);
		// $150 into a $1,500 fund at a fair NAV → 10% of the prior supply
		assertApproxEqRel(comptroller.shares().balanceOf(bob), supplyBefore / 10, 0.001e18);
	}
}

/// @notice The REAL Base sequencer uptime feed + REAL Chainlink standard feeds — proves the
///         check reads the live contract correctly (ABI, answer 0 = up, startedAt set).
///         Run: BASE_MAINNET_RPC=<url> forge test --match-contract SequencerUptimeForkTest
contract SequencerUptimeForkTest is Test {
	address internal constant BASE_SEQUENCER_UPTIME = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
	address internal constant WETH = 0x4200000000000000000000000000000000000006;
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	// Chainlink "Standard" (non-SVR) proxies — secondaryProxyAddress in the Base RDD
	address internal constant CL_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
	address internal constant CL_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;

	address internal admin = makeAddr('admin');

	function test_fork_liveSequencerUp_pricesWeth() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, 53_390_931); // pinned: live state moves under a fork at the latest block (2026-11-01)

		ValueInterpreter interpreter = new ValueInterpreter(admin);
		vm.startPrank(admin);
		interpreter.addPrimitive(WETH, CL_ETH_USD, 1 days);
		interpreter.addPrimitive(USDC, CL_USDC_USD, 1 days);
		interpreter.setSequencerUptimeFeed(BASE_SEQUENCER_UPTIME, 1 hours);
		vm.stopPrank();

		(, int256 status, uint256 startedAt,,) = MockAggregator(BASE_SEQUENCER_UPTIME).latestRoundData();
		assertEq(status, 0, 'Base sequencer reported up');
		assertGt(startedAt, 0);
		assertGt(block.timestamp - startedAt, 1 hours, 'up for longer than the grace period');

		uint256 oneEth = interpreter.calcCanonicalAssetValue(WETH, 1e18, USDC);
		assertGt(oneEth, 500e6);
		assertLt(oneEth, 20_000e6);
	}
}
