// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IExternalPosition} from '../interfaces/IExternalPosition.sol';
import {IExternalPositionTypeFactory} from '../interfaces/IExternalPositionTypeFactory.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {IUniswapV3NonfungiblePositionManager} from
	'../interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {Comptroller} from '../core/Comptroller.sol';
import {TickMath} from '../libraries/TickMath.sol';
import {LiquidityAmounts} from '../libraries/LiquidityAmounts.sol';

/// @title UniswapV3LPPosition
/// @notice External position holding ONE Uniswap v3 LP NFT. The fee-keyed twin of
///         SlipstreamLPPosition, minus the gauge machinery (Uniswap has no gauges —
///         positions always earn pool fees; 100% of them, no unstaked-fee skim).
/// @dev Valuation identical to SlipstreamLPPosition: liquidity split at the ORACLE-fair
///      sqrt price (frosty-core PriceOracle math) — never pool spot state (Gamma lesson #1).
///      Uncollected tokensOwed + idle balances held here are included in managed assets.
contract UniswapV3LPPosition is IExternalPosition {
	using SafeERC20 for IERC20;

	enum Action {
		Mint,
		IncreaseLiquidity,
		DecreaseLiquidity,
		Collect,
		Burn,
		SweepToVault
	}

	uint256 private constant Q96 = 0x1000000000000000000000000;

	address public immutable comptroller;
	IUniswapV3NonfungiblePositionManager public immutable positionManager;
	IERC20 public immutable token0;
	IERC20 public immutable token1;
	uint24 public immutable poolFee;
	uint256 private immutable scale0;
	uint256 private immutable scale1;

	uint256 public tokenId; // 0 = no active NFT

	event PositionMinted(uint256 indexed tokenId, uint128 liquidity);
	event LiquidityIncreased(uint128 liquidity);
	event LiquidityDecreased(uint128 liquidity);
	event FeesCollected(uint256 amount0, uint256 amount1);
	event PositionBurned(uint256 indexed tokenId);
	event SweptToVault(address indexed asset, uint256 amount);

	error OnlyComptroller();
	error UnknownAction();
	error NoActivePosition();
	error PositionAlreadyExists();
	error ZeroAddress();

	modifier onlyComptroller() {
		if (msg.sender != comptroller) revert OnlyComptroller();
		_;
	}

	constructor(
		address comptroller_,
		IUniswapV3NonfungiblePositionManager positionManager_,
		IERC20 token0_,
		IERC20 token1_,
		uint24 poolFee_
	) {
		if (
			comptroller_ == address(0) || address(positionManager_) == address(0) || address(token0_) == address(0)
				|| address(token1_) == address(0)
		) revert ZeroAddress();
		comptroller = comptroller_;
		positionManager = positionManager_;
		token0 = token0_;
		token1 = token1_;
		poolFee = poolFee_;
		scale0 = 10 ** IERC20Metadata(address(token0_)).decimals();
		scale1 = 10 ** IERC20Metadata(address(token1_)).decimals();
	}

	// ─── IExternalPosition ───────────────────────────────────────────────────────

	/// @inheritdoc IExternalPosition
	function getManagedAssets() external view returns (address[] memory assets, uint256[] memory amounts) {
		assets = new address[](2);
		assets[0] = address(token0);
		assets[1] = address(token1);
		amounts = new uint256[](2);
		amounts[0] = token0.balanceOf(address(this));
		amounts[1] = token1.balanceOf(address(this));

		if (tokenId != 0) {
			(,,,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,, uint128 tokensOwed0, uint128 tokensOwed1) =
				positionManager.positions(tokenId);

			if (liquidity != 0) {
				IValueInterpreter interpreter = Comptroller(comptroller).valueInterpreter();
				(uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
					_fairSqrtPriceX96(
						interpreter.calcUsdRate(address(token0)), interpreter.calcUsdRate(address(token1))
					),
					TickMath.getSqrtRatioAtTick(tickLower),
					TickMath.getSqrtRatioAtTick(tickUpper),
					liquidity
				);
				amounts[0] += amount0;
				amounts[1] += amount1;
			}

			amounts[0] += tokensOwed0;
			amounts[1] += tokensOwed1;
		}
	}

	/// @inheritdoc IExternalPosition
	function getDebtAssets() external pure returns (address[] memory assets, uint256[] memory amounts) {
		assets = new address[](0);
		amounts = new uint256[](0);
	}

	/// @inheritdoc IExternalPosition
	function receiveCallFromFund(bytes calldata actionData) external onlyComptroller {
		(uint8 rawAction, bytes memory args) = abi.decode(actionData, (uint8, bytes));

		if (rawAction == uint8(Action.Mint)) {
			_mint(args);
		} else if (rawAction == uint8(Action.IncreaseLiquidity)) {
			_increaseLiquidity(args);
		} else if (rawAction == uint8(Action.DecreaseLiquidity)) {
			_decreaseLiquidity(args);
		} else if (rawAction == uint8(Action.Collect)) {
			_collect();
		} else if (rawAction == uint8(Action.Burn)) {
			_burn();
		} else if (rawAction == uint8(Action.SweepToVault)) {
			_sweepToVault(abi.decode(args, (address)));
		} else {
			revert UnknownAction();
		}
	}

	// ─── Actions ─────────────────────────────────────────────────────────────────

	function _mint(bytes memory args) private {
		if (tokenId != 0) revert PositionAlreadyExists();
		(int24 tickLower, int24 tickUpper, uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min)
		= abi.decode(args, (int24, int24, uint256, uint256, uint256, uint256));

		token0.forceApprove(address(positionManager), amount0Desired);
		token1.forceApprove(address(positionManager), amount1Desired);

		(uint256 newTokenId, uint128 liquidity,,) = positionManager.mint(
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

		tokenId = newTokenId;
		emit PositionMinted(newTokenId, liquidity);
	}

	function _increaseLiquidity(bytes memory args) private {
		uint256 activeTokenId = _requireActive();
		(uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min) =
			abi.decode(args, (uint256, uint256, uint256, uint256));

		token0.forceApprove(address(positionManager), amount0Desired);
		token1.forceApprove(address(positionManager), amount1Desired);

		(uint128 liquidity,,) = positionManager.increaseLiquidity(
			IUniswapV3NonfungiblePositionManager.IncreaseLiquidityParams({
				tokenId: activeTokenId,
				amount0Desired: amount0Desired,
				amount1Desired: amount1Desired,
				amount0Min: amount0Min,
				amount1Min: amount1Min,
				deadline: block.timestamp
			})
		);
		emit LiquidityIncreased(liquidity);
	}

	function _decreaseLiquidity(bytes memory args) private {
		uint256 activeTokenId = _requireActive();
		(uint128 liquidity, uint256 amount0Min, uint256 amount1Min) = abi.decode(args, (uint128, uint256, uint256));

		positionManager.decreaseLiquidity(
			IUniswapV3NonfungiblePositionManager.DecreaseLiquidityParams({
				tokenId: activeTokenId,
				liquidity: liquidity,
				amount0Min: amount0Min,
				amount1Min: amount1Min,
				deadline: block.timestamp
			})
		);
		emit LiquidityDecreased(liquidity);
	}

	/// @dev Collects fees + decreased principal STRAIGHT to the vault (never parked here).
	function _collect() private {
		uint256 activeTokenId = _requireActive();

		(uint256 amount0, uint256 amount1) = positionManager.collect(
			IUniswapV3NonfungiblePositionManager.CollectParams({
				tokenId: activeTokenId,
				recipient: address(Comptroller(comptroller).vault()),
				amount0Max: type(uint128).max,
				amount1Max: type(uint128).max
			})
		);
		emit FeesCollected(amount0, amount1);
	}

	function _burn() private {
		uint256 activeTokenId = _requireActive();
		positionManager.burn(activeTokenId);
		tokenId = 0;
		emit PositionBurned(activeTokenId);
	}

	function _sweepToVault(address asset) private {
		uint256 balance = IERC20(asset).balanceOf(address(this));
		if (balance > 0) {
			IERC20(asset).safeTransfer(address(Comptroller(comptroller).vault()), balance);
		}
		emit SweptToVault(asset, balance);
	}

	function _requireActive() private view returns (uint256 activeTokenId) {
		activeTokenId = tokenId;
		if (activeTokenId == 0) revert NoActivePosition();
	}

	// ─── Fair pricing (ported from frosty-core PriceOracle._fairSqrtPriceX96) ────

	function _fairSqrtPriceX96(uint256 rate0, uint256 rate1) private view returns (uint160) {
		uint256 ratioX96 = Math.mulDiv(Math.mulDiv(rate0, Q96, rate1), scale1, scale0);

		uint256 sqrtRatio =
			ratioX96 <= type(uint256).max >> 64 ? Math.sqrt(ratioX96 << 64) << 16 : Math.sqrt(ratioX96) << 48;

		if (sqrtRatio < TickMath.MIN_SQRT_RATIO) return TickMath.MIN_SQRT_RATIO;
		if (sqrtRatio > TickMath.MAX_SQRT_RATIO) return TickMath.MAX_SQRT_RATIO;
		return uint160(sqrtRatio);
	}
}

/// @title UniswapV3LPPositionFactory
/// @notice Type factory for Uniswap v3 LP positions.
///         initArgs = abi.encode(token0, token1, poolFee).
contract UniswapV3LPPositionFactory is IExternalPositionTypeFactory {
	IUniswapV3NonfungiblePositionManager public immutable positionManager;

	error ZeroAddress();

	constructor(IUniswapV3NonfungiblePositionManager positionManager_) {
		if (address(positionManager_) == address(0)) revert ZeroAddress();
		positionManager = positionManager_;
	}

	/// @inheritdoc IExternalPositionTypeFactory
	function deployPosition(address comptroller, bytes calldata initArgs) external returns (address position) {
		(address token0, address token1, uint24 poolFee) = abi.decode(initArgs, (address, address, uint24));
		_requireSupported(comptroller, token0, token1);
		position =
			address(new UniswapV3LPPosition(comptroller, positionManager, IERC20(token0), IERC20(token1), poolFee));
	}

	error UnsupportedAsset(address asset);

	/// @dev Anything the position will ever report in getManagedAssets must be
	///      protocol-priceable — an unpriceable token0/token1 bricks calcGav fund-wide
	///      the moment 1 wei lands in the position (security review 2026-09-22, H-2).
	function _requireSupported(address comptroller, address token0, address token1) internal view {
		IValueInterpreter interpreter = Comptroller(comptroller).valueInterpreter();
		if (!interpreter.isSupportedAsset(token0)) revert UnsupportedAsset(token0);
		if (!interpreter.isSupportedAsset(token1)) revert UnsupportedAsset(token1);
	}
}
