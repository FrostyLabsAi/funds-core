// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test, Vm} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {IExternalPosition} from '../../src/interfaces/IExternalPosition.sol';
import {AggregatorV3Interface} from '../../src/interfaces/AggregatorV3Interface.sol';
import {ICLGauge} from '../../src/interfaces/external/ICLGauge.sol';
import {ISlipstreamSwapRouter} from '../../src/interfaces/external/ISlipstreamSwapRouter.sol';
import {
	ISlipstreamNonfungiblePositionManager,
	ISlipstreamPoolLookup
} from '../../src/interfaces/external/ISlipstreamNonfungiblePositionManager.sol';
import {SlipstreamLPPosition, SlipstreamLPPositionFactory} from '../../src/positions/SlipstreamLPPosition.sol';
import {SlipstreamLPPositionV2, SlipstreamLPPositionV2Factory} from '../../src/positions/SlipstreamLPPositionV2.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {StealingGauge} from './SlipstreamGaugeFork.t.sol';

/// @notice The live CLGauge views this test reads (verified on Basescan / aerodrome-finance/slipstream CLGauge.sol).
interface ICLGaugeLive {
	function pool() external view returns (address);
	function nft() external view returns (address);
	function voter() external view returns (address);
	function rewardRate() external view returns (uint256);
	function periodFinish() external view returns (uint256);
}

interface IVoterLive {
	function isAlive(address gauge) external view returns (bool);
}

interface ICLPoolGauge {
	function gauge() external view returns (address);
}

