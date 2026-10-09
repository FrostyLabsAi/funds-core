// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test, Vm} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {TimelockController} from '@openzeppelin/contracts/governance/TimelockController.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerV3} from '../../src/core/ComptrollerV3.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {ProtocolFeeReserve} from '../../src/core/ProtocolFeeReserve.sol';
import {VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {MinPoolLiquidityPolicy} from '../../src/policies/MinPoolLiquidityPolicy.sol';
import {IPolicy} from '../../src/interfaces/IPolicy.sol';
import {IComptrollerDeployer} from '../../src/interfaces/IComptrollerDeployer.sol';
import {PoolKey} from '../../src/interfaces/external/IUniswapV4.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {PoolPriceRegistrarV2} from '../../src/pricing/PoolPriceRegistrarV2.sol';
import {ProtocolFeeAdapter} from '../../src/adapters/ProtocolFeeAdapter.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {V4Pricing} from '../../script/mainnet/V4Pricing.sol';
import {FundsGovernance} from '../../script/mainnet/FundsGovernance.sol';
import {IPoolPriceAdapter} from '../../src/interfaces/IPoolPriceAdapter.sol';
import {MockERC20} from '../utils/Mocks.sol';
import {PoolPriceMath} from '../../src/libraries/PoolPriceMath.sol';

interface ISlipstreamSlot0 {
	function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, bool);
}
import {DeployV4Pricing} from '../../script/mainnet/DeployV4Pricing.s.sol';
import {V4PricingOwnerSteps} from '../../script/mainnet/V4PricingOwnerSteps.s.sol';

