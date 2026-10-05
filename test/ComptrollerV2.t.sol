// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {
	ComptrollerDeployer, ComptrollerBlueprintDeployer, SharesVaultDeployer
} from '../src/core/FundComponentDeployers.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ComptrollerV2} from '../src/core/ComptrollerV2.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {IPolicy} from '../src/interfaces/IPolicy.sol';
import {IUniswapV3SwapRouter} from '../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {UniswapV3SwapAdapter} from '../src/adapters/UniswapV3SwapAdapter.sol';
import {PoolPriceRegistrar} from '../src/pricing/PoolPriceRegistrar.sol';
import {MinPoolLiquidityPolicy} from '../src/policies/MinPoolLiquidityPolicy.sol';
import {MockERC20, MockAggregator, MockSwapRouter} from './utils/Mocks.sol';
import {
	ScriptedCLPool,
	MockUniswapV3Factory,
	MockSlipstreamFactory,
	MockAerodromeBasicFactory
} from './utils/PoolPriceMocks.sol';

/// @notice Fund version 2 (PLAN_FUND_V2_2026-10-04) on a real factory, deployed through the
///         blueprint deployer: TKN ($1, 6 decimals) is pool-priced from its scripted Uniswap pool,
///         WETH ($2,000) is Chainlink-priced, USDC is the denomination. Trades go through the real
///         Uniswap adapter against a router that fills at whatever price the test sets.
contract ComptrollerV2Test is Test {
	/// @dev USDC per share unit at the bootstrap price: 1 USDC per 1e18 shares.
	uint256 internal constant ONE_USDC_PRICE = 1e6;
	uint128 internal constant PLENTY = 1_000_000e6;

	ValueInterpreter internal vi;
	PoolPriceRegistrar internal registrar;
	FundFactory internal factory;
	MockSwapRouter internal router;
	UniswapV3SwapAdapter internal uniAdapter;
	MockERC20 internal usdc;
	MockERC20 internal weth;
	MockERC20 internal tkn;
	MockAggregator internal wethFeed;
	MockAggregator internal usdcFeed;
	ScriptedCLPool internal pool;

	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');
	address internal bob = makeAddr('bob');
	address internal attacker = makeAddr('attacker');
	uint256 internal nonce;

	function setUp() public {
		vm.warp(30 days);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		weth = new MockERC20('Wrapped Ether', 'WETH', 18);
		tkn = new MockERC20('Token', 'TKN', 6);
		wethFeed = new MockAggregator(8, 2000e8);
		vi = new ValueInterpreter(address(this));
		usdcFeed = new MockAggregator(8, 1e8);
		vi.addPrimitive(address(usdc), address(usdcFeed), 25 hours);
		vi.addPrimitive(address(weth), address(wethFeed), 1 hours);

		MockUniswapV3Factory uniswap = new MockUniswapV3Factory();
		address[] memory quotes = new address[](1);
		quotes[0] = address(usdc);
		registrar = new PoolPriceRegistrar(
			PoolPriceRegistrar.Wiring({
				valueInterpreter: vi,
				uniswapV3Factory: address(uniswap),
				slipstreamFactories: [
					address(new MockSlipstreamFactory()),
					address(new MockSlipstreamFactory()),
					address(new MockSlipstreamFactory())
				],
				aerodromeBasicFactory: address(new MockAerodromeBasicFactory()),
				quotes: quotes
			}),
			address(this)
		);
		vi.transferOwnership(address(registrar));
		registrar.execute(abi.encodeCall(Ownable2Step.acceptOwnership, ()));

		pool = new ScriptedCLPool(address(tkn), address(usdc), address(uniswap), 3000, 60);
		pool.setHistory(2 days);
		pool.setOracle(0, PLENTY);
		deal(address(usdc), address(pool), 1_000_000e6);
		uniswap.setPool(address(tkn), address(usdc), 3000, address(pool));
		registrar.register(address(tkn), address(pool));

		factory = new FundFactory(
			vi,
			new ComptrollerBlueprintDeployer(type(ComptrollerV2).creationCode, abi.encode(registrar)),
			new SharesVaultDeployer()
		);
		router = new MockSwapRouter();
		uniAdapter = new UniswapV3SwapAdapter(IUniswapV3SwapRouter(address(router)));
		factory.registerAdapter(address(uniAdapter));
		FundFactory.PolicyReg[] memory mandatory = new FundFactory.PolicyReg[](1);
		mandatory[0] = FundFactory.PolicyReg({
			hook: IPolicy.PolicyHook.PostCallOnIntegration, policy: address(new MinPoolLiquidityPolicy(registrar))
		});
		factory.setMandatoryPolicies(mandatory);
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	/// @dev A fund with `perfBps` performance fee; alice deposits 10,000 USDC at the bootstrap price.
	function _fund(uint16 perfBps) internal returns (ComptrollerV2 fund) {
		fund = ComptrollerV2(
			factory.createFund(
				FundFactory.FundConfig({
					name: string.concat('V2 Fund #', vm.toString(++nonce)),
					symbol: 'V2',
					denominationAsset: IERC20(address(usdc)),
					fundOwner: manager,
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: perfBps,
					sharesActionTimelock: 0,
					minRequestDuration: 1 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				})
			)
		);
		_deposit(fund, alice, 10_000e6, type(uint256).max);
	}

	function _request(ComptrollerV2 fund, address who, uint256 amount, uint256 maxSharePrice) internal {
		deal(address(usdc), who, amount);
		vm.startPrank(who);
		usdc.approve(address(fund), amount);
		fund.requestDeposit(amount, maxSharePrice);
		vm.stopPrank();
		skip(1 minutes);
	}

	function _deposit(ComptrollerV2 fund, address who, uint256 amount, uint256 maxSharePrice) internal {
		_request(fund, who, amount, maxSharePrice);
		fund.executeDepositRequest(who);
	}

	function _swap(ComptrollerV2 fund, MockERC20 tokenIn, MockERC20 tokenOut, uint256 amountIn, uint256 amountOut) internal {
		router.setNextAmountOut(amountOut);
		vm.prank(manager);
		fund.callOnIntegration(
			address(uniAdapter), abi.encode(address(tokenIn), address(tokenOut), uint24(3000), amountIn, uint256(0))
		);
	}

	/// @dev TKN's 30-minute pool price: tick 0 = $1; ±23028 ticks = ×10 (1.0001^23028 ≈ 10.0002).
	function _setTknPriceTick(int24 assetIsToken0Tick) internal {
		int24 tick = pool.token0() == address(tkn) ? assetIsToken0Tick : -assetIsToken0Tick;
		pool.setOracle(tick, PLENTY);
	}

	function _held(ComptrollerV2 fund, MockERC20 token) internal view returns (uint256) {
		return token.balanceOf(address(fund.vault()));
	}

	function _sharesOf(ComptrollerV2 fund, address who) internal view returns (uint256) {
		return fund.shares().balanceOf(who);
	}

	// ─── rule 1: redemptions ─────────────────────────────────────────────────────

	function test_redeemPaysCashForPricedHoldingsAndTheLongTailSliceInKind() public {
		ComptrollerV2 fund = _fund(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6); // 8,000 USDC + 2,000 TKN ($1)

		uint256 half = _sharesOf(fund, alice) / 2;
		vm.prank(alice);
		fund.redeemShares(half);

		// alice holds all but the bootstrap shares, so half her shares is a hair under half the fund
		assertApproxEqRel(usdc.balanceOf(alice), 4_000e6, 1e15);
		assertApproxEqRel(tkn.balanceOf(alice), 1_000e6, 1e15);
	}

	function test_aPumpedLongTailPriceAddsNoCashToARedemption() public {
		ComptrollerV2 fund = _fund(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		uint256 half = _sharesOf(fund, alice) / 2;
		vm.prank(alice);
		fund.redeemShares(half / 2);
		uint256 cashAtFairPrice = usdc.balanceOf(alice);

		_setTknPriceTick(23028); // TKN's pool pumped to $10 for the whole window
		vm.prank(alice);
		fund.redeemShares(half / 2);

		// the same slice of the fund paid the same cash: the pump added nothing
		assertApproxEqAbs(usdc.balanceOf(alice) - cashAtFairPrice, cashAtFairPrice, 1);
	}

	function test_aTokenWhosePriceCannotBeReadIsPaidInKind() public {
		ComptrollerV2 fund = _fund(0);
		_swap(fund, usdc, weth, 2_000e6, 1e18); // 8,000 USDC + 1 WETH
		skip(2 hours); // WETH's 1-hour feed is now stale; USDC's 25-hour one is not

		uint256 half = _sharesOf(fund, alice) / 2;
		vm.prank(alice);
		fund.redeemShares(half);

		assertApproxEqRel(usdc.balanceOf(alice), 4_000e6, 1e15);
		assertApproxEqRel(weth.balanceOf(alice), 0.5e18, 1e15);
	}

	function test_aReadablePricedHoldingIsPaidInCash() public {
		ComptrollerV2 fund = _fund(0);
		_swap(fund, usdc, weth, 2_000e6, 1e18); // 8,000 USDC + 1 WETH ($2,000)

		uint256 half = _sharesOf(fund, alice) / 2;
		vm.prank(alice);
		fund.redeemShares(half);

		assertApproxEqRel(usdc.balanceOf(alice), 5_000e6, 1e15);
		assertEq(weth.balanceOf(alice), 0);
	}

	// ─── rule 2: deposits ────────────────────────────────────────────────────────

	function test_aDepositExecutesAtItsMaxSharePrice() public {
		ComptrollerV2 fund = _fund(0);

		_deposit(fund, bob, 1_000e6, ONE_USDC_PRICE);

		assertApproxEqRel(_sharesOf(fund, bob), 1_000e18, 1e15);
	}

	function test_aDepositPricedOverItsMaximumDoesNotExecute() public {
		ComptrollerV2 fund = _fund(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		_request(fund, bob, 1_000e6, ONE_USDC_PRICE);
		_setTknPriceTick(23028); // pumped: 8,000 USDC + 2,000 TKN at $10 → ≈ $2.80 a share

		vm.expectPartialRevert(ComptrollerV2.SharePriceAboveMax.selector);
		vm.prank(attacker);
		fund.executeDepositRequest(bob);

		vm.prank(bob);
		fund.cancelDepositRequest();
		assertEq(usdc.balanceOf(bob), 1_000e6);
	}

	// ─── rule 3: performance fee ─────────────────────────────────────────────────

	function test_aPumpedLongTailPriceMintsNoPerformanceFee() public {
		ComptrollerV2 fund = _fund(2_000);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		_setTknPriceTick(23028);

		fund.settleFees();

		assertEq(_sharesOf(fund, manager), 0);
	}

	function test_aLongTailGainIsChargedOnceSold() public {
		ComptrollerV2 fund = _fund(2_000);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		_setTknPriceTick(6932); // TKN doubles (1.0001^6932 ≈ 2)
		_swap(fund, tkn, usdc, 2_000e6, 4_000e6); // sold at $2: +2,000 USDC realized

		fund.settleFees();

		// 20% of the $2,000 gain = $400 of fee, as shares of a $12,000 fund: 400/11,600 of supply
		uint256 supply = fund.shares().totalSupply();
		assertApproxEqRel(_sharesOf(fund, manager), supply * 400 / 12_000, 1e15);
	}

	function test_aLongTailLossCountsAtOnceAndRecoveringToCostChargesNothing() public {
		ComptrollerV2 fund = _fund(2_000);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		_setTknPriceTick(-6932); // TKN halves
		fund.settleFees();
		_setTknPriceTick(0); // back to cost
		_swap(fund, tkn, usdc, 2_000e6, 2_000e6);

		fund.settleFees();

		assertEq(_sharesOf(fund, manager), 0);
	}

	function test_aDepositIntoAFundWithUnrealizedGainsTriggersNoFee() public {
		ComptrollerV2 fund = _fund(2_000);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		_setTknPriceTick(6932); // unrealized: TKN worth $4,000 against a $2,000 cost

		_deposit(fund, bob, 12_000e6, type(uint256).max);
		fund.settleFees();

		assertEq(_sharesOf(fund, manager), 0);
	}

	function test_donatedLongTailTokensMintNoFee() public {
		ComptrollerV2 fund = _fund(2_000);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		tkn.mint(address(fund.vault()), 5_000e6); // a donation: units with no cost

		fund.settleFees();

		assertEq(_sharesOf(fund, manager), 0);
	}

	function test_costBasisFollowsBuysSalesAndInKindPayouts() public {
		ComptrollerV2 fund = _fund(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		assertEq(fund.costBasis(address(tkn)), 2_000e6); // TKN's pool value at the buy

		_swap(fund, tkn, usdc, 500e6, 500e6); // a quarter sold
		assertEq(fund.costBasis(address(tkn)), 1_500e6);

		uint256 shares = _sharesOf(fund, alice);
		uint256 supply = fund.shares().totalSupply();
		vm.prank(alice);
		fund.redeemShares(shares / 2); // ≈ half of the 1,500 TKN paid in kind

		assertApproxEqRel(fund.costBasis(address(tkn)), 1_500e6 - 1_500e6 * (shares / 2) / supply, 1e12);
	}

	function test_inKindRedemptionTakesItsShareOfTheCostBasis() public {
		ComptrollerV2 fund = _fund(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		uint256 shares = _sharesOf(fund, alice);
		uint256 supply = fund.shares().totalSupply();

		vm.prank(alice);
		fund.redeemSharesInKind(shares / 2);

		assertApproxEqRel(fund.costBasis(address(tkn)), 2_000e6 - 2_000e6 * (shares / 2) / supply, 1e12);
	}

	function test_aPriceThatCannotBeReadSkipsThePerformanceFeeNotTheExit() public {
		ComptrollerV2 fund = _fund(2_000);
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		wethFeed.setAnswer(3000e8); // +$1,000
		skip(2 hours); // WETH's feed is now stale

		uint256 small = _sharesOf(fund, alice) / 100;
		vm.prank(alice);
		fund.redeemShares(small);
		assertEq(_sharesOf(fund, manager), 0, 'fee waits for a readable price');

		wethFeed.setAnswer(3000e8);
		fund.settleFees();
		assertGt(_sharesOf(fund, manager), 0, 'and settles once it reads');
	}

	/// The upgrade path for funds created before v2: the factory points at the v2 build and the
	/// fund owner reconfigures; holders, vault and high-water mark carry over.
	function test_aV1FundMovesToV2ThroughReconfiguration() public {
		FundFactory v1Factory = new FundFactory(vi, new ComptrollerDeployer(), new SharesVaultDeployer());
		FundFactory.FundConfig memory config = FundFactory.FundConfig({
			name: 'Before V2',
			symbol: 'V1',
			denominationAsset: IERC20(address(usdc)),
			fundOwner: manager,
			mgmtScaledPerSecondRate: 0,
			perfFeeBps: 0,
			sharesActionTimelock: 0,
			minRequestDuration: 1 minutes,
			executionWindow: 1 days,
			allowRiskyAssets: false
		});
		Comptroller v1 = Comptroller(v1Factory.createFund(config));
		deal(address(usdc), alice, 10_000e6);
		vm.startPrank(alice);
		usdc.approve(address(v1), 10_000e6);
		v1.requestDeposit(10_000e6);
		vm.stopPrank();
		skip(1 minutes);
		v1.executeDepositRequest(alice);
		uint256 aliceShares = v1.shares().balanceOf(alice);
		uint256 hwm = v1.highWaterMark();

		v1Factory.setComptrollerDeployer(new ComptrollerBlueprintDeployer(type(ComptrollerV2).creationCode, abi.encode(registrar)));
		vm.prank(manager);
		ComptrollerV2 v2 = ComptrollerV2(v1Factory.createReconfigurationRequest(address(v1), config));
		skip(2 days);
		usdcFeed.setAnswer(1e8);
		vm.prank(manager);
		v1Factory.executeReconfiguration(address(v1));

		assertEq(address(v2.registrar()), address(registrar));
		assertEq(v2.shares().balanceOf(alice), aliceShares);
		assertEq(v2.highWaterMark(), hwm);
		vm.prank(alice);
		v2.redeemShares(aliceShares);
		assertApproxEqRel(usdc.balanceOf(alice), 10_000e6, 1e15);
	}
}
