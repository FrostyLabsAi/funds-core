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
import {TwapListingRegistry} from '../../src/pricing/TwapListingRegistry.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {PriceListingModule} from '../../src/pricing/PriceListingModule.sol';
import {ProtocolFeeReserve} from '../../src/core/ProtocolFeeReserve.sol';
import {MockERC20} from '../utils/Mocks.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {FundsGovernance} from '../../script/mainnet/FundsGovernance.sol';
import {TwapListingV2} from '../../script/mainnet/TwapListingV2.sol';

/// @notice THE MAINNET GENESIS REHEARSAL, on a Base fork against every real venue:
///         deploy exactly what DeployFundsMainnet ships → price the genesis assets → a fund
///         deposits, swaps on Uniswap AND both Aerodrome deployments, parks cash in Veranta's
///         avUSDC, opens a real Veranta perp → governance handoff to a FROST-style timelock
///         (Safe proposes, 2-day delay, open execution) → the deployer holds NOTHING and the
///         Safe's guardian lane works one way only.
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
	/// @dev TWAP listing v2 not deployed: the handoff as genesis shipped it
	FundsGovernance.TwapV2 internal noTwapV2;
	/// @dev fee compounders not deployed
	FundsGovernance.Compounders internal noCompounders;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc);
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
		assertEq(d.factory.getMandatoryPolicies().length, 4);
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

		vm.startPrank(deployer);
		FundsGovernance.start(d, noTwapV2, noCompounders, address(timelock), deployer);
		vm.stopPrank();
		(address[] memory targets, uint256[] memory values, bytes[] memory payloads) = FundsGovernance.acceptBatch(d, noTwapV2, noCompounders);
		bytes32 salt = keccak256('frostyfunds-genesis');
		vm.prank(SAFE);
		timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, 2 days);

		// not before the delay — then ANYONE executes
		vm.expectRevert();
		timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
		skip(2 days);
		timelock.executeBatch(targets, values, payloads, bytes32(0), salt);

		FundsGovernance.verify(d, noTwapV2, noCompounders, address(timelock), SAFE, deployer, keeper);

		// the deployer is powerless everywhere
		vm.startPrank(deployer);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
		d.factory.registerAdapter(address(1));
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
		d.valueInterpreter.addPrimitive(address(1), address(2), 1 hours);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
		d.verantaFactory.setPairAsset(9, address(1));
		vm.expectRevert();
		d.twapRegistry.list(FundsMainnet.AERO, FundsMainnet.USDC, TwapListingRegistry.Venue.UniswapV3, 3000);
		vm.stopPrank();

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
	}

	/// @notice TWAP listing v2 wired first (the module owns the VI), then the handoff: the MODULE and
	///         registry v2 move to the timelock in the VI's place, and the deployer holds nothing.
	function test_fork_handoffWithTwapV2() public {
		vm.skip(!forked);
		address twapKeeper = makeAddr('twapKeeper');

		// a v2 whose module does not own the VI (a v2 deploy that died mid-broadcast) is refused before anything moves
		FundsGovernance.TwapV2 memory halfWired = noTwapV2;
		halfWired.module = PriceListingModule(makeAddr('moduleWithoutTheVi'));
		vm.expectRevert(abi.encodeWithSelector(FundsGovernance.ModuleNotViOwner.selector, deployer));
		this.startExternal(halfWired);

		// exactly what DeployTwapListingV2 broadcasts, on this genesis, with a non-deployer keeper
		vm.startPrank(deployer);
		TwapListingV2.Deployed memory t = TwapListingV2.deploy(
			TwapListingV2.Config({
				deployer: deployer,
				valueInterpreter: d.valueInterpreter,
				factory: d.factory,
				twapPolicyV1: address(d.twapPolicy),
				keeper: twapKeeper
			})
		);
		FundsGovernance.TwapV2 memory v2 = FundsGovernance.TwapV2({module: t.module, registry: t.registry, policy: address(t.policy)});
		FundsGovernance.start(d, v2, noCompounders, address(timelock), deployer);
		vm.stopPrank();

		// module, registry v2, factory, v1 registry, Veranta factory, fee reserve — never the VI
		(address[] memory targets, uint256[] memory values, bytes[] memory payloads) = FundsGovernance.acceptBatch(d, v2, noCompounders);
		assertEq(targets.length, 6);
		for (uint256 i; i < targets.length; ++i) {
			assertTrue(targets[i] != address(d.valueInterpreter));
		}
		vm.prank(SAFE);
		timelock.scheduleBatch(targets, values, payloads, bytes32(0), keccak256('frostyfunds-twap-v2'), 2 days);
		skip(2 days);
		timelock.executeBatch(targets, values, payloads, bytes32(0), keccak256('frostyfunds-twap-v2'));

		FundsGovernance.verify(d, v2, noCompounders, address(timelock), SAFE, deployer, keeper);
		assertEq(d.valueInterpreter.owner(), address(t.module));
		assertTrue(t.module.keepers(twapKeeper)); // the auto-lister keeps its role through the handoff

		// the deployer is powerless over the module, registry v2 and the VI
		vm.startPrank(deployer);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
		t.module.execute(abi.encodeCall(ValueInterpreter.setAnswerBounds, (FundsMainnet.USDC, 1, 10e8)));
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
		t.module.setKeeper(deployer, true);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
		t.registry.setLister(deployer, true);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
		d.valueInterpreter.addPrimitive(address(1), address(2), 1 hours);
		vm.stopPrank();

		// the timelock reaches VI admin through the module
		vm.prank(address(timelock));
		t.module.execute(abi.encodeCall(ValueInterpreter.setAnswerBounds, (FundsMainnet.USDC, 1, 10e8)));
		(int256 min, int256 max) = d.valueInterpreter.answerBounds(FundsMainnet.USDC);
		assertEq(min, 1);
		assertEq(max, 10e8);

		_assertVerifyCatchesTwapV2Regressions(v2, address(d.twapPolicy));
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	/// @dev external so a revert can be expected (library calls are inlined)
	function verifyExternal(FundsGovernance.TwapV2 memory v2) external view {
		FundsGovernance.verify(d, v2, noCompounders, address(timelock), SAFE, deployer, keeper);
	}

	/// @dev external so a revert can be expected (library calls are inlined)
	function startExternal(FundsGovernance.TwapV2 memory v2) external {
		FundsGovernance.start(d, v2, noCompounders, address(timelock), deployer);
	}

	/// @dev Each v2 check in {FundsGovernance.verify} fires on its own regression (each undone after),
	///      and a verify that ignores v2 is refused once the module owns the VI.
	function _assertVerifyCatchesTwapV2Regressions(FundsGovernance.TwapV2 memory v2, address twapPolicyV1) internal {
		vm.expectRevert(
			abi.encodeWithSelector(FundsGovernance.NotHandedOff.selector, address(d.valueInterpreter), address(v2.module))
		);
		this.verifyExternal(noTwapV2);

		vm.startPrank(address(timelock));
		v2.module.setKeeper(deployer, true);
		vm.expectRevert(FundsGovernance.DeployerIsModuleKeeper.selector);
		this.verifyExternal(v2);
		v2.module.setKeeper(deployer, false);

		v2.registry.setLister(deployer, true);
		vm.expectRevert(FundsGovernance.DeployerStillV2Lister.selector);
		this.verifyExternal(v2);
		v2.registry.setLister(deployer, false);

		v2.registry.setLister(address(v2.module), false);
		vm.expectRevert(FundsGovernance.ModuleNotLister.selector);
		this.verifyExternal(v2);
		v2.registry.setLister(address(v2.module), true);

		// the VI handed on by the module: caught while pending, and once accepted — then handed back
		address stranger = makeAddr('stranger');
		v2.module.execute(abi.encodeCall(Ownable2Step.transferOwnership, (stranger)));
		vm.expectRevert(
			abi.encodeWithSelector(FundsGovernance.StillPending.selector, address(d.valueInterpreter), stranger)
		);
		this.verifyExternal(v2);
		vm.stopPrank();
		vm.startPrank(stranger);
		d.valueInterpreter.acceptOwnership();
		vm.expectRevert(abi.encodeWithSelector(FundsGovernance.ModuleNotViOwner.selector, stranger));
		this.verifyExternal(v2);
		d.valueInterpreter.transferOwnership(address(v2.module));
		vm.stopPrank();
		vm.startPrank(address(timelock));
		v2.module.execute(abi.encodeCall(Ownable2Step.acceptOwnership, ()));

		FundFactory.PolicyReg[] memory mandatory = d.factory.getMandatoryPolicies();
		mandatory[2].policy = twapPolicyV1;
		d.factory.setMandatoryPolicies(mandatory);
		vm.expectRevert(abi.encodeWithSelector(FundsGovernance.MandatoryPolicyNotV2.selector, uint256(2), twapPolicyV1));
		this.verifyExternal(v2);
		mandatory[2].policy = v2.policy;
		d.factory.setMandatoryPolicies(mandatory);
		vm.stopPrank();

		this.verifyExternal(v2);
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
///         first): no fee reserve, protocol fee off, the handoff moves the four remaining owners
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
	/// @dev TWAP listing v2 not deployed: the handoff as genesis shipped it
	FundsGovernance.TwapV2 internal noTwapV2;
	/// @dev fee compounders not deployed
	FundsGovernance.Compounders internal noCompounders;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc);
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
		assertEq(FundsGovernance.owned(d, noTwapV2, noCompounders).length, 4);
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

		// handoff — four owners, no reserve
		vm.startPrank(deployer);
		FundsGovernance.start(d, noTwapV2, noCompounders, address(timelock), deployer);
		vm.stopPrank();
		(address[] memory targets, uint256[] memory values, bytes[] memory payloads) = FundsGovernance.acceptBatch(d, noTwapV2, noCompounders);
		assertEq(targets.length, 4);
		vm.prank(SAFE);
		timelock.scheduleBatch(targets, values, payloads, bytes32(0), keccak256('handoff'), 2 days);
		skip(2 days);
		timelock.executeBatch(targets, values, payloads, bytes32(0), keccak256('handoff'));
		FundsGovernance.verify(d, noTwapV2, noCompounders, address(timelock), SAFE, deployer, keeper);

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