/// @notice Rehearsal of the v4 rollout on live Base at the latest block (spec
///         docs/superpowers/specs/2026-10-08-uniswap-v4-memestocks-design.md §6): DeployV4Pricing's library call and
///         address book, then V4PricingOwnerSteps from the genesis deployer. Afterwards a fresh fund is a
///         ComptrollerV4 on registrar V2 with the new long-tail policy, STFY registers, governance still reaches
///         the ValueInterpreter through registrar V2, TestFund4 values exactly as before, and today's spot adapters
///         are still registered (deregistering them is a later step).
///         Run: BASE_MAINNET_RPC=<url> forge test --match-path test/fork/V4PricingRolloutFork.t.sol -vv
contract V4PricingRolloutForkTest is Test {
	address internal constant STFY = 0xC6405D7a226e1C18E559Be2F335F74C01Ad07bF5;
	/// @dev A fund on today's registrar (owner: the deployer).
	address internal constant TEST_FUND_4 = 0xd989D464E8bD518AF14151cb0F95a4f970F365DA;
	/// @dev The governance timelock and Admin Safe (GovernanceHandoffFork), and TransferFundsGovernance's SALT
	TimelockController internal constant TIMELOCK = TimelockController(payable(0xd50AF6A924f23AC6944fB8eBc981E006B07D83Ba));
	address internal constant SAFE = 0xB0f37bE90a8BD82D991Bf694F960C67198778B8B;
	bytes32 internal constant SALT = keccak256('frostyfunds-handoff-2026-10');

	bool internal forked;
	address internal deployer;
	FundFactory internal factory;
	ValueInterpreter internal vi;
	PoolPriceRegistrar internal oldRegistrar;
	address internal oldPolicy;
	address internal queue;
	FundFactory.PolicyReg[] internal mandatoryBefore;
	/// @dev TestFund4 holds a perp account, whose value reads only while its prices are fresh
	bool internal testFund4Valued;
	uint256 internal testFund4GavBefore;
	V4Pricing.Deployment internal d;
	address internal manager = makeAddr('manager');
	// the governance handoff's inputs (_loadHandoff)
	FundsMainnet.Deployed internal gd;
	FundsGovernance.PoolPricing internal gp;
	FundsGovernance.Compounders internal gc;
	FundsGovernance.Retired internal gr;
	address internal keeper;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc);
		forked = true;
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		string memory pricing = vm.readFile('deployments/base-mainnet-pool-pricing.json');
		deployer = vm.parseJsonAddress(genesis, '.deployer');
		factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		vi = ValueInterpreter(vm.parseJsonAddress(genesis, '.valueInterpreter'));
		oldRegistrar = PoolPriceRegistrar(vm.parseJsonAddress(pricing, '.registrar'));
		oldPolicy = vm.parseJsonAddress(pricing, '.policy');
		queue = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-redemption.json'), '.queue');

		assertEq(oldRegistrar.owner(), deployer, 'live: the deployer owns today\'s registrar');
		assertEq(Ownable(address(factory)).owner(), deployer, 'live: the deployer owns the factory');
		FundFactory.PolicyReg[] memory regs = factory.getMandatoryPolicies();
		for (uint256 i; i < regs.length; ++i) {
			mandatoryBefore.push(regs[i]);
		}
		try ComptrollerV3(TEST_FUND_4).calcGav() returns (uint256 gav) {
			(testFund4Valued, testFund4GavBefore) = (true, gav);
		} catch {}

		// step 1 (DeployV4Pricing): the library call, then its address book read back as the owner steps read it
		vm.startPrank(deployer);
		V4Pricing.Deployment memory deployed = V4Pricing.deploy(deployer, oldRegistrar, queue);
		vm.stopPrank();
		string memory json = new DeployV4Pricing().serialize(deployed, block.number);
		d = new V4PricingOwnerSteps().load(json);
		assertEq(address(d.registrar), address(deployed.registrar), 'address book round trip');
		assertEq(address(d.fundDeployer), address(deployed.fundDeployer), 'address book round trip');
		// step 2 (V4PricingOwnerSteps)
		vm.startPrank(deployer);
		V4Pricing.ownerSteps(d, factory, oldPolicy, SAFE);
		vm.stopPrank();
	}

	function test_fork_ownershipAndApprovals() public {
		vm.skip(!forked);
		assertEq(oldRegistrar.owner(), address(d.registrar), "registrar V2 owns today's registrar");
		assertEq(vi.owner(), address(oldRegistrar), 'which still owns the ValueInterpreter');
		assertEq(d.registrar.owner(), deployer, 'the deployer until the governance handoff');
		assertEq(d.sampler.owner(), deployer);
		assertTrue(d.sampler.isKeeper(V4Pricing.KEEPER), 'the Engine keeper samples');
		assertTrue(d.registrar.isPoolApprover(SAFE), 'the Admin Safe approves v4 pools');
		assertFalse(d.registrar.isPoolApprover(deployer));
		bytes32[5] memory pools = V4Pricing.launchPools();
		for (uint256 i; i < pools.length; ++i) {
			assertTrue(d.registrar.isPoolApproved(pools[i]), 'the launch pools are approved (STFY, BLUECHIP, RAWR, MOONBASE, BASEASS)');
		}

		(bool approved, bytes memory hookData) = d.registrar.hookOf(V4Pricing.STOCKIFY_HOOK);
		assertTrue(approved);
		assertEq(hookData.length, 0);
		(approved, hookData) = d.registrar.hookOf(V4Pricing.O1_HOOK_1);
		assertTrue(approved);
		assertEq(hookData, abi.encode(V4Pricing.TREASURY), 'o1: the Treasury as referrer');
		(approved, hookData) = d.registrar.hookOf(V4Pricing.O1_HOOK_2);
		assertTrue(approved);
		assertEq(hookData, abi.encode(V4Pricing.TREASURY));

		address[8] memory quotes = [
			FundsMainnet.USDC, FundsMainnet.WETH, FundsMainnet.CBBTC, V4Pricing.NVDAC, V4Pricing.SPCXC, V4Pricing.AAPLC,
			V4Pricing.GOOGLC, V4Pricing.METAC
		];
		for (uint256 i; i < quotes.length; ++i) {
			assertTrue(d.registrar.isQuote(quotes[i]));
		}

		address[6] memory adapters = V4Pricing.adaptersOf(d);
		for (uint256 i; i < adapters.length; ++i) {
			assertTrue(factory.isAdapterRegistered(adapters[i]));
			ProtocolFeeAdapter adapter = ProtocolFeeAdapter(adapters[i]);
			assertEq(adapter.feeBps(), 5, '5 bps at deployment');
			assertEq(adapter.treasury(), V4Pricing.TREASURY);
			assertEq(adapter.owner(), deployer);
		}
	}

	/// New funds get the policy on registrar V2 in the old one's place, on the same hooks; a fresh fund is a
	/// ComptrollerV4 (no in-kind exit that forfeits, founder 2026-10-09) on registrar V2 and the redemption queue,
	/// carrying it.
	function test_fork_newFundsAreBuiltOnRegistrarV2() public {
		vm.skip(!forked);
		FundFactory.PolicyReg[] memory regs = factory.getMandatoryPolicies();
		assertEq(regs.length, mandatoryBefore.length);
		bool replaced;
		for (uint256 i; i < regs.length; ++i) {
			assertEq(uint8(regs[i].hook), uint8(mandatoryBefore[i].hook));
			assertTrue(regs[i].policy != oldPolicy, 'the old policy is gone');
			if (mandatoryBefore[i].policy == oldPolicy) {
				assertEq(regs[i].policy, address(d.policy));
				replaced = true;
			} else {
				assertEq(regs[i].policy, mandatoryBefore[i].policy, 'other mandatory policies kept');
			}
		}
		assertTrue(replaced);
		assertEq(address(factory.comptrollerDeployer()), address(d.fundDeployer));

		ComptrollerV3 fund = ComptrollerV3(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'v4 rollout rehearsal',
					symbol: 'frV4R',
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
		assertEq(address(fund.registrar()), address(d.registrar));
		assertEq(address(fund.redemptionQueue()), queue);
		address[] memory postTrade = fund.getPolicies(IPolicy.PolicyHook.PostCallOnIntegration);
		bool carries;
		for (uint256 i; i < postTrade.length; ++i) {
			if (postTrade[i] == address(d.policy)) carries = true;
		}
		assertTrue(carries, 'the long-tail policy checks its trades');

		// fund v4: in kind is refused while the fund holds a position (checked before the redeemer's balance)
		vm.prank(manager);
		fund.createExternalPosition(FundsMainnet.VERANTA_PERP_TYPE, '');
		vm.expectRevert(ComptrollerV3.UseRedemptionQueue.selector);
		fund.redeemSharesInKind(1);
	}

	/// The owner's cast transaction after the owner steps prices BLUECHIP from its USDC pool on Slipstream (founder
	/// 2026-10-08). BLUECHIP is a B20 token Foundry can't run: here its address gets a plain ERC-20's code (decimals 18,
	/// as on Base) — the pool, its USDC and the registrar are live code. The figure is the USDC the pool holds.
	function test_fork_bluechipPricedFromItsUsdcPool() public {
		vm.skip(!forked);
		vm.etch(V4Pricing.BLUECHIP, address(new MockERC20('', '', 18)).code);
		vm.prank(deployer);
		address adapter = d.registrar.setPool(V4Pricing.BLUECHIP, V4Pricing.BLUECHIP_USDC_POOL);
		assertEq(d.registrar.poolPricedAdapter(V4Pricing.BLUECHIP), adapter);
		IPoolPriceAdapter.Config memory c = IPoolPriceAdapter(adapter).config();
		assertEq(c.pool, V4Pricing.BLUECHIP_USDC_POOL);
		assertEq(c.quoteAsset, FundsMainnet.USDC);
		uint256 usdcHeld = IERC20(FundsMainnet.USDC).balanceOf(V4Pricing.BLUECHIP_USDC_POOL);
		assertLe(IPoolPriceAdapter(adapter).liquidityUsd(), usdcHeld * 1e12 * 1001 / 1000, 'capped by the USDC it holds');
		// the 30-minute TWAP, within 5% of the pool's price now (USDC is token0, BLUECHIP token1)
		(uint160 sqrtPriceX96,,,,,) = ISlipstreamSlot0(V4Pricing.BLUECHIP_USDC_POOL).slot0();
		uint256 spot = PoolPriceMath.usdPerAssetAtSqrtP(sqrtPriceX96, false, 18, 6, vi.calcUsdRate(FundsMainnet.USDC));
		assertApproxEqRel(vi.calcUsdRate(V4Pricing.BLUECHIP), spot, 0.05e18, 'priced from the USDC pool');
		assertTrue(d.registrar.isPoolApproved(V4Pricing.BLUECHIP_POOL_ID), 'its o1 pool stays approved for trading');
	}

	function test_fork_anyoneRegistersStfy() public {
		vm.skip(!forked);
		vm.prank(makeAddr('anyone'));
		address adapter = d.registrar.registerV4(STFY, PoolKey(address(0), STFY, 10_000, 200, V4Pricing.STOCKIFY_HOOK));
		assertTrue(vi.isSupportedAsset(STFY));
		assertEq(d.registrar.poolPricedAdapter(STFY), adapter);
	}

	/// Today's registrations stay long-tail through registrar V2; governance still reaches the ValueInterpreter.
	function test_fork_todaysListingsAndGovernanceCarryOver() public {
		vm.skip(!forked);
		address[] memory olds = oldRegistrar.getRegisteredAssets();
		assertGt(olds.length, 0);
		for (uint256 i; i < olds.length && i < 20; ++i) {
			assertEq(d.registrar.poolPricedAdapter(olds[i]), oldRegistrar.poolPricedAdapter(olds[i]));
		}

		(address aggregator, uint32 heartbeat,,) = vi.getAssetInfo(FundsMainnet.WETH);
		bytes memory addPrimitive = abi.encodeCall(ValueInterpreter.addPrimitive, (FundsMainnet.WETH, aggregator, heartbeat));
		vm.prank(deployer);
		d.registrar.callOldRegistrar(abi.encodeCall(PoolPriceRegistrar.execute, (addPrimitive)));
		(address after_,,,) = vi.getAssetInfo(FundsMainnet.WETH);
		assertEq(after_, aggregator, 'a VI admin call went through registrar V2');
	}

	function test_fork_testFund4AndTodaysAdaptersUnchanged() public {
		vm.skip(!forked);
		assertEq(address(ComptrollerV3(TEST_FUND_4).registrar()), address(oldRegistrar));
		if (testFund4Valued) {
			assertEq(ComptrollerV3(TEST_FUND_4).calcGav(), testFund4GavBefore, 'TestFund4 values exactly as before');
		}
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		string memory twapV2 = vm.readFile('deployments/base-mainnet-twap-v2.json');
		assertTrue(factory.isAdapterRegistered(vm.parseJsonAddress(genesis, '.uniAdapter')));
		assertTrue(factory.isAdapterRegistered(vm.parseJsonAddress(genesis, '.slipstreamAdapter')));
		assertTrue(factory.isAdapterRegistered(vm.parseJsonAddress(genesis, '.slipstream2Adapter')));
		assertTrue(factory.isAdapterRegistered(vm.parseJsonAddress(twapV2, '.slipstream3Adapter')));
		assertTrue(factory.isAdapterRegistered(vm.parseJsonAddress(twapV2, '.aerodromeBasicAdapter')));
	}

	/// The handoff with v4 deployed: registrar V2 moves in today's registrar's place, with the sampler and the six
	/// spot adapters; verify then requires new funds on registrar V2. Afterwards only the timelock sets the protocol
	/// fee and it reaches VI admin through both registrars. (The fee compounders are left out here: their check
	/// still expects the V3 perp factory on type 6, which is the V4 factory since 2026-10-08 — to be updated when
	/// the handoff is next rehearsed, its last step.)
	function test_fork_governanceHandoffMovesTheV4Owners() public {
		vm.skip(!forked);
		_loadHandoff();
		address[] memory owned = FundsGovernance.owned(gd, gp, gc, gr);
		assertEq(owned.length, 11, 'registrar V2, factory, V2 perp config, queue, sampler, six adapters');
		assertEq(owned[0], address(d.registrar), "in today's registrar's place");
		vm.startPrank(deployer);
		FundsGovernance.start(gd, gp, gc, gr, address(TIMELOCK));
		vm.stopPrank();
		(address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
			FundsGovernance.acceptBatch(gd, gp, gc, gr);
		uint256 delay = TIMELOCK.getMinDelay();
		vm.prank(SAFE);
		TIMELOCK.scheduleBatch(targets, values, payloads, bytes32(0), SALT, delay);
		skip(delay);
		TIMELOCK.executeBatch(targets, values, payloads, bytes32(0), SALT);
		FundsGovernance.verify(gd, gp, gc, gr, address(TIMELOCK), SAFE, deployer, keeper);
		assertEq(oldRegistrar.owner(), address(d.registrar), 'still under registrar V2');

		vm.prank(deployer);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
		d.v4Adapter.setFeeBps(10);
		// after the handoff the Admin Safe still approves a v4 pool at once (no timelock); the deployer can't
		bytes32 pool = keccak256('some v4 pool');
		vm.prank(SAFE);
		d.registrar.setPoolApproved(pool, true);
		assertTrue(d.registrar.isPoolApproved(pool));
		vm.prank(deployer);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrarV2.NotPoolApprover.selector, deployer));
		d.registrar.setPoolApproved(pool, false);
		vm.prank(address(TIMELOCK));
		d.uniAdapter.setFeeBps(0);
		assertEq(d.uniAdapter.feeBps(), 0, 'governance sets the protocol fee');

		(address aggregator, uint32 heartbeat,,) = vi.getAssetInfo(FundsMainnet.WETH);
		bytes memory addPrimitive = abi.encodeCall(ValueInterpreter.addPrimitive, (FundsMainnet.WETH, aggregator, heartbeat));
		vm.prank(address(TIMELOCK));
		d.registrar.callOldRegistrar(abi.encodeCall(PoolPriceRegistrar.execute, (addPrimitive)));
	}

	/// @dev The handoff's inputs as TransferFundsGovernance loads them once the v4 book exists (compounders and the
	///      retired tier left out, see above).
	function _loadHandoff() internal {
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		keeper = vm.parseJsonAddress(genesis, '.autopilotKeeper');
		gd.valueInterpreter = vi;
		gd.factory = factory;
		gd.feeReserve = ProtocolFeeReserve(vm.parseJsonAddress(genesis, '.feeReserve'));
		gd.verantaFactory = VerantaPerpPositionV2Factory(vm.parseJsonAddress(genesis, '.verantaFactory'));
		gp.registrar = oldRegistrar;
		gp.policy = MinPoolLiquidityPolicy(oldPolicy);
		gp.fundDeployer = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-pool-pricing.json'), '.fundDeployer');
		gp.redemptionQueue = queue;
		gp.fundV3Deployer = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-redemption.json'), '.fundV3Deployer');
		gp.registrarV2 = d.registrar;
		gp.sampler = d.sampler;
		gp.v4Adapters = V4Pricing.adaptersOf(d);
		gp.policyV2 = d.policy;
		gp.registrarV2FundDeployer = address(d.fundDeployer);
	}

	/// The handoff's verify checks the v4 book's wiring, not just its owners: a book naming another adapter as the v4
	/// one is refused (final review 2026-10-08, I3).
	function test_fork_handoffVerifyRefusesAMiswiredV4Book() public {
		vm.skip(!forked);
		_loadHandoff();
		vm.startPrank(deployer);
		FundsGovernance.start(gd, gp, gc, gr, address(TIMELOCK));
		vm.stopPrank();
		(address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
			FundsGovernance.acceptBatch(gd, gp, gc, gr);
		uint256 delay = TIMELOCK.getMinDelay();
		vm.prank(SAFE);
		TIMELOCK.scheduleBatch(targets, values, payloads, bytes32(0), SALT, delay);
		skip(delay);
		TIMELOCK.executeBatch(targets, values, payloads, bytes32(0), SALT);
		this.verifyHandoff(); // as deployed: passes
		gp.v4Adapters[0] = address(d.uniAdapter); // owned by the timelock too, but not the v4 adapter
		vm.expectRevert(abi.encodeWithSelector(FundsGovernance.V4NotWired.selector, address(d.uniAdapter)));
		this.verifyHandoff();
	}

	/// @dev external so a revert can be expected (library calls are inlined)
	function verifyHandoff() external view {
		FundsGovernance.verify(gd, gp, gc, gr, address(TIMELOCK), SAFE, deployer, keeper);
	}

	/// A stale `oldPolicy` (not on the mandatory list) stops the owner steps before new funds move to registrar V2
	/// (final review 2026-10-08, L1): with today's policy and fund deployer back, a run naming another policy reverts.
	function test_fork_ownerStepsRefuseAStaleOldPolicy() public {
		vm.skip(!forked);
		FundFactory.PolicyReg[] memory regs = factory.getMandatoryPolicies();
		for (uint256 i; i < regs.length; ++i) {
			if (regs[i].policy == address(d.policy)) regs[i].policy = oldPolicy;
		}
		address previous = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-redemption.json'), '.fundV3Deployer');
		vm.startPrank(deployer);
		factory.setMandatoryPolicies(regs);
		factory.setComptrollerDeployer(IComptrollerDeployer(previous));
		vm.stopPrank();

		vm.expectRevert(abi.encodeWithSelector(V4Pricing.MandatoryPolicyNotFound.selector, address(0xdead)));
		this.ownerStepsAsDeployer(address(0xdead));
		assertEq(address(factory.comptrollerDeployer()), previous, 'new funds stay where they were');
		this.ownerStepsAsDeployer(oldPolicy); // the right one completes it
		assertEq(address(factory.comptrollerDeployer()), address(d.fundDeployer));
	}

	/// @dev external so a revert can be expected (library calls are inlined)
	function ownerStepsAsDeployer(address oldPolicy_) external {
		vm.startPrank(deployer);
		V4Pricing.ownerSteps(d, factory, oldPolicy_, SAFE);
		vm.stopPrank();
	}

	/// A second run of the owner steps finds everything done and sends nothing.
	function test_fork_aRerunSendsNothing() public {
		vm.skip(!forked);
		vm.recordLogs();
		vm.startPrank(deployer);
		V4Pricing.ownerSteps(d, factory, oldPolicy, SAFE);
		vm.stopPrank();
		Vm.Log[] memory logs = vm.getRecordedLogs();
		assertEq(logs.length, 0, 'no state change');
	}
}
