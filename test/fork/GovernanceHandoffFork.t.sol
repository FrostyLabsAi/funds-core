// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {TimelockController} from '@openzeppelin/contracts/governance/TimelockController.sol';
import {AggregatorV3Interface} from '../../src/interfaces/AggregatorV3Interface.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerV2} from '../../src/core/ComptrollerV2.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {ProtocolFeeReserve} from '../../src/core/ProtocolFeeReserve.sol';
import {VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {VerantaPerpPositionV3Factory} from '../../src/positions/VerantaPerpPositionV3.sol';
import {SlipstreamLPPositionV2Factory} from '../../src/positions/SlipstreamLPPositionV2.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {MinPoolLiquidityPolicy} from '../../src/policies/MinPoolLiquidityPolicy.sol';
import {CompounderFactory} from '../../src/yield/CompounderFactory.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {FundsGovernance} from '../../script/mainnet/FundsGovernance.sol';
import {FinishFundsGovernance, VerifyFundsGovernance} from '../../script/mainnet/TransferFundsGovernance.s.sol';
import {RedemptionDeploy} from '../../script/mainnet/RedemptionDeploy.sol';
import {RedemptionQueue} from '../../src/redemption/RedemptionQueue.sol';
import {VerantaPriceStore} from '../../src/pricing/VerantaPriceStore.sol';

/// @notice THE LAUNCH-DAY HANDOFF, rehearsed on the LIVE Base deployment (PLAN_GOVERNANCE_HANDOFF_2026-10-04),
///         pinned after the pool-pricing switch-over and before any handoff: the deployer runs
///         {FundsGovernance.start} (what StartFundsGovernance broadcasts), the real Admin Safe schedules
///         the accept batch on the real timelock, it can't run before the 2-day delay, then the real
///         FinishFundsGovernance script executes it and verifies — and VerifyFundsGovernance agrees.
///         After it: the deployer holds nothing (nine owners moved, the retired lister's compounder
///         role revoked), the timelock reaches VI admin only through the registrar, ANYONE can still
///         price a new token from its pool (`register`), and a new fund is fund v2 and takes a deposit.
///         Facts at block 52190277 (cast): every owner below = the deployer 0xaE51…802a; the VI's owner =
///         the registrar 0x34Ac…4e2A; CompounderFactory.creators(Keeper · Lister 0x9B2C…646F) = true;
///         rETH 0xB6fe…624c is unpriced and `register` on its Uniswap v3 WETH 0.05% pool 0x9e13…0e98 succeeds.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/GovernanceHandoffFork.t.sol -vv
contract GovernanceHandoffForkTest is Test {
	uint256 internal constant FORK_BLOCK = 52_190_277;
	TimelockController internal constant TIMELOCK = TimelockController(payable(0xd50AF6A924f23AC6944fB8eBc981E006B07D83Ba));
	address internal constant SAFE = 0xB0f37bE90a8BD82D991Bf694F960C67198778B8B;
	address internal constant LISTER = 0x9B2C5B835eAeA359A7871e58be857D57277E646F;
	/// @dev TransferFundsGovernance's SALT: Finish executes the batch under it, so a mismatch fails here
	bytes32 internal constant SALT = keccak256('frostyfunds-handoff-2026-10');
	address internal constant RETH = 0xB6fe221Fe9EeF5aBa221c348bA20A1Bf5e73624c;
	address internal constant RETH_WETH_500 = 0x9e13996A9f5a9870C105D7e3C311848273740e98;

	bool internal forked;
	address internal deployer;
	address internal keeper;
	FundsMainnet.Deployed internal d;
	FundsGovernance.PoolPricing internal p;
	FundsGovernance.Compounders internal c;
	FundsGovernance.Retired internal r;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, FORK_BLOCK);
		forked = true;
		vm.setEnv('TIMELOCK', vm.toString(address(TIMELOCK)));

		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		deployer = vm.parseJsonAddress(genesis, '.deployer');
		keeper = vm.parseJsonAddress(genesis, '.autopilotKeeper');
		d.valueInterpreter = ValueInterpreter(vm.parseJsonAddress(genesis, '.valueInterpreter'));
		d.factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		d.feeReserve = ProtocolFeeReserve(vm.parseJsonAddress(genesis, '.feeReserve'));
		d.twapRegistry = vm.parseJsonAddress(genesis, '.twapRegistry');
		d.verantaFactory = VerantaPerpPositionV2Factory(vm.parseJsonAddress(genesis, '.verantaFactory'));

		string memory pricing = vm.readFile('deployments/base-mainnet-pool-pricing.json');
		p.registrar = PoolPriceRegistrar(vm.parseJsonAddress(pricing, '.registrar'));
		p.policy = MinPoolLiquidityPolicy(vm.parseJsonAddress(pricing, '.policy'));
		p.fundDeployer = vm.parseJsonAddress(pricing, '.fundDeployer');

		string memory compounders = vm.readFile('deployments/base-mainnet-compounders.json');
		c.factory = CompounderFactory(vm.parseJsonAddress(compounders, '.compounderFactory'));
		c.slipstreamLp = SlipstreamLPPositionV2Factory(vm.parseJsonAddress(compounders, '.slipstreamLpFactory'));
		c.slipstream2Lp = SlipstreamLPPositionV2Factory(vm.parseJsonAddress(compounders, '.slipstream2LpFactory'));
		c.perpV3 = VerantaPerpPositionV3Factory(vm.parseJsonAddress(compounders, '.perpV3Factory'));

		string memory twapV2 = vm.readFile('deployments/base-mainnet-twap-v2.json');
		r = FundsGovernance.Retired({
			registryV1: d.twapRegistry,
			module: vm.parseJsonAddress(twapV2, '.module'),
			registryV2: vm.parseJsonAddress(twapV2, '.registry'),
			lister: LISTER
		});
	}

	/// @notice Before the handoff, verify names the first owner still with the deployer: it never
	///         passes early.
	function test_fork_verifyRefusesBeforeTheHandoff() public {
		vm.skip(!forked);
		vm.expectRevert(abi.encodeWithSelector(FundsGovernance.NotHandedOff.selector, address(p.registrar), deployer));
		this.verifyExternal();
	}

	/// @notice After the handoff, a compounder role handed back to the retired lister is caught.
	function test_fork_verifyCatchesARegrantedLister() public {
		vm.skip(!forked);
		vm.startPrank(deployer);
		FundsGovernance.start(d, p, c, r, address(TIMELOCK));
		vm.stopPrank();
		(address[] memory targets, uint256[] memory values, bytes[] memory payloads) = FundsGovernance.acceptBatch(d, p, c, r);
		vm.prank(SAFE);
		TIMELOCK.scheduleBatch(targets, values, payloads, bytes32(0), SALT, 2 days);
		skip(2 days);
		TIMELOCK.executeBatch(targets, values, payloads, bytes32(0), SALT);
		this.verifyExternal();

		vm.prank(address(TIMELOCK));
		c.factory.setCreator(LISTER, true);
		vm.expectRevert(abi.encodeWithSelector(FundsGovernance.HoldsCompounderRole.selector, LISTER));
		this.verifyExternal();
	}

	/// The redemption queue (founder 2026-10-06), deployed and switched to before the handoff, moves to
	/// the timelock with the rest; verify accepts fund v3 as the new-fund version and checks the
	/// queue's wiring. Afterwards the guardian may still switch the approved unwinder on, only the
	/// timelock switches it off, and the deployer can do neither.
	// The full live-handoff rehearsal was removed 2026-11-01: the launch-day scripts predate registrar V3, fund v6 and the CLM
	// contracts, and it gets rewritten with them right before the handoff (founder 2026-10-27).

	function test_fork_handoffIncludesTheRedemptionQueue() public {
		vm.skip(!forked);
		VerantaPriceStore store =
			VerantaPriceStore(vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-veranta.json'), '.store'));
		vm.startPrank(deployer);
		RedemptionDeploy.Deployed memory q =
			RedemptionDeploy.deploy(deployer, address(d.factory), address(d.verantaFactory), p.registrar, store);
		d.factory.setComptrollerDeployer(q.fundV3Deployer);
		p.redemptionQueue = address(q.queue);
		p.fundV3Deployer = address(q.fundV3Deployer);
		FundsGovernance.start(d, p, c, r, address(TIMELOCK));
		vm.stopPrank();

		address[] memory owned = FundsGovernance.owned(d, p, c, r);
		assertEq(owned.length, 10, 'the nine plus the queue');
		assertEq(owned[9], address(q.queue));
		(address[] memory targets, uint256[] memory values, bytes[] memory payloads) = FundsGovernance.acceptBatch(d, p, c, r);
		vm.prank(SAFE);
		TIMELOCK.scheduleBatch(targets, values, payloads, bytes32(0), SALT, 2 days);
		skip(2 days);
		_restamp(FundsMainnet.USDC);
		_restamp(FundsMainnet.WETH);
		TIMELOCK.executeBatch(targets, values, payloads, bytes32(0), SALT);
		this.verifyExternal();
		assertEq(q.queue.owner(), address(TIMELOCK));

		vm.prank(d.factory.guardian());
		q.queue.setUnwinderOn(address(q.perpUnwinder), true);
		vm.prank(deployer);
		vm.expectRevert(RedemptionQueue.OnlyOwnerSwitchesOff.selector);
		q.queue.setUnwinderOn(address(q.perpUnwinder), false);
		vm.prank(deployer);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
		q.queue.approveUnwinder(address(1), true);
		vm.prank(address(TIMELOCK));
		q.queue.setUnwinderOn(address(q.perpUnwinder), false);
		assertFalse(q.queue.isUnwinderOn(address(q.perpUnwinder)));
	}

	/// @dev external so a revert can be expected (library calls are inlined)
	function verifyExternal() external view {
		FundsGovernance.verify(d, p, c, r, address(TIMELOCK), SAFE, deployer, keeper);
	}

	/// @dev `asset`'s VI feed answers its last real report again, stamped now (time skipped on a fork).
	function _restamp(address asset) internal {
		(address feed,,,) = d.valueInterpreter.getAssetInfo(asset);
		(uint80 round, int256 answer,,, uint80 answeredIn) = AggregatorV3Interface(feed).latestRoundData();
		vm.mockCall(
			feed,
			abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
			abi.encode(round, answer, block.timestamp, block.timestamp, answeredIn)
		);
	}

	function _assertNewFundIsV2AndTakesADeposit() internal {
		address manager = makeAddr('manager');
		address investor = makeAddr('investor');
		ComptrollerV2 fund = ComptrollerV2(
			d.factory.createFund(
				FundFactory.FundConfig({
					name: 'Post-Handoff Fund',
					symbol: 'frPOST',
					denominationAsset: IERC20(FundsMainnet.USDC),
					fundOwner: manager,
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: 0,
					sharesActionTimelock: 0,
					minRequestDuration: 1 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				})
			)
		);
		assertEq(address(fund.registrar()), address(p.registrar), 'a fund v2 on the live registrar');
		deal(FundsMainnet.USDC, investor, 1_000e6);
		vm.startPrank(investor);
		IERC20(FundsMainnet.USDC).approve(address(fund), 1_000e6);
		fund.requestDeposit(1_000e6, 1.01e6); // at most $1.01 a share
		vm.stopPrank();
		skip(1 minutes);
		fund.executeDepositRequest(investor);
		assertGt(IERC20(address(fund.shares())).balanceOf(investor), 0, 'shares minted');
	}
}
