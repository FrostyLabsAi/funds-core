// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {IPoolPriceAdapter} from '../interfaces/IPoolPriceAdapter.sol';

/// @title PoolPriceAdapterBase
/// @notice What every pool price adapter shares: the clone config, the feed shape, and the rule
///         that a pool under MIN_VALUATION_LIQUIDITY_USD values its asset at 1 wei (≈ $0; the VI
///         refuses an exact 0) — an abandoned or rugged pool's price can be set by anyone, so its
///         token counts as worthless until liquidity returns. A price that rounds to 0 also
///         answers 1 wei. Nothing about how far or how fast the price moves ever reverts.
/// @dev The quote token's USD price comes from the ValueInterpreter (a Chainlink primitive), so a
///      stale quote feed reverts here exactly as it would for the quote token itself.
abstract contract PoolPriceAdapterBase is IPoolPriceAdapter {
	uint32 public constant WINDOW = 30 minutes;
	/// @notice Whole USD of pool liquidity under which the asset is valued at ≈ $0.
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

	/// @notice USD per whole asset (18 decimals), stamped with the read's own time.
	function latestRoundData()
		external
		view
		returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
	{
		Config memory c = config();
		(uint256 liquidity, uint256 price) = _read(c, c.valueInterpreter.calcUsdRate(c.quoteAsset));
		if (liquidity < MIN_VALUATION_LIQUIDITY_USD * 1e18 || price == 0) price = 1;

		answer = int256(price);
		roundId = uint80(block.timestamp);
		answeredInRound = roundId;
		startedAt = block.timestamp;
		updatedAt = block.timestamp;
	}

	/// @inheritdoc IPoolPriceAdapter
	function liquidityUsd() external view returns (uint256 liquidity) {
		Config memory c = config();
		(liquidity,) = _read(c, c.valueInterpreter.calcUsdRate(c.quoteAsset));
	}

	/// @dev The pool's liquidity (see IPoolPriceAdapter.liquidityUsd) and the asset's window price,
	///      both USD with 18 decimals; the price may round to 0.
	function _read(Config memory c, uint256 quoteUsd18) internal view virtual returns (uint256 liquidityUsd18, uint256 priceUsd18);
}
