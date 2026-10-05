// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Vm} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {IUniswapV2Router02} from '../../src/interfaces/external/IUniswapV2Router02.sol';
import {IAerodromeRouter} from '../../src/interfaces/external/IAerodromeRouter.sol';
import {UniswapV2SwapAdapter} from '../../src/adapters/UniswapV2SwapAdapter.sol';
import {AerodromeBasicSwapAdapter} from '../../src/adapters/AerodromeBasicSwapAdapter.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {MockAggregator} from '../utils/Mocks.sol';
import {B20Mirror} from '../utils/B20Mirror.sol';

/// @notice Router02 0x4752…aD24 views (verified Basescan source).
interface IUniswapV2RouterQuotes {
	function factory() external view returns (address);
	/// @dev The 0.3%-fee x·y=k output the router pays for `amountIn` reaching the pair.
	function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) external pure returns (uint256);
}

/// @notice Uniswap v2 factory 0x8909…8eC6.
interface IUniswapV2PairFactory {
	function getPair(address tokenA, address tokenB) external view returns (address);
}

/// @notice Aerodrome Router 0xcF77…4E43: its factory view and slippage error (verified Basescan source).
interface IAerodromeRouterQuotes {
	error InsufficientOutputAmount();

	function defaultFactory() external view returns (address);
}

/// @notice A Uniswap v2 pair's or Aerodrome basic pool's reserves (v2 packs them as uint112/uint32,
///         which decode as the same three words).
interface IReservesPool {
	function token0() external view returns (address);
	function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);
}

interface IAerodromeBasicPool {
	function stable() external view returns (bool);
}

/// @notice Aerodrome PoolFactory 0x420D…40Da and basic pool's quote (verified Basescan source).
interface IAerodromePoolFactory {
	function getPool(address tokenA, address tokenB, bool stable) external view returns (address);
}

interface IAerodromePoolQuote {
	/// @dev Takes the pool fee, then x·y=k on the stored reserves: what the router's fee-on-transfer
	///      path pays for `balanceOf(pool) − reserve`.
	function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
}

/// @notice B18 (0xA0c8…25Cb, verified source): pair transfers pay buyFeeRate / sellFeeRate of
///         RATE_UNIT to `feeTo`; wallet-to-wallet transfers are untaxed.
interface IB18 {
	function buyFeeRate() external view returns (uint256);
	function sellFeeRate() external view returns (uint256);
	function RATE_UNIT() external view returns (uint256);
	function swapPairList(address) external view returns (bool);
	function tradeWhiteList(address) external view returns (bool);
}

/// @notice OfficeX (0x4880…6990, verified source): every transfer burns 1% unless `from` or `to` is
///         allowlisted; its USDC pair is allowlisted, so buys and pair-bound sells are untaxed while
///         the fund's own vault → adapter withdrawal is not.
interface IOfficeX {
	function allowlist(address) external view returns (bool);
	function BURN_RATE_BPS() external view returns (uint256);
	function BASIS_POINTS() external view returns (uint256);
}

