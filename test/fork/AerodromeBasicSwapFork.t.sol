// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Vm} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {IValueInterpreterAdmin} from '../../src/interfaces/IValueInterpreterAdmin.sol';
import {AerodromeBasicSwapAdapter} from '../../src/adapters/AerodromeBasicSwapAdapter.sol';
import {BaseMainnet} from '../../script/release/BaseMainnet.sol';
import {MockAggregator} from '../utils/Mocks.sol';
import {ReleaseFork} from './utils/ReleaseFork.sol';

/// @notice Aerodrome Router 0xcF77…4E43's slippage error (verified Basescan source).
interface IAerodromeRouterErrors {
	error InsufficientOutputAmount();
}

/// @notice Aerodrome PoolFactory 0x420D…40Da (verified Basescan source).
interface IAerodromePoolFactory {
	function getPool(address tokenA, address tokenB, bool stable) external view returns (address);
}

/// @notice An Aerodrome basic pool's reserves and quote (verified Basescan source).
interface IAerodromeBasicPoolQuote {
	function token0() external view returns (address);
	function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);
	/// @dev Takes the pool fee, then x·y=k on the stored reserves: what the router's fee-on-transfer
	///      path pays for `balanceOf(pool) − reserve`.
	function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
}

/// @notice The release's Aerodrome basic swap adapter on a release fund, the real router and real volatile pools, Base
///         fork. These three cases were in V2SwapAdaptersFork (deleted 2026-11-15 with the Uniswap v2 adapter, founder
///         2026-11-16: port them); there they ran on the adapter without the protocol fee, here on the release's, which
///         sends 5 bps of what reached it to the Treasury before the swap:
///         - untaxed: AWE/USDC, bought and sold back at exactly the pool's price for what reached it;
///         - a minimum one unit over that reverts in the ROUTER (the adapter passes it on);
///         - a real taxed token, fBOMB (1% burn on every transfer; 2026-09-30 scan of every DefiLlama Base
///           aerodrome-v1 USDC pool): the Comptroller credits what the vault actually received, and the adapter
///           spends what actually arrived (the router pulls its whole balance);
///         - after every action the adapter holds none of either token and no allowance.
///         Neither pool is one a test here prices from, so each token gets a fixed feed at its pool's spot price at
///         setUp (a fund takes in VI-supported assets only): pricing is not what this test checks.
///         Run: BASE_MAINNET_RPC=<url> forge test --match-path test/fork/AerodromeBasicSwapFork.t.sol -vv
contract AerodromeBasicSwapForkTest is ReleaseFork {
	/// @dev the fixed spot feeds are stamped at setUp; no test moves time this far
	uint32 internal constant FEED_HEARTBEAT = 1 days;
	uint256 internal constant ONE_USDC = 1e6;
	uint256 internal constant BPS = 10_000;

	address internal constant AWE = 0x1B4617734C43F6159F3a70b7E06d883647512778;
	address internal constant FBOMB = 0x74ccbe53F77b08632ce0CB91D3A545bF6B8E0979;

	Comptroller internal fund;
	address internal vault;
	AerodromeBasicSwapAdapter internal basic;
	address internal awePool;
	address internal fbombPool;

	function setUp() public override {
		super.setUp();
		if (!forked) return;
		basic = r.adapters.aerodromeBasic;
		// the volatile pools the adapter's route resolves to (its poolFactory, stable = false)
		awePool = IAerodromePoolFactory(basic.poolFactory()).getPool(AWE, USDC, false);
		fbombPool = IAerodromePoolFactory(basic.poolFactory()).getPool(FBOMB, USDC, false);
		_price(AWE, awePool);
		_price(FBOMB, fbombPool);
		// 10 USDC, as the fund these trades were sized for: a 1 USDC buy that went uncredited would move GAV by 10%
		fund = _fundWithDeposit(10 * ONE_USDC);
		vault = address(fund.vault());
	}

	// ─── untaxed: buy and sell at exactly the pool's quote ───────────────────────

	/// @notice The fund buys 1 USDC of AWE with the exact quote as its minimum, the AWE priced at its pool's spot
	///         keeps GAV whole, and the fund sells it all back.
	function test_fork_aerodromeBasicBuysAndSellsAwe() public {
		vm.skip(!forked);
		uint256 gavBefore = fund.calcGav();

		uint256 quote = _expected(awePool, USDC, _afterFee(ONE_USDC));
		uint256 bought = _trade(USDC, AWE, ONE_USDC, quote, _fee(ONE_USDC));
		assertEq(bought, quote, 'arrives exactly as quoted');
		emit log_named_decimal_uint('AWE bought for 1 USDC (Aerodrome basic)', bought, 18);
		assertApproxEqRel(fund.calcGav(), gavBefore, 0.01e18, 'AWE is credited and priced into GAV');

		uint256 sellQuote = _expected(awePool, AWE, _afterFee(bought));
		uint256 proceeds = _trade(AWE, USDC, bought, sellQuote, _fee(bought));
		assertEq(proceeds, sellQuote, 'sold exactly as quoted');
		assertEq(IERC20(AWE).balanceOf(vault), 0, 'all of it sold');
		emit log_named_decimal_uint('USDC back from selling it (Aerodrome basic)', proceeds, 6);
		assertLt(proceeds, ONE_USDC, 'a round trip pays two pool fees and two protocol fees');
		assertGt(proceeds, ONE_USDC * 99 / 100);
	}

	/// @notice A minimum one unit over the quote reverts in the router itself (the adapter hands the minimum on rather
	///         than leaving it to the Comptroller), and nothing moves.
	function test_fork_overTightMinimumRevertsInTheRouter() public {
		vm.skip(!forked);
		uint256 usdcBefore = IERC20(USDC).balanceOf(vault);
		uint256 treasuryBefore = IERC20(USDC).balanceOf(BaseMainnet.TREASURY);

		uint256 quote = _expected(awePool, USDC, _afterFee(ONE_USDC));
		vm.expectRevert(IAerodromeRouterErrors.InsufficientOutputAmount.selector);
		vm.prank(manager);
		fund.callOnIntegration(address(basic), abi.encode(USDC, AWE, ONE_USDC, quote + 1));

		assertEq(IERC20(USDC).balanceOf(vault), usdcBefore, 'nothing moved');
		assertEq(IERC20(USDC).balanceOf(BaseMainnet.TREASURY), treasuryBefore, 'no fee taken');
		assertEq(IERC20(AWE).balanceOf(vault), 0);
	}

	// ─── a real taxed token ──────────────────────────────────────────────────────

	/// @notice fBOMB burns 1% of every transfer. Buying, the vault is credited the pool's output less 1%. Selling, the
	///         withdrawal to the adapter, the fee's way to the Treasury and the adapter's transfer to the pool are each
	///         1% short, and the router prices exactly what reached the pool.
	function test_fork_aerodromeBasicTaxedFbombIsCreditedAsReceived() public {
		vm.skip(!forked);
		uint256 quote = _expected(fbombPool, USDC, _afterFee(ONE_USDC));
		uint256 bought = _trade(USDC, FBOMB, ONE_USDC, 0, _fee(ONE_USDC));
		assertEq(bought, quote * 99 / 100, 'the pool output less the 1% burn');

		uint256 atAdapter = bought * 99 / 100;
		uint256 atPool = _afterFee(atAdapter) * 99 / 100;
		uint256 expected = _expected(fbombPool, FBOMB, atPool);
		uint256 proceeds = _trade(FBOMB, USDC, bought, expected, _fee(atAdapter) * 99 / 100);
		assertEq(proceeds, expected, 'priced on what reached the pool after two burns');
		assertEq(IERC20(FBOMB).balanceOf(vault), 0, 'all of it sold');
		emit log_named_decimal_uint('fBOMB untaxed quote for 1 USDC', quote, 18);
		emit log_named_decimal_uint('fBOMB credited (after 1% burn)', bought, 18);
		emit log_named_decimal_uint('USDC back from selling it (two burns)', proceeds, 6);
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	/// @dev The fund trades through the adapter; returns what the Comptroller credited, after checking it is the
	///      vault's measured delta, the vault paid exactly amountIn, the Treasury received `treasuryGets` of tokenIn and
	///      the adapter kept nothing.
	function _trade(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint256 treasuryGets)
		internal
		returns (uint256 credited)
	{
		uint256 inBefore = IERC20(tokenIn).balanceOf(vault);
		uint256 outBefore = IERC20(tokenOut).balanceOf(vault);
		uint256 treasuryBefore = IERC20(tokenIn).balanceOf(BaseMainnet.TREASURY);

		vm.recordLogs();
		vm.prank(manager);
		fund.callOnIntegration(address(basic), abi.encode(tokenIn, tokenOut, amountIn, minOut));
		credited = _creditedAmount(vm.getRecordedLogs());

		assertEq(credited, IERC20(tokenOut).balanceOf(vault) - outBefore, 'credited = the vault balance delta');
		assertGe(credited, minOut);
		assertEq(inBefore - IERC20(tokenIn).balanceOf(vault), amountIn, 'the vault paid exactly amountIn');
		assertEq(IERC20(tokenIn).balanceOf(BaseMainnet.TREASURY) - treasuryBefore, treasuryGets, 'the protocol fee reached the Treasury');
		assertEq(IERC20(tokenIn).balanceOf(address(basic)), 0, 'no tokenIn left in the adapter');
		assertEq(IERC20(tokenOut).balanceOf(address(basic)), 0, 'no tokenOut left in the adapter');
		assertEq(IERC20(tokenIn).allowance(address(basic), address(basic.router())), 0, 'no allowance left to the router');
	}

	function _creditedAmount(Vm.Log[] memory logs) internal view returns (uint256) {
		for (uint256 i; i < logs.length; i++) {
			if (
				logs[i].emitter == address(fund) && logs[i].topics[0] == Comptroller.CallOnIntegrationExecuted.selector
					&& logs[i].topics[1] == bytes32(uint256(uint160(address(basic))))
			) {
				(,,, uint256[] memory incomingAmounts) = abi.decode(logs[i].data, (address[], uint256[], address[], uint256[]));
				return incomingAmounts[0];
			}
		}
		revert('no CallOnIntegrationExecuted');
	}

	/// @dev The protocol fee on `amount` reaching the adapter (ProtocolFeeAdapter._takeFee), and what is left to swap.
	function _fee(uint256 amount) internal view returns (uint256) {
		return amount * basic.feeBps() / BPS;
	}

	function _afterFee(uint256 amount) internal view returns (uint256) {
		return amount - _fee(amount);
	}

	/// @dev What the router's fee-on-transfer path pays when `arrives` of `tokenIn` reaches `pool`: the pool's own
	///      getAmountOut (pool fee, then x·y=k on the stored reserves) of balanceOf(pool) − reserve, any earlier
	///      excess included.
	function _expected(address pool, address tokenIn, uint256 arrives) internal view returns (uint256) {
		(uint256 r0, uint256 r1,) = IAerodromeBasicPoolQuote(pool).getReserves();
		uint256 rIn = IAerodromeBasicPoolQuote(pool).token0() == tokenIn ? r0 : r1;
		return IAerodromeBasicPoolQuote(pool).getAmountOut(IERC20(tokenIn).balanceOf(pool) - rIn + arrives, tokenIn);
	}

	/// @dev A primitive for `asset` on the release's VI, on a fixed 8-dp USD feed at `pool`'s spot price (USDC ≈ $1).
	function _price(address asset, address pool) internal {
		(uint256 r0, uint256 r1,) = IAerodromeBasicPoolQuote(pool).getReserves();
		(uint256 assetReserve, uint256 usdcReserve) = IAerodromeBasicPoolQuote(pool).token0() == asset ? (r0, r1) : (r1, r0);
		uint256 answer = usdcReserve * 10 ** IERC20Metadata(asset).decimals() * 1e8 / (assetReserve * 1e6);
		MockAggregator feed = new MockAggregator(8, int256(answer));
		r.registrar.execute(abi.encodeCall(IValueInterpreterAdmin.addPrimitive, (asset, address(feed), FEED_HEARTBEAT)));
	}
}
