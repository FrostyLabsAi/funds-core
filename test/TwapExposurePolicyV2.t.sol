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
import {TwapListingRegistryV2} from '../src/pricing/TwapListingRegistryV2.sol';
import {TwapAggregatorAdapterV2} from '../src/pricing/TwapAggregatorAdapterV2.sol';
import {ITwapPriceAdapter} from '../src/interfaces/ITwapPriceAdapter.sol';
import {TickMath} from '../src/libraries/TickMath.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {TwapExposurePolicyV2} from '../src/policies/TwapExposurePolicyV2.sol';
import {MockERC20, MockAggregator, MockSwapRouter, MockUniV3PositionManager} from './utils/Mocks.sol';
import {LimitOrderPosition, LimitOrderPositionFactory} from '../src/positions/LimitOrderPosition.sol';
import {UniswapV3LPPositionFactory} from '../src/positions/UniswapV3LPPosition.sol';
import {IUniswapV3NonfungiblePositionManager} from '../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {ScriptedPool} from './TwapAggregatorAdapter.t.sol';
import {ScriptedFactory} from './TwapListingRegistry.t.sol';
import {TestVenues} from './TwapListingRegistryV2.t.sol';

/// @notice The exposure limits on a real fund: MEME ($2,500, TWAP-listed) bought and sold
///         through the Uniswap adapter. V2 depth is the QUOTE side only (USDC within −10% of the
///         price; MEME is token0) and linear in liquidity: L = 1e18 → $2,566,602, closed form
///         L·(√P − √(0.9·P)) — v1's two-sided $4,893,076 is 1.906× that. v1's liquidities are
///         scaled ×1.9 so every scenario keeps v1's dollar depths: L = 7.6e16 → $195,062.
///         The floor is the QUOTE RESERVE (the pool's USDC balance, $25k). The scripted pool's
///         liquidity is flat from spot down to zero, so `_setPool` gives it exactly the USDC that
///         liquidity holds, L·√P (≈ 19.5× the band): $95.0M at L_DEEP, $3.80M at L_SMALL. "Under
///         the floor" (v1: $48.8k of depth under $50k) is L = 4.75e14: $23,750 of USDC, a $1,219 band.
contract TwapExposurePolicyV2Test is Test {
	int24 internal constant TICK_2500 = -198_080;
	uint128 internal constant L_DEEP = 1.9e18; // $4.88M depth → 50% cap
	uint128 internal constant L_SMALL = 7.6e16; // $195.1k depth → 10% cap ($19.5k)
	uint128 internal constant L_UNDER = 4.75e14; // $23.75k of USDC held → under the $25k reserve floor

	ValueInterpreter internal vi;
	MockERC20 internal meme;
	MockERC20 internal usdc;
	MockAggregator internal usdcFeed;
	ScriptedPool internal pool;
	TwapListingRegistryV2 internal registry;
	TwapExposurePolicyV2 internal policy;
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
		_setPool(L_DEEP);
		uni.setUni(address(meme), address(usdc), 3000, address(pool));
		registry = new TwapListingRegistryV2(
			TestVenues.build(
				IValueInterpreter(address(vi)),
				address(uni),
				address(new ScriptedFactory()),
				address(new ScriptedFactory()),
				address(new ScriptedFactory()),
				makeAddr('uniV2'),
				makeAddr('aero')
			)
		);
		registry.setQuote(address(usdc), AggregatorV3Interface(address(usdcFeed)), 2 days);
		registry.setLister(address(this), true); // v2 listers are explicit (the module in production)
		ITwapPriceAdapter adapter = registry.list(address(meme), address(usdc), TwapListingRegistryV2.Venue.UniswapV3, 3000);
		vi.addPrimitive(address(meme), address(adapter), 1 hours); // the VI owner's step
		policy = new TwapExposurePolicyV2(registry);

		factory = new FundFactory(vi, new ComptrollerDeployer(), new SharesVaultDeployer());
		router = new MockSwapRouter();
		uniAdapter = new UniswapV3SwapAdapter(IUniswapV3SwapRouter(address(router)));
		factory.registerAdapter(address(uniAdapter));
		usdc.mint(alice, 1_000_000e6);
		usdc.mint(bob, 1_000_000e6);
	}

	// ─── helpers ────────────────────────────────────────────────────────────────

	/// @dev Script the pool's liquidity at $2,500 and give it the USDC that flat liquidity holds
	///      from spot down to zero: L·√P (USDC is token1).
	function _setPool(uint128 liquidity) internal {
		pool.set(TICK_2500, TICK_2500, liquidity);
		deal(address(usdc), address(pool), Math.mulDiv(liquidity, TickMath.getSqrtRatioAtTick(TICK_2500), 1 << 96));
	}

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
		_buyMemeExpectingRevert(c, 25_000e6, abi.encodePacked(TwapExposurePolicyV2.TwapShareOfGavExceeded.selector));
	}

	// ─── per-pool caps ──────────────────────────────────────────────────────────

	function test_smallPool_capsAtTenPercentOfDepth() public {
		Comptroller c = _fund(false);
		_setPool(L_SMALL); // $195.1k depth → $19.51k cap
		_buyMemeExpectingRevert(c, 20_000e6, abi.encodePacked(TwapExposurePolicyV2.PoolShareExceeded.selector));
		_buyMeme(c, 19_000e6);
	}

	function test_largePool_capsAtFiftyPercentOfDepth() public {
		// a bigger fund, so the 20%-of-GAV rule does not bind first: $10M GAV, $2M allowed by
		// GAV; pool $4.88M → 50% = $2.44M allowed by depth
		Comptroller c = _fund(false);
		usdc.mint(bob, 9_900_000e6);
		_deposit(c, bob, 9_900_000e6);
		_buyMeme(c, 1_900_000e6);
		_setPool(1.33e18); // depth $3.41M → cap $1.71M, holding $1.9M
		_buyMemeExpectingRevert(c, 10_000e6, abi.encodePacked(TwapExposurePolicyV2.PoolShareExceeded.selector));
	}

	// ─── exits are never blocked ────────────────────────────────────────────────

	function test_sellingIsNeverBlocked_evenOverACap() public {
		Comptroller c = _fund(false);
		_buyMeme(c, 15_000e6);
		_setPool(1.9e15); // depth $4.9k → cap $488, holding $15k
		_sellMeme(c, 3e18); // partial exit, still way over the cap — allowed
		_sellMeme(c, 3e18);
		assertEq(_memeHeld(c), 0);
	}

	// ─── the 72-hour delisting ──────────────────────────────────────────────────

	function test_delisted_pausesDepositsButNotRedemptions_untilSold() public {
		Comptroller c = _fund(false);
		_buyMeme(c, 15_000e6);

		_setPool(L_UNDER);
		registry.pokeFloor(address(meme));
		skip(72 hours);
		_keepQuoteFresh();
		assertTrue(registry.isDelisted(address(meme)));

		// new deposits pause…
		vm.startPrank(bob);
		usdc.approve(address(c), 1_000e6);
		vm.expectRevert(abi.encodeWithSelector(TwapExposurePolicyV2.DepositsPausedDelistedHolding.selector, address(meme)));
		c.requestDeposit(1_000e6);
		vm.stopPrank();

		// …redemptions do not, and still price MEME at the market (no haircut)
		uint256 gav = c.calcGav();
		assertApproxEqRel(gav, 100_000e6, 0.001e18);
		uint256 shares = IERC20(address(c.shares())).balanceOf(alice) / 10;
		vm.prank(alice);
		c.redeemSharesForDenominationAsset(shares);

		// …buying more of it is refused…
		_buyMemeExpectingRevert(c, 100e6, abi.encodeWithSelector(TwapExposurePolicyV2.BuyingDelistedAsset.selector, address(meme)));

		// …and selling it lifts the pause
		_sellMeme(c, _memeHeld(c));
		_deposit(c, bob, 1_000e6);
	}

	function test_delisted_before72h_nothingPauses() public {
		Comptroller c = _fund(false);
		_buyMeme(c, 15_000e6);
		_setPool(L_UNDER);
		registry.pokeFloor(address(meme));
		skip(71 hours);
		_keepQuoteFresh();
		_deposit(c, bob, 1_000e6);
	}

	function test_delisted_fundsNotHoldingItAreUnaffected() public {
		Comptroller c = _fund(false);
		_setPool(L_UNDER);
		registry.pokeFloor(address(meme));
		skip(72 hours);
		_keepQuoteFresh();
		_deposit(c, bob, 1_000e6);
	}

	// ─── degen funds: community takeover ────────────────────────────────────────

	function test_degenFund_skipsTheCaps() public {
		Comptroller c = _fund(true);
		_setPool(L_SMALL); // $19.51k pool cap for a standard fund
		_buyMeme(c, 60_000e6); // 60% of GAV, 3× the pool cap
		assertEq(_memeHeld(c), 24e18);
	}

	function test_degenFund_stillGetsTheDepositPause() public {
		Comptroller c = _fund(true);
		_buyMeme(c, 60_000e6);
		_setPool(L_UNDER);
		registry.pokeFloor(address(meme));
		skip(72 hours);
		_keepQuoteFresh();
		vm.startPrank(bob);
		usdc.approve(address(c), 1_000e6);
		vm.expectRevert(abi.encodeWithSelector(TwapExposurePolicyV2.DepositsPausedDelistedHolding.selector, address(meme)));
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
		_buyMemeExpectingRevert(bare, 25_000e6, abi.encodePacked(TwapExposurePolicyV2.TwapShareOfGavExceeded.selector));
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
		vm.expectRevert(abi.encodeWithSelector(TwapExposurePolicyV2.TwapAssetInExternalPosition.selector, address(meme)));
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
		vm.expectRevert(abi.encodeWithSelector(TwapExposurePolicyV2.TwapAssetInExternalPosition.selector, address(meme)));
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
		_buyMemeExpectingRevert(c, 10_000e6, abi.encodePacked(TwapExposurePolicyV2.TwapShareOfGavExceeded.selector));
	}

	// ─── flash liquidity (amendment A): live depth over the recorded one lifts nothing ─

	function test_capUsesLowerOfLiveAndRecorded() public {
		Comptroller c = _fund(false);
		// the keeper (a lister) last sampled a small pool: $195.1k recorded
		_setPool(L_SMALL);
		registry.pokeFloor(address(meme));
		uint256 recorded = registry.recordedDepthUsd18(address(meme));
		// then liquidity is added the way a same-transaction mint would: live depth $4.88M
		_setPool(L_DEEP);
		uint256 live = TwapAggregatorAdapterV2(registry.adapterOf(address(meme))).poolDepthUsd();
		assertGt(live, 20 * recorded, 'live depth now far above the recorded one');

		// the cap stays 10% of the RECORDED depth ($19.51k), not 50% of live ($2.44M)
		uint256 holdingUsd18 = (vi.calcUsdRate(address(meme)) * 8e18) / 1e18; // $20k buys 8 MEME
		uint256 capUsd18 = (recorded * policy.SMALL_POOL_CAP_BPS()) / policy.BPS();
		_buyMemeExpectingRevert(
			c,
			20_000e6,
			abi.encodeWithSelector(TwapExposurePolicyV2.PoolShareExceeded.selector, address(meme), holdingUsd18, capUsd18)
		);

		// only a lister re-sampling the deeper pool records it, and only then does the cap lift
		registry.pokeFloor(address(meme));
		assertEq(registry.recordedDepthUsd18(address(meme)), live);
		_buyMeme(c, 20_000e6);
		assertEq(_memeHeld(c), 8e18);
	}
}
