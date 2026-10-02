// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice The Uniswap v2 pair views the recorder and the adapter read, verified with cast on Base
///         against pairs of factory 0x8909…8eC6 (verified UniswapV2Pair source, Solidity 0.5.16).
interface IUniswapV2Pair {
	function token0() external view returns (address);

	function token1() external view returns (address);

	/// @notice `blockTimestampLast` is block.timestamp mod 2^32 at the pair's last update.
	function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

	/// @notice Σ (reserve1 / reserve0 as UQ112x112) × seconds up to `blockTimestampLast`; wraps mod
	///         2^256 by design.
	function price0CumulativeLast() external view returns (uint256);

	/// @notice Σ (reserve0 / reserve1 as UQ112x112) × seconds up to `blockTimestampLast`; wraps mod
	///         2^256 by design.
	function price1CumulativeLast() external view returns (uint256);
}

/// @title UniswapV2ObservationRecorder
/// @notice Keeps the price history a Uniswap v2 pair doesn't: a ring of the pair's cumulative prices
///         per pair, written by anyone at most once per MIN_SPACING. Permissionless and ownerless.
/// @dev A keeper calls `record` every 10–15 minutes; anyone may. A snapshot is the pair's cumulative
///      prices at `block.timestamp`, computed counterfactually as UniswapV2OracleLibrary does, so it
///      depends only on prices held BEFORE this second: a swap in the recording block (before or
///      after the call) can't move it.
///      Spam can't flush the window: with MIN_SPACING 10 min and RING 16, the oldest kept snapshot is
///      ≥ 150 min older than the newest, so once there are 30 minutes of history a snapshot at least
///      30 minutes old always exists (test_spamCannotStarveWindow).
///      Wrap: the cumulatives wrap mod 2^256 and the pair's timestamps are uint32 (mod 2^32), both by
///      design; every add and delta here is `unchecked` and exact as long as the true span is under
///      2^32 seconds (136 years), since a true cumulative delta is then below 2^224 × 2^32 = 2^256.
contract UniswapV2ObservationRecorder {
	uint32 public constant MIN_SPACING = 10 minutes;
	uint8 public constant RING = 16;

	struct Snapshot {
		uint256 price0Cumulative;
		uint256 price1Cumulative;
		/// @dev block.timestamp mod 2^32, as the pair keeps it
		uint32 timestamp;
	}

	mapping(address pair => Snapshot[16]) internal ring;
	/// @notice Ring slot of the pair's newest snapshot (meaningful once `count` > 0).
	mapping(address pair => uint8) public head;
	/// @notice Snapshots held for the pair, at most RING.
	mapping(address pair => uint8) public count;

	event Recorded(address indexed pair, uint32 timestamp);

	error ZeroReserves(address pair);
	error NoSnapshot(address pair);

	/// @notice Store the pair's counterfactual cumulative prices now; a no-op (returns false) within
	///         MIN_SPACING of the pair's last snapshot. Reverts on a pair with a zero reserve.
	function record(address pair) external returns (bool recorded) {
		uint8 n = count[pair];
		uint8 h = head[pair];
		uint32 now32 = _now32();
		if (n != 0) {
			// wrap-safe: the uint32 delta is exact across 2^32
			unchecked {
				if (now32 - ring[pair][h].timestamp < MIN_SPACING) return false;
			}
			h = (h + 1) % RING;
		}
		(uint256 price0Cumulative, uint256 price1Cumulative,) = currentCumulativePrices(pair);
		ring[pair][h] = Snapshot({price0Cumulative: price0Cumulative, price1Cumulative: price1Cumulative, timestamp: now32});
		head[pair] = h;
		if (n < RING) count[pair] = n + 1;
		emit Recorded(pair, now32);
		return true;
	}

	/// @notice Newest snapshot at least `minAge` seconds old; reverts NoSnapshot(pair) if none.
	/// @dev Walks back from the newest, reading only each timestamp until one qualifies.
	function snapshotAtLeast(address pair, uint32 minAge) external view returns (Snapshot memory) {
		uint8 n = count[pair];
		uint8 h = head[pair];
		uint32 now32 = _now32();
		for (uint8 i; i < n; ++i) {
			uint8 slot = (h + RING - i) % RING;
			unchecked {
				if (now32 - ring[pair][slot].timestamp >= minAge) return ring[pair][slot];
			}
		}
		revert NoSnapshot(pair);
	}

	/// @notice UniswapV2OracleLibrary.currentCumulativePrices, written for 0.8: the pair's
	///         cumulatives plus the current reserves' price × (now − blockTimestampLast) when time has
	///         passed since its last update, with uint32 time and wrapping (unchecked) adds.
	/// @dev The library's price is FixedPoint.fraction(reserve1, reserve0) = (reserve1 << 112) /
	///      reserve0 for uint112 reserves, the same value the pair's own `_update` accrues
	///      (UQ112x112.encode(reserve1).uqdiv(reserve0)); each term is < 2^224 × 2^32, so only the add
	///      wraps. One deliberate difference: a zero reserve reverts ZeroReserves even when no time
	///      has passed (the library returns the stored cumulatives then, and reverts or accrues 0 when
	///      time has passed); a pair with an empty side has no price to record or read.
	function currentCumulativePrices(address pair)
		public
		view
		returns (uint256 price0Cumulative, uint256 price1Cumulative, uint32 timestamp)
	{
		timestamp = _now32();
		price0Cumulative = IUniswapV2Pair(pair).price0CumulativeLast();
		price1Cumulative = IUniswapV2Pair(pair).price1CumulativeLast();
		(uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = IUniswapV2Pair(pair).getReserves();
		if (reserve0 == 0 || reserve1 == 0) revert ZeroReserves(pair);
		if (blockTimestampLast != timestamp) {
			unchecked {
				uint32 timeElapsed = timestamp - blockTimestampLast; // wraps by design
				price0Cumulative += ((uint256(reserve1) << 112) / reserve0) * timeElapsed;
				price1Cumulative += ((uint256(reserve0) << 112) / reserve1) * timeElapsed;
			}
		}
	}

	/// @dev UniswapV2OracleLibrary.currentBlockTimestamp
	function _now32() internal view returns (uint32) {
		return uint32(block.timestamp % 2 ** 32);
	}
}
