// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {TimelockController} from '@openzeppelin/contracts/governance/TimelockController.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {AggregatorV3Interface} from '../../src/interfaces/AggregatorV3Interface.sol';
import {IVerantaMulticall} from '../../src/interfaces/external/IVeranta.sol';
import {VerantaPerpPositionV2} from '../../src/positions/VerantaPerpPositionV2.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {ComptrollerDeployer} from '../../src/core/FundComponentDeployers.sol';
import {IComptrollerDeployer} from '../../src/interfaces/IComptrollerDeployer.sol';
import {ProtocolFeeReserve} from '../../src/core/ProtocolFeeReserve.sol';
import {MockERC20} from '../utils/Mocks.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {FundsGovernance} from '../../script/mainnet/FundsGovernance.sol';
import {FreshPoolPricing} from '../utils/FreshPoolPricing.sol';

/// @notice THE MAINNET GENESIS REHEARSAL, on a Base fork against every real venue:
///         deploy exactly what DeployFundsMainnet ships → price the genesis assets → a fund
///         deposits, swaps on Uniswap AND both Aerodrome deployments, parks cash in Veranta's
///         avUSDC, opens a real Veranta perp → the 2026-10-04 pool pricing installed as on mainnet
///         (PoolPriceRegistrar owns the VI, long-tail policy, fund v2) → governance handoff to a
///         FROST-style timelock (Safe proposes, 2-day delay, open execution) → the deployer holds
///         NOTHING and the Safe's guardian lane works one way only. The handoff of the LIVE
///         deployment is rehearsed in test/fork/GovernanceHandoffFork.
///         FROST is not on mainnet yet: a stand-in ERC20 plays the fee reserve's burn asset.
///         Run: BASE_MAINNET_RPC=<url> forge test --match-path test/fork/FundsMainnetGenesisFork.t.sol -vv
contract FundsMainnetGenesisForkTest is Test {
	address internal constant SAFE = 0xB0f37bE90a8BD82D991Bf694F960C67198778B8B; // live 2-of-3 on Base
	uint16 internal constant FEE_BPS = 25;

	bool internal forked;
	address internal deployer = makeAddr('deployer');
	address internal keeper = makeAddr('autopilotKeeper');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');
	TimelockController internal timelock;
	FundsMainnet.Deployed internal d;
	/// @dev a rehearsal genesis has no TWAP tier (retired 2026-10-04) and no fee compounders
	FundsGovernance.Retired internal noRetired;
	FundsGovernance.Compounders internal noCompounders;
	FundsGovernance.PoolPricing internal pp;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, 53_390_931); // pinned: live state moves under a fork at the latest block (2026-11-01)
		forked = true;

		// FROST's genesis shape: Safe proposes/cancels, anyone executes, no admin
		address[] memory proposers = new address[](1);
		proposers[0] = SAFE;
		address[] memory executors = new address[](1);
		executors[0] = address(0);
		timelock = new TimelockController(2 days, proposers, executors, address(0));

		MockERC20 frostStandIn = new MockERC20('FROST stand-in', 'FROST', 18);
		vm.startPrank(deployer);
		d = FundsMainnet.deploy(
			FundsMainnet.Config({deployer: deployer, safe: SAFE, frost: address(frostStandIn), autopilotKeeper: keeper, protocolFeeBps: FEE_BPS})
		);
		vm.stopPrank();
	}

	// ─── genesis wiring ──────────────────────────────────────────────────────────

	function test_fork_genesisPricesEveryAsset() public {
		vm.skip(!forked);
		_assertNearChainlink(FundsMainnet.WETH, 1e18, FundsMainnet.CL_ETH_USD);
		_assertNearChainlink(FundsMainnet.CBBTC, 1e8, FundsMainnet.CL_CBBTC_USD);
		_assertNearChainlink(FundsMainnet.AERO, 1e18, FundsMainnet.CL_AERO_USD);
		_assertNearChainlink(FundsMainnet.EURC, 1e6, FundsMainnet.CL_EURC_USD);
		// avUSDC at exit value: what previewRedeem pays, strictly under the fee-free mark
		uint256 value = d.valueInterpreter.calcCanonicalAssetValue(FundsMainnet.AV_USDC, 1e6, FundsMainnet.USDC);
		assertEq(value, IERC4626(FundsMainnet.AV_USDC).previewRedeem(1e6));
		assertLt(value, IERC4626(FundsMainnet.AV_USDC).convertToAssets(1e6));

		assertEq(d.factory.protocolFeeBps(), FEE_BPS);
		assertEq(d.factory.protocolFeeRecipient(), address(d.feeReserve));
		assertEq(d.factory.guardian(), SAFE);
		// genesis no longer ships the TWAP tier (retired 2026-10-04); the long-tail policy comes with
		// pool pricing (FreshPoolPricing.install, as MigratePoolPricing did on mainnet)
		assertEq(d.factory.getMandatoryPolicies().length, 0);
		assertEq(d.twapRegistry, address(0));
		assertEq(d.verantaFactory.pairAsset(FundsMainnet.VERANTA_ETH_PAIR), FundsMainnet.WETH);
		assertEq(d.verantaFactory.referralCode(), FundsMainnet.VERANTA_REFERRAL_CODE);
	}

	// ─── a real fund on real venues ──────────────────────────────────────────────

	function test_fork_fundTradesEveryGenesisVenue() public {
		vm.skip(!forked);
		Comptroller fund = _fundWithDeposit(10_000e6);

		_swap(fund, d.uniAdapter, abi.encode(FundsMainnet.USDC, FundsMainnet.WETH, uint24(500), uint256(2_000e6), uint256(0)));
		_swap(fund, d.slipstream2Adapter, abi.encode(FundsMainnet.USDC, FundsMainnet.WETH, int24(50), uint256(2_000e6), uint256(0)));
		_swap(fund, d.slipstream2Adapter, abi.encode(FundsMainnet.USDC, FundsMainnet.CBBTC, int24(50), uint256(1_000e6), uint256(0)));
		_swap(fund, d.slipstreamAdapter, abi.encode(FundsMainnet.USDC, FundsMainnet.AERO, int24(100), uint256(500e6), uint256(0)));
		_swap(fund, d.erc4626Adapter, abi.encode(uint8(0), FundsMainnet.AV_USDC, uint256(1_000e6), uint256(0)));

		// every leg priced; GAV within swap costs + avUSDC's 1.5% exit fee of 10,000
		uint256 gav = fund.calcGav();
		emit log_named_decimal_uint('GAV after 5 trades', gav, 6);
		assertApproxEqRel(gav, 10_000e6, 0.01e18);
		assertGt(IERC20(FundsMainnet.WETH).balanceOf(address(fund.vault())), 0);
		assertGt(IERC20(FundsMainnet.CBBTC).balanceOf(address(fund.vault())), 0);
		assertGt(IERC20(FundsMainnet.AERO).balanceOf(address(fund.vault())), 0);
		assertGt(IERC20(FundsMainnet.AV_USDC).balanceOf(address(fund.vault())), 0);
	}

	function test_fork_fundOpensARealVerantaPerp() public {
		vm.skip(!forked);
		Comptroller fund = _fundWithDeposit(10_000e6);
		vm.prank(manager);
		VerantaPerpPositionV2 position =
			VerantaPerpPositionV2(fund.createExternalPosition(FundsMainnet.VERANTA_PERP_TYPE, ''));

		(, int256 eth,,,) = AggregatorV3Interface(FundsMainnet.CL_ETH_USD).latestRoundData();
		address[] memory assets = new address[](1);
		assets[0] = FundsMainnet.USDC;
		uint256[] memory amounts = new uint256[](1);
		amounts[0] = 200e6;
		bytes memory open = abi.encode(
			uint8(VerantaPerpPositionV2.Action.OpenTrade),
			abi.encode(FundsMainnet.VERANTA_ETH_PAIR, uint256(200e6), uint256(2e10), false, uint256(eth) * 1e2, uint256(5e10), uint8(0), uint256(0), uint256(0))
		);
		vm.prank(manager);
		fund.callOnExternalPosition(address(position), assets, amounts, new address[](0), open);

		IVerantaMulticall.PendingOrder[] memory pending =
			IVerantaMulticall(FundsMainnet.VERANTA_MULTICALL).getPendingOrder(address(position));
		assertEq(pending.length, 1);
		assertEq(fund.calcGav(), 10_000e6); // the escrow stays valued while Veranta's operator fills

		// the protocol referral code links on the REAL Referral contract
		vm.prank(manager);
		fund.callOnExternalPosition(
			address(position), new address[](0), new uint256[](0), new address[](0),
			abi.encode(uint8(VerantaPerpPositionV2.Action.LinkReferral), bytes(''))
		);
	}

	// ─── governance handoff ──────────────────────────────────────────────────────

	function test_fork_handoffLeavesTheDeployerNothing() public {
		vm.skip(!forked);
		Comptroller fund = _fundWithDeposit(1_000e6);
		_installPoolPricing();

		vm.startPrank(deployer);
		FundsGovernance.start(d, pp, noCompounders, noRetired, address(timelock));
		vm.stopPrank();
		// registrar, factory, Veranta factory, fee reserve — never the VI
		(address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
			FundsGovernance.acceptBatch(d, pp, noCompounders, noRetired);
		assertEq(targets.length, 4);
		for (uint256 i; i < targets.length; ++i) {
			assertTrue(targets[i] != address(d.valueInterpreter));
		}
		bytes32 salt = keccak256('frostyfunds-genesis');
		vm.prank(SAFE);
		timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, 2 days);

		// not before the delay — then ANYONE executes
		vm.expectRevert();
		timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
		skip(2 days);
		timelock.executeBatch(targets, values, payloads, bytes32(0), salt);

		FundsGovernance.verify(d, pp, noCompounders, noRetired, address(timelock), SAFE, deployer, keeper);
		assertEq(d.valueInterpreter.owner(), address(pp.registrar), 'the registrar keeps the VI');

		// the deployer is powerless everywhere
		vm.startPrank(deployer);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
		d.factory.registerAdapter(address(1));
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
		d.valueInterpreter.addPrimitive(address(1), address(2), 1 hours);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
		pp.registrar.execute(abi.encodeCall(ValueInterpreter.setAnswerBounds, (FundsMainnet.USDC, 1, 10e8)));
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
		pp.registrar.setPool(FundsMainnet.AERO, address(1));
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
		d.verantaFactory.setPairAsset(9, address(1));
		vm.stopPrank();

		// the timelock reaches VI admin through the registrar
		vm.prank(address(timelock));
		pp.registrar.execute(abi.encodeCall(ValueInterpreter.setAnswerBounds, (FundsMainnet.USDC, 1, 10e8)));
		(int256 min, int256 max) = d.valueInterpreter.answerBounds(FundsMainnet.USDC);
		assertEq(min, 1);
		assertEq(max, 10e8);

		// the Safe's lane is one-way: it pauses instantly, it cannot unpause
		vm.prank(SAFE);
		d.factory.pauseFundDeposits(address(fund));
		assertTrue(fund.guardianDepositsPaused());
		vm.prank(SAFE);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, SAFE));
		d.factory.unpauseFundDeposits(address(fund));
		// only the timelock (after its own delay, via the Safe's proposal) re-opens
		vm.prank(address(timelock));
		d.factory.unpauseFundDeposits(address(fund));
		assertFalse(fund.guardianDepositsPaused());

		_assertVerifyCatchesRegressions();
	}

	/// @notice Before the switch-over the VI is not the registrar's: the handoff refuses to start, and
	///         a verify without pool pricing is refused outright.
	function test_fork_handoffRefusesBeforeTheRegistrarOwnsTheVi() public {
		vm.skip(!forked);
		vm.startPrank(deployer);
		FundsGovernance.PoolPricing memory notYet;
		notYet.registrar = FreshPoolPricing.takeOverVi(d, deployer).registrar;
		notYet.policy = pp.policy;
		// the registrar exists but hands the VI back (a takeover undone): start refuses, nothing moves
		notYet.registrar.execute(abi.encodeCall(Ownable2Step.transferOwnership, (deployer)));
		d.valueInterpreter.acceptOwnership();
		vm.stopPrank();
		vm.expectRevert(abi.encodeWithSelector(FundsGovernance.RegistrarNotViOwner.selector, deployer));
		this.startExternal(notYet);
		assertEq(d.factory.owner(), deployer);
		assertEq(d.factory.pendingOwner(), address(0), 'nothing began to move');

		FundsGovernance.PoolPricing memory none;
		vm.expectRevert(FundsGovernance.NoPoolPricing.selector);
		this.startExternal(none);
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	function _installPoolPricing() internal {
		vm.startPrank(deployer);
		pp = FreshPoolPricing.install(d, deployer);
		vm.stopPrank();
	}

	/// @dev external so a revert can be expected (library calls are inlined)
	function verifyExternal() external view {
		FundsGovernance.verify(d, pp, noCompounders, noRetired, address(timelock), SAFE, deployer, keeper);
	}

	/// @dev external so a revert can be expected (library calls are inlined); only for refusals, which
	///      fire on reads before anything is sent, so no prank is needed
	function startExternal(FundsGovernance.PoolPricing memory p) external {
		FundsGovernance.start(d, p, noCompounders, noRetired, address(timelock));
	}

	/// @dev Each pool-pricing check in {FundsGovernance.verify} fires on its own regression, each undone
	///      after, as the timelock (the owner of everything once handed off).
	function _assertVerifyCatchesRegressions() internal {
		// the VI handed on through the registrar: caught while pending, and once accepted — then handed back
		address stranger = makeAddr('stranger');
		vm.prank(address(timelock));
		pp.registrar.execute(abi.encodeCall(Ownable2Step.transferOwnership, (stranger)));
		vm.expectRevert(abi.encodeWithSelector(FundsGovernance.StillPending.selector, address(d.valueInterpreter), stranger));
		this.verifyExternal();
		vm.startPrank(stranger);
		d.valueInterpreter.acceptOwnership();
		vm.expectRevert(abi.encodeWithSelector(FundsGovernance.RegistrarNotViOwner.selector, stranger));
		this.verifyExternal();
		d.valueInterpreter.transferOwnership(address(pp.registrar));
		vm.stopPrank();
		vm.startPrank(address(timelock));
		pp.registrar.execute(abi.encodeCall(Ownable2Step.acceptOwnership, ()));

		// the long-tail policy dropped from the mandatory list, then one entry naming another policy
		FundFactory.PolicyReg[] memory mandatory = d.factory.getMandatoryPolicies();
		d.factory.setMandatoryPolicies(new FundFactory.PolicyReg[](0));
		vm.expectRevert(abi.encodeWithSelector(FundsGovernance.MandatoryPoliciesMismatch.selector, uint256(0), uint256(3)));
		this.verifyExternal();
		FundFactory.PolicyReg[] memory swapped = new FundFactory.PolicyReg[](mandatory.length);
		for (uint256 k; k < mandatory.length; ++k) {
			swapped[k] = mandatory[k];
		}
		address other = makeAddr('otherPolicy');
		swapped[1] = FundFactory.PolicyReg({hook: mandatory[1].hook, policy: other});
		d.factory.setMandatoryPolicies(swapped);
		vm.expectRevert(abi.encodeWithSelector(FundsGovernance.MandatoryPolicyMismatch.selector, uint256(1), other));
		this.verifyExternal();
		d.factory.setMandatoryPolicies(mandatory);

		// new funds back on fund v1
		IComptrollerDeployer v1 = new ComptrollerDeployer();
		d.factory.setComptrollerDeployer(v1);
		vm.expectRevert(abi.encodeWithSelector(FundsGovernance.NotFundV2.selector, address(v1)));
		this.verifyExternal();
		d.factory.setComptrollerDeployer(IComptrollerDeployer(pp.fundDeployer));
		vm.stopPrank();

		this.verifyExternal();
	}

	function _fundWithDeposit(uint256 amount) internal returns (Comptroller fund) {
		fund = Comptroller(
			d.factory.createFund(
				FundFactory.FundConfig({
					name: 'Genesis Rehearsal Fund',
					symbol: 'frGEN',
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
		deal(FundsMainnet.USDC, alice, amount);
		vm.startPrank(alice);
		IERC20(FundsMainnet.USDC).approve(address(fund), amount);
		fund.requestDeposit(amount);
		vm.stopPrank();
		skip(1 minutes);
		fund.executeDepositRequest(alice);
	}

	function _swap(Comptroller fund, address adapter, bytes memory data) internal {
		vm.prank(manager);
		fund.callOnIntegration(adapter, data);
	}

	function _assertNearChainlink(address asset, uint256 unit, address feed) internal view {
		(, int256 answer,,,) = AggregatorV3Interface(feed).latestRoundData();
		uint256 expected = uint256(answer) / 100; // 8-dp USD → 6-dp USDC (USDC itself ≈ $1)
		assertApproxEqRel(d.valueInterpreter.calcCanonicalAssetValue(asset, unit, FundsMainnet.USDC), expected, 0.01e18);
	}
}

/// @notice THE SAME GENESIS WITHOUT FROST (founder decision 2026-09-28: FrostyFunds launches
///         first): no fee reserve, protocol fee off, the handoff moves the three remaining owners
///         — then FROST arrives and governance turns the fee on with ONE timelock batch
///         (`settleFees()` on every live fund, then `setProtocolFee`). A fund left out of that
///         batch is charged for the whole time the fee was off, which is why the batch must
///         name every fund.
///         Run: BASE_MAINNET_RPC=<url> forge test --match-contract FundsMainnetGenesisNoFrostForkTest -vv
contract FundsMainnetGenesisNoFrostForkTest is Test {
	address internal constant SAFE = 0xB0f37bE90a8BD82D991Bf694F960C67198778B8B; // live 2-of-3 on Base
	uint16 internal constant FEE_BPS = 25;
	uint256 internal constant YEAR = 365 days;

	bool internal forked;
	address internal deployer = makeAddr('deployer');
	address internal keeper = makeAddr('autopilotKeeper');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');
	TimelockController internal timelock;
	FundsMainnet.Deployed internal d;
	/// @dev a rehearsal genesis has no TWAP tier (retired 2026-10-04) and no fee compounders
	FundsGovernance.Retired internal noRetired;
	FundsGovernance.Compounders internal noCompounders;
	FundsGovernance.PoolPricing internal pp;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, 53_390_931); // pinned: live state moves under a fork at the latest block (2026-11-01)
		forked = true;

		// DeployFundsTimelock's shape: Safe proposes/cancels, anyone executes, no admin
		address[] memory proposers = new address[](1);
		proposers[0] = SAFE;
		address[] memory executors = new address[](1);
		executors[0] = address(0);
		timelock = new TimelockController(2 days, proposers, executors, address(0));

		vm.startPrank(deployer);
		d = FundsMainnet.deploy(_config(address(0), 0));
		vm.stopPrank();
	}

	function test_fork_noFrost_noReserveAndTheFeeIsOff() public {
		vm.skip(!forked);
		assertEq(address(d.feeReserve), address(0));
		assertEq(d.factory.protocolFeeBps(), 0);
		assertEq(d.factory.protocolFeeRecipient(), address(0));
		vm.startPrank(deployer);
		pp = FreshPoolPricing.install(d, deployer);
		vm.stopPrank();
		// registrar, factory, Veranta factory: no reserve
		assertEq(FundsGovernance.owned(d, pp, noCompounders, noRetired).length, 3);
	}

	function test_fork_noFrost_aFeeWithoutFrostIsRefused() public {
		vm.skip(!forked);
		vm.expectRevert(FundsMainnet.BadConfig.selector);
		this.deployExternal(_config(address(0), FEE_BPS));
	}

	function test_fork_noFrost_handoffThenTheFeeTurnsOnWithoutBackCharging() public {
		vm.skip(!forked);
		Comptroller settled = _fundWithDeposit('Settled In The Batch', 'frIN', 10_000e6);
		Comptroller leftOut = _fundWithDeposit('Left Out Of The Batch', 'frOUT', 10_000e6);

		// pool pricing as on mainnet since 2026-10-04, then the handoff — three owners, no reserve
		vm.startPrank(deployer);
		pp = FreshPoolPricing.install(d, deployer);
		FundsGovernance.start(d, pp, noCompounders, noRetired, address(timelock));
		vm.stopPrank();
		(address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
			FundsGovernance.acceptBatch(d, pp, noCompounders, noRetired);
		assertEq(targets.length, 3);
		vm.prank(SAFE);
		timelock.scheduleBatch(targets, values, payloads, bytes32(0), keccak256('handoff'), 2 days);
		skip(2 days);
		timelock.executeBatch(targets, values, payloads, bytes32(0), keccak256('handoff'));
		FundsGovernance.verify(d, pp, noCompounders, noRetired, address(timelock), SAFE, deployer, keeper);

		// half a year with the fee off — nobody touches either fund
		skip(180 days);

		// FROST launches; its reserve is owned by the timelock from the start
		MockERC20 frost = new MockERC20('FROST stand-in', 'FROST', 18);
		ProtocolFeeReserve reserve = new ProtocolFeeReserve(address(frost), address(timelock));

		// ONE batch: settle every live fund (only `settled` here, on purpose), then turn the fee on
		address[] memory t = new address[](2);
		bytes[] memory p = new bytes[](2);
		t[0] = address(settled);
		p[0] = abi.encodeCall(Comptroller.settleFees, ());
		t[1] = address(d.factory);
		p[1] = abi.encodeCall(FundFactory.setProtocolFee, (FEE_BPS, address(reserve)));
		vm.prank(SAFE);
		timelock.scheduleBatch(t, new uint256[](2), p, bytes32(0), keccak256('fee on'), 2 days);
		skip(2 days);
		timelock.executeBatch(t, new uint256[](2), p, bytes32(0), keccak256('fee on'));
		assertEq(d.factory.protocolFeeBps(), FEE_BPS);
		assertEq(d.factory.protocolFeeRecipient(), address(reserve));

		// 30 days with the fee on, then both funds settle
		skip(30 days);
		settled.settleFees();
		leftOut.settleFees();

		uint256 settledFee = IERC20(address(settled.shares())).balanceOf(address(reserve));
		uint256 leftOutFee = IERC20(address(leftOut.shares())).balanceOf(address(reserve));
		uint256 supply = 10_000e18; // $10k at the $1 bootstrap price (bootstrap shares included)
		// the batched fund pays for the 30 days the fee was on — nothing more
		assertApproxEqRel(settledFee, (supply * FEE_BPS * 30 days) / (YEAR * 10_000), 0.01e18);
		// the fund left out pays for everything since its deposit (2 + 180 + 2 + 30 days)
		assertApproxEqRel(leftOutFee, (supply * FEE_BPS * 214 days) / (YEAR * 10_000), 0.01e18);
	}

	/// @dev external so a config revert can be expected (library calls are inlined)
	function deployExternal(FundsMainnet.Config memory cfg) external returns (FundsMainnet.Deployed memory) {
		return FundsMainnet.deploy(cfg);
	}

	function _config(address frost, uint16 feeBps) internal view returns (FundsMainnet.Config memory) {
		return FundsMainnet.Config({deployer: deployer, safe: SAFE, frost: frost, autopilotKeeper: keeper, protocolFeeBps: feeBps});
	}

	function _fundWithDeposit(string memory name, string memory symbol, uint256 amount) internal returns (Comptroller fund) {
		fund = Comptroller(
			d.factory.createFund(
				FundFactory.FundConfig({
					name: name,
					symbol: symbol,
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
		deal(FundsMainnet.USDC, alice, amount);
		vm.startPrank(alice);
		IERC20(FundsMainnet.USDC).approve(address(fund), amount);
		fund.requestDeposit(amount);
		vm.stopPrank();
		skip(1 minutes);
		fund.executeDepositRequest(alice);
	}
}
