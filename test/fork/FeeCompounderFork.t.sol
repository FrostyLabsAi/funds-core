// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test, Vm} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {IValueInterpreter} from '../../src/interfaces/IValueInterpreter.sol';
import {IUniswapV3SwapRouter} from '../../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {ISlipstreamSwapRouter} from '../../src/interfaces/external/ISlipstreamSwapRouter.sol';
import {IUniswapV3NonfungiblePositionManager} from
	'../../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {
	ISlipstreamNonfungiblePositionManager,
	ISlipstreamPoolLookup
} from '../../src/interfaces/external/ISlipstreamNonfungiblePositionManager.sol';
import {IUniswapV3PoolFactory} from '../../src/pricing/TwapListingRegistry.sol';
import {TickMath} from '../../src/libraries/TickMath.sol';
import {LiquidityAmounts} from '../../src/libraries/LiquidityAmounts.sol';
import {CompounderAdapter} from '../../src/adapters/CompounderAdapter.sol';
import {CompounderPriceFeed} from '../../src/pricing/CompounderPriceFeed.sol';
import {FeeCompounderBase, ICompounderRoles} from '../../src/yield/FeeCompounderBase.sol';
import {SlipstreamFeeCompounder} from '../../src/yield/SlipstreamFeeCompounder.sol';
import {UniswapV3FeeCompounder} from '../../src/yield/UniswapV3FeeCompounder.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';

interface IVenueLinked {
	function factory() external view returns (address);
}

interface IPoolView {
	function token0() external view returns (address);
	function token1() external view returns (address);
	function tickSpacing() external view returns (int24);
}

interface IUniswapV3FeeTiers {
	function feeAmountTickSpacing(uint24 fee) external view returns (int24);
}

/// @dev Pure access logic standing in for Task 2's CompounderFactory (Ruling C1): who may compound().
contract CompounderRoleHolder is ICompounderRoles {
	address public immutable admin;
	mapping(address => bool) public compounders;

	error NotAdmin();

	constructor(address admin_) {
		admin = admin_;
	}

	function setCompounder(address account, bool allowed) external {
		if (msg.sender != admin) revert NotAdmin();
		compounders[account] = allowed;
	}
}

