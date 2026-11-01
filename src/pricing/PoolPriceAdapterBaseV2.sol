// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {IPoolPriceAdapter} from '../interfaces/IPoolPriceAdapter.sol';
import {IPoolWatch} from '../interfaces/IPoolWatch.sol';

/// @title PoolPriceAdapterBaseV2
/// @notice PoolPriceAdapterBase with two liquidity figures, as V4PoolPriceAdapter has (final review 2026-10-08, M1):
///         - the ≈ $0 rule (under MIN_VALUATION_LIQUIDITY_USD the asset answers 1 wei) reads the window's liquidity only;
///         - `liquidityUsd()` (MinPoolLiquidityPolicy's $25k buy floor) stays the lower of the window's and the pool's now.
///         A cliff read from the pool's current quote balance could be dropped for one call: a flash of the pool's quote
///         token made the adapter answer 1 wei inside the flash, so a depositor executed their own request at a GAV
///         without the token, or a manager settled the queue short (red-team PRICING-POOL-01 + EXITS-01, 2026-10-27).
///         A real rug still reaches 1 wei once the window's liquidity shows it. Everything else is PoolPriceAdapterBase's,
///         which stays as deployed for the registrars' existing clones.
abstract contract PoolPriceAdapterBaseV2 is IPoolPriceAdapter, IPoolWatch {
	uint32 public constant WINDOW = 30 minutes;
	/// @notice Whole USD of windowed pool liquidity under which the asset is valued at ≈ $0.
	uint256 public constant MIN_VALUATION_LIQUIDITY_USD = 5_000;
	uint8 private constant ANSWER_DECIMALS = 18;

	/// @notice The pool has no observation older than this block (a just-created pool, for one block).
	error NoPriceHistory();

	/// @inheritdoc IPoolPriceAdapter
	function config() public view returns (Config memory) {
		return abi.decode(Clones.fetchCloneArgs(address(this)), (Config));
	}

	function decimals() external pure returns (uint8) {
		return ANSWER_DECIMALS;
	}

	/// @notice USD per whole asset (18 decimals), stamped with the read's own time; 1 wei while the window's liquidity is
	///         under MIN_VALUATION_LIQUIDITY_USD or the price rounds to 0.
	function latestRoundData()
		external
		view
		returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
	{
		Config memory c = config();
		(uint256 windowed,, uint256 price) = _read(c, c.valueInterpreter.calcUsdRate(c.quoteAsset));
		if (windowed < MIN_VALUATION_LIQUIDITY_USD * 1e18 || price == 0) price = 1;

		answer = int256(price);
		roundId = uint80(block.timestamp);
		answeredInRound = roundId;
		startedAt = block.timestamp;
		updatedAt = block.timestamp;
	}

	/// @inheritdoc IPoolPriceAdapter
	/// @dev The lower of the window's liquidity and the pool's now (the buy floor): liquidity added right before a buy
	///      doesn't count, liquidity pulled counts at once.
	function liquidityUsd() external view returns (uint256) {
		Config memory c = config();
		(uint256 windowed, uint256 current,) = _read(c, c.valueInterpreter.calcUsdRate(c.quoteAsset));
		return current < windowed ? current : windowed;
	}

	/// @inheritdoc IPoolWatch
	function poolUnsettled() external view returns (bool) {
		return _poolUnsettled(config());
	}

	/// @dev Reads liquidity against liquidity, with no USD price, so a stale quote feed can't make it revert on its own.
	function _poolUnsettled(Config memory c) internal view virtual returns (bool);

	/// @dev The window's and the current quote-side liquidity, and the asset's window price, all USD with 18 decimals; the
	///      price may round to 0.
	function _read(Config memory c, uint256 quoteUsd18)
		internal
		view
		virtual
		returns (uint256 windowedUsd18, uint256 currentUsd18, uint256 priceUsd18);
}
