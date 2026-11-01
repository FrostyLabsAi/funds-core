// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {V6Host} from './utils/V6Host.sol';
import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {ComptrollerV6 as Comptroller} from '../src/core/ComptrollerV6.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {IPolicy} from '../src/interfaces/IPolicy.sol';
import {IUniswapV3SwapRouter} from '../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {UniswapV3SwapAdapter} from '../src/adapters/UniswapV3SwapAdapter.sol';
import {PoolPriceRegistrar} from '../src/pricing/PoolPriceRegistrar.sol';
import {PoolPriceRegistrarWindowed} from '../src/pricing/PoolPriceRegistrarWindowed.sol';
import {MinPoolLiquidityPolicy} from '../src/policies/MinPoolLiquidityPolicy.sol';
import {MockERC20, MockAggregator, MockSwapRouter, MockUniV3PositionManager} from './utils/Mocks.sol';
import {LimitOrderPosition, LimitOrderPositionFactory} from '../src/positions/LimitOrderPosition.sol';
import {UniswapV3LPPositionFactory} from '../src/positions/UniswapV3LPPosition.sol';
import {IUniswapV3NonfungiblePositionManager} from '../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {
	ScriptedCLPool,
	MockUniswapV3Factory,
	MockSlipstreamFactory,
	MockAerodromeBasicFactory
} from './utils/PoolPriceMocks.sol';

