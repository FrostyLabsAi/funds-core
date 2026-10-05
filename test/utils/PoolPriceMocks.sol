// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {TickMath} from '../../src/libraries/TickMath.sol';

/// @dev A Uniswap v3-shaped pool whose oracle is scripted. `observe` builds cumulatives from a
///      constant mean tick and harmonic-mean liquidity over whatever span is asked, exactly as
///      Uniswap accumulates them, and reverts 'OLD' past the oldest observation — the real
///      pool's behaviour. slot0 and observations have Uniswap v3's full return shapes.
contract ScriptedCLPool {
	struct Observation {
		uint32 blockTimestamp;
		int56 tickCumulative;
		uint160 secondsPerLiquidityCumulativeX128;
		bool initialized;
	}

	address public immutable token0;
	address public immutable token1;
	address public immutable factory;
	uint24 public immutable fee;
	int24 public immutable tickSpacing;

	int24 public meanTick;
	uint128 public meanLiquidity;
	int24 public spotTick;
	uint16 public observationIndex;
	uint16 public observationCardinality = 1;
	uint16 public observationCardinalityNext = 1;
	mapping(uint256 => Observation) public observations;
	/// @dev Before the last `recentSpan` seconds the pool sat at `olderTick` (0 = never).
	int24 public olderTick;
	uint32 public recentSpan;

	constructor(address a, address b, address factory_, uint24 fee_, int24 tickSpacing_) {
		(token0, token1) = a < b ? (a, b) : (b, a);
		factory = factory_;
		fee = fee_;
		tickSpacing = tickSpacing_;
	}

	/// @dev Mean tick and harmonic-mean liquidity over any window; spot = mean unless set apart.
	function setOracle(int24 meanTick_, uint128 meanLiquidity_) external {
		meanTick = meanTick_;
		spotTick = meanTick_;
		meanLiquidity = meanLiquidity_;
	}

	function setSpotTick(int24 spotTick_) external {
		spotTick = spotTick_;
	}

	function setOlderTick(int24 olderTick_, uint32 recentSpan_) external {
		olderTick = olderTick_;
		recentSpan = recentSpan_;
	}

	/// @dev A full ring: index 0 is the newest, index 1 (the next to overwrite) the oldest.
	function setHistory(uint32 oldestAge) external {
		observationIndex = 0;
		observationCardinality = 2;
		if (observationCardinalityNext < 2) observationCardinalityNext = 2;
		observations[0] = Observation(uint32(block.timestamp), 0, 0, true);
		observations[1] = Observation(uint32(block.timestamp - oldestAge), 0, 0, true);
	}

	/// @dev A ring that just grew: slot index+1 is reserved but not yet written (blockTimestamp 1,
	///      as increaseObservationCardinalityNext leaves it), so slot 0 holds the oldest.
	function setGrowingHistory(uint32 slotZeroAge) external {
		observationIndex = 5;
		observationCardinality = 10;
		observationCardinalityNext = 10;
		observations[0] = Observation(uint32(block.timestamp - slotZeroAge), 0, 0, true);
		observations[5] = Observation(uint32(block.timestamp), 0, 0, true);
		observations[6] = Observation(1, 0, 0, false);
	}

	function observe(uint32[] calldata secondsAgos)
		external
		view
		returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
	{
		uint32 oldestAge = uint32(block.timestamp) - _oldestTimestamp();
		require(secondsAgos[0] <= oldestAge, 'OLD');
		uint32 span = secondsAgos[0] - secondsAgos[1];
		int56 tickTime = int56(meanTick) * int56(uint56(span));
		if (recentSpan != 0 && span > recentSpan) {
			tickTime = int56(meanTick) * int56(uint56(recentSpan)) + int56(olderTick) * int56(uint56(span - recentSpan));
		}
		tickCumulatives = new int56[](2);
		secondsPerLiquidityCumulativeX128s = new uint160[](2);
		tickCumulatives[0] = 1_000_000;
		tickCumulatives[1] = 1_000_000 + tickTime;
		secondsPerLiquidityCumulativeX128s[0] = 7;
		secondsPerLiquidityCumulativeX128s[1] = 7 + uint160((uint256(span) << 128) / meanLiquidity);
	}

	function slot0()
		external
		view
		returns (uint160, int24, uint16, uint16, uint16, uint8, bool)
	{
		return (
			TickMath.getSqrtRatioAtTick(spotTick),
			spotTick,
			observationIndex,
			observationCardinality,
			observationCardinalityNext,
			0,
			true
		);
	}

	function increaseObservationCardinalityNext(uint16 next) external {
		if (next > observationCardinalityNext) observationCardinalityNext = next;
	}

	function _oldestTimestamp() internal view returns (uint32) {
		Observation memory o = observations[(observationIndex + 1) % observationCardinality];
		if (!o.initialized) o = observations[0];
		return o.blockTimestamp;
	}
}

