// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ComptrollerBlueprintDeployer} from '../src/core/ComptrollerBlueprintDeployer.sol';
import {SharesVaultDeployer} from '../src/core/SharesVaultDeployer.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {Shares} from '../src/fund/Shares.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {IPolicy} from '../src/interfaces/IPolicy.sol';
import {IUniswapV3SwapRouter} from '../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {UniswapV3SwapAdapter} from '../src/adapters/UniswapV3SwapAdapter.sol';
import {PoolPriceRegistrar} from '../src/pricing/PoolPriceRegistrar.sol';
import {RegistrarFixture} from './utils/RegistrarFixture.sol';
import {MinPoolLiquidityPolicy} from '../src/policies/MinPoolLiquidityPolicy.sol';
import {MockERC20, MockAggregator, MockSwapRouter} from './utils/Mocks.sol';
import {MockRedemptionQueue} from './utils/MockRedemptionQueue.sol';
import {MockUnwindPosition, MockUnwindPositionFactory} from './utils/MockUnwindPosition.sol';
import {AllowedSharesTransferRecipientsPolicy} from '../src/policies/AllowedSharesTransferRecipientsPolicy.sol';
import {
	ScriptedCLPool,
	MockUniswapV3Factory,
	MockSlipstreamFactory,
	MockAerodromeBasicFactory
} from './utils/PoolPriceMocks.sol';
import {IShares} from '../src/interfaces/IShares.sol';