/// @notice SlipstreamLPPositionV2 (the AERO claim fee) on a Base fork against the LIVE genesis:
///         the V2 factories are registered on the live FundFactory under fresh type ids 104 (Slipstream-1)
///         and 107 (Slipstream-2) by its real owner; a fresh fund on that factory mints, stakes into
///         the pool's own live CLGauge, earns real AERO emissions and claims or unstakes (CLGauge.withdraw
///         pays accrued AERO too, so Unstake takes the same fee: ruling C-1). No mocks; `deal` only
///         funds balances. Pools (both WETH/USDC, non-B20), each read with `cast` at block 52014634:
///         - Slipstream-1 ts100 0xb2cc…DC59: gauge() 0xF33a…e0c8 (gauge.pool() = the pool, nft() =
///           CL_NPM, rewardToken() = AERO, rewardRate 0.1943 AERO/s, periodFinish 1791417600,
///           Voter 0x1661…80A5 isAlive true); staked liquidity 1.943e18 of 2.671e18.
///         - Slipstream-2 ts50 0x3FE0…392A: gauge() 0xA0B6…2D28 (gauge.pool() = the pool, nft() =
///           CL2_NPM, rewardToken() = AERO, rewardRate 0.3578 AERO/s, same periodFinish, isAlive
///           true); staked liquidity 7.186e18 of 8.536e18. Its gauge factory has penaltyRate 10000
///           with minStakeTimes(pool) = 10 s: a claim within 10 s of staking pays nothing (every claim
///           here is ≥ 10 min after staking, and the split is on what actually arrived).
///         CL_NPM.factory() = CL_FACTORY and CL2_NPM.factory() = CL2_FACTORY; types 4 and 7 point at
///         the live V1 factories 0x7542…8176 / 0xa205…B62e (positionManager() = CL_NPM / CL2_NPM).
///         Heartbeats: at the pinned block the WETH feed (VI heartbeat 3600 s) is 1,150 s old, so a
///         test has 2,450 s of warp; USDC/AERO (90,000 s) are not binding. Every test stays ≤ 1,860 s
///         (1 min deposit window + accruals) and `_accrue` asserts the WETH feed is still fresh. The
///         ETH/USD rounds before the pinned one are 750–1,230 s apart, so an unpinned block's round is
///         young enough for 1,860 s too (≤ ~1,230 + 1,860 < 3,600).
///         Run: BASE_MAINNET_RPC=<url> forge test --match-path test/fork/SlipstreamLPPositionV2Fork.t.sol -j 1 -vv
contract SlipstreamLPPositionV2ForkTest is Test {
	string internal constant GENESIS_FILE = 'deployments/base-mainnet.json';
	/// @dev The default fork block since 2026-10-25: at the live head the Aero merger (2026-10-22) has killed these
	///      gauges, and the factory makes newer funds than the genesis Comptroller these tests deposit into.
	uint256 internal constant PINNED_BLOCK = 52_014_634;

	address internal constant WETH = FundsMainnet.WETH; // token0 of both pools (0x42… < 0x83…)
	address internal constant USDC = FundsMainnet.USDC;
	address internal constant AERO = FundsMainnet.AERO;
	/// @dev FrostyDAO Treasury Safe: VERSION() "1.4.1", getThreshold() 2 (cast, block 52014634)
	address internal constant TREASURY = 0x47b7702a4789912d0dfFDadC07c50395c293fF0A;

	address internal constant CL1_POOL = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
	address internal constant CL1_GAUGE = 0xF33a96b5932D9E9B9A0eDA447AbD8C9d48d2e0c8;
	address internal constant CL2_POOL = 0x3FE04A59Ebd38cF06080a6F60a98D124eb59392A;
	address internal constant CL2_GAUGE = 0xA0B61fdB9f1FB9b917Fe38b49427Fd4D87472D28;
	address internal constant V1_CL1_FACTORY = 0x7542c62565f48520A34Cf79884656efDEdD38176;
	address internal constant V1_CL2_FACTORY = 0xa205812D1748ea91e4563253ca2af2F66fD3B62e;
	uint256 internal constant V2_CL1_TYPE = 104;
	uint256 internal constant V2_CL2_TYPE = 107;

	uint8 internal constant MINT = uint8(SlipstreamLPPositionV2.Action.Mint);
	uint8 internal constant DECREASE = uint8(SlipstreamLPPositionV2.Action.DecreaseLiquidity);
	uint8 internal constant COLLECT = uint8(SlipstreamLPPositionV2.Action.Collect);
	uint8 internal constant BURN = uint8(SlipstreamLPPositionV2.Action.Burn);
	uint8 internal constant STAKE = uint8(SlipstreamLPPositionV2.Action.Stake);
	uint8 internal constant UNSTAKE = uint8(SlipstreamLPPositionV2.Action.Unstake);
	uint8 internal constant CLAIM = uint8(SlipstreamLPPositionV2.Action.ClaimRewards);
	uint8 internal constant SWEEP = uint8(SlipstreamLPPositionV2.Action.SweepToVault);

	/// @dev ±1,000 ticks (≈ ±10%) around the live tick: in range, so the stake earns emissions
	int24 internal constant HALF_RANGE = 1000;
	uint256 internal constant ACCRUAL = 15 minutes;
	uint256 internal constant LP_WETH = 20 ether;
	uint256 internal constant LP_USDC = 60_000e6;

	struct Venue {
		string label;
		address npm;
		address router;
		address pool;
		address gauge;
		address poolFactory;
		int24 spacing;
		uint256 v1Type;
		address v1Factory;
		uint256 v2Type;
		SlipstreamLPPositionV2Factory v2Factory;
	}

	/// @dev One gauge payout (a claim or an unstake), measured.
	struct Claim {
		uint256 earned; // the gauge's own earned() just before the action
		uint256 fromGauge; // AERO that left the gauge
		uint256 toTreasury;
		uint256 toVault;
		uint256 gavBefore;
		uint256 gavAfter;
	}

	bool internal forked;
	FundFactory internal factory;
	ValueInterpreter internal vi;
	address internal uniAdapter;
	address internal deployer;
	SlipstreamLPPositionV2Factory internal v2Cl1;
	SlipstreamLPPositionV2Factory internal v2Cl2;

	address internal manager = makeAddr('manager');
	address internal investor = makeAddr('investor');
	address internal stranger = makeAddr('stranger');
	address internal swapper = makeAddr('swapper');
	address internal donor = makeAddr('donor');
	address internal thief = makeAddr('thief');
	address internal governance = makeAddr('governance');
	address internal newTreasury = makeAddr('newTreasury');

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, vm.envOr('BASE_FORK_BLOCK', PINNED_BLOCK));
		forked = true;

		string memory genesis = vm.readFile(GENESIS_FILE);
		deployer = vm.parseJsonAddress(genesis, '.deployer');
		vi = ValueInterpreter(vm.parseJsonAddress(genesis, '.valueInterpreter'));
		factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		uniAdapter = vm.parseJsonAddress(genesis, '.uniAdapter');

		// Task 4's deploy: the genesis deployer creates both V2 factories (it owns them until governance)
		vm.startPrank(deployer);
		v2Cl1 = new SlipstreamLPPositionV2Factory(ISlipstreamNonfungiblePositionManager(FundsMainnet.CL_NPM));
		v2Cl2 = new SlipstreamLPPositionV2Factory(ISlipstreamNonfungiblePositionManager(FundsMainnet.CL2_NPM));
		vm.stopPrank();
		// fresh type ids here; re-pointing 4 / 7 is Task 4's (rehearsed in the re-point tests below)
		vm.startPrank(Ownable(address(factory)).owner());
		factory.registerPositionType(V2_CL1_TYPE, address(v2Cl1));
		factory.registerPositionType(V2_CL2_TYPE, address(v2Cl2));
		vm.stopPrank();
	}

	// ─── live wiring ─────────────────────────────────────────────────────────────

	function test_fork_poolsGaugesAndFactoriesAreLive() public {
		vm.skip(!forked);
		_assertVenueLive(_cl1());
		_assertVenueLive(_cl2());
		// the terminal sends these ordinals (frosty-terminal slipstreamGauge.ts: Stake 5, Unstake 6, ClaimRewards 7)
		assertEq(uint8(SlipstreamLPPosition.Action.Mint), MINT);
		assertEq(uint8(SlipstreamLPPosition.Action.DecreaseLiquidity), DECREASE);
		assertEq(uint8(SlipstreamLPPosition.Action.Collect), COLLECT);
		assertEq(uint8(SlipstreamLPPosition.Action.Burn), BURN);
		assertEq(uint8(SlipstreamLPPosition.Action.Stake), STAKE);
		assertEq(uint8(SlipstreamLPPosition.Action.Unstake), UNSTAKE);
		assertEq(uint8(SlipstreamLPPosition.Action.ClaimRewards), CLAIM);
		assertEq(uint8(SlipstreamLPPosition.Action.SweepToVault), SWEEP);
		assertEq(STAKE, 5);
		assertEq(UNSTAKE, 6);
		assertEq(CLAIM, 7);
	}

	function _assertVenueLive(Venue memory v) internal {
		assertEq(ICLPoolGauge(v.pool).gauge(), v.gauge, 'the pool names its gauge');
		ICLGaugeLive g = ICLGaugeLive(v.gauge);
		assertEq(g.pool(), v.pool, 'the gauge is the pool gauge');
		assertEq(g.nft(), v.npm, 'the gauge takes this NFT manager');
		assertEq(ICLGauge(v.gauge).rewardToken(), AERO, 'it pays AERO');
		assertGt(g.rewardRate(), 0, 'with live emissions');
		assertGt(g.periodFinish(), block.timestamp + 1 hours, 'for the whole test');
		assertTrue(IVoterLive(g.voter()).isAlive(v.gauge), 'the gauge is alive');
		assertEq(ISlipstreamNonfungiblePositionManager(v.npm).factory(), v.poolFactory, 'NPM mints into this venue');
		assertEq(ISlipstreamPoolLookup(v.poolFactory).getPool(WETH, USDC, v.spacing), v.pool);
		assertEq(factory.positionTypeFactories(v.v1Type), v.v1Factory, 'the live V1 type');
		assertEq(address(SlipstreamLPPositionFactory(v.v1Factory).positionManager()), v.npm);
		assertEq(factory.positionTypeFactories(v.v2Type), address(v.v2Factory), 'the V2 type');
		assertEq(address(v.v2Factory.positionManager()), v.npm);
		assertEq(v.v2Factory.owner(), deployer);
		assertEq(v.v2Factory.aeroFeeBps(), 1000, 'starts at 10%');
		assertEq(v.v2Factory.treasury(), TREASURY, 'starts at the DAO Safe');
		emit log_named_string('venue', v.label);
		emit log_named_decimal_uint('  gauge rewardRate (AERO/s)', g.rewardRate(), 18);
	}

	// ─── the claim fee ───────────────────────────────────────────────────────────

	function test_fork_cl1_claimPaysTheTreasuryTenPercent() public {
		vm.skip(!forked);
		_claimSplitsTenPercent(_cl1());
	}

	function test_fork_cl2_claimPaysTheTreasuryTenPercent() public {
		vm.skip(!forked);
		_claimSplitsTenPercent(_cl2());
	}

	function _claimSplitsTenPercent(Venue memory v) internal {
		Comptroller fund = _fund(string.concat('Claim ', v.label));
		address position = _open(fund, v, v.v2Type);
		assertEq(address(SlipstreamLPPositionV2(position).factory()), address(v.v2Factory), 'a V2 position');
		_mint(fund, v, position);
		_act(fund, position, STAKE);
		assertEq(IERC721(v.npm).ownerOf(SlipstreamLPPositionV2(position).tokenId()), v.gauge, 'staked in the pool gauge');
		_accrue(ACCRUAL);

		vm.recordLogs();
		Claim memory c = _claim(fund, position, v.gauge, TREASURY);
		_assertSplit(c, 1000, position);
		_assertFeeEvent(vm.getRecordedLogs(), position, TREASURY, c);
		assertTrue(_tracks(fund, AERO), 'the fund tracks the AERO it received');
		assertGt(c.gavAfter, c.gavBefore, "the vault's AERO counts in GAV");
		emit log_named_string('venue', v.label);
		_logClaim(c);
	}

	/// The factory's fee and treasury are read at claim time: governance moves every position at once.
	function test_fork_feeAndTreasuryChangesApplyToTheNextClaim() public {
		vm.skip(!forked);
		Venue memory v = _cl2();
		Comptroller fund = _fund('Fee change');
		address position = _open(fund, v, v.v2Type);
		_mint(fund, v, position);
		_act(fund, position, STAKE);

		_accrue(10 minutes);
		Claim memory c1 = _claim(fund, position, v.gauge, TREASURY);
		_assertSplit(c1, 1000, position);

		vm.prank(deployer);
		v.v2Factory.setAeroFee(2500);
		_accrue(10 minutes);
		Claim memory c2 = _claim(fund, position, v.gauge, TREASURY);
		_assertSplit(c2, 2500, position);

		vm.prank(deployer);
		v.v2Factory.setTreasury(newTreasury);
		uint256 safeBefore = IERC20(AERO).balanceOf(TREASURY);
		_accrue(10 minutes);
		Claim memory c3 = _claim(fund, position, v.gauge, newTreasury);
		_assertSplit(c3, 2500, position);
		assertEq(IERC20(AERO).balanceOf(TREASURY), safeBefore, 'the old treasury gets nothing more');
		emit log_string('claim 1 @ 10%');
		_logClaim(c1);
		emit log_string('claim 2 @ 25%');
		_logClaim(c2);
		emit log_string('claim 3 @ 25%, new treasury');
		_logClaim(c3);
	}

	function test_fork_feeBoundsAndOwnerControls() public {
		vm.skip(!forked);
		SlipstreamLPPositionV2Factory f = v2Cl2;
		assertEq(f.MIN_AERO_FEE_BPS(), 500);
		assertEq(f.MAX_AERO_FEE_BPS(), 3000);
		assertEq(f.INITIAL_AERO_FEE_BPS(), 1000);
		assertEq(f.DAO_TREASURY(), TREASURY);

		vm.startPrank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		f.setAeroFee(1500);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		f.setTreasury(stranger);
		vm.stopPrank();

		vm.startPrank(deployer);
		uint16[4] memory outside = [uint16(0), 499, 3001, type(uint16).max];
		for (uint256 i; i < outside.length; ++i) {
			vm.expectRevert(abi.encodeWithSelector(SlipstreamLPPositionV2Factory.AeroFeeOutOfBounds.selector, outside[i]));
			f.setAeroFee(outside[i]);
		}
		assertEq(f.aeroFeeBps(), 1000, 'unchanged by the refused calls');
		vm.expectEmit(address(f));
		emit SlipstreamLPPositionV2Factory.AeroFeeSet(500);
		f.setAeroFee(500);
		assertEq(f.aeroFeeBps(), 500);
		f.setAeroFee(3000);
		assertEq(f.aeroFeeBps(), 3000);
		vm.expectRevert(SlipstreamLPPositionV2Factory.ZeroAddress.selector);
		f.setTreasury(address(0));
		assertEq(f.treasury(), TREASURY);
		vm.expectEmit(address(f));
		emit SlipstreamLPPositionV2Factory.TreasurySet(newTreasury);
		f.setTreasury(newTreasury);
		assertEq(f.treasury(), newTreasury);

		// two-step handover to governance
		f.transferOwnership(governance);
		vm.stopPrank();
		assertEq(f.owner(), deployer, 'still the deployer until accepted');
		assertEq(f.pendingOwner(), governance);
		vm.prank(governance);
		f.acceptOwnership();
		assertEq(f.owner(), governance);
		vm.prank(deployer);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
		f.setAeroFee(1000);
		vm.prank(governance);
		f.setAeroFee(1000);
		assertEq(f.aeroFeeBps(), 1000);

		vm.expectRevert(SlipstreamLPPositionV2Factory.ZeroAddress.selector);
		new SlipstreamLPPositionV2Factory(ISlipstreamNonfungiblePositionManager(address(0)));
	}

	/// AERO already on the position (here a donation) is never charged: the fee is on what the claim
	/// brought in; the vault gets everything else, as V1 sends it everything.
	function test_fork_feeIsOnTheClaimedDeltaNeverTheBalance() public {
		vm.skip(!forked);
		Venue memory v = _cl2();
		Comptroller fund = _fund('Fee on delta');
		address position = _open(fund, v, v.v2Type);
		_mint(fund, v, position);
		_act(fund, position, STAKE);
		_accrue(ACCRUAL);

		uint256 donation = 1_000e18;
		deal(AERO, donor, donation);
		vm.prank(donor);
		assertTrue(IERC20(AERO).transfer(position, donation));

		Claim memory c = _claim(fund, position, v.gauge, TREASURY);
		assertGt(c.earned, 0);
		assertEq(c.fromGauge, c.earned);
		uint256 fee = c.earned * 1000 / 10_000;
		assertEq(c.toTreasury, fee, 'the fee is on the claim alone');
		assertEq(c.toVault, donation + c.earned - fee, 'the vault gets the rest, the donation included');
		assertEq(IERC20(AERO).balanceOf(position), 0);
		_logClaim(c);
	}

	// ─── unchanged paths: no cut ─────────────────────────────────────────────────

	/// Trading fees and principal reach the vault whole: exactly what the NFT manager itself would pay.
	function test_fork_collectPaysTheVaultEverything() public {
		vm.skip(!forked);
		Venue memory v = _cl2();
		Comptroller fund = _fund('Collect');
		address fv = address(fund.vault());
		address position = _open(fund, v, v.v2Type);
		_mint(fund, v, position);
		_churn(v, 30 ether, 2); // real swaps through the pool pay it fees

		(uint256 fees0, uint256 fees1) = _collectable(v, position);
		assertGt(fees0, 0, 'real WETH fees');
		assertGt(fees1, 0, 'real USDC fees');
		uint256[4] memory before_ = _wethUsdc(fv);
		_act(fund, position, _assets(WETH, USDC), COLLECT, '');
		uint256[4] memory after_ = _wethUsdc(fv);
		assertEq(after_[0] - before_[0], fees0, 'vault: every WETH fee');
		assertEq(after_[1] - before_[1], fees1, 'vault: every USDC fee');
		assertEq(after_[2], before_[2], 'treasury: no WETH');
		assertEq(after_[3], before_[3], 'treasury: no USDC');

		// principal: decrease half, collect, all of it to the vault
		uint256 id = SlipstreamLPPositionV2(position).tokenId();
		(,,,,,,, uint128 liquidity,,,,) = ISlipstreamNonfungiblePositionManager(v.npm).positions(id);
		_act(fund, position, new address[](0), DECREASE, abi.encode(liquidity / 2, uint256(0), uint256(0)));
		(uint256 out0, uint256 out1) = _collectable(v, position);
		assertGt(out0, 0);
		assertGt(out1, 0);
		before_ = _wethUsdc(fv);
		_act(fund, position, _assets(WETH, USDC), COLLECT, '');
		after_ = _wethUsdc(fv);
		assertEq(after_[0] - before_[0], out0, 'vault: all decreased WETH');
		assertEq(after_[1] - before_[1], out1, 'vault: all decreased USDC');
		assertEq(after_[2], before_[2]);
		assertEq(after_[3], before_[3]);
		emit log_named_decimal_uint('collected WETH fees', fees0, 18);
		emit log_named_decimal_uint('collected USDC fees', fees1, 6);
	}

	// ─── NAV parity with V1 ──────────────────────────────────────────────────────

	function test_fork_cl1_navMatchesV1() public {
		vm.skip(!forked);
		_navMatchesV1(_cl1());
	}

	function test_fork_cl2_navMatchesV1() public {
		vm.skip(!forked);
		_navMatchesV1(_cl2());
	}

	/// A V1 position (live type) and a V2 position (new type) given the same mint report the same
	/// managed assets at every step; only the claim differs (V1: 100% to the vault).
	function _navMatchesV1(Venue memory v) internal {
		Comptroller fund = _fund(string.concat('NAV ', v.label));
		address p1 = _open(fund, v, v.v1Type);
		address p2 = _open(fund, v, v.v2Type);
		assertTrue(p1.codehash != p2.codehash, 'one of each');
		assertEq(address(SlipstreamLPPositionV2(p2).factory()), address(v.v2Factory));
		_mint(fund, v, p1);
		_mint(fund, v, p2);
		assertEq(_liquidity(v, p1), _liquidity(v, p2), 'same liquidity');
		_assertSameNav(p1, p2, 'minted');

		_act(fund, p1, STAKE);
		_act(fund, p2, STAKE);
		_assertSameNav(p1, p2, 'staked');
		_accrue(ACCRUAL);
		_assertSameNav(p1, p2, 'accrued');

		Claim memory c1 = _claim(fund, p1, v.gauge, TREASURY);
		Claim memory c2 = _claim(fund, p2, v.gauge, TREASURY);
		assertEq(c1.earned, c2.earned, 'same emissions');
		assertEq(c1.toVault, c1.earned, 'V1: the vault gets 100%');
		assertEq(c1.toTreasury, 0, 'V1: no fee');
		_assertSplit(c2, 1000, p2);
		_assertSameNav(p1, p2, 'claimed');

		_act(fund, p1, UNSTAKE);
		_act(fund, p2, UNSTAKE);
		_assertSameNav(p1, p2, 'unstaked');
	}

	// ─── re-point safety (Task 4) ────────────────────────────────────────────────

	function test_fork_cl1_v1PositionSurvivesTheRepoint() public {
		vm.skip(!forked);
		_v1SurvivesRepoint(_cl1());
	}

	function test_fork_cl2_v1PositionSurvivesTheRepoint() public {
		vm.skip(!forked);
		_v1SurvivesRepoint(_cl2());
	}

	/// A V1 position opened under type 4 / 7 BEFORE `registerPositionType(type, v2Factory)` still
	/// claims (fee-free), unstakes, collects, burns and is removed afterwards; the next position
	/// under the same type id is a V2 and pays the fee.
	function _v1SurvivesRepoint(Venue memory v) internal {
		Comptroller fund = _fund(string.concat('Repoint ', v.label));
		address fv = address(fund.vault());
		address p1 = _open(fund, v, v.v1Type);
		(bool hasFactory,) = p1.staticcall(abi.encodeWithSignature('factory()'));
		assertFalse(hasFactory, 'a V1 position');
		_mint(fund, v, p1);
		_act(fund, p1, STAKE);
		_accrue(ACCRUAL);

		// Task 4's call, by the FundFactory owner
		vm.prank(Ownable(address(factory)).owner());
		factory.registerPositionType(v.v1Type, address(v.v2Factory));
		assertEq(factory.positionTypeFactories(v.v1Type), address(v.v2Factory), 're-pointed');

		Claim memory c = _claim(fund, p1, v.gauge, TREASURY);
		assertGt(c.earned, 0);
		assertEq(c.fromGauge, c.earned);
		assertEq(c.toVault, c.earned, 'the V1 position still pays its vault 100%');
		assertEq(c.toTreasury, 0, 'and nothing to the treasury');

		_act(fund, p1, UNSTAKE);
		assertEq(IERC721(v.npm).ownerOf(SlipstreamLPPosition(p1).tokenId()), p1, 'unstaked');
		uint128 liquidity = _liquidity(v, p1);
		_act(fund, p1, new address[](0), DECREASE, abi.encode(liquidity, uint256(0), uint256(0)));
		uint256 wethBefore = IERC20(WETH).balanceOf(fv);
		uint256 usdcBefore = IERC20(USDC).balanceOf(fv);
		_act(fund, p1, _assets(WETH, USDC), COLLECT, '');
		assertGt(IERC20(WETH).balanceOf(fv), wethBefore, 'principal WETH back');
		assertGt(IERC20(USDC).balanceOf(fv), usdcBefore, 'principal USDC back');
		_act(fund, p1, BURN);
		assertEq(SlipstreamLPPosition(p1).tokenId(), 0, 'burned');
		_act(fund, p1, _assets(WETH, USDC), SWEEP, abi.encode(WETH));
		_act(fund, p1, _assets(WETH, USDC), SWEEP, abi.encode(USDC));
		(, uint256[] memory left) = IExternalPosition(p1).getManagedAssets();
		assertEq(left[0] + left[1], 0, 'nothing left');
		vm.prank(manager);
		fund.removeExternalPosition(p1);
		address[] memory open = fund.getExternalPositions();
		for (uint256 i; i < open.length; ++i) {
			assertTrue(open[i] != p1, 'removed');
		}

		address p2 = _open(fund, v, v.v1Type);
		assertEq(address(SlipstreamLPPositionV2(p2).factory()), address(v.v2Factory), 'new positions are V2');
		_mint(fund, v, p2);
		_act(fund, p2, STAKE);
		_accrue(ACCRUAL);
		Claim memory c2 = _claim(fund, p2, v.gauge, TREASURY);
		_assertSplit(c2, 1000, p2);
		emit log_named_string('venue', v.label);
		emit log_named_decimal_uint('V1 claim to vault (no fee)', c.toVault, 18);
		_logClaim(c2);
	}

	// ─── the 2026-09-27 fixes, ported ────────────────────────────────────────────

	function test_fork_v2KeepsTheGaugeAndNftFixes() public {
		vm.skip(!forked);
		Venue memory v = _cl2();
		Comptroller fund = _fund('Fixes');

		// only the pool's own gauge: an NFT-keeping fake and another pool's real gauge are both refused
		StealingGauge fake = new StealingGauge(IERC721(v.npm), thief);
		vm.startPrank(manager);
		vm.expectRevert(
			abi.encodeWithSelector(SlipstreamLPPositionV2Factory.GaugeNotPoolGauge.selector, address(fake), v.pool)
		);
		fund.createExternalPosition(v.v2Type, abi.encode(WETH, USDC, v.spacing, address(fake)));
		vm.expectRevert(abi.encodeWithSelector(SlipstreamLPPositionV2Factory.GaugeNotPoolGauge.selector, CL1_GAUGE, v.pool));
		fund.createExternalPosition(v.v2Type, abi.encode(WETH, USDC, v.spacing, CL1_GAUGE));
		vm.stopPrank();

		// only its own NFT from its own NFT manager
		address position = _open(fund, v, v.v2Type);
		_mint(fund, v, position);
		uint256 own = SlipstreamLPPositionV2(position).tokenId();
		uint256 foreign = _strangerMints(v);
		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(SlipstreamLPPositionV2.UnexpectedNft.selector, v.npm, foreign));
		IERC721(v.npm).safeTransferFrom(stranger, position, foreign);
		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(SlipstreamLPPositionV2.UnexpectedNft.selector, stranger, own));
		SlipstreamLPPositionV2(position).onERC721Received(stranger, stranger, own, '');
		// and the stake round trip (the gauge's safeTransferFrom back) still lands
		_act(fund, position, STAKE);
		skip(1 minutes);
		_act(fund, position, UNSTAKE);
		assertEq(IERC721(v.npm).ownerOf(own), position);
	}

	// ─── Unstake takes the same fee (ruling C-1) ─────────────────────────────────

	function test_fork_cl1_unstakePaysTheTreasuryTenPercent() public {
		vm.skip(!forked);
		_unstakeSplitsTenPercent(_cl1());
	}

	function test_fork_cl2_unstakePaysTheTreasuryTenPercent() public {
		vm.skip(!forked);
		_unstakeSplitsTenPercent(_cl2());
	}

	/// CLGauge.withdraw pays the accrued AERO to the position: Unstake takes the same fee on that
	/// delta and leaves the rest on the position (V1 leaves all of it there); a sweep moves it on.
	function _unstakeSplitsTenPercent(Venue memory v) internal {
		Comptroller fund = _fund(string.concat('Unstake ', v.label));
		address position = _open(fund, v, v.v2Type);
		_mint(fund, v, position);
		_act(fund, position, STAKE);
		_accrue(ACCRUAL);

		vm.recordLogs();
		Claim memory u = _unstake(fund, position, v.gauge, TREASURY);
		assertGt(u.earned, 0, 'the gauge owed AERO');
		assertEq(u.fromGauge, u.earned, 'withdraw paid exactly what it owed');
		uint256 fee = u.earned * 1000 / 10_000;
		assertGt(fee, 0);
		assertEq(u.toTreasury, fee, 'treasury: exactly 10% of what the unstake brought in');
		assertEq(u.toVault, 0, 'the unstake forwards nothing to the vault');
		assertEq(IERC20(AERO).balanceOf(position), u.earned - fee, 'the other 90% stays on the position');
		_assertFeeEvent(vm.getRecordedLogs(), position, TREASURY, u);
		assertEq(IERC721(v.npm).ownerOf(SlipstreamLPPositionV2(position).tokenId()), position, 'unstaked');

		uint256 swept = _sweepAero(fund, position);
		assertEq(swept, u.earned - fee, 'the sweep moves exactly that 90% to the vault');
		emit log_named_string('venue', v.label);
		emit log_named_decimal_uint('  unstake: AERO paid by the gauge', u.earned, 18);
		emit log_named_decimal_uint('  unstake: treasury cut          ', u.toTreasury, 18);
		emit log_named_decimal_uint('  unstake: held on the position  ', u.earned - fee, 18);
		emit log_named_decimal_uint('  sweep: to the vault            ', swept, 18);
	}

	/// Each AERO is charged once. Claim, unstake, then stake and unstake again while still holding the
	/// first unstake's 90%: the treasury gets 10% of each delta and nothing of AERO already charged.
	/// A claim needs the NFT staked (CLGauge.getReward reverts "NA"), so the held AERO leaves either by
	/// a sweep or by the next claim after a re-stake; neither charges it again.
	function test_fork_noDoubleChargeAcrossClaimUnstakeAndSweep() public {
		vm.skip(!forked);
		Venue memory v = _cl2();
		Comptroller fund = _fund('No double charge');
		address position = _open(fund, v, v.v2Type);
		_mint(fund, v, position);
		uint256 safe0 = IERC20(AERO).balanceOf(TREASURY);

		_act(fund, position, STAKE);
		_accrue(10 minutes);
		Claim memory c1 = _claim(fund, position, v.gauge, TREASURY);
		_assertSplit(c1, 1000, position);

		_accrue(5 minutes);
		Claim memory u2 = _unstake(fund, position, v.gauge, TREASURY);
		uint256 fee2 = u2.earned * 1000 / 10_000;
		assertGt(fee2, 0);
		assertEq(u2.toTreasury, fee2, 'unstake: 10% of its own delta');
		uint256 held = u2.earned - fee2;
		assertEq(IERC20(AERO).balanceOf(position), held);

		address[] memory receive_ = new address[](1);
		receive_[0] = AERO;
		vm.prank(manager);
		vm.expectRevert(bytes('NA'));
		fund.callOnExternalPosition(
			position, new address[](0), new uint256[](0), receive_, abi.encode(CLAIM, bytes(''))
		);

		_act(fund, position, STAKE);
		_accrue(5 minutes);
		Claim memory u3 = _unstake(fund, position, v.gauge, TREASURY);
		uint256 fee3 = u3.earned * 1000 / 10_000;
		assertGt(fee3, 0);
		assertEq(u3.toTreasury, fee3, 'unstake again: 10% of the new delta, none of the held AERO');
		assertEq(u3.toVault, 0);
		held += u3.earned - fee3;
		assertEq(IERC20(AERO).balanceOf(position), held, 'holding both unstakes\' 90%');

		uint256 snap = vm.snapshotState();
		// route A: the sweep moves exactly what is held, uncharged
		assertEq(_sweepAero(fund, position), held, 'the sweep moves exactly what is held');
		assertEq(
			IERC20(AERO).balanceOf(TREASURY) - safe0, c1.toTreasury + fee2 + fee3, 'treasury: 10% of each delta, no more'
		);
		vm.revertToState(snap);

		// route B: stake once more and claim: the held AERO passes to the vault uncharged
		_act(fund, position, STAKE);
		_accrue(2 minutes);
		Claim memory c4 = _claim(fund, position, v.gauge, TREASURY);
		uint256 fee4 = c4.earned * 1000 / 10_000;
		assertGt(fee4, 0);
		assertEq(c4.toTreasury, fee4, 'the claim charges only its own delta');
		assertEq(c4.toVault, held + c4.earned - fee4, 'and passes the held AERO through');
		assertEq(IERC20(AERO).balanceOf(position), 0);
		assertEq(
			IERC20(AERO).balanceOf(TREASURY) - safe0,
			c1.toTreasury + fee2 + fee3 + fee4,
			'treasury: 10% of each delta, no more'
		);
		emit log_string('claim 1');
		_logClaim(c1);
		emit log_named_decimal_uint('unstake 2: gauge paid ', u2.earned, 18);
		emit log_named_decimal_uint('unstake 2: treasury   ', fee2, 18);
		emit log_named_decimal_uint('unstake 3: gauge paid ', u3.earned, 18);
		emit log_named_decimal_uint('unstake 3: treasury   ', fee3, 18);
		emit log_named_decimal_uint('held after unstake 3  ', held, 18);
		emit log_string('route B claim 4 (re-staked)');
		_logClaim(c4);
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	function _cl1() internal view returns (Venue memory) {
		return Venue({
			label: 'Slipstream-1 WETH/USDC ts100',
			npm: FundsMainnet.CL_NPM,
			router: FundsMainnet.CL_SWAP_ROUTER,
			pool: CL1_POOL,
			gauge: CL1_GAUGE,
			poolFactory: FundsMainnet.CL_FACTORY,
			spacing: 100,
			v1Type: FundsMainnet.SLIPSTREAM_LP_TYPE,
			v1Factory: V1_CL1_FACTORY,
			v2Type: V2_CL1_TYPE,
			v2Factory: v2Cl1
		});
	}

	function _cl2() internal view returns (Venue memory) {
		return Venue({
			label: 'Slipstream-2 WETH/USDC ts50',
			npm: FundsMainnet.CL2_NPM,
			router: FundsMainnet.CL2_SWAP_ROUTER,
			pool: CL2_POOL,
			gauge: CL2_GAUGE,
			poolFactory: FundsMainnet.CL2_FACTORY,
			spacing: 50,
			v1Type: FundsMainnet.SLIPSTREAM2_LP_TYPE,
			v1Factory: V1_CL2_FACTORY,
			v2Type: V2_CL2_TYPE,
			v2Factory: v2Cl2
		});
	}

	/// @dev A fresh non-degen fund on the live factory: 400k USDC in, 150k of it swapped to WETH.
	function _fund(string memory name) internal returns (Comptroller fund) {
		fund = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: name,
					symbol: 'frSV2',
					denominationAsset: IERC20(USDC),
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
		deal(USDC, investor, 400_000e6);
		vm.startPrank(investor);
		IERC20(USDC).approve(address(fund), 400_000e6);
		fund.requestDeposit(400_000e6);
		vm.stopPrank();
		_accrue(1 minutes);
		fund.executeDepositRequest(investor);
		vm.prank(manager);
		fund.callOnIntegration(uniAdapter, abi.encode(USDC, WETH, uint24(500), uint256(150_000e6), uint256(0)));
	}

	function _open(Comptroller fund, Venue memory v, uint256 typeId) internal returns (address position) {
		vm.prank(manager);
		position = fund.createExternalPosition(typeId, abi.encode(WETH, USDC, v.spacing, v.gauge));
	}

	function _mint(Comptroller fund, Venue memory v, address position) internal {
		(, int24 tick) = _slot0(v.pool);
		int24 base = _floor(tick, v.spacing);
		address[] memory send = _assets(WETH, USDC);
		uint256[] memory amounts = new uint256[](2);
		amounts[0] = LP_WETH;
		amounts[1] = LP_USDC;
		vm.prank(manager);
		fund.callOnExternalPosition(
			position,
			send,
			amounts,
			new address[](0),
			abi.encode(MINT, abi.encode(base - HALF_RANGE, base + HALF_RANGE, LP_WETH, LP_USDC, uint256(0), uint256(0)))
		);
		assertGt(_liquidity(v, position), 0, 'minted');
	}

	function _act(Comptroller fund, address position, uint8 action) internal {
		_act(fund, position, new address[](0), action, '');
	}

	function _act(Comptroller fund, address position, address[] memory receive_, uint8 action, bytes memory args)
		internal
	{
		vm.prank(manager);
		fund.callOnExternalPosition(position, new address[](0), new uint256[](0), receive_, abi.encode(action, args));
	}

	function _claim(Comptroller fund, address position, address gauge, address treasury_)
		internal
		returns (Claim memory)
	{
		address[] memory receive_ = new address[](1);
		receive_[0] = AERO; // as the terminal sends it, so the fund tracks it
		return _gaugePayout(fund, position, gauge, treasury_, CLAIM, receive_);
	}

	/// @dev Unstake as the terminal sends it: nothing listed as received.
	function _unstake(Comptroller fund, address position, address gauge, address treasury_)
		internal
		returns (Claim memory)
	{
		return _gaugePayout(fund, position, gauge, treasury_, UNSTAKE, new address[](0));
	}

	/// @dev One action that makes the gauge pay, measured: the gauge's own earned() just before,
	///      the AERO that left the gauge, and where it went.
	function _gaugePayout(
		Comptroller fund,
		address position,
		address gauge,
		address treasury_,
		uint8 action,
		address[] memory receive_
	) internal returns (Claim memory c) {
		address fv = address(fund.vault());
		c.earned = ICLGauge(gauge).earned(position, SlipstreamLPPositionV2(position).tokenId());
		uint256 t0 = IERC20(AERO).balanceOf(treasury_);
		uint256 v0 = IERC20(AERO).balanceOf(fv);
		uint256 g0 = IERC20(AERO).balanceOf(gauge);
		c.gavBefore = fund.calcGav();
		_act(fund, position, receive_, action, '');
		c.toTreasury = IERC20(AERO).balanceOf(treasury_) - t0;
		c.toVault = IERC20(AERO).balanceOf(fv) - v0;
		c.fromGauge = g0 - IERC20(AERO).balanceOf(gauge);
		c.gavAfter = fund.calcGav();
	}

	/// @dev SweepToVault(AERO), listing AERO as received; returns what the vault got. Never a fee.
	function _sweepAero(Comptroller fund, address position) internal returns (uint256 toVault) {
		address fv = address(fund.vault());
		uint256 v0 = IERC20(AERO).balanceOf(fv);
		uint256 t0 = IERC20(AERO).balanceOf(TREASURY);
		address[] memory receive_ = new address[](1);
		receive_[0] = AERO;
		_act(fund, position, receive_, SWEEP, abi.encode(AERO));
		toVault = IERC20(AERO).balanceOf(fv) - v0;
		assertEq(IERC20(AERO).balanceOf(TREASURY), t0, 'a sweep pays no fee');
		assertEq(IERC20(AERO).balanceOf(position), 0, 'swept clean');
	}

	function _assertSplit(Claim memory c, uint256 bps, address position) internal view {
		assertGt(c.earned, 0, 'the gauge owed AERO');
		assertEq(c.fromGauge, c.earned, 'the gauge paid exactly what it owed');
		uint256 fee = c.earned * bps / 10_000;
		assertGt(fee, 0);
		assertEq(c.toTreasury, fee, 'treasury: exactly the fee share of the claim');
		assertEq(c.toVault, c.earned - fee, 'vault: the rest');
		assertEq(IERC20(AERO).balanceOf(position), 0, 'nothing left on the position');
	}

	function _assertFeeEvent(Vm.Log[] memory logs, address position, address treasury_, Claim memory c) internal pure {
		bool found;
		for (uint256 i; i < logs.length; ++i) {
			if (logs[i].emitter != position || logs[i].topics[0] != SlipstreamLPPositionV2.RewardFeePaid.selector) {
				continue;
			}
			found = true;
			assertEq(logs[i].topics[1], bytes32(uint256(uint160(AERO))));
			assertEq(logs[i].topics[2], bytes32(uint256(uint160(treasury_))));
			(uint256 claimed, uint256 fee) = abi.decode(logs[i].data, (uint256, uint256));
			assertEq(claimed, c.earned, 'event: claimed');
			assertEq(fee, c.toTreasury, 'event: fee');
		}
		assertTrue(found, 'RewardFeePaid emitted');
	}

	function _assertSameNav(address p1, address p2, string memory step) internal {
		(address[] memory a1, uint256[] memory m1) = IExternalPosition(p1).getManagedAssets();
		(address[] memory a2, uint256[] memory m2) = IExternalPosition(p2).getManagedAssets();
		assertEq(a1.length, 2);
		assertEq(a2.length, 2);
		assertEq(a1[0], a2[0]);
		assertEq(a1[1], a2[1]);
		assertGt(m1[0] + m1[1], 0);
		assertEq(m1[0], m2[0], string.concat('same token0 amount: ', step));
		assertEq(m1[1], m2[1], string.concat('same token1 amount: ', step));
		emit log_named_string('NAV step', step);
		emit log_named_decimal_uint('  WETH (V1 = V2)', m1[0], 18);
		emit log_named_decimal_uint('  USDC (V1 = V2)', m1[1], 6);
	}

	/// @dev A fork gets no new oracle rounds: every warp must stay inside the WETH feed's heartbeat.
	function _accrue(uint256 secs) internal {
		vm.warp(block.timestamp + secs);
		vm.roll(block.number + secs / 2); // Base: 2 s blocks
		(address aggregator, uint32 heartbeat,,) = vi.getAssetInfo(WETH);
		(,,, uint256 updatedAt,) = AggregatorV3Interface(aggregator).latestRoundData();
		assertLe(block.timestamp, updatedAt + heartbeat, 'inside the WETH feed heartbeat');
	}

	function _tracks(Comptroller fund, address asset) internal view returns (bool) {
		address[] memory tracked = fund.getTrackedAssets();
		for (uint256 i; i < tracked.length; ++i) {
			if (tracked[i] == asset) return true;
		}
		return false;
	}

	function _liquidity(Venue memory v, address position) internal view returns (uint128 liquidity) {
		(,,,,,,, liquidity,,,,) =
			ISlipstreamNonfungiblePositionManager(v.npm).positions(SlipstreamLPPositionV2(position).tokenId());
	}

	/// @dev What the position could collect right now (the NPM itself, state rolled back).
	function _collectable(Venue memory v, address position) internal returns (uint256 c0, uint256 c1) {
		uint256 id = SlipstreamLPPositionV2(position).tokenId(); // read before the prank: an argument call would consume it
		uint256 snap = vm.snapshotState();
		vm.prank(position);
		(c0, c1) = ISlipstreamNonfungiblePositionManager(v.npm).collect(
			ISlipstreamNonfungiblePositionManager.CollectParams({
				tokenId: id,
				recipient: position,
				amount0Max: type(uint128).max,
				amount1Max: type(uint128).max
			})
		);
		vm.revertToState(snap);
	}

	/// @dev [vault WETH, vault USDC, treasury WETH, treasury USDC]
	function _wethUsdc(address fv) internal view returns (uint256[4] memory b) {
		b[0] = IERC20(WETH).balanceOf(fv);
		b[1] = IERC20(USDC).balanceOf(fv);
		b[2] = IERC20(WETH).balanceOf(TREASURY);
		b[3] = IERC20(USDC).balanceOf(TREASURY);
	}

	function _churn(Venue memory v, uint256 wethIn, uint256 rounds) internal {
		for (uint256 i; i < rounds; ++i) {
			uint256 usdcOut = _swap(v, WETH, USDC, wethIn);
			_swap(v, USDC, WETH, usdcOut);
		}
	}

	function _swap(Venue memory v, address tokenIn, address tokenOut, uint256 amountIn)
		internal
		returns (uint256 amountOut)
	{
		deal(tokenIn, swapper, amountIn);
		vm.startPrank(swapper);
		IERC20(tokenIn).approve(v.router, amountIn);
		amountOut = ISlipstreamSwapRouter(v.router).exactInputSingle(
			ISlipstreamSwapRouter.ExactInputSingleParams({
				tokenIn: tokenIn,
				tokenOut: tokenOut,
				tickSpacing: v.spacing,
				recipient: swapper,
				deadline: block.timestamp,
				amountIn: amountIn,
				amountOutMinimum: 0,
				sqrtPriceLimitX96: 0
			})
		);
		vm.stopPrank();
	}

	/// @dev A plain position minted straight on the NFT manager by someone else.
	function _strangerMints(Venue memory v) internal returns (uint256 id) {
		(, int24 tick) = _slot0(v.pool);
		int24 base = _floor(tick, v.spacing);
		deal(WETH, stranger, 1 ether);
		deal(USDC, stranger, 3_000e6);
		vm.startPrank(stranger);
		IERC20(WETH).approve(v.npm, 1 ether);
		IERC20(USDC).approve(v.npm, 3_000e6);
		(id,,,) = ISlipstreamNonfungiblePositionManager(v.npm).mint(
			ISlipstreamNonfungiblePositionManager.MintParams({
				token0: WETH,
				token1: USDC,
				tickSpacing: v.spacing,
				tickLower: base - HALF_RANGE,
				tickUpper: base + HALF_RANGE,
				amount0Desired: 1 ether,
				amount1Desired: 3_000e6,
				amount0Min: 0,
				amount1Min: 0,
				recipient: stranger,
				deadline: block.timestamp,
				sqrtPriceX96: 0
			})
		);
		vm.stopPrank();
	}

	function _assets(address a, address b) internal pure returns (address[] memory assets) {
		assets = new address[](2);
		assets[0] = a;
		assets[1] = b;
	}

	function _slot0(address pool) internal view returns (uint160 sqrtPriceX96, int24 tick) {
		(bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature('slot0()'));
		assertTrue(ok);
		(sqrtPriceX96, tick) = abi.decode(data, (uint160, int24));
	}

	/// @dev Round toward negative infinity to a multiple of `spacing`.
	function _floor(int24 tick, int24 spacing) internal pure returns (int24) {
		int24 r = tick % spacing;
		return r < 0 ? tick - r - spacing : tick - r;
	}

	function _logClaim(Claim memory c) internal {
		emit log_named_decimal_uint('  claimed AERO       ', c.earned, 18);
		emit log_named_decimal_uint('  treasury cut       ', c.toTreasury, 18);
		emit log_named_decimal_uint('  vault share        ', c.toVault, 18);
		emit log_named_decimal_uint('  GAV before (USDC)  ', c.gavBefore, 6);
		emit log_named_decimal_uint('  GAV after (USDC)   ', c.gavAfter, 6);
	}
}
