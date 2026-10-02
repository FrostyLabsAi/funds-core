// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {AggregatorV3Interface} from '../interfaces/AggregatorV3Interface.sol';
import {IConcentratedPoolOracle} from './TwapAggregatorAdapter.sol';
import {TwapAggregatorAdapterV2} from './TwapAggregatorAdapterV2.sol';
import {IUniswapV2Pair, UniswapV2ObservationRecorder} from './UniswapV2ObservationRecorder.sol';
import {UniswapV2TwapAdapter} from './UniswapV2TwapAdapter.sol';
import {IAerodromeBasicPool, AerodromeBasicTwapAdapter} from './AerodromeBasicTwapAdapter.sol';

// The three deployers hold the adapters' creation code so TwapListingRegistryV2 doesn't (it would
// pass EIP-170's 24,576-byte limit). Each is stateless and permissionless: `deploy` takes exactly its
// adapter's constructor arguments and returns the new adapter. An adapter made here by anyone is no
// different from one deployed directly; only the registry's own calls create listings.

/// @title ConcentratedTwapAdapterDeployer
/// @notice Creates TwapAggregatorAdapterV2 (Uniswap v3 and Slipstream pools).
contract ConcentratedTwapAdapterDeployer {
	function deploy(
		IConcentratedPoolOracle pool,
		address asset,
		AggregatorV3Interface quoteFeed,
		uint32 window,
		uint256 minLiquidityUsd,
		uint16 maxDeviationBps,
		uint32 quoteHeartbeat,
		string calldata description
	) external returns (address) {
		return address(
			new TwapAggregatorAdapterV2(pool, asset, quoteFeed, window, minLiquidityUsd, maxDeviationBps, quoteHeartbeat, description)
		);
	}
}

/// @title UniswapV2TwapAdapterDeployer
/// @notice Creates UniswapV2TwapAdapter (Uniswap v2 pairs, priced from `recorder`'s snapshots).
contract UniswapV2TwapAdapterDeployer {
	function deploy(
		IUniswapV2Pair pair,
		address asset,
		AggregatorV3Interface quoteFeed,
		UniswapV2ObservationRecorder recorder,
		uint32 window,
		uint256 minLiquidityUsd,
		uint16 maxDeviationBps,
		uint32 quoteHeartbeat,
		string calldata description
	) external returns (address) {
		return address(
			new UniswapV2TwapAdapter(
				pair, asset, quoteFeed, recorder, window, minLiquidityUsd, maxDeviationBps, quoteHeartbeat, description
			)
		);
	}
}

/// @title AerodromeBasicTwapAdapterDeployer
/// @notice Creates AerodromeBasicTwapAdapter (Aerodrome basic VOLATILE pools; the adapter refuses stable ones).
contract AerodromeBasicTwapAdapterDeployer {
	function deploy(
		IAerodromeBasicPool pool,
		address asset,
		AggregatorV3Interface quoteFeed,
		uint32 window,
		uint256 minLiquidityUsd,
		uint16 maxDeviationBps,
		uint32 quoteHeartbeat,
		string calldata description
	) external returns (address) {
		return address(
			new AerodromeBasicTwapAdapter(pool, asset, quoteFeed, window, minLiquidityUsd, maxDeviationBps, quoteHeartbeat, description)
		);
	}
}