/// @notice The $25k buy rule on a real fund: TKN ($1, 6 decimals, pool-priced from its Uniswap v3
///         USDC pool) and WETH (Chainlink) bought and sold through the Uniswap adapter, with the
///         policy attached by the factory as a mandatory policy.
contract MinPoolLiquidityPolicyTest is Test {
	ValueInterpreter internal vi;
	PoolPriceRegistrar internal registrar;
	MinPoolLiquidityPolicy internal policy;
	FundFactory internal factory;
	MockSwapRouter internal router;
	UniswapV3SwapAdapter internal uniAdapter;
	MockERC20 internal usdc;
	MockERC20 internal weth;
	MockERC20 internal tkn;
	ScriptedCLPool internal pool;
	Comptroller internal fund;

	uint256 internal constant LIMIT_ORDER_TYPE = 2;
	uint256 internal constant LP_TYPE = 3;

	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');

	function setUp() public {
		vm.warp(30 days);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		weth = new MockERC20('Wrapped Ether', 'WETH', 18);
		tkn = new MockERC20('Token', 'TKN', 6);
		vi = new ValueInterpreter(address(this));
		vi.addPrimitive(address(usdc), address(new MockAggregator(8, 1e8)), 25 hours);
		vi.addPrimitive(address(weth), address(new MockAggregator(8, 2000e8)), 1 hours);

		MockUniswapV3Factory uniswap = new MockUniswapV3Factory();
		address[] memory quotes = new address[](1);
		quotes[0] = address(usdc);
		registrar = PoolPriceRegistrar(address(new PoolPriceRegistrarWindowed(
			PoolPriceRegistrarWindowed.Wiring({
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
		)));
		vi.transferOwnership(address(registrar));
		registrar.execute(abi.encodeCall(Ownable2Step.acceptOwnership, ()));

		pool = new ScriptedCLPool(address(tkn), address(usdc), address(uniswap), 3000, 60);
		pool.setHistory(2 days);
		pool.setOracle(0, 1_000_000e6); // $1; the window held ≈ $1M of USDC as a full-range reserve
		_setPoolUsdc(1_000_000e6);
		uniswap.setPool(address(tkn), address(usdc), 3000, address(pool));
		registrar.register(address(tkn), address(pool));

		policy = new MinPoolLiquidityPolicy(registrar);
		factory = new FundFactory(vi, V6Host.deployer(), new SharesVaultDeployer());
		router = new MockSwapRouter();
		uniAdapter = new UniswapV3SwapAdapter(IUniswapV3SwapRouter(address(router)));
		factory.registerAdapter(address(uniAdapter));
		IPolicy.PolicyHook[] memory hooks = policy.implementedHooks();
		FundFactory.PolicyReg[] memory mandatory = new FundFactory.PolicyReg[](hooks.length);
		for (uint256 i; i < hooks.length; ++i) {
			mandatory[i] = FundFactory.PolicyReg({hook: hooks[i], policy: address(policy)});
		}
		factory.setMandatoryPolicies(mandatory);
		factory.registerPositionType(LIMIT_ORDER_TYPE, address(new LimitOrderPositionFactory()));
		factory.registerPositionType(
			LP_TYPE,
			address(new UniswapV3LPPositionFactory(IUniswapV3NonfungiblePositionManager(address(new MockUniV3PositionManager()))))
		);

		fund = _fund();
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	function _fund() internal returns (Comptroller c) {
		c = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Long Tail',
					symbol: 'LT',
					denominationAsset: IERC20(address(usdc)),
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
		usdc.mint(alice, 100_000e6);
		vm.startPrank(alice);
		usdc.approve(address(c), 100_000e6);
		c.requestDeposit(100_000e6, type(uint256).max);
		vm.stopPrank();
		skip(1 minutes);
		c.executeDepositRequest(alice);
	}

	function _setPoolUsdc(uint256 amount) internal {
		deal(address(usdc), address(pool), amount);
	}

	function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) internal {
		router.setNextAmountOut(amountOut);
		vm.prank(manager);
		fund.callOnIntegration(address(uniAdapter), abi.encode(tokenIn, tokenOut, uint24(3000), amountIn, uint256(0)));
	}

	function _held(MockERC20 token) internal view returns (uint256) {
		return token.balanceOf(address(fund.vault()));
	}

	// ─── buys ────────────────────────────────────────────────────────────────────

	function test_aFundBuysAPoolPricedTokenWhoseLiquidityMeetsTheMinimum() public {
		_setPoolUsdc(25_000e6);

		_swap(address(usdc), address(tkn), 1_000e6, 1_000e6);

		assertEq(_held(tkn), 1_000e6);
	}

	function test_aFundCannotBuyAPoolPricedTokenUnderTheMinimum() public {
		_setPoolUsdc(24_999e6);
		router.setNextAmountOut(1_000e6);

		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(MinPoolLiquidityPolicy.PoolTooThin.selector, address(tkn), 24_999e18));
		fund.callOnIntegration(address(uniAdapter), abi.encode(address(usdc), address(tkn), uint24(3000), 1_000e6, uint256(0)));
	}

	function test_aFundSellsAPoolPricedTokenWhateverItsLiquidity() public {
		_swap(address(usdc), address(tkn), 1_000e6, 1_000e6);
		_setPoolUsdc(1_000e6); // the pool thinned out after the buy

		_swap(address(tkn), address(usdc), 1_000e6, 1_000e6);

		assertEq(_held(tkn), 0);
	}

	function test_tokensNotPricedFromAPoolAreNotChecked() public {
		_setPoolUsdc(0);

		_swap(address(usdc), address(weth), 2_000e6, 1e18);

		assertEq(_held(weth), 1e18);
	}

	// ─── long-tail tokens stay out of positions ──────────────────────────────────

	function _limitOrderPosition() internal returns (LimitOrderPosition position) {
		vm.prank(manager);
		position = LimitOrderPosition(fund.createExternalPosition(LIMIT_ORDER_TYPE, ''));
	}

	function _placeOrder(LimitOrderPosition position, address sell, address buy, uint256 sellAmt, uint256 minBuy)
		internal
	{
		address[] memory transferAssets = new address[](1);
		transferAssets[0] = sell;
		uint256[] memory transferAmounts = new uint256[](1);
		transferAmounts[0] = sellAmt;
		bytes memory place = abi.encode(
			uint8(LimitOrderPosition.Action.PlaceOrder),
			abi.encode(sell, buy, uint128(sellAmt), uint128(minBuy), uint64(block.timestamp + 1 days))
		);
		vm.prank(manager);
		fund.callOnExternalPosition(address(position), transferAssets, transferAmounts, new address[](0), place);
	}

	function test_aFundCannotOpenAnLpPositionOnAPoolPricedToken() public {
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(MinPoolLiquidityPolicy.PoolPricedTokenInPosition.selector, address(tkn)));
		fund.createExternalPosition(LP_TYPE, abi.encode(address(tkn), address(usdc), uint24(3000)));
	}

	function test_aFundOpensAnLpPositionOnTokensPricedOtherwise() public {
		vm.prank(manager);
		fund.createExternalPosition(LP_TYPE, abi.encode(address(weth), address(usdc), uint24(3000)));

		assertEq(fund.getExternalPositions().length, 1);
	}

	function test_aLimitOrderBuyingAPoolPricedTokenIsRefused() public {
		LimitOrderPosition position = _limitOrderPosition();

		vm.expectRevert(abi.encodeWithSelector(MinPoolLiquidityPolicy.PoolPricedTokenInPosition.selector, address(tkn)));
		this.placeOrderAsManager(position, address(usdc), address(tkn), 1_000e6, 1_000e6);
	}

	function test_aLimitOrderSellingAPoolPricedTokenIsRefused() public {
		_swap(address(usdc), address(tkn), 1_000e6, 1_000e6);
		LimitOrderPosition position = _limitOrderPosition();

		vm.expectRevert(abi.encodeWithSelector(MinPoolLiquidityPolicy.PoolPricedTokenInPosition.selector, address(tkn)));
		this.placeOrderAsManager(position, address(tkn), address(usdc), 1_000e6, 1_000e6);
	}

	function test_aLimitOrderBetweenTokensPricedOtherwiseIsAllowed() public {
		LimitOrderPosition position = _limitOrderPosition();

		_placeOrder(position, address(usdc), address(weth), 2_000e6, 1e18);

		assertEq(usdc.balanceOf(address(position)), 2_000e6);
	}

	/// @dev Lets expectRevert land on the fund call itself, not the order encoding before it.
	function placeOrderAsManager(LimitOrderPosition position, address sell, address buy, uint256 sellAmt, uint256 minBuy)
		external
	{
		_placeOrder(position, sell, buy, sellAmt, minBuy);
	}

	function test_refusesToRunOnAnyOtherHook() public {
		vm.expectRevert(
			abi.encodeWithSelector(MinPoolLiquidityPolicy.UnsupportedHook.selector, IPolicy.PolicyHook.PostDepositRequest)
		);
		policy.validate(IPolicy.PolicyHook.PostDepositRequest, abi.encode(alice, uint256(1)));
	}
}
