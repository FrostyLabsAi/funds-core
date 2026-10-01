// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {TwapAggregatorAdapterV2} from '../src/pricing/TwapAggregatorAdapterV2.sol';
import {TwapAggregatorAdapter, IConcentratedPoolOracle} from '../src/pricing/TwapAggregatorAdapter.sol';
import {AggregatorV3Interface} from '../src/interfaces/AggregatorV3Interface.sol';
import {IUniswapV3NonfungiblePositionManager} from
	'../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';

/// @notice The Uniswap v3 pool reads the test needs beyond the adapter's oracle surface.
interface IUniswapV3PoolState {
	function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
	function fee() external view returns (uint24);
}

/// @notice Quote-side depth on real Base pools: a two-sided pool keeps a real depth; LUMIA's
///         one-sided pool (0.98 WETH vs 150M LUMIA) collapses to its ~$2.6k of WETH. A quote-only
///         position minted through the real NonfungiblePositionManager moves the depth by exactly
///         its USD value in both orientations (asset = token1 and asset = token0).
///         Run: BASE_MAINNET_RPC=<url> [BASE_FORK_BLOCK=<n>] forge test --match-path test/TwapAggregatorAdapterV2Fork.t.sol -vv
contract TwapAggregatorAdapterV2ForkTest is Test {
	address internal constant WETH = 0x4200000000000000000000000000000000000006;
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant ETH_USD = 0x50015f8b17fb2C290Dde41fDc246ed0dcEE93a8b; // standard proxy
	address internal constant USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
	address internal constant LUMIA = 0x550161Ae735DebeE90Ba117025db0E83131bf9A6;
	address internal constant LUMIA_POOL = 0x36523a7A21139e0D85D1d3BA69E9F8Aa9A5bD185; // UniV3 0.3% vs WETH
	address internal constant VIRTUAL = 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b;
	address internal constant VIRTUAL_POOL = 0x529d2863a1521d0b57db028168fdE2E97120017C; // UniV3 0.3% vs USDC
	// Uniswap v3 NPM on Base: factory() = both pools' factory 0x33128a8f…F6FDfD, WETH9() = WETH (cast, 2026-09-30)
	address internal constant NPM = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
	// Quote-token wei the depth delta may differ from the minted amount by. Only rounding separates
	// them: the pool rounds the paid amount up (≤ 1 wei), the band walk rounds each segment down
	// (≤ 1 wei each), and the position's two new ticks split two existing segments. At spacing 60
	// the 2007-tick band holds at most 34 initialized ticks, so the error is < 40 wei; 100 wei is
	// $0.0001 of USDC and ~$3e-13 of WETH.
	uint256 internal constant ROUNDING_WEI = 100;

	bool internal forked;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		uint256 blockNumber = vm.envOr('BASE_FORK_BLOCK', uint256(0));
		if (blockNumber > 0) vm.createSelectFork(rpc, blockNumber);
		else vm.createSelectFork(rpc);
		forked = true;
	}

	function _pair(address pool, address asset, address feed, uint32 hb)
		internal
		returns (TwapAggregatorAdapter v1, TwapAggregatorAdapterV2 v2)
	{
		v1 = new TwapAggregatorAdapter(IConcentratedPoolOracle(pool), asset, AggregatorV3Interface(feed), 30 minutes, 50_000, 500, hb, 'v1');
		v2 = new TwapAggregatorAdapterV2(IConcentratedPoolOracle(pool), asset, AggregatorV3Interface(feed), 30 minutes, 50_000, 500, hb, 'v2');
	}

	function test_fork_oneSidedPoolIsShallow() public {
		vm.skip(!forked);
		(TwapAggregatorAdapter v1, TwapAggregatorAdapterV2 v2) = _pair(LUMIA_POOL, LUMIA, ETH_USD, 3600);
		assertGt(v1.poolDepthUsd(), 1_000_000e18, 'v1 counts the self-priced asset side');
		assertLt(v2.poolDepthUsd(), 10_000e18, 'v2 counts only the WETH side');
		assertGt(v2.poolDepthUsd(), 1_000e18, 'the real WETH side still counts');
		assertTrue(v2.isBelowFloor());
	}

	function test_fork_twoSidedPoolKeepsDepth() public {
		vm.skip(!forked);
		(, TwapAggregatorAdapterV2 v2) = _pair(VIRTUAL_POOL, VIRTUAL, USDC_USD, 90_000);
		assertGt(v2.poolDepthUsd(), 50_000e18, 'real USDC bids within 10%');
		assertFalse(v2.isBelowFloor());
		(, int256 answer,,,) = v2.latestRoundData();
		assertGt(answer, 0);
	}

	function test_fork_quoteSideNeverExceedsTwoSided() public {
		vm.skip(!forked);
		(TwapAggregatorAdapter v1, TwapAggregatorAdapterV2 v2) = _pair(VIRTUAL_POOL, VIRTUAL, USDC_USD, 90_000);
		assertLt(v2.poolDepthUsd(), v1.poolDepthUsd(), 'the VIRTUAL side is not counted');
	}

	/// @notice asset = token1 (LUMIA; WETH is token0): a WETH-only position above spot.
	function test_fork_quotePositionMovesDepth_assetToken1() public {
		vm.skip(!forked);
		(, TwapAggregatorAdapterV2 v2) = _pair(LUMIA_POOL, LUMIA, ETH_USD, 3600);
		assertFalse(v2.assetIsToken0());
		_assertDepthTracksQuotePosition(v2, ETH_USD, 1 ether);
	}

	/// @notice asset = token0 (VIRTUAL; USDC is token1): a USDC-only position below spot.
	function test_fork_quotePositionMovesDepth_assetToken0() public {
		vm.skip(!forked);
		(, TwapAggregatorAdapterV2 v2) = _pair(VIRTUAL_POOL, VIRTUAL, USDC_USD, 90_000);
		assertTrue(v2.assetIsToken0());
		_assertDepthTracksQuotePosition(v2, USDC_USD, 10_000e6);
	}

	/// @dev Mints `quoteIn` of the quote token as an out-of-range position inside the band, checks
	///      the depth rises by its USD value, burns it, and checks the depth returns exactly. The
	///      position is out of range, so the TWAP and harmonic-mean legs cannot move; the current
	///      band leg must bind before and after, or the delta would not show.
	function _assertDepthTracksQuotePosition(TwapAggregatorAdapterV2 v2, address feed, uint256 quoteIn) internal {
		uint256 before = v2.poolDepthUsd();
		assertEq(before, v2.spotBandDepthUsd(), 'current band leg binds before');

		(uint256 tokenId, uint128 liquidity, uint256 quotePaid) = _mintQuoteOnly(v2, quoteIn);
		uint256 quoteUsd18 = _quoteUsd18(feed);
		uint256 unit = 10 ** IERC20Metadata(v2.quoteAsset()).decimals();
		uint256 positionUsd = Math.mulDiv(quotePaid, quoteUsd18, unit);
		uint256 during = v2.poolDepthUsd();
		assertEq(during, v2.spotBandDepthUsd(), 'current band leg binds during');

		emit log_named_decimal_uint('depth before      ', before, 18);
		emit log_named_decimal_uint('position USD      ', positionUsd, 18);
		emit log_named_decimal_uint('depth delta       ', during - before, 18);
		assertApproxEqAbs(during - before, positionUsd, Math.mulDiv(ROUNDING_WEI, quoteUsd18, unit) + 1);

		_burn(tokenId, liquidity);
		emit log_named_decimal_uint('depth after burn  ', v2.poolDepthUsd(), 18);
		assertEq(v2.poolDepthUsd(), before, 'depth returns after burn');
	}

	/// @dev Ten tick spacings just past spot on the quote side: above spot holds only token0,
	///      below only token1. With spacing 60 the range stays within +660 / −660 ticks of spot,
	///      inside the +953 / −1054 band.
	function _quoteOnlyRange(TwapAggregatorAdapterV2 v2) internal view returns (int24 lo, int24 hi) {
		address pool = address(v2.pool());
		(, int24 spot,,,,,) = IUniswapV3PoolState(pool).slot0();
		int24 spacing = IConcentratedPoolOracle(pool).tickSpacing();
		int24 c = spot / spacing;
		if (spot < 0 && spot % spacing != 0) c--;
		if (v2.assetIsToken0()) {
			hi = c * spacing;
			lo = hi - 10 * spacing;
		} else {
			lo = (c + 1) * spacing;
			hi = lo + 10 * spacing;
		}
	}

	function _mintQuoteOnly(TwapAggregatorAdapterV2 v2, uint256 quoteIn)
		internal
		returns (uint256 tokenId, uint128 liquidity, uint256 quotePaid)
	{
		(int24 lo, int24 hi) = _quoteOnlyRange(v2);
		bool quoteIsToken0 = !v2.assetIsToken0();
		deal(v2.quoteAsset(), address(this), quoteIn);
		IERC20(v2.quoteAsset()).approve(NPM, quoteIn);
		uint256 paid0;
		uint256 paid1;
		(tokenId, liquidity, paid0, paid1) = IUniswapV3NonfungiblePositionManager(NPM).mint(
			IUniswapV3NonfungiblePositionManager.MintParams({
				token0: quoteIsToken0 ? v2.quoteAsset() : v2.asset(),
				token1: quoteIsToken0 ? v2.asset() : v2.quoteAsset(),
				fee: IUniswapV3PoolState(address(v2.pool())).fee(),
				tickLower: lo,
				tickUpper: hi,
				amount0Desired: quoteIsToken0 ? quoteIn : 0,
				amount1Desired: quoteIsToken0 ? 0 : quoteIn,
				amount0Min: 0,
				amount1Min: 0,
				recipient: address(this),
				deadline: block.timestamp
			})
		);
		assertEq(quoteIsToken0 ? paid1 : paid0, 0, 'quote-only position');
		quotePaid = quoteIsToken0 ? paid0 : paid1;
	}

	function _burn(uint256 tokenId, uint128 liquidity) internal {
		IUniswapV3NonfungiblePositionManager npm = IUniswapV3NonfungiblePositionManager(NPM);
		npm.decreaseLiquidity(
			IUniswapV3NonfungiblePositionManager.DecreaseLiquidityParams({
				tokenId: tokenId, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
			})
		);
		npm.collect(
			IUniswapV3NonfungiblePositionManager.CollectParams({
				tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
			})
		);
		npm.burn(tokenId);
	}

	function _quoteUsd18(address feed) internal view returns (uint256) {
		(, int256 answer,,,) = AggregatorV3Interface(feed).latestRoundData();
		return SafeCast.toUint256(answer) * 10 ** (18 - AggregatorV3Interface(feed).decimals());
	}
}