/// @dev An Aerodrome basic (v2-style) pool whose oracle is scripted: observations and the
///      current cumulative reserves are set directly, with the real pool's view shapes.
contract ScriptedBasicPool {
	struct Observation {
		uint256 timestamp;
		uint256 reserve0Cumulative;
		uint256 reserve1Cumulative;
	}

	address public immutable token0;
	address public immutable token1;
	address public immutable factory;
	bool public immutable stable;
	uint256 public constant periodSize = 1800;

	Observation[] public observations;
	uint256 internal current0;
	uint256 internal current1;
	uint256 internal reserve0;
	uint256 internal reserve1;

	constructor(address a, address b, address factory_, bool stable_) {
		(token0, token1) = a < b ? (a, b) : (b, a);
		factory = factory_;
		stable = stable_;
	}

	function addObservation(uint256 age, uint256 reserve0Cumulative, uint256 reserve1Cumulative) external {
		observations.push(Observation(block.timestamp - age, reserve0Cumulative, reserve1Cumulative));
	}

	function setCurrentCumulatives(uint256 c0, uint256 c1) external {
		current0 = c0;
		current1 = c1;
	}

	function setReserves(uint256 r0, uint256 r1) external {
		reserve0 = r0;
		reserve1 = r1;
	}

	function observationLength() external view returns (uint256) {
		return observations.length;
	}

	function lastObservation() external view returns (uint256, uint256, uint256) {
		Observation memory o = observations[observations.length - 1];
		return (o.timestamp, o.reserve0Cumulative, o.reserve1Cumulative);
	}

	function currentCumulativePrices() external view returns (uint256, uint256, uint256) {
		return (current0, current1, block.timestamp);
	}

	function getReserves() external view returns (uint256, uint256, uint256) {
		return (reserve0, reserve1, block.timestamp);
	}
}

/// @dev Uniswap v3's factory lookup: getPool(tokenA, tokenB, fee), either token order.
contract MockUniswapV3Factory {
	mapping(address => mapping(address => mapping(uint24 => address))) public getPool;

	function setPool(address a, address b, uint24 fee, address pool) external {
		getPool[a][b][fee] = pool;
		getPool[b][a][fee] = pool;
	}
}

/// @dev Slipstream's factory lookup: getPool(tokenA, tokenB, tickSpacing), either token order.
contract MockSlipstreamFactory {
	mapping(address => mapping(address => mapping(int24 => address))) public getPool;

	function setPool(address a, address b, int24 tickSpacing, address pool) external {
		getPool[a][b][tickSpacing] = pool;
		getPool[b][a][tickSpacing] = pool;
	}
}

/// @dev Aerodrome basic's factory lookup: getPool(tokenA, tokenB, stable), either token order.
contract MockAerodromeBasicFactory {
	mapping(address => mapping(address => mapping(bool => address))) public getPool;

	function setPool(address a, address b, bool stable, address pool) external {
		getPool[a][b][stable] = pool;
		getPool[b][a][stable] = pool;
	}
}
