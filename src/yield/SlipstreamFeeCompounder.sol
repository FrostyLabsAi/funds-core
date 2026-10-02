// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {
	ISlipstreamNonfungiblePositionManager,
	ISlipstreamPoolLookup
} from '../interfaces/external/ISlipstreamNonfungiblePositionManager.sol';
import {FeeCompounderBase, ICompounderRoles} from './FeeCompounderBase.sol';

/// @dev Slipstream CLPool slot0 (no feeProtocol field, unlike Uniswap v3).
interface ISlipstreamPoolSlot0 {
	function slot0()
		external
		view
		returns (
			uint160 sqrtPriceX96,
			int24 tick,
			uint16 observationIndex,
			uint16 observationCardinality,
			uint16 observationCardinalityNext,
			bool unlocked
		);
}

/// @title SlipstreamFeeCompounder
/// @notice Fee compounder on one Aerodrome Slipstream pool, through the NonfungiblePositionManager of
///         the pool's own Slipstream deployment. Full range = ±(887272 / tickSpacing) × tickSpacing.
/// @dev The position stays unstaked: it earns the pool's trading fees (less the pool's unstakedFee),
///      never AERO.
contract SlipstreamFeeCompounder is FeeCompounderBase {
	using SafeERC20 for IERC20;

	ISlipstreamNonfungiblePositionManager public immutable positionManager;
	int24 public immutable tickSpacing;
	/// @notice The canonical pool: `getPool(token0, token1, tickSpacing)` on the manager's factory.
	address public immutable pool;

	constructor(
		string memory name_,
		string memory symbol_,
		ISlipstreamNonfungiblePositionManager positionManager_,
		IERC20 token0_,
		IERC20 token1_,
		int24 tickSpacing_,
		uint16 perfFeeBps_,
		address treasury_,
		address owner_,
		ICompounderRoles roles_
	)
		FeeCompounderBase(
			name_,
			symbol_,
			token0_,
			token1_,
			-_fullRangeTick(tickSpacing_),
			_fullRangeTick(tickSpacing_),
			perfFeeBps_,
			treasury_,
			owner_,
			roles_
		)
	{
		if (address(positionManager_) == address(0)) revert ZeroAddress();
		positionManager = positionManager_;
		tickSpacing = tickSpacing_;
		pool = ISlipstreamPoolLookup(positionManager_.factory()).getPool(address(token0_), address(token1_), tickSpacing_);
		if (pool == address(0)) revert PoolNotFound();
		token0_.forceApprove(address(positionManager_), type(uint256).max);
		token1_.forceApprove(address(positionManager_), type(uint256).max);
	}

	function _mintPosition(uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min)
		internal
		override
		returns (uint256 newTokenId, uint128 liquidity, uint256 used0, uint256 used1)
	{
		return positionManager.mint(
			ISlipstreamNonfungiblePositionManager.MintParams({
				token0: address(token0),
				token1: address(token1),
				tickSpacing: tickSpacing,
				tickLower: tickLower,
				tickUpper: tickUpper,
				amount0Desired: amount0Desired,
				amount1Desired: amount1Desired,
				amount0Min: amount0Min,
				amount1Min: amount1Min,
				recipient: address(this),
				deadline: block.timestamp,
				sqrtPriceX96: 0 // the pool exists; a price would ask the manager to create it
			})
		);
	}

	function _increase(
		uint256 id,
		uint256 amount0Desired,
		uint256 amount1Desired,
		uint256 amount0Min,
		uint256 amount1Min,
		bool tolerant
	) internal override returns (uint128 liquidity, uint256 used0, uint256 used1) {
		ISlipstreamNonfungiblePositionManager.IncreaseLiquidityParams memory params = ISlipstreamNonfungiblePositionManager
			.IncreaseLiquidityParams({
			tokenId: id,
			amount0Desired: amount0Desired,
			amount1Desired: amount1Desired,
			amount0Min: amount0Min,
			amount1Min: amount1Min,
			deadline: block.timestamp
		});
		if (!tolerant) return positionManager.increaseLiquidity(params);
		try positionManager.increaseLiquidity(params) returns (uint128 l, uint256 u0, uint256 u1) {
			return (l, u0, u1);
		} catch {}
	}

	function _decrease(uint256 id, uint128 liquidity, uint256 amount0Min, uint256 amount1Min)
		internal
		override
		returns (uint256 amount0, uint256 amount1)
	{
		return positionManager.decreaseLiquidity(
			ISlipstreamNonfungiblePositionManager.DecreaseLiquidityParams({
				tokenId: id,
				liquidity: liquidity,
				amount0Min: amount0Min,
				amount1Min: amount1Min,
				deadline: block.timestamp
			})
		);
	}

	function _collect(uint256 id, address recipient, uint128 amount0Max, uint128 amount1Max)
		internal
		override
		returns (uint256 amount0, uint256 amount1)
	{
		return positionManager.collect(
			ISlipstreamNonfungiblePositionManager.CollectParams({
				tokenId: id,
				recipient: recipient,
				amount0Max: amount0Max,
				amount1Max: amount1Max
			})
		);
	}

	function _sqrtPriceX96() internal view override returns (uint160 sqrtPriceX96) {
		(sqrtPriceX96,,,,,) = ISlipstreamPoolSlot0(pool).slot0();
	}

	/// @dev Slipstream's positions() carries tickSpacing where Uniswap has fee; the rest lines up.
	function _positions(uint256 id) internal view override returns (uint128 liquidity, uint128 owed0, uint128 owed1) {
		(,,,,,,, liquidity,,, owed0, owed1) = positionManager.positions(id);
	}
}
