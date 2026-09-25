// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {IPolicy} from '../src/interfaces/IPolicy.sol';
import {IValueInterpreter} from '../src/interfaces/IValueInterpreter.sol';
import {AggregatorV3Interface} from '../src/interfaces/AggregatorV3Interface.sol';
import {IUniswapV3SwapRouter} from '../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {UniswapV3SwapAdapter} from '../src/adapters/UniswapV3SwapAdapter.sol';
import {TwapListingRegistry, IUniswapV3PoolFactory, ISlipstreamPoolFactory} from '../src/pricing/TwapListingRegistry.sol';
import {TwapAggregatorAdapter} from '../src/pricing/TwapAggregatorAdapter.sol';
import {TwapExposurePolicy} from '../src/policies/TwapExposurePolicy.sol';
import {MockERC20, MockAggregator, MockSwapRouter, MockUniV3PositionManager} from './utils/Mocks.sol';
import {LimitOrderPosition, LimitOrderPositionFactory} from '../src/positions/LimitOrderPosition.sol';
import {UniswapV3LPPositionFactory} from '../src/positions/UniswapV3LPPosition.sol';
import {IUniswapV3NonfungiblePositionManager} from '../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {ScriptedPool} from './TwapAggregatorAdapter.t.sol';
import {ScriptedFactory} from './TwapListingRegistry.t.sol';

