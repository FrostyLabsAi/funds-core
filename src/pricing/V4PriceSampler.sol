// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {IV4StateView} from '../interfaces/external/IUniswapV4.sol';

/// @title V4PriceSampler
/// @notice Price history for Uniswap v4 pools, which keep none of their own (no `observe`): an approved keeper
///         reads each pool's tick and in-range liquidity every ~10 minutes and this contract keeps the last 12
///         readings per pool. V4PoolPriceAdapter prices from the median of the last hour (spec 2026-10-08 §4.1;
///         founder 2026-10-08: on-chain sampling every 10 minutes, keeper-only).
/// @dev Sampling is keeper-only: if anyone could sample, an attacker could fill a pool's history with readings
///      taken while they hold the price up. The keeper only chooses when; the values come from the pool.
contract V4PriceSampler is Ownable2Step {
	uint256 public constant SLOTS = 12;
	/// @notice A pool sampled more recently than this is skipped, so a keeper bug can't flood its history.
	uint256 public constant MIN_INTERVAL = 9 minutes;

	/// @dev One storage slot: 32 + 24 + 128 bits.
	struct Sample {
		uint32 time;
		int24 tick;
		uint128 liquidity;
	}

	IV4StateView public immutable stateView;

	mapping(address => bool) public isKeeper;
	/// @notice Samples ever taken for a pool; the newest sits at (count − 1) % SLOTS.
	mapping(bytes32 => uint256) public sampleCount;
	mapping(bytes32 => Sample[SLOTS]) internal _ring;

	event KeeperSet(address indexed keeper, bool allowed);
	event Sampled(bytes32 indexed poolId, int24 tick, uint128 liquidity);

	error NotKeeper(address caller);
	error ZeroAddress();

	constructor(IV4StateView stateView_, address owner_) Ownable(owner_) {
		if (address(stateView_) == address(0)) revert ZeroAddress();
		stateView = stateView_;
	}

	function setKeeper(address keeper, bool allowed) external onlyOwner {
		if (keeper == address(0)) revert ZeroAddress();
		isKeeper[keeper] = allowed;
		emit KeeperSet(keeper, allowed);
	}

	/// @notice Record one reading of each pool; pools sampled under MIN_INTERVAL ago, or not initialized, are skipped.
	function sample(bytes32[] calldata poolIds) external {
		if (!isKeeper[msg.sender]) revert NotKeeper(msg.sender);
		for (uint256 i; i < poolIds.length; ++i) {
			bytes32 id = poolIds[i];
			uint256 count = sampleCount[id];
			if (count != 0 && block.timestamp < _ring[id][(count - 1) % SLOTS].time + MIN_INTERVAL) continue;
			(uint160 sqrtPriceX96, int24 tick,,) = stateView.getSlot0(id);
			if (sqrtPriceX96 == 0) continue;
			uint128 liquidity = stateView.getLiquidity(id);
			_ring[id][count % SLOTS] = Sample({time: uint32(block.timestamp), tick: tick, liquidity: liquidity});
			sampleCount[id] = count + 1;
			emit Sampled(id, tick, liquidity);
		}
	}

	/// @notice The pool's kept readings, newest first (at most SLOTS).
	function samples(bytes32 poolId) external view returns (Sample[] memory out) {
		uint256 count = sampleCount[poolId];
		uint256 n = count < SLOTS ? count : SLOTS;
		out = new Sample[](n);
		for (uint256 i; i < n; ++i) {
			out[i] = _ring[poolId][(count - 1 - i) % SLOTS];
		}
	}
}
