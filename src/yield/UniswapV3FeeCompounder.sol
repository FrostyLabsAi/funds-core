// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IUniswapV3NonfungiblePositionManager} from
	'../interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {FeeCompounderBase, ICompounderRoles} from './FeeCompounderBase.sol';

/// @dev The canonical NonfungiblePositionManager's pool factory.
interface IUniswapV3PositionManagerFactory {
	function factory() external view returns (address);
}

/// @dev UniswapV3Factory: the tick spacing of an enabled fee tier (0 if not enabled) and its pools.
interface IUniswapV3FeeTierSpacing {
	function feeAmountTickSpacing(uint24 fee) external view returns (int24);
	function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IUniswapV3PoolSlot0 {
	function slot0()
		external
		view
		returns (
			uint160 sqrtPriceX96,
			int24 tick,
			uint16 observationIndex,
			uint16 observationCardinality,
			uint16 observationCardinalityNext,
			uint8 feeProtocol,
			bool unlocked
		);
}

/// @title UniswapV3FeeCompounder
/// @notice Fee compounder on one Uniswap v3 pool. Full range = ±(887272 / spacing) × spacing, with
///         the spacing read from the manager's factory (`feeAmountTickSpacing(poolFee)`).
contract UniswapV3FeeCompounder is FeeCompounderBase {
	using SafeERC20 for IERC20;

	IUniswapV3NonfungiblePositionManager public immutable positionManager;
	uint24 public immutable poolFee;
	/// @notice The canonical pool: `getPool(token0, token1, poolFee)` on the manager's factory.
	address public immutable pool;

	constructor(
		string memory name_,
		string memory symbol_,
		IUniswapV3NonfungiblePositionManager positionManager_,
		IERC20 token0_,
		IERC20 token1_,
		uint24 poolFee_,
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
			-_fullRangeTick(_tickSpacing(positionManager_, poolFee_)),
			_fullRangeTick(_tickSpacing(positionManager_, poolFee_)),
			perfFeeBps_,
			treasury_,
			owner_,
			roles_
		)
	{
		positionManager = positionManager_;
		poolFee = poolFee_;
		address poolFactory = IUniswapV3PositionManagerFactory(address(positionManager_)).factory();
		pool = IUniswapV3FeeTierSpacing(poolFactory).getPool(address(token0_), address(token1_), poolFee_);
		if (pool == address(0)) revert PoolNotFound();
		token0_.forceApprove(address(positionManager_), type(uint256).max);
		token1_.forceApprove(address(positionManager_), type(uint256).max);
	}

	/// @dev Reverts for a zero manager (no code to call); 0 for a fee tier the factory never enabled.
	function _tickSpacing(IUniswapV3NonfungiblePositionManager positionManager_, uint24 poolFee_)
		private
		view
		returns (int24)
	{
		address poolFactory = IUniswapV3PositionManagerFactory(address(positionManager_)).factory();
		return IUniswapV3FeeTierSpacing(poolFactory).feeAmountTickSpacing(poolFee_);
	}

	function _mintPosition(uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min)
		internal
		override
		returns (uint256 newTokenId, uint128 liquidity, uint256 used0, uint256 used1)
	{
		return positionManager.mint(
			IUniswapV3NonfungiblePositionManager.MintParams({
				token0: address(token0),
				token1: address(token1),
				fee: poolFee,
				tickLower: tickLower,
				tickUpper: tickUpper,
				amount0Desired: amount0Desired,
				amount1Desired: amount1Desired,
				amount0Min: amount0Min,
				amount1Min: amount1Min,
				recipient: address(this),
				deadline: block.timestamp
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
		IUniswapV3NonfungiblePositionManager.IncreaseLiquidityParams memory params = IUniswapV3NonfungiblePositionManager
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
			IUniswapV3NonfungiblePositionManager.DecreaseLiquidityParams({
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
			IUniswapV3NonfungiblePositionManager.CollectParams({
				tokenId: id,
				recipient: recipient,
				amount0Max: amount0Max,
				amount1Max: amount1Max
			})
		);
	}

	function _sqrtPriceX96() internal view override returns (uint160 sqrtPriceX96) {
		(sqrtPriceX96,,,,,,) = IUniswapV3PoolSlot0(pool).slot0();
	}

	function _positions(uint256 id) internal view override returns (uint128 liquidity, uint128 owed0, uint128 owed1) {
		(,,,,,,, liquidity,,, owed0, owed1) = positionManager.positions(id);
	}
}
