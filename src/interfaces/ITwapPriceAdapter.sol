// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title ITwapPriceAdapter
/// @notice What every TWAP price adapter exposes (concentrated-liquidity, Uniswap v2, Aerodrome
///         basic), alongside AggregatorV3Interface.
/// @dev Two liquidity reads. Together they are the floor that gates listing and the delist clock
///      (`isBelowFloor()`, Ruling 23): the quote RESERVE ≥ `minLiquidityUsd` AND the −10% band depth
///      ≥ `minBandDepthUsd` (TwapFloor.minBandDepthUsd(minLiquidityUsd): what a full-range pool
///      holding the reserve floor has within −10%). A balance alone is not bids — uncollected
///      fees, removed-but-uncollected liquidity and donations hold a concentrated pool's reserve
///      with nothing near the price. The band depth also sizes exposure caps, the recorded depth
///      and the repoint margin.
///      No `pool()`: each adapter's getter returns its own pool type, which Solidity won't accept
///      as an override of `address`; the registry stores the pool.
interface ITwapPriceAdapter {
	/// @notice The token this adapter prices.
	function asset() external view returns (address);

	/// @notice The pool's other token (USDC or WETH), priced by a Chainlink feed.
	function quoteAsset() external view returns (address);

	/// @notice USD per whole `asset`, reverting guards applied (AggregatorV3 shape).
	function latestRoundData()
		external
		view
		returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

	/// @notice Decimals of `latestRoundData`'s answer.
	function decimals() external view returns (uint8);

	/// @notice USD (18 decimals) of the QUOTE token the pool holds; reverts if the pool can't serve
	///         the TWAP window.
	function quoteReserveUsd() external view returns (uint256);

	/// @notice USD (18 decimals) of quote-token bids within −10% of the price: the floor's second
	///         part, and what exposure caps, the recorded depth and the repoint margin measure.
	function poolDepthUsd() external view returns (uint256);

	/// @notice quoteReserveUsd() < minLiquidityUsd · 1e18 || poolDepthUsd() < minBandDepthUsd · 1e18
	///         (the band is read only when the reserve holds; either read reverting reverts)
	function isBelowFloor() external view returns (bool);
}