/// @notice The two v2-style swap adapters on the LIVE fund, real routers and real pools, Base fork.
///         The genesis deployer owns the live fund (Comptroller 0x833A…dE9, ~10 USDC), so the test
///         plays it; the FundFactory's and the PoolPriceRegistrar's owners (whoever they are: the
///         deployer before the governance handoff, the timelock after) register each adapter and
///         price the bought tokens (a fund takes in VI-supported assets only), then the fund trades
///         through `callOnIntegration`. 2026-10-04: the TWAP adapters that priced them were retired,
///         and none of these pools is one the registrar prices (Uniswap v2 pairs aren't a venue), so
///         each token gets a fixed feed at its pool's spot price at setUp — pricing is not what this
///         test checks.
///         - untaxed: AGNT/USDC on Uniswap v2, AWE/USDC on Aerodrome basic (vAMM) — bought and sold
///           back at exactly the router's price for what reached the pool (its quote, plus any
///           excess the pool already held);
///         - a minimum one unit over that reverts in the ROUTER (the adapter passes it on);
///         - real taxed tokens (2026-09-30 scan of every DefiLlama Base uniswap-v2 / aerodrome-v1
///           USDC pool): B18 (3% on pair transfers, v2), OfficeX (1% burn unless an allowlisted
///           address — its pair — is involved, so the fund's own withdrawal to the adapter is
///           short, v2) and fBOMB (1% burn on every transfer, Aerodrome). The Comptroller credits
///           what the vault actually received, and the adapter spends what actually arrived (the
///           router pulls its whole balance);
///         - after every action the adapter holds none of either token and no allowance.
///         Run: BASE_MAINNET_RPC=<url> [BASE_FORK_BLOCK=<n>] forge test --match-path test/fork/V2SwapAdaptersFork.t.sol -vv
contract V2SwapAdaptersForkTest is B20Mirror {
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	/// @dev the fixed spot feeds are stamped at setUp; no test moves time this far
	uint32 internal constant FEED_HEARTBEAT = 1 days;

	// global constraints (cast, 2026-09-30)
	address internal constant UNI_V2_ROUTER = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
	address internal constant UNI_V2_FACTORY = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
	address internal constant AERO_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
	address internal constant AERO_POOL_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

	/// @dev The live fund (owner = the genesis deployer, denomination USDC)
	Comptroller internal constant FUND = Comptroller(0x833A506d761A4756AF279ABC24183Db407823dE9);

	// untaxed long-tail tokens (Tasks 2 and 3), none VI-priced on mainnet
	address internal constant AGNT = 0x7484a9fB40b16c4DFE9195Da399e808aa45E9BB9;
	address internal constant AGNT_USDC = 0x378551Ab1B395B1E12a49aE3914DD8066860770D; // v2, AGNT token0
	address internal constant AWE = 0x1B4617734C43F6159F3a70b7E06d883647512778;
	address internal constant AWE_USDC = 0xcb7f520d18141E36956fE0b3A6Bc3D4F11245521; // vAMM, AWE token0
	// real taxed tokens (fork scan at 52014634; factory.getPair / getPool(…, false) with cast)
	address internal constant B18 = 0xA0c8b0C06Ff087d168B79177bab402F8844825Cb;
	address internal constant B18_USDC = 0x35876a255B24c76a686259943AfCFC455D52Ab53; // v2, $625k USDC
	address internal constant OFFICEX = 0x48808407d95f691D076C90337d42eE3836656990;
	address internal constant OFFICEX_USDC = 0x073f7324d7dF7033b29565CDF50bE2DAA94C8e29; // v2, $12.4k USDC
	address internal constant FBOMB = 0x74ccbe53F77b08632ce0CB91D3A545bF6B8E0979;
	address internal constant FBOMB_USDC = 0xFf8e0bD2d8F02904e7e18Dd00ea50aeC68f37A10; // vAMM, $660k USDC

	uint256 internal constant ONE_USDC = 1e6;

	bool internal forked;
	FundFactory internal factory;
	ValueInterpreter internal vi;
	address internal deployer;
	address internal vault;
	UniswapV2SwapAdapter internal uniV2;
	AerodromeBasicSwapAdapter internal aero;
	PoolPriceRegistrar internal registrar;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		uint256 blockNumber = vm.envOr('BASE_FORK_BLOCK', uint256(0));
		if (blockNumber > 0) vm.createSelectFork(rpc, blockNumber);
		else vm.createSelectFork(rpc);
		forked = true;

		string memory book = vm.readFile(string.concat(vm.projectRoot(), '/deployments/base-mainnet.json'));
		factory = FundFactory(vm.parseJsonAddress(book, '.factory'));
		vi = ValueInterpreter(vm.parseJsonAddress(book, '.valueInterpreter'));
		deployer = vm.parseJsonAddress(book, '.deployer');
		vault = address(FUND.vault());
		string memory pricing = vm.readFile(string.concat(vm.projectRoot(), '/deployments/base-mainnet-pool-pricing.json'));
		registrar = PoolPriceRegistrar(vm.parseJsonAddress(pricing, '.registrar'));

		// ALPHA is a throwaway test fund and is being wound down (0.07 USDC on 2026-10-04): top its vault
		// up to the ~10 USDC these trades were sized for (`deal` funds balances only)
		if (IERC20(USDC).balanceOf(vault) < 10 * ONE_USDC) deal(USDC, vault, 10 * ONE_USDC);
		// it also holds B20 stocks (METAc, MSTRc) Foundry can't run: answer them from the chain
		_mirrorB20s(FUND);

		uniV2 = new UniswapV2SwapAdapter(IUniswapV2Router02(UNI_V2_ROUTER));
		aero = new AerodromeBasicSwapAdapter(IAerodromeRouter(AERO_ROUTER), AERO_POOL_FACTORY);

		vm.startPrank(factory.owner());
		factory.registerAdapter(address(uniV2));
		factory.registerAdapter(address(aero));
		vm.stopPrank();
		vm.startPrank(registrar.owner());
		_price(AGNT, AGNT_USDC);
		_price(B18, B18_USDC);
		_price(OFFICEX, OFFICEX_USDC);
		_price(AWE, AWE_USDC);
		_price(FBOMB, FBOMB_USDC);
		vm.stopPrank();
	}

	// ─── premises and shape ──────────────────────────────────────────────────────

	/// @notice The deployer owns the live fund and the registrar owns the VI; the routers' factories,
	///         pools and token taxes are what the trade tests assume; both adapters are registered.
	function test_fork_premises() public {
		vm.skip(!forked);
		assertEq(vi.owner(), address(registrar), 'the registrar owns the VI (since 2026-10-04)');
		assertEq(FUND.fundOwner(), deployer, 'live fund owner');
		assertEq(address(FUND.valueInterpreter()), address(vi), 'the fund prices with the live VI');
		assertEq(address(FUND.denominationAsset()), USDC);
		assertGe(IERC20(USDC).balanceOf(vault), 2 * ONE_USDC, 'the live fund holds USDC to trade');

		assertEq(IUniswapV2RouterQuotes(UNI_V2_ROUTER).factory(), UNI_V2_FACTORY, 'router02.factory()');
		assertEq(IAerodromeRouterQuotes(AERO_ROUTER).defaultFactory(), AERO_POOL_FACTORY, 'router.defaultFactory()');
		assertEq(IUniswapV2PairFactory(UNI_V2_FACTORY).getPair(AGNT, USDC), AGNT_USDC);
		assertEq(IUniswapV2PairFactory(UNI_V2_FACTORY).getPair(B18, USDC), B18_USDC);
		assertEq(IUniswapV2PairFactory(UNI_V2_FACTORY).getPair(OFFICEX, USDC), OFFICEX_USDC);
		assertEq(IAerodromePoolFactory(AERO_POOL_FACTORY).getPool(AWE, USDC, false), AWE_USDC);
		assertEq(IAerodromePoolFactory(AERO_POOL_FACTORY).getPool(FBOMB, USDC, false), FBOMB_USDC);
		assertFalse(IAerodromeBasicPool(AWE_USDC).stable());
		assertFalse(IAerodromeBasicPool(FBOMB_USDC).stable());

		// taxes as the taxed-token tests assume
		assertTrue(IB18(B18).swapPairList(B18_USDC), 'B18 taxes its USDC pair');
		assertGt(IB18(B18).buyFeeRate(), 0, 'B18 buy tax');
		assertGt(IB18(B18).sellFeeRate(), 0, 'B18 sell tax');
		assertTrue(IOfficeX(OFFICEX).allowlist(OFFICEX_USDC), 'OfficeX pair is allowlisted');
		assertFalse(IOfficeX(OFFICEX).allowlist(vault), 'the vault is not');

		assertTrue(factory.isAdapterRegistered(address(uniV2)));
		assertTrue(factory.isAdapterRegistered(address(aero)));
		assertEq(address(uniV2.router()), UNI_V2_ROUTER);
		assertEq(address(aero.router()), AERO_ROUTER);
		assertEq(aero.poolFactory(), AERO_POOL_FACTORY);
	}

	/// @notice parseAssetsForAction: one spend leg (tokenIn, amountIn), one incoming (tokenOut, min).
	function test_parseAssetsForActionShape() public {
		UniswapV2SwapAdapter u = new UniswapV2SwapAdapter(IUniswapV2Router02(UNI_V2_ROUTER));
		AerodromeBasicSwapAdapter a = new AerodromeBasicSwapAdapter(IAerodromeRouter(AERO_ROUTER), AERO_POOL_FACTORY);
		bytes memory data = abi.encode(USDC, AGNT, uint256(7e6), uint256(5e18));
		_assertShape(u, data);
		_assertShape(a, data);
	}

	// ─── untaxed: buy and sell at exactly the router's quote ─────────────────────

	/// @notice The live fund buys 1 USDC of AGNT on Uniswap v2 with the exact quote as its minimum,
	///         the AGNT priced at its pool's spot keeps GAV whole, and the fund sells it all back.
	function test_fork_uniswapV2BuysAndSellsAgnt() public {
		vm.skip(!forked);
		uint256 gavBefore = FUND.calcGav();
		uint256 agntBefore = IERC20(AGNT).balanceOf(vault);

		uint256 quote = _v2Expected(AGNT_USDC, USDC, ONE_USDC);
		uint256 bought = _trade(address(uniV2), UNI_V2_ROUTER, USDC, AGNT, ONE_USDC, quote);
		assertEq(bought, quote, 'arrives exactly as quoted');
		emit log_named_decimal_uint('AGNT bought for 1 USDC (v2)', bought, 18);
		assertApproxEqRel(FUND.calcGav(), gavBefore, 0.01e18, 'AGNT is credited and priced into GAV');

		uint256 sellQuote = _v2Expected(AGNT_USDC, AGNT, bought);
		uint256 proceeds = _trade(address(uniV2), UNI_V2_ROUTER, AGNT, USDC, bought, sellQuote);
		assertEq(proceeds, sellQuote, 'sold exactly as quoted');
		assertEq(IERC20(AGNT).balanceOf(vault), agntBefore, 'all of it sold');
		emit log_named_decimal_uint('USDC back from selling it (v2)', proceeds, 6);
		assertLt(proceeds, ONE_USDC, 'a round trip pays two 0.3% fees');
		assertGt(proceeds, ONE_USDC * 99 / 100);
	}

	/// @notice The same on an Aerodrome basic volatile pool: AWE/USDC.
	function test_fork_aerodromeBasicBuysAndSellsAwe() public {
		vm.skip(!forked);
		uint256 gavBefore = FUND.calcGav();
		uint256 aweBefore = IERC20(AWE).balanceOf(vault);

		uint256 quote = _aeroExpected(AWE_USDC, USDC, ONE_USDC);
		uint256 bought = _trade(address(aero), AERO_ROUTER, USDC, AWE, ONE_USDC, quote);
		assertEq(bought, quote, 'arrives exactly as quoted');
		emit log_named_decimal_uint('AWE bought for 1 USDC (Aerodrome basic)', bought, 18);
		assertApproxEqRel(FUND.calcGav(), gavBefore, 0.01e18, 'AWE is credited and priced into GAV');

		uint256 sellQuote = _aeroExpected(AWE_USDC, AWE, bought);
		uint256 proceeds = _trade(address(aero), AERO_ROUTER, AWE, USDC, bought, sellQuote);
		assertEq(proceeds, sellQuote, 'sold exactly as quoted');
		assertEq(IERC20(AWE).balanceOf(vault), aweBefore, 'all of it sold');
		emit log_named_decimal_uint('USDC back from selling it (Aerodrome basic)', proceeds, 6);
		assertLt(proceeds, ONE_USDC, 'a round trip pays two pool fees');
		assertGt(proceeds, ONE_USDC * 99 / 100);
	}

	/// @notice A minimum one unit over the quote reverts in the router itself (the adapter hands the
	///         minimum on rather than leaving it to the Comptroller), and nothing moves.
	function test_fork_overTightMinimumRevertsInTheRouter() public {
		vm.skip(!forked);
		uint256 usdcBefore = IERC20(USDC).balanceOf(vault);

		uint256 quote = _v2Expected(AGNT_USDC, USDC, ONE_USDC);
		vm.expectRevert(bytes('UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT'));
		vm.prank(deployer);
		FUND.callOnIntegration(address(uniV2), abi.encode(USDC, AGNT, ONE_USDC, quote + 1));

		quote = _aeroExpected(AWE_USDC, USDC, ONE_USDC);
		vm.expectRevert(IAerodromeRouterQuotes.InsufficientOutputAmount.selector);
		vm.prank(deployer);
		FUND.callOnIntegration(address(aero), abi.encode(USDC, AWE, ONE_USDC, quote + 1));

		assertEq(IERC20(USDC).balanceOf(vault), usdcBefore, 'nothing moved');
		assertEq(IERC20(AGNT).balanceOf(vault), 0);
		assertEq(IERC20(AWE).balanceOf(vault), 0);
	}

	// ─── real taxed tokens ───────────────────────────────────────────────────────

	/// @notice B18 taxes transfers to and from its pair. Buying, the vault receives the pair's output
	///         less the buy tax, and that net is what the Comptroller credits — a minimum at the
	///         untaxed quote reverts. Selling, the pair receives less than the adapter sent, and the
	///         router's fee-on-transfer path prices exactly what arrived.
	function test_fork_uniswapV2TaxedB18IsCreditedAsReceived() public {
		vm.skip(!forked);
		uint256 unit = IB18(B18).RATE_UNIT();

		uint256 quote = _v2Expected(B18_USDC, USDC, ONE_USDC);
		vm.expectRevert(bytes('UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT'));
		vm.prank(deployer);
		FUND.callOnIntegration(address(uniV2), abi.encode(USDC, B18, ONE_USDC, quote));

		uint256 bought = _trade(address(uniV2), UNI_V2_ROUTER, USDC, B18, ONE_USDC, 0);
		assertEq(bought, quote - quote * IB18(B18).buyFeeRate() / unit, 'the pair output less the buy tax');
		emit log_named_decimal_uint('B18 untaxed quote for 1 USDC', quote, 18);
		emit log_named_decimal_uint('B18 credited (after buy tax)', bought, 18);

		uint256 arrives = bought - bought * IB18(B18).sellFeeRate() / unit;
		uint256 expected = _v2Expected(B18_USDC, B18, arrives);
		uint256 untaxed = _v2Expected(B18_USDC, B18, bought);
		uint256 proceeds = _trade(address(uniV2), UNI_V2_ROUTER, B18, USDC, bought, 0);
		assertEq(proceeds, expected, 'priced on what reached the pair after the sell tax');
		assertLt(proceeds, untaxed);
		assertEq(IERC20(B18).balanceOf(vault), 0, 'all of it sold');
		emit log_named_decimal_uint('USDC back from selling B18 (after sell tax)', proceeds, 6);
	}

	/// @notice OfficeX burns 1% of every transfer that doesn't touch an allowlisted address. The fund's
	///         own withdrawal to the adapter is such a transfer, so the adapter holds 1% less than
	///         amountIn: it swaps what arrived, the vault is debited the full amountIn, and nothing
	///         is stranded. (Swapping amountIn would revert: the router can't pull it.)
	function test_fork_uniswapV2SpendsWhatArrivedWhenTheWithdrawalIsTaxed() public {
		vm.skip(!forked);
		uint256 quote = _v2Expected(OFFICEX_USDC, USDC, ONE_USDC);
		uint256 bought = _trade(address(uniV2), UNI_V2_ROUTER, USDC, OFFICEX, ONE_USDC, quote);
		assertEq(bought, quote, 'the allowlisted pair pays out untaxed');

		uint256 arrives = bought - bought * IOfficeX(OFFICEX).BURN_RATE_BPS() / IOfficeX(OFFICEX).BASIS_POINTS();
		uint256 expected = _v2Expected(OFFICEX_USDC, OFFICEX, arrives);
		uint256 proceeds = _trade(address(uniV2), UNI_V2_ROUTER, OFFICEX, USDC, bought, expected);
		assertEq(proceeds, expected, 'swapped what reached the adapter after the 1% burn');
		assertEq(IERC20(OFFICEX).balanceOf(vault), 0, 'all of it sold');
		emit log_named_decimal_uint('OFFICEX bought for 1 USDC', bought, 18);
		emit log_named_decimal_uint('OFFICEX reaching the adapter on the sell', arrives, 18);
		emit log_named_decimal_uint('USDC back from selling it', proceeds, 6);
	}

	/// @notice fBOMB burns 1% of every transfer. Buying on Aerodrome basic, the vault is credited the
	///         pool's output less 1%. Selling, the withdrawal to the adapter and the adapter's transfer
	///         to the pool are each 1% short, and the router prices exactly what reached the pool.
	function test_fork_aerodromeBasicTaxedFbombIsCreditedAsReceived() public {
		vm.skip(!forked);
		uint256 quote = _aeroExpected(FBOMB_USDC, USDC, ONE_USDC);
		uint256 bought = _trade(address(aero), AERO_ROUTER, USDC, FBOMB, ONE_USDC, 0);
		assertEq(bought, quote * 99 / 100, 'the pool output less the 1% burn');

		uint256 atAdapter = bought * 99 / 100;
		uint256 atPool = atAdapter * 99 / 100;
		uint256 expected = _aeroExpected(FBOMB_USDC, FBOMB, atPool);
		uint256 proceeds = _trade(address(aero), AERO_ROUTER, FBOMB, USDC, bought, expected);
		assertEq(proceeds, expected, 'priced on what reached the pool after two burns');
		assertEq(IERC20(FBOMB).balanceOf(vault), 0, 'all of it sold');
		emit log_named_decimal_uint('fBOMB untaxed quote for 1 USDC', quote, 18);
		emit log_named_decimal_uint('fBOMB credited (after 1% burn)', bought, 18);
		emit log_named_decimal_uint('USDC back from selling it (two burns)', proceeds, 6);
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	/// @dev The live fund trades through `adapter`; returns what the Comptroller credited, after
	///      checking it is the vault's measured delta, the vault paid exactly amountIn, and the adapter
	///      kept nothing.
	function _trade(address adapter, address router, address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
		internal
		returns (uint256 credited)
	{
		uint256 inBefore = IERC20(tokenIn).balanceOf(vault);
		uint256 outBefore = IERC20(tokenOut).balanceOf(vault);

		vm.recordLogs();
		vm.prank(deployer);
		FUND.callOnIntegration(adapter, abi.encode(tokenIn, tokenOut, amountIn, minOut));
		credited = _creditedAmount(vm.getRecordedLogs(), adapter);

		assertEq(credited, IERC20(tokenOut).balanceOf(vault) - outBefore, 'credited = the vault balance delta');
		assertGe(credited, minOut);
		assertEq(inBefore - IERC20(tokenIn).balanceOf(vault), amountIn, 'the vault paid exactly amountIn');
		assertEq(IERC20(tokenIn).balanceOf(adapter), 0, 'no tokenIn left in the adapter');
		assertEq(IERC20(tokenOut).balanceOf(adapter), 0, 'no tokenOut left in the adapter');
		assertEq(IERC20(tokenIn).allowance(adapter, router), 0, 'no allowance left to the router');
	}

	function _creditedAmount(Vm.Log[] memory logs, address adapter) internal view returns (uint256) {
		for (uint256 i; i < logs.length; i++) {
			if (
				logs[i].emitter == address(FUND) && logs[i].topics[0] == Comptroller.CallOnIntegrationExecuted.selector
					&& logs[i].topics[1] == bytes32(uint256(uint160(adapter)))
			) {
				(,,, uint256[] memory incomingAmounts) = abi.decode(logs[i].data, (address[], uint256[], address[], uint256[]));
				return incomingAmounts[0];
			}
		}
		revert('no CallOnIntegrationExecuted');
	}

	/// @dev What the fee-on-transfer path pays when `arrives` of `tokenIn` reaches `pair`: it swaps
	///      balanceOf(pair) − reserve (any earlier excess included) against the stored reserves —
	///      router02.getAmountsOut when the pair holds no excess.
	function _v2Expected(address pair, address tokenIn, uint256 arrives) internal view returns (uint256) {
		(uint256 r0, uint256 r1,) = IReservesPool(pair).getReserves();
		(uint256 rIn, uint256 rOut) = IReservesPool(pair).token0() == tokenIn ? (r0, r1) : (r1, r0);
		uint256 amountIn = IERC20(tokenIn).balanceOf(pair) - rIn + arrives;
		return IUniswapV2RouterQuotes(UNI_V2_ROUTER).getAmountOut(amountIn, rIn, rOut);
	}

	/// @dev The same for an Aerodrome basic pool: the pool's own getAmountOut (fee, then x·y=k on the
	///      stored reserves) of balanceOf(pool) − reserve.
	function _aeroExpected(address pool, address tokenIn, uint256 arrives) internal view returns (uint256) {
		(uint256 r0, uint256 r1,) = IReservesPool(pool).getReserves();
		uint256 rIn = IReservesPool(pool).token0() == tokenIn ? r0 : r1;
		return IAerodromePoolQuote(pool).getAmountOut(IERC20(tokenIn).balanceOf(pool) - rIn + arrives, tokenIn);
	}

	/// @dev A VI primitive for `asset` on a fixed 8-dp USD feed at `pool`'s spot price (USDC ≈ $1),
	///      added through the registrar's `execute` (caller pranks as its owner).
	function _price(address asset, address pool) internal {
		(uint256 r0, uint256 r1,) = IReservesPool(pool).getReserves();
		(uint256 assetReserve, uint256 usdcReserve) = IReservesPool(pool).token0() == asset ? (r0, r1) : (r1, r0);
		uint256 answer = usdcReserve * 10 ** IERC20Metadata(asset).decimals() * 1e8 / (assetReserve * 1e6);
		MockAggregator feed = new MockAggregator(8, int256(answer));
		registrar.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (asset, address(feed), FEED_HEARTBEAT)));
	}

	function _assertShape(UniswapV2SwapAdapter adapter, bytes memory data) internal view {
		(address[] memory spend, uint256[] memory spendAmounts, address[] memory incoming, uint256[] memory mins) =
			adapter.parseAssetsForAction(data);
		_assertLegs(spend, spendAmounts, incoming, mins);
	}

	function _assertShape(AerodromeBasicSwapAdapter adapter, bytes memory data) internal view {
		(address[] memory spend, uint256[] memory spendAmounts, address[] memory incoming, uint256[] memory mins) =
			adapter.parseAssetsForAction(data);
		_assertLegs(spend, spendAmounts, incoming, mins);
	}

	function _assertLegs(
		address[] memory spend,
		uint256[] memory spendAmounts,
		address[] memory incoming,
		uint256[] memory mins
	) internal pure {
		assertEq(spend.length, 1);
		assertEq(spend[0], USDC);
		assertEq(spendAmounts.length, 1);
		assertEq(spendAmounts[0], 7e6);
		assertEq(incoming.length, 1);
		assertEq(incoming[0], AGNT);
		assertEq(mins.length, 1);
		assertEq(mins[0], 5e18);
	}
}
