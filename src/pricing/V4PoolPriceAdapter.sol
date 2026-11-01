// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IPoolPriceAdapter} from '../interfaces/IPoolPriceAdapter.sol';
import {IPoolWatch} from '../interfaces/IPoolWatch.sol';
import {V4PriceSampler} from './V4PriceSampler.sol';
import {IV4StateView} from '../interfaces/external/IUniswapV4.sol';
import {TickMath} from '../libraries/TickMath.sol';
import {PoolPriceMath} from '../libraries/PoolPriceMath.sol';

/// @title V4PoolPriceAdapter
/// @notice Prices one asset from its Uniswap v4 pool, which keeps no price history: the median of the
///         V4PriceSampler readings from the last hour (at least four), times the ValueInterpreter's USD price of
///         the pool's other token (WETH for a native-ETH pool). One minimal clone per asset (PoolPriceRegistrarV2);
///         its clone args are abi.encode(Config, V4Extra) (spec 2026-10-08 §4.2).
/// @dev - Under four readings in the window both the price and the liquidity revert NoPriceHistory: a new
///        registration warms up before anyone can buy (the buy-floor policy reads liquidityUsd), and a stopped
///        keeper ends the price within the hour (long-tail rules then pay the token in kind).
///      - Two liquidity figures, each the full-range-equivalent quote reserve (a pool holds no tokens of its own in v4 —
///        the PoolManager does — so there's no balance to read):
///        · `liquidityUsd()` (the $25k buy floor): the lower of the current in-range liquidity and the sampled median —
///          liquidity added right before a buy doesn't count, liquidity pulled counts at once;
///        · the ≈ $0 rule (under $5k the asset answers 1 wei): the sampled median only. v4's flash accounting lets an
///          LP pull and re-add a position inside one transaction for nothing, so a cliff read from the current pool
///          could be dropped for one call — e.g. a depositor's own executeDepositRequest at a GAV without the token
///          (final review 2026-10-08, M1). A real rug therefore reaches 1 wei once half the hour's readings show it.
///        Implements the feed itself rather than PoolPriceAdapterBase, whose single liquidity serves both (that base
///        stays as deployed for today's adapters).
///      - Two readings pumped out of six don't move the median; moving it takes holding the price through at
///        least half the readings, ≈ 30 minutes at the keeper's 10-minute cadence.
contract V4PoolPriceAdapter is IPoolPriceAdapter, IPoolWatch {
	uint32 public constant SAMPLE_WINDOW = 1 hours;
	uint256 public constant MIN_SAMPLES = 4;
	/// @notice Whole USD of sampled pool liquidity under which the asset is valued at ≈ $0 (PoolPriceAdapterBase's).
	uint256 public constant MIN_VALUATION_LIQUIDITY_USD = 5_000;
	uint8 private constant ANSWER_DECIMALS = 18;

	/// @notice Fewer than MIN_SAMPLES readings within SAMPLE_WINDOW (a new registration warming up, or a stopped keeper).
	error NoPriceHistory();

	struct V4Extra {
		V4PriceSampler sampler;
		IV4StateView stateView;
		bytes32 poolId;
	}

	/// @inheritdoc IPoolPriceAdapter
	function config() public view returns (Config memory c) {
		(c,) = abi.decode(Clones.fetchCloneArgs(address(this)), (Config, V4Extra));
	}

	/// @notice The v4 half of the clone args.
	function v4Extra() public view returns (V4Extra memory e) {
		(, e) = abi.decode(Clones.fetchCloneArgs(address(this)), (Config, V4Extra));
	}

	function decimals() external pure returns (uint8) {
		return ANSWER_DECIMALS;
	}

	/// @notice USD per whole asset (18 decimals) at the median of the last hour's readings, stamped with the read's
	///         own time; 1 wei while the sampled liquidity is under MIN_VALUATION_LIQUIDITY_USD or the price rounds to 0.
	function latestRoundData()
		external
		view
		returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
	{
		Config memory c = config();
		(uint256 sampledUsd18,, uint256 price) = _read(c, c.valueInterpreter.calcUsdRate(c.quoteAsset));
		if (sampledUsd18 < MIN_VALUATION_LIQUIDITY_USD * 1e18 || price == 0) price = 1;
		answer = int256(price);
		roundId = uint80(block.timestamp);
		answeredInRound = roundId;
		startedAt = block.timestamp;
		updatedAt = block.timestamp;
	}

	/// @inheritdoc IPoolPriceAdapter
	/// @dev The lower of the sampled median and the pool right now (the buy floor).
	function liquidityUsd() external view returns (uint256) {
		Config memory c = config();
		(uint256 sampledUsd18, uint256 nowUsd18,) = _read(c, c.valueInterpreter.calcUsdRate(c.quoteAsset));
		return nowUsd18 < sampledUsd18 ? nowUsd18 : sampledUsd18;
	}

	/// @inheritdoc IPoolWatch
	/// @dev The pool now against the sampled median, read at a fixed quote price since only the ratio counts (review 2026-11-01).
	///      v4's flash accounting lets a manager's own contract re-add for one call: this stops a plain rug, not that.
	function poolUnsettled() external view returns (bool) {
		(uint256 sampled, uint256 current,) = _read(config(), 1e18);
		return current * 2 < sampled;
	}

	/// @dev The sampled and current liquidity (USD, 18 decimals; current is 0 for a pool gone uninitialized) and the
	///      median price (may round to 0).
	function _read(Config memory c, uint256 quoteUsd18) internal view returns (uint256 sampledUsd18, uint256 nowUsd18, uint256 price) {
		V4Extra memory e = v4Extra();
		(int24 medianTick, uint128 medianLiquidity) = _window(e);
		uint256 sqrtMedian = TickMath.getSqrtRatioAtTick(medianTick);
		uint256 unit = 10 ** c.quoteDecimals;
		sampledUsd18 = Math.mulDiv(PoolPriceMath.quoteReserve(medianLiquidity, sqrtMedian, c.assetIsToken0), quoteUsd18, unit);
		(uint160 sqrtNow,,,) = e.stateView.getSlot0(e.poolId);
		if (sqrtNow != 0) {
			uint256 reserveNow = PoolPriceMath.quoteReserve(e.stateView.getLiquidity(e.poolId), sqrtNow, c.assetIsToken0);
			nowUsd18 = Math.mulDiv(reserveNow, quoteUsd18, unit);
		}
		price = PoolPriceMath.usdPerAssetAtSqrtP(sqrtMedian, c.assetIsToken0, c.assetDecimals, c.quoteDecimals, quoteUsd18);
	}

	/// @dev Median tick (an even count averages the two middles, rounded toward −∞ like Uniswap's mean tick) and
	///      median in-range liquidity (the lower middle) of the readings taken within SAMPLE_WINDOW.
	function _window(V4Extra memory e) internal view returns (int24 medianTick, uint128 medianLiquidity) {
		V4PriceSampler.Sample[] memory all = e.sampler.samples(e.poolId);
		uint256 cutoff = block.timestamp > SAMPLE_WINDOW ? block.timestamp - SAMPLE_WINDOW : 0;
		int24[] memory ticks = new int24[](all.length);
		uint128[] memory liquidities = new uint128[](all.length);
		uint256 n;
		for (uint256 i; i < all.length; ++i) {
			if (all[i].time < cutoff) break; // newest first: everything after is older
			ticks[n] = all[i].tick;
			liquidities[n] = all[i].liquidity;
			++n;
		}
		if (n < MIN_SAMPLES) revert NoPriceHistory();
		_sortTicks(ticks, n);
		_sortLiquidities(liquidities, n);
		if (n % 2 == 1) {
			medianTick = ticks[n / 2];
		} else {
			int256 sum = int256(ticks[n / 2 - 1]) + int256(ticks[n / 2]);
			int256 half = sum / 2;
			if (sum < 0 && sum % 2 != 0) half -= 1;
			medianTick = int24(half);
		}
		medianLiquidity = liquidities[(n - 1) / 2];
	}

	/// @dev Insertion sort of the first `n` entries (n ≤ 12).
	function _sortTicks(int24[] memory a, uint256 n) private pure {
		for (uint256 i = 1; i < n; ++i) {
			int24 v = a[i];
			uint256 j = i;
			while (j > 0 && a[j - 1] > v) {
				a[j] = a[j - 1];
				--j;
			}
			a[j] = v;
		}
	}

	function _sortLiquidities(uint128[] memory a, uint256 n) private pure {
		for (uint256 i = 1; i < n; ++i) {
			uint128 v = a[i];
			uint256 j = i;
			while (j > 0 && a[j - 1] > v) {
				a[j] = a[j - 1];
				--j;
			}
			a[j] = v;
		}
	}
}