/// @notice Fee compounders on REAL Base pools: Uniswap v3 WETH/USDC 0.3%, Slipstream-1 WETH/USDC
///         ts100 and Slipstream-2 WETH/USDC ts50. Fees come from real swaps through each venue's
///         own router; the pool price is then put back exactly, so token amounts are proportional
///         to liquidity and "more than it put in" is exact in both tokens.
///         Proven per venue: a late depositor never takes fees earned before they joined; the
///         treasury gets exactly perfFeeBps of every harvest and nothing of principal; compound()
///         is role-only while deposit/withdraw stay open; a donation before the first deposit
///         cannot steal it; the DEPLOYED-shape CompounderAdapter and CompounderPriceFeed (new
///         instances of the existing code) carry a fund in and out, and the feed values shares
///         within 1% of an independent oracle-fair computation.
///         Fix round 1 (rulings C-1, C-3): harvest leftovers the reinvest can't pair are tracked idle,
///         owned pro-rata — deposits buy in, exits are paid out, NAV counts them — and nothing sent
///         to the vault ever pairs with them (round 0's one-transaction capture of a Slipstream idle
///         pile is now a guard); a fee change harvests at the old rate first.
///         Every external address was read with `cast` at block 52014634: each NPM's and router's
///         factory() is its venue's pool factory; getPool(WETH, USDC, ·) returns the pools below;
///         Uniswap feeAmountTickSpacing(100/500/3000/10000) = 1/10/60/200.
///         Run: BASE_MAINNET_RPC=<url> [BASE_FORK_BLOCK=52014634] forge test --match-path test/fork/FeeCompounderFork.t.sol -j 1 -vv
contract FeeCompounderForkTest is Test {
	string internal constant GENESIS_FILE = 'deployments/base-mainnet.json';

	/// @dev token0 of every pool below (0x42… sorts before 0x83…)
	address internal constant WETH = FundsMainnet.WETH;
	address internal constant USDC = FundsMainnet.USDC;
	/// @dev FrostyDAO Treasury Safe: VERSION() "1.4.1", getThreshold() 2 (cast, block 52014634)
	address internal constant TREASURY = 0x47b7702a4789912d0dfFDadC07c50395c293fF0A;

	/// @dev Uniswap getPool(WETH, USDC, 3000): tickSpacing 60; 30,688 WETH + 78.8M USDC
	address internal constant UNI_WETH_USDC_3000 = 0x6c561B446416E1A00E8E93E221854d6eA4171372;
	/// @dev Slipstream-1 getPool(WETH, USDC, 100): fee 639, unstakedFee 5%; 1,507 WETH + 3.78M USDC
	address internal constant SLIP1_WETH_USDC_100 = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
	/// @dev Slipstream-2 getPool(WETH, USDC, 50): fee 425, unstakedFee 5%; 1,441 WETH + 5.67M USDC
	address internal constant SLIP2_WETH_USDC_50 = 0x3FE04A59Ebd38cF06080a6F60a98D124eb59392A;

	uint8 internal constant UNI = 0;
	uint8 internal constant SLIP1 = 1;
	uint8 internal constant SLIP2 = 2;
	uint16 internal constant FEE_BPS = 1000;
	int24 internal constant MAX_TICK = 887_272;

	struct Venue {
		string label;
		uint8 kind;
		address npm;
		address router;
		address pool;
		address poolFactory;
		int24 spacing;
		uint24 fee; // Uniswap only
		int24 fullRange; // expected ±tick, worked out by hand: (887272 / spacing) * spacing
		uint256 churnWeth; // WETH sold per leg to make fees
	}

	struct Flow {
		uint256 shares;
		uint256 amount0;
		uint256 amount1;
	}

	struct Harvest {
		bool found;
		uint256 harvested0;
		uint256 harvested1;
		uint256 fee0;
		uint256 fee1;
		uint128 added;
	}

	bool internal forked;
	ValueInterpreter internal vi;
	FundFactory internal factory;
	address internal uniAdapter;
	CompounderRoleHolder internal roles;

	address internal owner = makeAddr('compounderFactory'); // Task 2's factory owns every vault
	address internal keeper = makeAddr('workflowVaultWallet'); // the compounder role
	address internal alice = makeAddr('alice');
	address internal bob = makeAddr('bob');
	address internal stranger = makeAddr('stranger');
	address internal attacker = makeAddr('attacker');
	address internal swapper = makeAddr('swapper');
	address internal manager = makeAddr('manager');
	address internal investor = makeAddr('investor');

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		uint256 blockNumber = vm.envOr('BASE_FORK_BLOCK', uint256(0));
		if (blockNumber > 0) vm.createSelectFork(rpc, blockNumber);
		else vm.createSelectFork(rpc);
		forked = true;

		string memory genesis = vm.readFile(GENESIS_FILE);
		vi = ValueInterpreter(vm.parseJsonAddress(genesis, '.valueInterpreter'));
		factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		uniAdapter = vm.parseJsonAddress(genesis, '.uniAdapter');

		roles = new CompounderRoleHolder(owner);
		vm.prank(owner);
		roles.setCompounder(keeper, true);
	}

	// ─── venues ──────────────────────────────────────────────────────────────────

	function test_fork_venuesAreTheCanonicalDeployments() public {
		vm.skip(!forked);
		Venue[3] memory venues = [_uni(), _slip1(), _slip2()];
		for (uint256 i; i < 3; ++i) {
			Venue memory v = venues[i];
			assertEq(IVenueLinked(v.npm).factory(), v.poolFactory, 'the NPM mints into this venue');
			assertEq(IVenueLinked(v.router).factory(), v.poolFactory, 'the router swaps on this venue');
			assertEq(IVenueLinked(v.pool).factory(), v.poolFactory, 'the pool belongs to this venue');
			assertEq(IPoolView(v.pool).token0(), WETH);
			assertEq(IPoolView(v.pool).token1(), USDC);
			assertEq(IPoolView(v.pool).tickSpacing(), v.spacing);
			if (v.kind == UNI) {
				assertEq(IUniswapV3PoolFactory(v.poolFactory).getPool(WETH, USDC, v.fee), v.pool);
				assertEq(IUniswapV3FeeTiers(v.poolFactory).feeAmountTickSpacing(v.fee), v.spacing);
			} else {
				assertEq(ISlipstreamPoolLookup(v.poolFactory).getPool(WETH, USDC, v.spacing), v.pool);
			}
		}
	}

	function test_fork_fullRangeTicksAlignToEachVenue() public {
		vm.skip(!forked);
		Venue[3] memory venues = [_uni(), _slip1(), _slip2()];
		for (uint256 i; i < 3; ++i) {
			Venue memory v = venues[i];
			FeeCompounderBase vault = _deploy(v, FEE_BPS);
			assertEq(vault.tickUpper(), v.fullRange, 'upper = the widest spacing-aligned tick');
			assertEq(vault.tickLower(), -v.fullRange, 'lower mirrors upper');
			assertEq(v.fullRange % v.spacing, 0);
			assertGt(v.fullRange + v.spacing, MAX_TICK);
		}
		// Uniswap reads the spacing from the factory's feeAmountTickSpacing(fee); hand-worked values
		uint24[4] memory fees = [uint24(100), 500, 3000, 10000];
		int24[4] memory uniFull = [int24(887_272), 887_270, 887_220, 887_200];
		for (uint256 i; i < 4; ++i) {
			FeeCompounderBase vault = new UniswapV3FeeCompounder(
				'n', 's', IUniswapV3NonfungiblePositionManager(FundsMainnet.UNI_NPM), IERC20(WETH), IERC20(USDC),
				fees[i], FEE_BPS, TREASURY, owner, roles
			);
			assertEq(vault.tickUpper(), uniFull[i]);
			assertEq(vault.tickLower(), -uniFull[i]);
		}
		// Slipstream takes the pool's spacing
		int24[4] memory spacings = [int24(1), 10, 200, 2000];
		int24[4] memory slipFull = [int24(887_272), 887_270, 887_200, 886_000];
		for (uint256 i; i < 4; ++i) {
			FeeCompounderBase vault = new SlipstreamFeeCompounder(
				'n', 's', ISlipstreamNonfungiblePositionManager(FundsMainnet.CL_NPM), IERC20(WETH), IERC20(USDC),
				spacings[i], FEE_BPS, TREASURY, owner, roles
			);
			assertEq(vault.tickUpper(), slipFull[i]);
			assertEq(vault.tickLower(), -slipFull[i]);
		}
		// no spacing, no vault: a fee tier the factory never enabled, a non-positive Slipstream spacing
		vm.expectRevert(FeeCompounderBase.InvalidTickSpacing.selector);
		new UniswapV3FeeCompounder(
			'n', 's', IUniswapV3NonfungiblePositionManager(FundsMainnet.UNI_NPM), IERC20(WETH), IERC20(USDC),
			1234, FEE_BPS, TREASURY, owner, roles
		);
		vm.expectRevert(FeeCompounderBase.InvalidTickSpacing.selector);
		new SlipstreamFeeCompounder(
			'n', 's', ISlipstreamNonfungiblePositionManager(FundsMainnet.CL_NPM), IERC20(WETH), IERC20(USDC),
			0, FEE_BPS, TREASURY, owner, roles
		);
	}

	/// @notice Slipstream's MintParams.sqrtPriceX96 is a pool-creation price: non-zero asks the NPM
	///         to create the pool, which already exists and refuses; zero mints into it.
	function test_fork_slipstreamMintTakesZeroSqrtPriceForAnExistingPool() public {
		vm.skip(!forked);
		Venue[2] memory venues = [_slip1(), _slip2()];
		for (uint256 i; i < 2; ++i) {
			Venue memory v = venues[i];
			deal(WETH, alice, 1 ether);
			deal(USDC, alice, 5_000e6);
			vm.startPrank(alice);
			IERC20(WETH).approve(v.npm, 1 ether);
			IERC20(USDC).approve(v.npm, 5_000e6);
			(uint160 sqrtP,) = _slot0(v.pool);
			ISlipstreamNonfungiblePositionManager.MintParams memory p = ISlipstreamNonfungiblePositionManager.MintParams({
				token0: WETH,
				token1: USDC,
				tickSpacing: v.spacing,
				tickLower: -v.fullRange,
				tickUpper: v.fullRange,
				amount0Desired: 1 ether,
				amount1Desired: 5_000e6,
				amount0Min: 0,
				amount1Min: 0,
				recipient: alice,
				deadline: block.timestamp,
				sqrtPriceX96: sqrtP
			});
			// a price is read as "create the pool": the NPM calls its factory, which refuses an existing pool
			vm.expectCall(
				v.poolFactory,
				abi.encodeWithSignature('createPool(address,address,int24,uint160)', WETH, USDC, v.spacing, sqrtP)
			);
			vm.expectRevert(bytes(''));
			ISlipstreamNonfungiblePositionManager(v.npm).mint(p);
			p.sqrtPriceX96 = 0;
			vm.expectCall(v.poolFactory, abi.encodeWithSignature('createPool(address,address,int24,uint160)'), 0);
			(uint256 id, uint128 liquidity,,) = ISlipstreamNonfungiblePositionManager(v.npm).mint(p);
			vm.stopPrank();
			assertGt(liquidity, 0, 'zero mints into the existing pool');
			(,,,, int24 ts,,,,,,,) = ISlipstreamNonfungiblePositionManager(v.npm).positions(id);
			assertEq(ts, v.spacing);
		}
	}

	// ─── share math under compounding ────────────────────────────────────────────

	function test_fork_uni_feesCompoundToHoldersNotLateJoiners() public {
		vm.skip(!forked);
		_feesCompound(_uni());
	}

	function test_fork_slip1_feesCompoundToHoldersNotLateJoiners() public {
		vm.skip(!forked);
		_feesCompound(_slip1());
	}

	function test_fork_slip2_feesCompoundToHoldersNotLateJoiners() public {
		vm.skip(!forked);
		_feesCompound(_slip2());
	}

	// ─── inflation / donation ────────────────────────────────────────────────────

	function test_fork_uni_donationBeforeFirstDepositFails() public {
		vm.skip(!forked);
		_donationFails(_uni());
	}

	function test_fork_slip1_donationBeforeFirstDepositFails() public {
		vm.skip(!forked);
		_donationFails(_slip1());
	}

	function test_fork_slip2_donationBeforeFirstDepositFails() public {
		vm.skip(!forked);
		_donationFails(_slip2());
	}

	// ─── deployed-shape adapter + feed ───────────────────────────────────────────

	function test_fork_uni_fundThroughDeployedShapeAdapterAndFeed() public {
		vm.skip(!forked);
		_fundRoundTrip(_uni(), 'Fee Compounder Fork Fund UNI');
	}

	function test_fork_slip1_fundThroughDeployedShapeAdapterAndFeed() public {
		vm.skip(!forked);
		_fundRoundTrip(_slip1(), 'Fee Compounder Fork Fund SLIP1');
	}

	function test_fork_slip2_fundThroughDeployedShapeAdapterAndFeed() public {
		vm.skip(!forked);
		_fundRoundTrip(_slip2(), 'Fee Compounder Fork Fund SLIP2');
	}

	// ─── fee bounds, owner, roles ────────────────────────────────────────────────

	function test_fork_feeBoundsAndOwnerControls() public {
		vm.skip(!forked);
		Venue[3] memory venues = [_uni(), _slip1(), _slip2()];
		for (uint256 i; i < 3; ++i) {
			Venue memory v = venues[i];
			vm.expectRevert(abi.encodeWithSelector(FeeCompounderBase.PerfFeeOutOfBounds.selector, uint16(499)));
			_deploy(v, 499);
			vm.expectRevert(abi.encodeWithSelector(FeeCompounderBase.PerfFeeOutOfBounds.selector, uint16(3001)));
			_deploy(v, 3001);
			assertEq(_deploy(v, 500).perfFeeBps(), 500);
			assertEq(_deploy(v, 3000).perfFeeBps(), 3000);
			vm.expectRevert(FeeCompounderBase.ZeroAddress.selector);
			_deployWith(v, FEE_BPS, address(0), roles, WETH, USDC);
			vm.expectRevert(FeeCompounderBase.ZeroAddress.selector);
			_deployWith(v, FEE_BPS, TREASURY, ICompounderRoles(address(0)), WETH, USDC);
			vm.expectRevert(FeeCompounderBase.TokensOutOfOrder.selector);
			_deployWith(v, FEE_BPS, TREASURY, roles, USDC, WETH);

			FeeCompounderBase vault = _deploy(v, FEE_BPS);
			assertEq(vault.MIN_PERF_FEE_BPS(), 500);
			assertEq(vault.MAX_PERF_FEE_BPS(), 3000);
			assertEq(vault.perfFeeBps(), FEE_BPS);
			assertEq(vault.treasury(), TREASURY);
			assertEq(vault.owner(), owner, 'the owner is explicit, not the deployer');
			assertEq(address(vault.roles()), address(roles));

			address[2] memory outsiders = [stranger, keeper];
			for (uint256 j; j < 2; ++j) {
				vm.prank(outsiders[j]);
				vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsiders[j]));
				vault.setPerfFee(1500);
				vm.prank(outsiders[j]);
				vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsiders[j]));
				vault.setTreasury(outsiders[j]);
			}

			vm.startPrank(owner);
			uint16[3] memory outOfBounds = [uint16(0), 499, 3001];
			for (uint256 j; j < 3; ++j) {
				vm.expectRevert(abi.encodeWithSelector(FeeCompounderBase.PerfFeeOutOfBounds.selector, outOfBounds[j]));
				vault.setPerfFee(outOfBounds[j]);
			}
			vault.setPerfFee(3000);
			assertEq(vault.perfFeeBps(), 3000);
			vault.setPerfFee(500);
			assertEq(vault.perfFeeBps(), 500);
			vm.expectRevert(FeeCompounderBase.ZeroAddress.selector);
			vault.setTreasury(address(0));
			vault.setTreasury(alice);
			assertEq(vault.treasury(), alice);
			vm.stopPrank();
		}
	}

	function test_fork_compoundIsRoleOnly_depositAndWithdrawStayOpen() public {
		vm.skip(!forked);
		FeeCompounderBase vault = _deploy(_slip2(), FEE_BPS);
		vm.prank(stranger);
		vm.expectRevert(FeeCompounderBase.NotCompounder.selector);
		vault.compound();

		// anyone deposits and withdraws
		Flow memory s = _deposit(vault, stranger, 1 ether, 5_000e6);
		assertGt(s.shares, 0);

		vm.prank(keeper);
		vault.compound();
		vm.prank(owner);
		vm.expectRevert(FeeCompounderBase.NotCompounder.selector);
		vault.compound(); // owning the vault is not the compounder role

		vm.prank(owner);
		roles.setCompounder(keeper, false);
		vm.prank(keeper);
		vm.expectRevert(FeeCompounderBase.NotCompounder.selector);
		vault.compound();

		vm.prank(owner);
		roles.setCompounder(stranger, true);
		vm.prank(stranger);
		vault.compound();

		Flow memory out = _withdraw(vault, stranger, s.shares);
		assertEq(vault.balanceOf(stranger), 0);
		assertGt(out.amount0, 0);
		assertGt(out.amount1, 0);
	}

	// ─── idle leftovers (fix round 1: ruling C-1) and fee changes (ruling C-3) ───

	/// @notice Round 0's probe as a guard. On Slipstream-1 the harvest's unpaired USDC piles up as
	///         tracked idle. An outsider deposits ~100x the vault (paying the idle buy-in), donates
	///         the missing WETH and withdraws, all at once: the donation stays untracked, nothing pairs
	///         with it, and he takes back no more than he paid. Pre-fix he netted +$9.69 of a $9.89
	///         pile. Alice's exit then carries her idle slice.
	function test_fork_idlePileCannotBeCaptured() public {
		vm.skip(!forked);
		Venue memory v = _slip1();
		FeeCompounderBase vault = _deploy(v, FEE_BPS);
		Flow memory a = _deposit(vault, alice, 50 ether, 200_000e6);
		_accrueIdle(v, vault, 3);
		uint256 pile1 = vault.idle1();
		uint256 pileUsd = _usd18(vault.idle0(), pile1);
		assertGt(pile1, 1e6, 'the unpaired USDC is a real pile (> 1 USDC)');

		(int256 captureUsd, int256 pnlUsd, uint256 don0) = _flashDepositDonateWithdraw(v, vault, pile1);
		assertLe(captureUsd, int256(pileUsd / 100_000), 'he takes back no more than he paid, to rounding');
		assertLt(pnlUsd, 0, 'and the donation is his loss');

		uint256 idlePaid1 = _exitIdlePaid(v, vault, alice, a.shares);
		assertGe(idlePaid1 * 100, pile1 * 99, 'alice is paid nearly all of the pile she earned');
		emit log_named_decimal_uint('idle pile before the attack (USD)', pileUsd, 18);
		emit log_named_decimal_uint('attacker donated WETH             ', don0, 18);
		emit log_named_decimal_int('attacker capture excl. donation (USD)', captureUsd, 18);
		emit log_named_decimal_int('attacker PnL incl. donation (USD)    ', pnlUsd, 18);
		emit log_named_decimal_uint('alice idle USDC paid on exit      ', idlePaid1, 6);
	}

	/// @dev One transaction: deposit ~100x the vault (the idle buy-in paid), donate what would pair
	///      with the idle pile, withdraw. Returns the attacker's take excluding and including the
	///      donation; the owner then sweeps exactly the donation.
	function _flashDepositDonateWithdraw(Venue memory v, FeeCompounderBase vault, uint256 pile1)
		internal
		returns (int256 captureUsd, int256 pnlUsd, uint256 don0)
	{
		uint256 supplyBefore = vault.totalSupply();
		Flow memory atk = _deposit(vault, attacker, 5_000 ether, 20_000_000e6);
		assertEq(
			vault.idle1(),
			pile1 + Math.mulDiv(pile1, atk.shares, supplyBefore, Math.Rounding.Ceil),
			'the attacker bought into the pile at its per-share rate'
		);
		uint256 don1;
		(don0, don1) = _donateMissingSide(v, vault);
		Flow memory out = _withdraw(vault, attacker, atk.shares);
		captureUsd = _usd18Signed(int256(out.amount0) - int256(atk.amount0), int256(out.amount1) - int256(atk.amount1));
		pnlUsd = captureUsd - int256(_usd18(don0, don1));
		_sweepExactly(vault, don0, don1);
	}

	/// @dev `who` exits; returns the idle USDC paid on top of the liquidity slice, checked exact.
	function _exitIdlePaid(Venue memory v, FeeCompounderBase vault, address who, uint256 shares)
		internal
		returns (uint256 idlePaid1)
	{
		uint256 supplyBefore = vault.totalSupply();
		vm.recordLogs();
		Flow memory out = _withdraw(vault, who, shares);
		(, uint256 decreased1) = _decreasedIn(vm.getRecordedLogs(), v.npm);
		idlePaid1 = out.amount1 - decreased1;
		assertEq(idlePaid1, Math.mulDiv(vault.idle1() + idlePaid1, shares, supplyBefore), 'the exact idle slice');
	}

	/// @notice positionState's pending = what the NPM owes + tracked idle, so the DEPLOYED
	///         CompounderPriceFeed counts idle pro-rata: NAV rises by the fund's share of the WHOLE
	///         net harvest at compound, and the exit pays the idle slice.
	function test_fork_idleCountsInNavAndPaysOutOnExit() public {
		vm.skip(!forked);
		Venue memory v = _slip1();
		FundCtx memory c = _fundSetup(v, 'Fee Compounder Fork Fund IDLE');
		uint256 shares = _fundDeposits(c);
		(uint160 sqrtP0,) = _slot0(v.pool);
		_churn(v, 3);
		_restore(v, sqrtP0);
		uint256 gav3 = _compoundRaisesNavByWholeNet(v, c, shares);
		_assertPendingIsOwedPlusIdle(v, c.vault);

		uint256 supplyBefore = c.vault.totalSupply();
		uint256 usdcBefore = IERC20(USDC).balanceOf(c.fv);
		vm.recordLogs();
		vm.prank(manager);
		c.fund.callOnIntegration(
			address(c.adapter), abi.encode(uint8(1), address(c.vault), shares, uint256(1), uint256(1))
		);
		(, uint256 decreased1) = _decreasedIn(vm.getRecordedLogs(), v.npm);
		uint256 idlePaid1 = IERC20(USDC).balanceOf(c.fv) - usdcBefore - decreased1;
		assertGt(idlePaid1, 0, 'the exit pays idle');
		assertEq(idlePaid1, Math.mulDiv(c.vault.idle1() + idlePaid1, shares, supplyBefore), 'exactly the pro-rata idle slice');
		_assertNothingStuck(address(c.adapter), address(c.vault));
		assertApproxEqRel(c.fund.calcGav(), gav3, 0.001e18, 'withdrawing moves value, not NAV');
		emit log_named_decimal_uint('idle USDC paid to the fund   ', idlePaid1, 6);
	}

	/// @dev The role compounds; NAV rises by the fund's share of the WHOLE net harvest (the
	///      reinvested liquidity and the unpaired idle alike). Returns GAV after.
	function _compoundRaisesNavByWholeNet(Venue memory v, FundCtx memory c, uint256 shares) internal returns (uint256 gav3) {
		uint256 gav2 = c.fund.calcGav();
		Harvest memory h;
		{
			(uint256 e0, uint256 e1) = _collectable(v, c.vault);
			vm.recordLogs();
			vm.prank(keeper);
			c.vault.compound();
			h = _harvest(address(c.vault));
			assertEq(h.harvested0, e0);
			assertEq(h.harvested1, e1);
		}
		assertGt(c.vault.idle1(), 0, 'part of the harvest could not pair');
		gav3 = c.fund.calcGav();
		uint256 netUsdc = vi.calcCanonicalAssetValue(WETH, h.harvested0 - h.fee0, USDC) + (h.harvested1 - h.fee1);
		uint256 fundShareOfNet = Math.mulDiv(netUsdc, shares, c.vault.totalSupply());
		assertApproxEqRel(gav3 - gav2, fundShareOfNet, 0.01e18, 'NAV counts the whole net harvest, idle included');
		emit log_named_decimal_uint('net harvest, fund share (USDC)', fundShareOfNet, 6);
		emit log_named_decimal_uint('GAV step at compound   (USDC)', gav3 - gav2, 6);
		emit log_named_decimal_uint('tracked idle USDC            ', c.vault.idle1(), 6);
	}

	function _assertPendingIsOwedPlusIdle(Venue memory v, FeeCompounderBase vault) internal view {
		(, uint128 pending0, uint128 pending1) = vault.positionState();
		(uint128 owed0, uint128 owed1) = _owed(v, vault);
		assertEq(pending0, owed0 + vault.idle0(), 'pending = owed + idle (WETH)');
		assertEq(pending1, owed1 + vault.idle1(), 'pending = owed + idle (USDC)');
	}

	/// @notice A depositor always buys into the idle pile at its per-share rate, out of its own
	///         amounts: the vault sets the buy-in aside before adding liquidity. Pool-ratio amounts
	///         therefore buy fewer shares than a plain LP of the same tokens gets liquidity; with the
	///         buy-in sent on top in the idle token, the extra pays it and the spare is refunded. Both
	///         land exactly as previewDeposit says, the buy-in = idle x shares / supply rounded up.
	function test_fork_depositBuyInRequired() public {
		vm.skip(!forked);
		Venue memory v = _slip1();
		FeeCompounderBase vault = _deploy(v, FEE_BPS);
		_deposit(vault, alice, 50 ether, 200_000e6);
		_accrueIdle(v, vault, 1);
		vm.prank(keeper);
		vault.compound(); // settled: a second pass pairs nothing more
		assertGt(vault.idle1(), 0);

		// a plain LP of 10 WETH on the same range: its liquidity and the USDC the pool ratio needs
		(uint128 plainLiquidity,, uint256 ratioUsdc) = _plainLp(v, 10 ether, 1_000_000e6);
		(uint128 vaultLiquidity,,) = vault.positionState();
		uint256 plainShares = (uint256(plainLiquidity) * vault.totalSupply()) / vaultLiquidity;

		uint256 snap = vm.snapshotState();
		(uint256 sharesRatio, uint256 buyInRatio) = _buyInPaidAsPreviewed(vault, 10 ether, ratioUsdc);
		assertGt(buyInRatio, 0, 'the pool-ratio deposit paid the idle buy-in');
		assertLt(sharesRatio, plainShares, 'out of its own tokens: fewer shares than their liquidity alone');
		vm.revertToState(snap);

		(uint256 sharesExtra,) = _buyInPaidAsPreviewed(vault, 10 ether, ratioUsdc + buyInRatio + 5e6);
		assertGt(sharesExtra, sharesRatio, 'with the buy-in sent on top, the WETH buys liquidity again');
		assertLe(sharesExtra, plainShares);
		emit log_named_uint('shares, plain-liquidity equivalent', plainShares);
		emit log_named_uint('shares, pool-ratio amounts        ', sharesRatio);
		emit log_named_uint('shares, buy-in sent on top        ', sharesExtra);
	}

	function _buyInPaidAsPreviewed(FeeCompounderBase vault, uint256 weth, uint256 usdc)
		internal
		returns (uint256 shares, uint256 buyIn1)
	{
		uint256 used0;
		uint256 used1;
		uint256 buyIn0;
		(shares, used0, used1, buyIn0, buyIn1) = vault.previewDeposit(weth, usdc);
		uint256 supplyBefore = vault.totalSupply();
		uint256[2] memory idle = [vault.idle0(), vault.idle1()];
		Flow memory b = _deposit(vault, bob, weth, usdc);
		assertEq(b.shares, shares, 'shares as previewed');
		assertEq(b.amount0, used0 + buyIn0, 'WETH paid = liquidity + buy-in, the rest refunded');
		assertEq(b.amount1, used1 + buyIn1, 'USDC paid = liquidity + buy-in, the rest refunded');
		assertEq(buyIn1, Math.mulDiv(idle[1], shares, supplyBefore, Math.Rounding.Ceil), 'buy-in = idle x shares / supply, up');
		assertEq(buyIn0, Math.mulDiv(idle[0], shares, supplyBefore, Math.Rounding.Ceil));
		assertEq(vault.idle1(), idle[1] + buyIn1, 'the buy-in joins the idle pile');
		assertEq(vault.idle0(), idle[0] + buyIn0);
		assertLe(Math.mulDiv(vault.idle1(), shares, vault.totalSupply()), buyIn1, "bob's idle claim is no more than he paid");
		emit log_named_decimal_uint('bob buy-in USDC', buyIn1, 6);
	}

	/// @dev A plain full-range LP of these amounts straight on the venue's NPM, rolled back.
	function _plainLp(Venue memory v, uint256 amount0, uint256 amount1)
		internal
		returns (uint128 liquidity, uint256 used0, uint256 used1)
	{
		uint256 snap = vm.snapshotState();
		deal(WETH, stranger, amount0);
		deal(USDC, stranger, amount1);
		vm.startPrank(stranger);
		IERC20(WETH).approve(v.npm, amount0);
		IERC20(USDC).approve(v.npm, amount1);
		if (v.kind == UNI) {
			(, liquidity, used0, used1) = IUniswapV3NonfungiblePositionManager(v.npm).mint(
				IUniswapV3NonfungiblePositionManager.MintParams({
					token0: WETH,
					token1: USDC,
					fee: v.fee,
					tickLower: -v.fullRange,
					tickUpper: v.fullRange,
					amount0Desired: amount0,
					amount1Desired: amount1,
					amount0Min: 0,
					amount1Min: 0,
					recipient: stranger,
					deadline: block.timestamp
				})
			);
		} else {
			(, liquidity, used0, used1) = ISlipstreamNonfungiblePositionManager(v.npm).mint(
				ISlipstreamNonfungiblePositionManager.MintParams({
					token0: WETH,
					token1: USDC,
					tickSpacing: v.spacing,
					tickLower: -v.fullRange,
					tickUpper: v.fullRange,
					amount0Desired: amount0,
					amount1Desired: amount1,
					amount0Min: 0,
					amount1Min: 0,
					recipient: stranger,
					deadline: block.timestamp,
					sqrtPriceX96: 0
				})
			);
		}
		vm.stopPrank();
		vm.revertToState(snap);
	}

	/// @notice Ruling C-3: a fee change first harvests at the OLD rate.
	function test_fork_setPerfFeeHarvestsAtTheOldRateFirst() public {
		vm.skip(!forked);
		Venue memory v = _uni();
		FeeCompounderBase vault = _deploy(v, FEE_BPS);
		(uint160 sqrtP0,) = _slot0(v.pool);
		_deposit(vault, alice, 50 ether, 200_000e6);
		_churn(v, 3);
		_restore(v, sqrtP0);
		(uint256 e0, uint256 e1) = _collectable(v, vault);
		uint256[2] memory t = _treasury();
		vm.recordLogs();
		vm.prank(owner);
		vault.setPerfFee(3000);
		_assertHarvest(_harvest(address(vault)), e0, e1, FEE_BPS, t); // fees earned at 10% are charged 10%
		assertEq(vault.perfFeeBps(), 3000);

		_churn(v, 2);
		_restore(v, sqrtP0);
		(e0, e1) = _collectable(v, vault);
		t = _treasury();
		vm.recordLogs();
		vm.prank(keeper);
		vault.compound();
		_assertHarvest(_harvest(address(vault)), e0, e1, 3000, t); // and later fees at the new 30%
	}

	// ─── scenarios ───────────────────────────────────────────────────────────────

	/// @dev alice deposits → real swaps → bob joins (his deposit harvests first) and leaves at once
	///      → real swaps → the role compounds → the fee goes to 30% → real swaps → alice leaves
	///      (her withdraw harvests first). The pool price is put back exactly before each step.
	function _feesCompound(Venue memory v) internal {
		emit log_named_string('venue', v.label);
		FeeCompounderBase vault = _deploy(v, FEE_BPS);
		(uint160 sqrtP0,) = _slot0(v.pool);

		Flow memory a = _deposit(vault, alice, 50 ether, 200_000e6);
		_assertPositionLayout(v, vault);
		(uint128 liqA,,) = vault.positionState();
		assertEq(a.shares, uint256(liqA) - vault.MIN_BOOTSTRAP_SHARES(), 'first deposit: liquidity less the bootstrap seed');
		assertEq(vault.balanceOf(vault.BOOTSTRAP_SHARES_SINK()), vault.MIN_BOOTSTRAP_SHARES());

		// period 1: fees accrue while alice is the only holder
		_churn(v, 3);
		_restore(v, sqrtP0);
		Harvest memory h1 = _bobJoinsAndLeaves(v, vault, a.shares, liqA);

		// period 2: the compounder role harvests; outsiders and the owner cannot
		_churn(v, 3);
		_restore(v, sqrtP0);
		Harvest memory h2 = _roleCompounds(v, vault);

		// period 3: the fee moves to the 30% cap; alice's own exit harvests first
		vm.prank(owner);
		vault.setPerfFee(3000);
		_churn(v, 2);
		_restore(v, sqrtP0);
		(uint256 e0, uint256 e1) = _collectable(v, vault);
		uint256[2] memory t = _treasury();
		vm.recordLogs();
		Flow memory aOut = _withdraw(vault, alice, a.shares);
		Harvest memory h3 = _harvest(address(vault));
		_assertHarvest(h3, e0, e1, 3000, t); // the treasury got 30% of the harvest, none of the principal

		assertGt(aOut.amount0, a.amount0, 'alice leaves with more WETH than she put in');
		assertGt(aOut.amount1, a.amount1, 'alice leaves with more USDC than she put in');
		assertLe(
			aOut.amount0 - a.amount0,
			h1.harvested0 - h1.fee0 + h2.harvested0 - h2.fee0 + h3.harvested0 - h3.fee0,
			'her gain is net of the fee'
		);
		assertLe(
			aOut.amount1 - a.amount1, h1.harvested1 - h1.fee1 + h2.harvested1 - h2.fee1 + h3.harvested1 - h3.fee1
		);
		emit log_named_decimal_uint('alice in  WETH', a.amount0, 18);
		emit log_named_decimal_uint('alice out WETH', aOut.amount0, 18);
		emit log_named_decimal_uint('alice in  USDC', a.amount1, 6);
		emit log_named_decimal_uint('alice out USDC', aOut.amount1, 6);
		emit log_named_decimal_uint('tracked idle WETH left (the sink share)', vault.idle0(), 18);
		emit log_named_decimal_uint('tracked idle USDC left (the sink share)', vault.idle1(), 6);
	}

	/// @dev bob joins after period 1's fees: his deposit harvests them first, so they stay with
	///      alice; leaving at once, he takes back no more than he put in.
	function _bobJoinsAndLeaves(Venue memory v, FeeCompounderBase vault, uint256 aliceShares, uint128 liqA)
		internal
		returns (Harvest memory h1)
	{
		(uint256 e0, uint256 e1) = _collectable(v, vault);
		uint256[2] memory t = _treasury();
		uint256 valueBefore = _shareValue(vault);
		vm.recordLogs();
		Flow memory b = _deposit(vault, bob, 50 ether, 200_000e6);
		h1 = _harvest(address(vault));
		_assertHarvest(h1, e0, e1, FEE_BPS, t);
		assertGt(h1.added, 0, 'the net fees were reinvested before bob got shares');
		_logHarvest('harvest #1 (inside bob deposit)', h1);
		emit log_named_decimal_uint('share value before (liquidity / 1e18 shares)', valueBefore, 18);
		emit log_named_decimal_uint('share value after                           ', _shareValue(vault), 18);

		(uint128 liqAB,,) = vault.positionState();
		uint256 bobAdded = uint256(liqAB) - liqA - h1.added;
		uint256 bobClaim = _claim(vault, b.shares);
		assertLe(bobClaim, bobAdded, 'bob holds no claim on fees earned before he joined');
		assertApproxEqAbs(bobClaim, bobAdded, 2, 'and loses at most rounding');
		assertGt(_claim(vault, aliceShares), aliceShares, "alice's claim carries period 1's reinvested fees");

		Flow memory bOut = _withdraw(vault, bob, b.shares);
		assertLe(bOut.amount0, b.amount0, 'bob takes back no more WETH than he put in');
		assertLe(bOut.amount1, b.amount1, 'bob takes back no more USDC than he put in');
	}

	function _roleCompounds(Venue memory v, FeeCompounderBase vault) internal returns (Harvest memory h2) {
		vm.prank(stranger);
		vm.expectRevert(FeeCompounderBase.NotCompounder.selector);
		vault.compound();
		vm.prank(owner);
		vm.expectRevert(FeeCompounderBase.NotCompounder.selector);
		vault.compound();

		(uint128 liqBefore,,) = vault.positionState();
		uint256 valueBefore = _shareValue(vault);
		(uint256 e0, uint256 e1) = _collectable(v, vault);
		uint256[2] memory t = _treasury();
		vm.recordLogs();
		vm.prank(keeper);
		vault.compound();
		h2 = _harvest(address(vault));
		_assertHarvest(h2, e0, e1, FEE_BPS, t);
		(uint128 liqAfter,,) = vault.positionState();
		assertGt(h2.added, 0);
		assertEq(liqAfter - liqBefore, h2.added, 'the position grew by exactly the reinvested liquidity');
		assertGt(_shareValue(vault), valueBefore, 'every share is worth more liquidity');
		_logHarvest('harvest #2 (role compound)', h2);
		emit log_named_decimal_uint('share value before (liquidity / 1e18 shares)', valueBefore, 18);
		emit log_named_decimal_uint('share value after                           ', _shareValue(vault), 18);
	}

	/// @dev (A) tokens donated to an EMPTY vault never enter share value or reinvestment; only the
	///      owner can sweep them, and only them. (B) the classic inflation attack: seed the supply
	///      with dust, then inflate liquidityBefore. A token donation now moves nothing; the lever
	///      left is liquidity added straight to the vault's NFT through the position manager, which
	///      the 1e6-share sink makes a loss and a quoted minShares refuses.
	function _donationFails(Venue memory v) internal {
		emit log_named_string('venue', v.label);
		FeeCompounderBase vault = _deploy(v, FEE_BPS);
		_donate(vault, 5 ether, 20_000e6);
		Flow memory a = _deposit(vault, alice, 10 ether, 40_000e6);
		(uint128 liq,,) = vault.positionState();
		assertEq(a.shares, uint256(liq) - vault.MIN_BOOTSTRAP_SHARES());
		assertEq(IERC20(WETH).balanceOf(address(vault)), 5 ether, "the mint drew only on the depositor's tokens");
		assertEq(IERC20(USDC).balanceOf(address(vault)), 20_000e6);
		assertEq(vault.balanceOf(attacker), 0);
		vm.prank(keeper);
		vault.compound();
		(uint128 liq2, uint128 pending0, uint128 pending1) = vault.positionState();
		assertEq(liq2, liq, 'the donation was not reinvested');
		assertEq(uint256(pending0) + pending1 + vault.idle0() + vault.idle1(), 0, 'nor counted as pending or idle');
		assertEq(_claim(vault, a.shares), a.shares);
		_sweepExactly(vault, 5 ether, 20_000e6);

		FeeCompounderBase target = _deploy(v, FEE_BPS);
		(uint256 dust0, uint256 dust1) = _amountsFor(v, 1e6 + 1_000);
		Flow memory seed = _deposit(target, attacker, dust0 + 1, dust1 + 1);
		assertGt(seed.shares, 0);
		assertLe(seed.shares, 2_000, 'the attacker holds a dust supply');

		uint256 snap = vm.snapshotState();
		uint256 quoted = _deposit(target, bob, 10 ether, 40_000e6).shares;
		vm.revertToState(snap);

		_donate(target, 20 ether, 80_000e6);
		snap = vm.snapshotState();
		assertEq(_deposit(target, bob, 10 ether, 40_000e6).shares, quoted, 'a token donation moves nothing');
		vm.revertToState(snap);

		(uint256 donated0, uint256 donated1) = _donateLiquidity(v, target, 20 ether, 80_000e6);
		deal(WETH, bob, 10 ether);
		deal(USDC, bob, 40_000e6);
		vm.startPrank(bob);
		IERC20(WETH).approve(address(target), 10 ether);
		IERC20(USDC).approve(address(target), 40_000e6);
		vm.expectPartialRevert(FeeCompounderBase.SharesBelowMin.selector);
		target.deposit(10 ether, 40_000e6, 0, 0, (quoted * 99) / 100);
		vm.stopPrank();

		// unbounded, the victim still loses at most one share's worth of rounding
		(uint128 before_,,) = target.positionState();
		uint256 supplyBefore = target.totalSupply();
		Flow memory vct = _deposit(target, bob, 10 ether, 40_000e6);
		(uint128 liqAfter,,) = target.positionState();
		uint256 added_ = uint256(liqAfter) - before_;
		uint256 claim = _claim(target, vct.shares);
		assertLe(claim, added_);
		assertLe(added_ - claim, uint256(before_) / supplyBefore + 1, 'loss bounded by one share');
		assertLe((added_ - claim) * 1e6, added_ * 10, 'which is under 10 ppm of the deposit');

		Flow memory out = _withdraw(target, attacker, seed.shares);
		assertLt(out.amount0, donated0 / 100, 'the attacker recovers under 1% of the WETH donated');
		assertLt(out.amount1, donated1 / 100, 'the attacker recovers under 1% of the USDC donated');
		emit log_named_uint('attacker seed shares', seed.shares);
		emit log_named_uint('victim liquidity added', added_);
		emit log_named_uint('victim rounding loss (liquidity)', added_ - claim);
		emit log_named_decimal_uint('attacker WETH donated as liquidity', donated0, 18);
		emit log_named_decimal_uint('attacker WETH back                ', out.amount0, 18);
		emit log_named_decimal_uint('attacker USDC donated as liquidity', donated1, 6);
		emit log_named_decimal_uint('attacker USDC back                ', out.amount1, 6);
	}

	/// @dev Only the owner sweeps, never to zero, and exactly the untracked surplus.
	function _sweepExactly(FeeCompounderBase vault, uint256 expected0, uint256 expected1) internal {
		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		vault.sweepUntracked(IERC20(WETH), stranger);
		uint256 idle0 = vault.idle0();
		uint256 idle1 = vault.idle1();
		uint256[2] memory t = _treasury();
		vm.startPrank(owner);
		vm.expectRevert(FeeCompounderBase.ZeroAddress.selector);
		vault.sweepUntracked(IERC20(WETH), address(0));
		assertEq(vault.sweepUntracked(IERC20(WETH), TREASURY), expected0, 'swept exactly the untracked WETH');
		assertEq(vault.sweepUntracked(IERC20(USDC), TREASURY), expected1, 'swept exactly the untracked USDC');
		assertEq(vault.sweepUntracked(IERC20(WETH), TREASURY), 0, 'nothing untracked is left');
		assertEq(vault.sweepUntracked(IERC20(USDC), TREASURY), 0);
		vm.stopPrank();
		assertEq(IERC20(WETH).balanceOf(TREASURY) - t[0], expected0);
		assertEq(IERC20(USDC).balanceOf(TREASURY) - t[1], expected1);
		assertEq(vault.idle0(), idle0, 'the tracked idle is never swept');
		assertEq(vault.idle1(), idle1);
		assertEq(IERC20(WETH).balanceOf(address(vault)), idle0, 'what stays is exactly the tracked idle');
		assertEq(IERC20(USDC).balanceOf(address(vault)), idle1);
	}

	struct FundCtx {
		CompounderAdapter adapter;
		CompounderPriceFeed feed;
		FeeCompounderBase vault;
		Comptroller fund;
		address fv;
	}

	/// @dev A fresh non-degen fund on the live factory deposits into the vault through a NEW
	///      instance of the deployed CompounderAdapter, is valued through a NEW CompounderPriceFeed
	///      on the live VI, earns real fees, and withdraws.
	function _fundRoundTrip(Venue memory v, string memory name) internal {
		emit log_named_string('venue', v.label);
		FundCtx memory c = _fundSetup(v, name);
		uint256 gav0 = c.fund.calcGav();
		uint256 shares = _fundDeposits(c);
		uint256 gav1 = c.fund.calcGav();
		assertApproxEqRel(gav1, gav0, 0.001e18, 'depositing moves value, not NAV');
		_assertFeedFair(c.vault, c.feed, shares);

		(uint160 sqrtP0,) = _slot0(v.pool);
		_churn(v, 2);
		_restore(v, sqrtP0);
		uint256 gav2 = c.fund.calcGav();
		vm.prank(keeper);
		c.vault.compound();
		uint256 gav3 = c.fund.calcGav();
		assertGt(gav3, gav2, 'the reinvested fees raise NAV');
		_assertFeedFair(c.vault, c.feed, shares);

		vm.prank(manager);
		c.fund.callOnIntegration(
			address(c.adapter), abi.encode(uint8(1), address(c.vault), shares, uint256(1), uint256(1))
		);
		assertEq(c.vault.balanceOf(c.fv), 0, 'every share redeemed');
		_assertNothingStuck(address(c.adapter), address(c.vault));
		uint256 gav4 = c.fund.calcGav();
		assertApproxEqRel(gav4, gav3, 0.001e18, 'withdrawing moves value, not NAV');
		assertGt(gav4, gav1, 'the fund ends richer by its fees');
		emit log_named_decimal_uint('GAV before deposit (USDC)', gav0, 6);
		emit log_named_decimal_uint('GAV after deposit        ', gav1, 6);
		emit log_named_decimal_uint('GAV before compound      ', gav2, 6);
		emit log_named_decimal_uint('GAV after compound       ', gav3, 6);
		emit log_named_decimal_uint('GAV after withdraw       ', gav4, 6);
	}

	function _fundSetup(Venue memory v, string memory name) internal returns (FundCtx memory c) {
		c.adapter = new CompounderAdapter();
		c.feed = new CompounderPriceFeed(IValueInterpreter(address(vi)));
		vm.prank(Ownable(address(factory)).owner());
		factory.registerAdapter(address(c.adapter));
		c.vault = _deploy(v, FEE_BPS);
		assertTrue(c.feed.isSupportedAsset(address(c.vault)), "positionState() answers the feed's 96-byte probe");
		vm.prank(Ownable(address(vi)).owner());
		vi.addDerivative(address(c.vault), address(c.feed));
		c.fund = _fundWithDeposit(name, 400_000e6);
		c.fv = address(c.fund.vault());
		vm.prank(manager);
		c.fund.callOnIntegration(uniAdapter, abi.encode(USDC, WETH, uint24(500), uint256(150_000e6), uint256(0)));
	}

	function _fundDeposits(FundCtx memory c) internal returns (uint256 shares) {
		uint256 wethHeld = IERC20(WETH).balanceOf(c.fv); // read before the prank: an argument call would consume it
		vm.prank(manager);
		c.fund.callOnIntegration(
			address(c.adapter), abi.encode(uint8(0), address(c.vault), wethHeld, uint256(200_000e6), uint256(1))
		);
		shares = c.vault.balanceOf(c.fv);
		assertGt(shares, 0, 'the shares landed in the fund vault');
		_assertNothingStuck(address(c.adapter), address(c.vault));
	}

	// ─── assertions ──────────────────────────────────────────────────────────────

	function _assertHarvest(Harvest memory h, uint256 e0, uint256 e1, uint16 bps, uint256[2] memory t) internal view {
		assertTrue(h.found, 'a Compounded event');
		assertGt(h.harvested0, 0, 'real swaps paid WETH fees');
		assertGt(h.harvested1, 0, 'real swaps paid USDC fees');
		assertEq(h.harvested0, e0, 'harvested every WETH fee the position was owed');
		assertEq(h.harvested1, e1, 'harvested every USDC fee the position was owed');
		assertEq(h.fee0, (h.harvested0 * bps) / 10_000, 'fee = perfFeeBps of the WETH harvest');
		assertEq(h.fee1, (h.harvested1 * bps) / 10_000, 'fee = perfFeeBps of the USDC harvest');
		assertEq(IERC20(WETH).balanceOf(TREASURY) - t[0], h.fee0, 'the treasury received exactly the WETH fee');
		assertEq(IERC20(USDC).balanceOf(TREASURY) - t[1], h.fee1, 'the treasury received exactly the USDC fee');
	}

	/// @dev The NFT is the vault's own (never staked) and carries the venue's layout: Uniswap keys
	///      positions by fee, Slipstream by tickSpacing in the same slot.
	function _assertPositionLayout(Venue memory v, FeeCompounderBase vault) internal view {
		uint256 id = vault.tokenId();
		assertGt(id, 0);
		assertEq(IERC721(v.npm).ownerOf(id), address(vault), 'the vault holds its NFT, unstaked');
		address t0;
		address t1;
		int24 lo;
		int24 hi;
		if (v.kind == UNI) {
			uint24 fee;
			(,, t0, t1, fee, lo, hi,,,,,) = IUniswapV3NonfungiblePositionManager(v.npm).positions(id);
			assertEq(fee, v.fee);
		} else {
			int24 ts;
			(,, t0, t1, ts, lo, hi,,,,,) = ISlipstreamNonfungiblePositionManager(v.npm).positions(id);
			assertEq(ts, v.spacing);
		}
		assertEq(t0, WETH);
		assertEq(t1, USDC);
		assertEq(lo, -v.fullRange);
		assertEq(hi, v.fullRange);
	}

	/// @dev The feed's value of `shares` against an independent oracle-fair value: a full-range
	///      position of liquidity L at price p (token1 per token0, raw units) is worth 2·L·√p of
	///      token1 (the ±887k boundary terms are ~1e-19 of it), plus pro-rata pending fees.
	function _assertFeedFair(FeeCompounderBase vault, CompounderPriceFeed feed, uint256 shares) internal {
		uint256 feedUsd = _feedUsd(vault, feed, shares);
		uint256 fairUsd = _fairUsd(vault, shares);
		assertApproxEqRel(feedUsd, fairUsd, 0.01e18, 'the feed values shares at the oracle-fair price');
		uint256 viUsdc = vi.calcCanonicalAssetValue(address(vault), shares, USDC);
		assertApproxEqRel(Math.mulDiv(viUsdc, vi.calcUsdRate(USDC), 1e6), feedUsd, 1e12, 'the VI prices through the feed');
		emit log_named_decimal_uint('feed value (USD)       ', feedUsd, 18);
		emit log_named_decimal_uint('oracle-fair value (USD)', fairUsd, 18);
		emit log_named_uint(
			'|feed - fair| (ppb)', (feedUsd > fairUsd ? feedUsd - fairUsd : fairUsd - feedUsd) * 1e9 / fairUsd
		);
	}

	function _feedUsd(FeeCompounderBase vault, CompounderPriceFeed feed, uint256 shares) internal view returns (uint256) {
		(address[] memory underlyings, uint256[] memory amounts) = feed.calcUnderlyingValues(address(vault), shares);
		assertEq(underlyings[0], WETH);
		assertEq(underlyings[1], USDC);
		return Math.mulDiv(amounts[0], vi.calcUsdRate(WETH), 1e18) + Math.mulDiv(amounts[1], vi.calcUsdRate(USDC), 1e6);
	}

	function _fairUsd(FeeCompounderBase vault, uint256 shares) internal view returns (uint256 fairUsd) {
		uint256 rate0 = vi.calcUsdRate(WETH);
		uint256 rate1 = vi.calcUsdRate(USDC);
		(uint128 liquidity, uint128 pending0, uint128 pending1) = vault.positionState();
		uint256 supply = vault.totalSupply();
		uint256 l = (uint256(liquidity) * shares) / supply;
		uint256 sqrtPriceE18 = Math.sqrt(Math.mulDiv(rate0 * 1e6, 1e36, rate1 * 1e18)); // √p · 1e18
		fairUsd = Math.mulDiv(2 * l * sqrtPriceE18, rate1, 1e18 * 1e6)
			+ Math.mulDiv((uint256(pending0) * shares) / supply, rate0, 1e18)
			+ Math.mulDiv((uint256(pending1) * shares) / supply, rate1, 1e6);
	}

	function _assertNothingStuck(address adapter, address vault) internal view {
		assertEq(IERC20(WETH).balanceOf(adapter), 0, 'no WETH left in the adapter');
		assertEq(IERC20(USDC).balanceOf(adapter), 0, 'no USDC left in the adapter');
		assertEq(IERC20(vault).balanceOf(adapter), 0, 'no shares left in the adapter');
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	function _uni() internal pure returns (Venue memory) {
		return Venue({
			label: 'Uniswap v3 WETH/USDC 0.3%',
			kind: UNI,
			npm: FundsMainnet.UNI_NPM,
			router: FundsMainnet.UNI_SWAP_ROUTER02,
			pool: UNI_WETH_USDC_3000,
			poolFactory: FundsMainnet.UNI_FACTORY,
			spacing: 60,
			fee: 3000,
			fullRange: 887_220,
			churnWeth: 1_000 ether
		});
	}

	function _slip1() internal pure returns (Venue memory) {
		return Venue({
			label: 'Slipstream-1 WETH/USDC ts100',
			kind: SLIP1,
			npm: FundsMainnet.CL_NPM,
			router: FundsMainnet.CL_SWAP_ROUTER,
			pool: SLIP1_WETH_USDC_100,
			poolFactory: FundsMainnet.CL_FACTORY,
			spacing: 100,
			fee: 0,
			fullRange: 887_200,
			churnWeth: 300 ether
		});
	}

	function _slip2() internal pure returns (Venue memory) {
		return Venue({
			label: 'Slipstream-2 WETH/USDC ts50',
			kind: SLIP2,
			npm: FundsMainnet.CL2_NPM,
			router: FundsMainnet.CL2_SWAP_ROUTER,
			pool: SLIP2_WETH_USDC_50,
			poolFactory: FundsMainnet.CL2_FACTORY,
			spacing: 50,
			fee: 0,
			fullRange: 887_250,
			churnWeth: 300 ether
		});
	}

	function _deploy(Venue memory v, uint16 bps) internal returns (FeeCompounderBase) {
		return _deployWith(v, bps, TREASURY, roles, WETH, USDC);
	}

	function _deployWith(Venue memory v, uint16 bps, address treasury_, ICompounderRoles roles_, address t0, address t1)
		internal
		returns (FeeCompounderBase)
	{
		if (v.kind == UNI) {
			return new UniswapV3FeeCompounder(
				'Frosty Compounding WETH-USDC', 'fcWETHUSDC', IUniswapV3NonfungiblePositionManager(v.npm), IERC20(t0),
				IERC20(t1), v.fee, bps, treasury_, owner, roles_
			);
		}
		return new SlipstreamFeeCompounder(
			'Frosty Compounding WETH-USDC', 'fcWETHUSDC', ISlipstreamNonfungiblePositionManager(v.npm), IERC20(t0),
			IERC20(t1), v.spacing, bps, treasury_, owner, roles_
		);
	}

	/// @dev `who` deposits exactly these amounts; returns the shares and what the pool ratio used.
	function _deposit(FeeCompounderBase vault, address who, uint256 amount0, uint256 amount1)
		internal
		returns (Flow memory f)
	{
		deal(WETH, who, amount0);
		deal(USDC, who, amount1);
		vm.startPrank(who);
		IERC20(WETH).approve(address(vault), amount0);
		IERC20(USDC).approve(address(vault), amount1);
		f.shares = vault.deposit(amount0, amount1, 0, 0, 0);
		vm.stopPrank();
		f.amount0 = amount0 - IERC20(WETH).balanceOf(who);
		f.amount1 = amount1 - IERC20(USDC).balanceOf(who);
	}

	function _withdraw(FeeCompounderBase vault, address who, uint256 shares) internal returns (Flow memory f) {
		uint256 b0 = IERC20(WETH).balanceOf(who);
		uint256 b1 = IERC20(USDC).balanceOf(who);
		vm.prank(who);
		(uint256 r0, uint256 r1) = vault.withdraw(shares, 0, 0);
		f.shares = shares;
		f.amount0 = IERC20(WETH).balanceOf(who) - b0;
		f.amount1 = IERC20(USDC).balanceOf(who) - b1;
		assertEq(f.amount0, r0, 'withdraw returns what it paid (WETH)');
		assertEq(f.amount1, r1, 'withdraw returns what it paid (USDC)');
	}

	function _donate(FeeCompounderBase vault, uint256 amount0, uint256 amount1) internal {
		deal(WETH, attacker, amount0);
		deal(USDC, attacker, amount1);
		vm.startPrank(attacker);
		IERC20(WETH).transfer(address(vault), amount0);
		IERC20(USDC).transfer(address(vault), amount1);
		vm.stopPrank();
	}

	/// @dev Real swaps both ways through the venue's own router.
	function _churn(Venue memory v, uint256 rounds) internal {
		for (uint256 i; i < rounds; ++i) {
			uint256 usdcOut = _swap(v, WETH, USDC, v.churnWeth, 0);
			_swap(v, USDC, WETH, usdcOut, 0);
		}
	}

	/// @dev Real swaps up to an exact price limit put the pool back at `target`.
	function _restore(Venue memory v, uint160 target) internal {
		(uint160 sqrtNow,) = _slot0(v.pool);
		if (sqrtNow > target) _swap(v, WETH, USDC, 1_000_000 ether, target);
		else if (sqrtNow < target) _swap(v, USDC, WETH, 10_000_000_000e6, target);
		(sqrtNow,) = _slot0(v.pool);
		assertEq(sqrtNow, target, 'the pool price is back exactly');
	}

	function _swap(Venue memory v, address tokenIn, address tokenOut, uint256 amountIn, uint160 limit)
		internal
		returns (uint256 amountOut)
	{
		deal(tokenIn, swapper, amountIn);
		uint256 before_ = IERC20(tokenOut).balanceOf(swapper);
		vm.startPrank(swapper);
		IERC20(tokenIn).approve(v.router, amountIn);
		if (v.kind == UNI) {
			IUniswapV3SwapRouter(v.router).exactInputSingle(
				IUniswapV3SwapRouter.ExactInputSingleParams({
					tokenIn: tokenIn,
					tokenOut: tokenOut,
					fee: v.fee,
					recipient: swapper,
					amountIn: amountIn,
					amountOutMinimum: 0,
					sqrtPriceLimitX96: limit
				})
			);
		} else {
			ISlipstreamSwapRouter(v.router).exactInputSingle(
				ISlipstreamSwapRouter.ExactInputSingleParams({
					tokenIn: tokenIn,
					tokenOut: tokenOut,
					tickSpacing: v.spacing,
					recipient: swapper,
					deadline: block.timestamp,
					amountIn: amountIn,
					amountOutMinimum: 0,
					sqrtPriceLimitX96: limit
				})
			);
		}
		vm.stopPrank();
		amountOut = IERC20(tokenOut).balanceOf(swapper) - before_;
	}

	/// @dev What the vault's position could collect right now (the NPM itself, state rolled back):
	///      the independent source for "harvested".
	function _collectable(Venue memory v, FeeCompounderBase vault) internal returns (uint256 c0, uint256 c1) {
		uint256 id = vault.tokenId();
		uint256 snap = vm.snapshotState();
		vm.prank(address(vault));
		if (v.kind == UNI) {
			(c0, c1) = IUniswapV3NonfungiblePositionManager(v.npm).collect(
				IUniswapV3NonfungiblePositionManager.CollectParams({
					tokenId: id,
					recipient: address(vault),
					amount0Max: type(uint128).max,
					amount1Max: type(uint128).max
				})
			);
		} else {
			(c0, c1) = ISlipstreamNonfungiblePositionManager(v.npm).collect(
				ISlipstreamNonfungiblePositionManager.CollectParams({
					tokenId: id,
					recipient: address(vault),
					amount0Max: type(uint128).max,
					amount1Max: type(uint128).max
				})
			);
		}
		vm.revertToState(snap);
	}

	function _harvest(address vault) internal returns (Harvest memory) {
		return _harvestIn(vm.getRecordedLogs(), vault);
	}

	function _harvestIn(Vm.Log[] memory logs, address vault) internal returns (Harvest memory h) {
		for (uint256 i; i < logs.length; ++i) {
			if (logs[i].emitter == vault && logs[i].topics[0] == FeeCompounderBase.Compounded.selector) {
				assertFalse(h.found, 'one harvest per call');
				h.found = true;
				(h.harvested0, h.harvested1, h.fee0, h.fee1, h.added) =
					abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint128));
			}
		}
	}

	/// @dev The position manager's DecreaseLiquidity amounts in `logs` (the liquidity part of a withdraw).
	function _decreasedIn(Vm.Log[] memory logs, address npm) internal returns (uint256 amount0, uint256 amount1) {
		bytes32 topic = keccak256('DecreaseLiquidity(uint256,uint128,uint256,uint256)');
		bool found;
		for (uint256 i; i < logs.length; ++i) {
			if (logs[i].emitter == npm && logs[i].topics[0] == topic) {
				assertFalse(found, 'one decrease');
				found = true;
				(, amount0, amount1) = abi.decode(logs[i].data, (uint128, uint256, uint256));
			}
		}
		assertTrue(found, 'a DecreaseLiquidity event');
	}

	function _owed(Venue memory v, FeeCompounderBase vault) internal view returns (uint128 owed0, uint128 owed1) {
		uint256 id = vault.tokenId();
		if (v.kind == UNI) (,,,,,,,,,, owed0, owed1) = IUniswapV3NonfungiblePositionManager(v.npm).positions(id);
		else (,,,,,,,,,, owed0, owed1) = ISlipstreamNonfungiblePositionManager(v.npm).positions(id);
	}

	/// @dev `rounds` × (3 churn rounds, price put back, role compound).
	function _accrueIdle(Venue memory v, FeeCompounderBase vault, uint256 rounds) internal {
		(uint160 sqrtP0,) = _slot0(v.pool);
		for (uint256 i; i < rounds; ++i) {
			_churn(v, 3);
			_restore(v, sqrtP0);
			vm.prank(keeper);
			vault.compound();
		}
	}

	/// @dev An attacker's second address sends the vault what would pair with its tracked idle.
	function _donateMissingSide(Venue memory v, FeeCompounderBase vault) internal returns (uint256 don0, uint256 don1) {
		(uint160 sqrtP,) = _slot0(v.pool);
		uint256 priceX128 = Math.mulDiv(sqrtP, sqrtP, 1 << 64); // token1 raw per token0 raw, X128
		uint256 need0 = Math.mulDiv(vault.idle1(), 1 << 128, priceX128);
		uint256 need1 = Math.mulDiv(vault.idle0(), priceX128, 1 << 128);
		don0 = need0 > vault.idle0() ? need0 - vault.idle0() : 0;
		don1 = need1 > vault.idle1() ? need1 - vault.idle1() : 0;
		deal(WETH, stranger, don0);
		deal(USDC, stranger, don1);
		vm.startPrank(stranger);
		IERC20(WETH).transfer(address(vault), don0);
		IERC20(USDC).transfer(address(vault), don1);
		vm.stopPrank();
	}

	/// @dev The attacker adds liquidity straight to the vault's NFT (no shares minted).
	function _donateLiquidity(Venue memory v, FeeCompounderBase vault, uint256 amount0, uint256 amount1)
		internal
		returns (uint256 used0, uint256 used1)
	{
		uint256 id = vault.tokenId();
		deal(WETH, attacker, amount0);
		deal(USDC, attacker, amount1);
		vm.startPrank(attacker);
		IERC20(WETH).approve(v.npm, amount0);
		IERC20(USDC).approve(v.npm, amount1);
		if (v.kind == UNI) {
			(, used0, used1) = IUniswapV3NonfungiblePositionManager(v.npm).increaseLiquidity(
				IUniswapV3NonfungiblePositionManager.IncreaseLiquidityParams({
					tokenId: id,
					amount0Desired: amount0,
					amount1Desired: amount1,
					amount0Min: 0,
					amount1Min: 0,
					deadline: block.timestamp
				})
			);
		} else {
			(, used0, used1) = ISlipstreamNonfungiblePositionManager(v.npm).increaseLiquidity(
				ISlipstreamNonfungiblePositionManager.IncreaseLiquidityParams({
					tokenId: id,
					amount0Desired: amount0,
					amount1Desired: amount1,
					amount0Min: 0,
					amount1Min: 0,
					deadline: block.timestamp
				})
			);
		}
		vm.stopPrank();
	}

	function _usd18(uint256 amount0, uint256 amount1) internal view returns (uint256) {
		return Math.mulDiv(amount0, vi.calcUsdRate(WETH), 1e18) + Math.mulDiv(amount1, vi.calcUsdRate(USDC), 1e6);
	}

	function _usd18Signed(int256 amount0, int256 amount1) internal view returns (int256) {
		return (amount0 * int256(vi.calcUsdRate(WETH))) / 1e18 + (amount1 * int256(vi.calcUsdRate(USDC))) / 1e6;
	}

	function _treasury() internal view returns (uint256[2] memory t) {
		t[0] = IERC20(WETH).balanceOf(TREASURY);
		t[1] = IERC20(USDC).balanceOf(TREASURY);
	}

	function _claim(FeeCompounderBase vault, uint256 shares) internal view returns (uint256) {
		(uint128 liquidity,,) = vault.positionState();
		return (uint256(liquidity) * shares) / vault.totalSupply();
	}

	/// @dev Liquidity per 1e18 shares.
	function _shareValue(FeeCompounderBase vault) internal view returns (uint256) {
		return _claim(vault, 1e18);
	}

	/// @dev Token amounts for `liquidity` over the venue's full range at the pool's spot.
	function _amountsFor(Venue memory v, uint128 liquidity) internal view returns (uint256, uint256) {
		(uint160 sqrtP,) = _slot0(v.pool);
		return LiquidityAmounts.getAmountsForLiquidity(
			sqrtP, TickMath.getSqrtRatioAtTick(-v.fullRange), TickMath.getSqrtRatioAtTick(v.fullRange), liquidity
		);
	}

	/// @dev (sqrtPriceX96, tick) — the first two words of slot0 on Uniswap v3 and Slipstream alike.
	function _slot0(address pool) internal view returns (uint160 sqrtPriceX96, int24 tick) {
		(bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature('slot0()'));
		assertTrue(ok);
		(sqrtPriceX96, tick) = abi.decode(data, (uint160, int24));
	}

	function _fundWithDeposit(string memory name, uint256 amount) internal returns (Comptroller fund) {
		fund = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: name,
					symbol: 'frFCF',
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
		deal(USDC, investor, amount);
		vm.startPrank(investor);
		IERC20(USDC).approve(address(fund), amount);
		fund.requestDeposit(amount);
		vm.stopPrank();
		skip(1 minutes);
		fund.executeDepositRequest(investor);
	}

	function _logHarvest(string memory label, Harvest memory h) internal {
		emit log_string(label);
		emit log_named_decimal_uint('  harvested WETH', h.harvested0, 18);
		emit log_named_decimal_uint('  harvested USDC', h.harvested1, 6);
		emit log_named_decimal_uint('  treasury WETH ', h.fee0, 18);
		emit log_named_decimal_uint('  treasury USDC ', h.fee1, 6);
		emit log_named_uint('  liquidity added', h.added);
	}
}