/// @notice The exposure limits on a real fund: MEME ($2,500, TWAP-listed) bought and sold
///         through the Uniswap adapter. Pool depth is linear in liquidity: L = 1e18 → $4,893,076
///         (closed form, see TwapAggregatorAdapter.t.sol), so L = 4e16 → $195,723 and
///         L = 1e16 → $48,931 (under the $50k floor).
contract TwapExposurePolicyTest is Test {
	int24 internal constant TICK_2500 = -198_080;
	uint128 internal constant L_DEEP = 1e18; // $4.89M depth → 50% cap
	uint128 internal constant L_SMALL = 4e16; // $195.7k depth → 10% cap ($19.6k)
	uint128 internal constant L_UNDER = 1e16; // $48.9k depth → under the floor

	ValueInterpreter internal vi;
	MockERC20 internal meme;
	MockERC20 internal usdc;
	MockAggregator internal usdcFeed;
	ScriptedPool internal pool;
	TwapListingRegistry internal registry;
	TwapExposurePolicy internal policy;
	FundFactory internal factory;
	MockSwapRouter internal router;
	UniswapV3SwapAdapter internal uniAdapter;

	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');
	address internal bob = makeAddr('bob');
	uint256 internal nonce;

	function setUp() public {
		vm.warp(10 days);
		deployCodeTo('Mocks.sol:MockERC20', abi.encode('Meme', 'MEME', uint8(18)), address(0x1111));
		deployCodeTo('Mocks.sol:MockERC20', abi.encode('USD Coin', 'USDC', uint8(6)), address(0x2222));
		meme = MockERC20(address(0x1111));
		usdc = MockERC20(address(0x2222));
		usdcFeed = new MockAggregator(8, 1e8);

		vi = new ValueInterpreter(address(this));
		vi.addPrimitive(address(usdc), address(usdcFeed), 7 days);

		ScriptedFactory uni = new ScriptedFactory();
		pool = new ScriptedPool(address(meme), address(usdc));
		pool.set(TICK_2500, TICK_2500, L_DEEP);
		uni.setUni(address(meme), address(usdc), 3000, address(pool));
		registry = new TwapListingRegistry(IValueInterpreter(address(vi)), IUniswapV3PoolFactory(address(uni)), ISlipstreamPoolFactory(address(new ScriptedFactory())));
		registry.setQuote(address(usdc), AggregatorV3Interface(address(usdcFeed)), 2 days);
		TwapAggregatorAdapter adapter = registry.list(address(meme), address(usdc), TwapListingRegistry.Venue.UniswapV3, 3000);
		vi.addPrimitive(address(meme), address(adapter), 1 hours); // the VI owner's step
		policy = new TwapExposurePolicy(registry);

		factory = new FundFactory(vi, new ComptrollerDeployer(), new SharesVaultDeployer());
		router = new MockSwapRouter();
		uniAdapter = new UniswapV3SwapAdapter(IUniswapV3SwapRouter(address(router)));
		factory.registerAdapter(address(uniAdapter));
		usdc.mint(alice, 1_000_000e6);
		usdc.mint(bob, 1_000_000e6);
	}

	// ─── helpers ────────────────────────────────────────────────────────────────

	function _fund(bool degen) internal returns (Comptroller c) {
		FundFactory.PolicyReg[] memory regs = new FundFactory.PolicyReg[](4);
		regs[0] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnIntegration, policy: address(policy)});
		regs[1] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostDepositRequest, policy: address(policy)});
		regs[2] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.CreateExternalPosition, policy: address(policy)});
		regs[3] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnExternalPosition, policy: address(policy)});
		c = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: string.concat('TWAP Fund #', vm.toString(++nonce)),
					symbol: 'TW',
					denominationAsset: IERC20(address(usdc)),
					fundOwner: manager,
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: 0,
					sharesActionTimelock: 0,
					minRequestDuration: 1 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: degen
				}),
				regs
			)
		);
		_deposit(c, alice, 100_000e6);
	}

	function _deposit(Comptroller c, address who, uint256 amount) internal {
		vm.startPrank(who);
		usdc.approve(address(c), amount);
		c.requestDeposit(amount);
		vm.stopPrank();
		skip(1 minutes);
		c.executeDepositRequest(who);
	}

	function _buyMeme(Comptroller c, uint256 usdcIn) internal {
		router.setNextAmountOut((usdcIn * 1e12) / 2_500); // at the TWAP price, no slippage
		vm.prank(manager);
		c.callOnIntegration(address(uniAdapter), abi.encode(address(usdc), address(meme), uint24(3000), usdcIn, uint256(0)));
	}

	/// @dev expectRevert must land on the fund's trade, not on the router setup before it.
	function _buyMemeExpectingRevert(Comptroller c, uint256 usdcIn, bytes memory revertData) internal {
		router.setNextAmountOut((usdcIn * 1e12) / 2_500);
		vm.prank(manager);
		if (revertData.length == 4) vm.expectPartialRevert(bytes4(revertData));
		else vm.expectRevert(revertData);
		c.callOnIntegration(address(uniAdapter), abi.encode(address(usdc), address(meme), uint24(3000), usdcIn, uint256(0)));
	}

	function _sellMeme(Comptroller c, uint256 memeIn) internal {
		router.setNextAmountOut((memeIn * 2_500) / 1e12);
		vm.prank(manager);
		c.callOnIntegration(address(uniAdapter), abi.encode(address(meme), address(usdc), uint24(3000), memeIn, uint256(0)));
	}

	function _memeHeld(Comptroller c) internal view returns (uint256) {
		return meme.balanceOf(address(c.vault()));
	}

	function _keepQuoteFresh() internal {
		usdcFeed.setAnswer(1e8);
	}

	// ─── 20% of GAV ─────────────────────────────────────────────────────────────

	function test_buyWithinTwentyPercent_ok() public {
		Comptroller c = _fund(false);
		_buyMeme(c, 15_000e6);
		assertEq(_memeHeld(c), 6e18);
	}

	function test_buyOverTwentyPercent_reverts() public {
		Comptroller c = _fund(false);
		_buyMemeExpectingRevert(c, 25_000e6, abi.encodePacked(TwapExposurePolicy.TwapShareOfGavExceeded.selector));
	}

	// ─── per-pool caps ──────────────────────────────────────────────────────────

	function test_smallPool_capsAtTenPercentOfDepth() public {
		Comptroller c = _fund(false);
		pool.set(TICK_2500, TICK_2500, L_SMALL); // $195.7k depth → $19.57k cap
		_buyMemeExpectingRevert(c, 20_000e6, abi.encodePacked(TwapExposurePolicy.PoolShareExceeded.selector));
		_buyMeme(c, 19_000e6);
	}

	function test_largePool_capsAtFiftyPercentOfDepth() public {
		// a bigger fund, so the 20%-of-GAV rule does not bind first: $10M GAV, $2M allowed by
		// GAV; pool $4.89M → 50% = $2.45M allowed by depth
		Comptroller c = _fund(false);
		usdc.mint(bob, 9_900_000e6);
		_deposit(c, bob, 9_900_000e6);
		_buyMeme(c, 1_900_000e6);
		pool.set(TICK_2500, TICK_2500, 7e17); // depth $3.43M → cap $1.71M, holding $1.9M
		_buyMemeExpectingRevert(c, 10_000e6, abi.encodePacked(TwapExposurePolicy.PoolShareExceeded.selector));
	}

	// ─── exits are never blocked ────────────────────────────────────────────────

	function test_sellingIsNeverBlocked_evenOverACap() public {
		Comptroller c = _fund(false);
		_buyMeme(c, 15_000e6);
		pool.set(TICK_2500, TICK_2500, 1e15); // depth $4.9k → cap $489, holding $15k
		_sellMeme(c, 3e18); // partial exit, still way over the cap — allowed
		_sellMeme(c, 3e18);
		assertEq(_memeHeld(c), 0);
	}

	// ─── the 72-hour delisting ──────────────────────────────────────────────────

	function test_delisted_pausesDepositsButNotRedemptions_untilSold() public {
		Comptroller c = _fund(false);
		_buyMeme(c, 15_000e6);

		pool.set(TICK_2500, TICK_2500, L_UNDER);
		registry.pokeFloor(address(meme));
		skip(72 hours);
		_keepQuoteFresh();
		assertTrue(registry.isDelisted(address(meme)));

		// new deposits pause…
		vm.startPrank(bob);
		usdc.approve(address(c), 1_000e6);
		vm.expectRevert(abi.encodeWithSelector(TwapExposurePolicy.DepositsPausedDelistedHolding.selector, address(meme)));
		c.requestDeposit(1_000e6);
		vm.stopPrank();

		// …redemptions do not, and still price MEME at the market (no haircut)
		uint256 gav = c.calcGav();
		assertApproxEqRel(gav, 100_000e6, 0.001e18);
		uint256 shares = IERC20(address(c.shares())).balanceOf(alice) / 10;
		vm.prank(alice);
		c.redeemSharesForDenominationAsset(shares);

		// …buying more of it is refused…
		_buyMemeExpectingRevert(c, 100e6, abi.encodeWithSelector(TwapExposurePolicy.BuyingDelistedAsset.selector, address(meme)));

		// …and selling it lifts the pause
		_sellMeme(c, _memeHeld(c));
		_deposit(c, bob, 1_000e6);
	}

	function test_delisted_before72h_nothingPauses() public {
		Comptroller c = _fund(false);
		_buyMeme(c, 15_000e6);
		pool.set(TICK_2500, TICK_2500, L_UNDER);
		registry.pokeFloor(address(meme));
		skip(71 hours);
		_keepQuoteFresh();
		_deposit(c, bob, 1_000e6);
	}

	function test_delisted_fundsNotHoldingItAreUnaffected() public {
		Comptroller c = _fund(false);
		pool.set(TICK_2500, TICK_2500, L_UNDER);
		registry.pokeFloor(address(meme));
		skip(72 hours);
		_keepQuoteFresh();
		_deposit(c, bob, 1_000e6);
	}

	// ─── degen funds: community takeover ────────────────────────────────────────

	function test_degenFund_skipsTheCaps() public {
		Comptroller c = _fund(true);
		pool.set(TICK_2500, TICK_2500, L_SMALL); // $19.57k pool cap for a standard fund
		_buyMeme(c, 60_000e6); // 60% of GAV, 3× the pool cap
		assertEq(_memeHeld(c), 24e18);
	}

	function test_degenFund_stillGetsTheDepositPause() public {
		Comptroller c = _fund(true);
		_buyMeme(c, 60_000e6);
		pool.set(TICK_2500, TICK_2500, L_UNDER);
		registry.pokeFloor(address(meme));
		skip(72 hours);
		_keepQuoteFresh();
		vm.startPrank(bob);
		usdc.approve(address(c), 1_000e6);
		vm.expectRevert(abi.encodeWithSelector(TwapExposurePolicy.DepositsPausedDelistedHolding.selector, address(meme)));
		c.requestDeposit(1_000e6);
		vm.stopPrank();
	}

	// ─── mandatory: a fund with NO ruleset of its own is still capped ───────────

	function test_mandatoryViaTheFactory_bareFundIsCapped() public {
		FundFactory.PolicyReg[] memory regs = new FundFactory.PolicyReg[](4);
		regs[0] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnIntegration, policy: address(policy)});
		regs[1] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostDepositRequest, policy: address(policy)});
		regs[2] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.CreateExternalPosition, policy: address(policy)});
		regs[3] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnExternalPosition, policy: address(policy)});
		factory.setMandatoryPolicies(regs);

		Comptroller bare = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'No Ruleset',
					symbol: 'NR',
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
		_deposit(bare, alice, 100_000e6);
		_buyMemeExpectingRevert(bare, 25_000e6, abi.encodePacked(TwapExposurePolicy.TwapShareOfGavExceeded.selector));
		_buyMeme(bare, 15_000e6);
	}

	// ─── non-TWAP trades are untouched ──────────────────────────────────────────

	function test_hooks() public view {
		IPolicy.PolicyHook[] memory hooks = policy.implementedHooks();
		assertEq(hooks.length, 4);
		assertEq(uint8(hooks[0]), uint8(IPolicy.PolicyHook.PostCallOnIntegration));
		assertEq(uint8(hooks[1]), uint8(IPolicy.PolicyHook.PostDepositRequest));
		assertEq(uint8(hooks[2]), uint8(IPolicy.PolicyHook.CreateExternalPosition));
		assertEq(uint8(hooks[3]), uint8(IPolicy.PolicyHook.PostCallOnExternalPosition));
	}

	// ─── external positions (security review 2026-09-24, M-2) ──────────────────

	uint256 internal constant LIMIT_ORDER_TYPE = 2;
	uint256 internal constant LP_TYPE = 3;

	function _registerPositionTypes() internal {
		factory.registerPositionType(LIMIT_ORDER_TYPE, address(new LimitOrderPositionFactory()));
		factory.registerPositionType(
			LP_TYPE,
			address(new UniswapV3LPPositionFactory(IUniswapV3NonfungiblePositionManager(address(new MockUniV3PositionManager()))))
		);
	}

	function _limitOrderPosition(Comptroller c) internal returns (LimitOrderPosition position) {
		vm.prank(manager);
		position = LimitOrderPosition(c.createExternalPosition(LIMIT_ORDER_TYPE, ''));
	}

	function _place(Comptroller c, LimitOrderPosition position, address sell, address buy, uint256 sellAmt, uint256 minBuy, address moveIn)
		internal
	{
		address[] memory transferAssets = new address[](1);
		transferAssets[0] = moveIn;
		uint256[] memory transferAmounts = new uint256[](1);
		transferAmounts[0] = sellAmt;
		address[] memory none = new address[](0);
		bytes memory place = abi.encode(
			uint8(LimitOrderPosition.Action.PlaceOrder),
			abi.encode(sell, buy, uint128(sellAmt), uint128(minBuy), uint64(block.timestamp + 1 days))
		);
		vm.prank(manager);
		c.callOnExternalPosition(address(position), transferAssets, transferAmounts, none, place);
	}

	function test_m2_lpOnATwapToken_refusedForNonDegen_allowedForDegen() public {
		_registerPositionTypes();
		Comptroller c = _fund(false);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(TwapExposurePolicy.TwapAssetInExternalPosition.selector, address(meme)));
		c.createExternalPosition(LP_TYPE, abi.encode(address(meme), address(usdc), uint24(3000)));

		Comptroller degen = _fund(true);
		vm.prank(manager);
		degen.createExternalPosition(LP_TYPE, abi.encode(address(meme), address(usdc), uint24(3000)));
	}

	function test_m2_limitOrderBuyingATwapToken_refused() public {
		_registerPositionTypes();
		Comptroller c = _fund(false);
		LimitOrderPosition position = _limitOrderPosition(c);
		_keepQuoteFresh();
		// sell 5,000 USDC for ≥ 2 MEME ($2,500 each — oracle parity)
		address[] memory transferAssets = new address[](1);
		transferAssets[0] = address(usdc);
		uint256[] memory transferAmounts = new uint256[](1);
		transferAmounts[0] = 5_000e6;
		address[] memory none = new address[](0);
		bytes memory place = abi.encode(
			uint8(LimitOrderPosition.Action.PlaceOrder),
			abi.encode(address(usdc), address(meme), uint128(5_000e6), uint128(2e18), uint64(block.timestamp + 1 days))
		);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(TwapExposurePolicy.TwapAssetInExternalPosition.selector, address(meme)));
		c.callOnExternalPosition(address(position), transferAssets, transferAmounts, none, place);
	}

	function test_m2_limitOrderSellingATwapToken_isAnExit_allowed() public {
		_registerPositionTypes();
		Comptroller c = _fund(false);
		_buyMeme(c, 10_000e6); // 4 MEME
		LimitOrderPosition position = _limitOrderPosition(c);
		_keepQuoteFresh();
		_place(c, position, address(meme), address(usdc), 4e18, 10_000e6, address(meme));
		assertEq(meme.balanceOf(address(position)), 4e18);
	}

	function test_m2_tokensParkedInAPosition_stillCountTowardTheGavCap() public {
		_registerPositionTypes();
		Comptroller c = _fund(false);
		_buyMeme(c, 15_000e6); // 15% of GAV
		// park all of it as limit-order SELL inventory: the vault no longer shows it
		LimitOrderPosition position = _limitOrderPosition(c);
		_keepQuoteFresh();
		_place(c, position, address(meme), address(usdc), _memeHeld(c), 15_000e6, address(meme));
		assertEq(_memeHeld(c), 0);
		// another 10% would put the fund at ~25% TWAP exposure — refused
		_keepQuoteFresh();
		_buyMemeExpectingRevert(c, 10_000e6, abi.encodePacked(TwapExposurePolicy.TwapShareOfGavExceeded.selector));
	}
}