/// @notice The fund's core behaviour on a real factory through the blueprint deployer: TKN ($1,
///         6 decimals) is pool-priced from its scripted Uniswap pool, WETH ($2,000) is Chainlink-priced, USDC is the
///         denomination. Trades go through the real Uniswap adapter against a router that fills at whatever price the test
///         sets. ComptrollerTest runs these and adds the USDC-only exit's own.
abstract contract ComptrollerBase is Test {
	/// @dev USDC per share unit at the bootstrap price: 1 USDC per 1e18 shares.
	uint256 internal constant ONE_USDC_PRICE = 1e6;
	uint128 internal constant PLENTY = 1_000_000e6;
	uint256 internal constant UNWIND_TYPE = 99;
	/// @dev 2%/yr management fee as a 1e27-scaled per-second rate
	uint128 internal constant TWO_PCT_MGMT = 1_000_000_000_627_507_379_616_874_496;

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
	MockRedemptionQueue internal queue;

	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');
	address internal bob = makeAddr('bob');
	address internal attacker = makeAddr('attacker');
	uint256 internal nonce;

	function setUp() public virtual {
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
		registrar = RegistrarFixture.deploy(
			address(vi), address(uniswap), [address(new MockSlipstreamFactory()), address(new MockSlipstreamFactory()), address(new MockSlipstreamFactory())], address(new MockAerodromeBasicFactory()), quotes, address(this)
		);
		vi.transferOwnership(address(registrar));
		registrar.execute(abi.encodeCall(Ownable2Step.acceptOwnership, ()));

		pool = new ScriptedCLPool(address(tkn), address(usdc), address(uniswap), 3000, 60);
		pool.setHistory(2 days);
		pool.setOracle(0, PLENTY);
		deal(address(usdc), address(pool), 1_000_000e6);
		uniswap.setPool(address(tkn), address(usdc), 3000, address(pool));
		registrar.register(address(tkn), address(pool));

		queue = new MockRedemptionQueue();
		factory = new FundFactory(
			vi,
			new ComptrollerBlueprintDeployer(type(Comptroller).creationCode, abi.encode(registrar, queue)),
			new SharesVaultDeployer()
		);
		router = new MockSwapRouter();
		uniAdapter = new UniswapV3SwapAdapter(IUniswapV3SwapRouter(address(router)), address(0xFEE), 0, address(this));
		factory.registerAdapter(address(uniAdapter));
		FundFactory.PolicyReg[] memory mandatory = new FundFactory.PolicyReg[](1);
		mandatory[0] = FundFactory.PolicyReg({
			hook: IPolicy.PolicyHook.PostCallOnIntegration, policy: address(new MinPoolLiquidityPolicy(registrar))
		});
		factory.setMandatoryPolicies(mandatory);
		factory.registerPositionType(UNWIND_TYPE, address(new MockUnwindPositionFactory(IERC20(address(usdc)))));
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	/// @dev A fund with `perfBps` performance fee; alice deposits 10,000 USDC at the bootstrap price.
	function _fund(uint16 perfBps) internal returns (Comptroller fund) {
		fund = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: string.concat('Fund #', vm.toString(++nonce)),
					symbol: 'FUND',
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

	function _request(Comptroller fund, address who, uint256 amount, uint256 maxSharePrice) internal {
		deal(address(usdc), who, amount);
		vm.startPrank(who);
		usdc.approve(address(fund), amount);
		fund.requestDeposit(amount, maxSharePrice);
		vm.stopPrank();
		skip(1 minutes);
	}

	function _deposit(Comptroller fund, address who, uint256 amount, uint256 maxSharePrice) internal {
		_request(fund, who, amount, maxSharePrice);
		fund.executeDepositRequest(who);
	}

	function _swap(Comptroller fund, MockERC20 tokenIn, MockERC20 tokenOut, uint256 amountIn, uint256 amountOut) internal {
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

	function _held(Comptroller fund, MockERC20 token) internal view returns (uint256) {
		return token.balanceOf(address(fund.vault()));
	}

	function _sharesOf(Comptroller fund, address who) internal view returns (uint256) {
		return fund.shares().balanceOf(who);
	}

	// ─── rule 1: redemptions ─────────────────────────────────────────────────────

	function test_aReadablePricedHoldingIsPaidInCash() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, weth, 2_000e6, 1e18); // 8,000 USDC + 1 WETH ($2,000)

		uint256 half = _sharesOf(fund, alice) / 2;
		vm.prank(alice);
		fund.redeemShares(half);

		assertApproxEqRel(usdc.balanceOf(alice), 5_000e6, 1e15);
		assertEq(weth.balanceOf(alice), 0);
	}

	// ─── rule 2: deposits ────────────────────────────────────────────────────────

	function test_aDepositExecutesAtItsMaxSharePrice() public {
		Comptroller fund = _fund(0);

		_deposit(fund, bob, 1_000e6, ONE_USDC_PRICE);

		assertApproxEqRel(_sharesOf(fund, bob), 1_000e18, 1e15);
	}

	function test_aDepositPricedOverItsMaximumDoesNotExecute() public {
		Comptroller fund = _fund(0);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		_request(fund, bob, 1_000e6, ONE_USDC_PRICE);
		_setTknPriceTick(23028); // pumped: 8,000 USDC + 2,000 TKN at $10 → ≈ $2.80 a share

		vm.expectPartialRevert(Comptroller.SharePriceAboveMax.selector);
		vm.prank(attacker);
		fund.executeDepositRequest(bob);

		vm.prank(bob);
		fund.cancelDepositRequest();
		assertEq(usdc.balanceOf(bob), 1_000e6);
	}

	// ─── rule 3: performance fee ─────────────────────────────────────────────────

	function test_aPumpedLongTailPriceMintsNoPerformanceFee() public {
		Comptroller fund = _fund(2_000);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		_setTknPriceTick(23028);

		fund.settleFees();

		assertEq(_sharesOf(fund, manager), 0);
	}

	function test_aLongTailGainIsChargedOnceSold() public {
		Comptroller fund = _fund(2_000);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		_setTknPriceTick(6932); // TKN doubles (1.0001^6932 ≈ 2)
		_swap(fund, tkn, usdc, 2_000e6, 4_000e6); // sold at $2: +2,000 USDC realized

		fund.settleFees();

		// 20% of the $2,000 gain = $400 of fee, as shares of a $12,000 fund: 400/11,600 of supply
		uint256 supply = fund.shares().totalSupply();
		assertApproxEqRel(_sharesOf(fund, manager), supply * 400 / 12_000, 1e15);
	}

	function test_aLongTailLossCountsAtOnceAndRecoveringToCostChargesNothing() public {
		Comptroller fund = _fund(2_000);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		_setTknPriceTick(-6932); // TKN halves
		fund.settleFees();
		_setTknPriceTick(0); // back to cost
		_swap(fund, tkn, usdc, 2_000e6, 2_000e6);

		fund.settleFees();

		assertEq(_sharesOf(fund, manager), 0);
	}

	function test_aDepositIntoAFundWithUnrealizedGainsTriggersNoFee() public {
		Comptroller fund = _fund(2_000);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		_setTknPriceTick(6932); // unrealized: TKN worth $4,000 against a $2,000 cost

		_deposit(fund, bob, 12_000e6, type(uint256).max);
		fund.settleFees();

		assertEq(_sharesOf(fund, manager), 0);
	}

	function test_donatedLongTailTokensMintNoFee() public {
		Comptroller fund = _fund(2_000);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		tkn.mint(address(fund.vault()), 5_000e6); // a donation: units with no cost

		fund.settleFees();

		assertEq(_sharesOf(fund, manager), 0);
	}

	/// EIP-170: the comptroller's runtime must fit.
	function test_runtimeSizeFitsEip170() public {
		Comptroller fund = _fund(0);
		assertLt(address(fund).code.length, 24_577);
	}

	// ─── redemption-queue hooks (founder 2026-10-06) ─────────────────────────────

	function _config(uint128 mgmtRate, uint16 perfBps) internal returns (FundFactory.FundConfig memory) {
		return FundFactory.FundConfig({
			name: string.concat('Fund #', vm.toString(++nonce)),
			symbol: 'FUND',
			denominationAsset: IERC20(address(usdc)),
			fundOwner: manager,
			mgmtScaledPerSecondRate: mgmtRate,
			perfFeeBps: perfBps,
			sharesActionTimelock: 0,
			minRequestDuration: 1 minutes,
			executionWindow: 1 days,
			allowRiskyAssets: false
		});
	}

	/// @dev alice's 10,000 USDC fund with 4,000 USDC locked in an unwindable position.
	function _fundWithUnwindPosition() internal returns (Comptroller fund, MockUnwindPosition position) {
		fund = _fund(0);
		vm.startPrank(manager);
		position = MockUnwindPosition(fund.createExternalPosition(UNWIND_TYPE, ''));
		address[] memory assets = new address[](1);
		assets[0] = address(usdc);
		uint256[] memory amounts = new uint256[](1);
		amounts[0] = 4_000e6;
		fund.callOnExternalPosition(address(position), assets, amounts, new address[](0), abi.encode(uint8(0), abi.encode(uint256(4_000e6))));
		vm.stopPrank();
	}

	function _refreshFeeds() internal {
		usdcFeed.setAnswer(1e8);
		wethFeed.setAnswer(wethFeed.answer());
	}

	function _usdc(uint256 amount) internal view returns (address[] memory assets, uint256[] memory amounts) {
		assets = new address[](1);
		assets[0] = address(usdc);
		amounts = new uint256[](1);
		amounts[0] = amount;
	}

	function test_settleFeesForRedemption_onlyTheQueue() public {
		Comptroller fund = _fund(0);
		vm.expectRevert(Comptroller.OnlyRedemptionQueue.selector);
		fund.settleFeesForRedemption();
	}

	function test_instantCashRedemption_refusedWhileTheFundHoldsAPosition() public {
		(Comptroller fund,) = _fundWithUnwindPosition();
		vm.prank(alice);
		vm.expectRevert(Comptroller.UseRedemptionQueue.selector);
		fund.redeemShares(1e18);
	}

	function test_sharesMovingToAndFromTheQueue_skipTransferPolicies() public {
		FundFactory.PolicyReg[] memory regs = new FundFactory.PolicyReg[](1);
		AllowedSharesTransferRecipientsPolicy allowList = new AllowedSharesTransferRecipientsPolicy(manager, new address[](0));
		regs[0] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PreTransferShares, policy: address(allowList)});
		Comptroller fund = Comptroller(factory.createFund(_config(0, 0), regs));
		_deposit(fund, alice, 10_000e6, type(uint256).max);

		IShares fundShares = fund.shares();
		vm.prank(alice);
		fundShares.transfer(address(queue), 1e18); // a request
		vm.prank(address(queue));
		fundShares.transfer(alice, 1e18); // a cancel
		vm.prank(alice);
		vm.expectRevert(abi.encodeWithSelector(AllowedSharesTransferRecipientsPolicy.TransferRecipientNotAllowed.selector, bob));
		fundShares.transfer(bob, 1e18); // anyone else: the allow list still applies
	}

	function test_feeStop_managementFeeTimeIsForfeitedWhileOverdue() public {
		Comptroller fund = Comptroller(factory.createFund(_config(TWO_PCT_MGMT, 0)));
		_deposit(fund, alice, 10_000e6, type(uint256).max);
		skip(30 days);
		_refreshFeeds();
		queue.setOverdue(address(fund), true);
		uint256 supply = fund.shares().totalSupply();
		fund.settleFees();
		assertEq(fund.shares().totalSupply(), supply, 'no management fee while overdue');

		queue.setOverdue(address(fund), false);
		skip(1 days);
		_refreshFeeds();
		fund.settleFees();
		uint256 minted = fund.shares().totalSupply() - supply;
		assertApproxEqRel(minted, supply * 2 / 100 / 365, 0.02e18, 'only the day after the clear is charged');
	}

	function test_feeStop_gainsMadeWhileOverdueAreNeverCharged() public {
		Comptroller fund = _fund(2_000);
		_swap(fund, usdc, weth, 5_000e6, 2.5e18);
		queue.setOverdue(address(fund), true);
		wethFeed.setAnswer(3_000e8); // +2,500 while overdue
		uint256 supply = fund.shares().totalSupply();
		fund.settleFees();
		assertEq(fund.shares().totalSupply(), supply, 'no performance fee while overdue');

		queue.setOverdue(address(fund), false);
		fund.settleFees();
		assertEq(fund.shares().totalSupply(), supply, 'the overdue gains stay uncharged after the clear');

		wethFeed.setAnswer(4_000e8); // +2,500 after the clear
		fund.settleFees();
		assertGt(fund.shares().totalSupply(), supply, 'later gains are charged again');
	}
}
