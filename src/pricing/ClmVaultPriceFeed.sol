// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IDerivativePriceFeed} from '../interfaces/IDerivativePriceFeed.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {IPoolPriceRegistrar} from '../interfaces/IPoolPriceRegistrar.sol';
import {ISlipstreamNonfungiblePositionManager} from '../interfaces/external/ISlipstreamNonfungiblePositionManager.sol';
import {IFrostyClmVault, IFrostyClmStrategy} from '../interfaces/external/IFrostyClm.sol';
import {TickMath} from '../libraries/TickMath.sol';
import {LiquidityAmounts} from '../libraries/LiquidityAmounts.sol';

/// @title ClmVaultPriceFeed
/// @notice Derivative feed for FrostyFi CLM vault shares (funds-yield; plan 2, 2026-10-13). A share amount resolves to
///         what a withdrawal of it would pay, valued at oracle prices (hard rule 1):
///         - both positions' liquidity split at the oracle-fair price, plus their uncollected tokens;
///         - plus the strategy's idle pool tokens;
///         - minus harvest proceeds not yet released (they reach the share price over LOCK_DURATION).
///         Not counted, because a withdrawal doesn't pay them: claimed AERO waiting to be sold, AERO unclaimed in the
///         gauge (hard rule 4: explicitly out of GAV). One instance serves every vault of `strategyFactory`.
///         Only vaults whose two tokens are oracle-fed (final review I1, founder 2026-10-13): a pool-priced token inside a
///         vault share would slip past the fund rules made for long-tail tokens, and an unpriced one would make NAV
///         revert.
/// @dev Never reads the pool's spot price: not `slot0`, and not the strategy's `balances()`/`lockedProfit()`, which do.
contract ClmVaultPriceFeed is IDerivativePriceFeed {
	uint256 private constant Q96 = 0x1000000000000000000000000;
	/// @notice funds-yield StratFeeManagerInitializable.DURATION (1 day since final review I1, 2026-10-13).
	///         Pinned by test_lockDuration_matchesTheStrategy.
	uint256 public constant LOCK_DURATION = 1 days;

	IValueInterpreter public immutable valueInterpreter;
	/// @notice FrostyFi's strategy factory. Only its vaults are priced: anyone can deploy the same bytecode with their
	///         own factory and fee settings.
	address public immutable strategyFactory;
	/// @notice The pool-price registrar, which answers whether a token is pool-priced.
	IPoolPriceRegistrar public immutable registrar;

	error ZeroAddress();

	constructor(IValueInterpreter valueInterpreter_, address strategyFactory_, address registrar_) {
		if (address(valueInterpreter_) == address(0) || strategyFactory_ == address(0) || registrar_ == address(0)) {
			revert ZeroAddress();
		}
		valueInterpreter = valueInterpreter_;
		strategyFactory = strategyFactory_;
		registrar = IPoolPriceRegistrar(registrar_);
	}

	/// @inheritdoc IDerivativePriceFeed
	function calcUnderlyingValues(address derivative, uint256 amount)
		external
		view
		returns (address[] memory underlyings, uint256[] memory underlyingAmounts)
	{
		IFrostyClmStrategy strategy = IFrostyClmStrategy(IFrostyClmVault(derivative).strategy());
		underlyings = new address[](2);
		underlyings[0] = strategy.lpToken0();
		underlyings[1] = strategy.lpToken1();
		underlyingAmounts = new uint256[](2);
		uint256 supply = IFrostyClmVault(derivative).totalSupply();
		if (supply == 0 || amount == 0) return (underlyings, underlyingAmounts);

		(uint256 total0, uint256 total1) = _fairBalances(strategy, underlyings[0], underlyings[1]);
		(uint256 locked0, uint256 locked1) = _locked(strategy);
		underlyingAmounts[0] = Math.mulDiv(total0 - Math.min(locked0, total0), amount, supply);
		underlyingAmounts[1] = Math.mulDiv(total1 - Math.min(locked1, total1), amount, supply);
	}

	/// @inheritdoc IDerivativePriceFeed
	function isSupportedAsset(address asset) external view returns (bool) {
		address strategy = _addressCall(asset, abi.encodeCall(IFrostyClmVault.strategy, ()));
		if (strategy == address(0)) return false;
		if (_addressCall(strategy, abi.encodeCall(IFrostyClmStrategy.factory, ())) != strategyFactory) return false;
		if (_addressCall(strategy, abi.encodeCall(IFrostyClmStrategy.vault, ())) != asset) return false;
		return _oracleFed(IFrostyClmStrategy(strategy).lpToken0()) && _oracleFed(IFrostyClmStrategy(strategy).lpToken1());
	}

	/// @dev A priced primitive that isn't pool-priced: a Chainlink-style feed (or Veranta/Redstone/Pyth store).
	function _oracleFed(address token) private view returns (bool) {
		(address aggregator,,,) = valueInterpreter.getAssetInfo(token);
		return aggregator != address(0) && registrar.poolPricedAdapter(token) == address(0);
	}

	/// @notice Harvest proceeds of `vault` not yet released to its share price (before the cap at what it holds).
	function locked(address vault) external view returns (uint256 locked0, uint256 locked1) {
		return _locked(IFrostyClmStrategy(IFrostyClmVault(vault).strategy()));
	}

	function _locked(IFrostyClmStrategy strategy) private view returns (uint256 locked0, uint256 locked1) {
		uint256 elapsed = block.timestamp - strategy.lastHarvest();
		if (elapsed >= LOCK_DURATION) return (0, 0);
		uint256 remaining = LOCK_DURATION - elapsed;
		locked0 = strategy.totalLocked0() * remaining / LOCK_DURATION;
		locked1 = strategy.totalLocked1() * remaining / LOCK_DURATION;
	}

	/// @dev Idle balances plus both positions at the oracle-fair price.
	function _fairBalances(IFrostyClmStrategy strategy, address token0, address token1)
		private
		view
		returns (uint256 total0, uint256 total1)
	{
		(total0, total1) = strategy.balancesOfThis();
		uint160 fairSqrtPriceX96 = _fairSqrtPriceX96(
			valueInterpreter.calcUsdRate(token0),
			valueInterpreter.calcUsdRate(token1),
			10 ** IERC20Metadata(token0).decimals(),
			10 ** IERC20Metadata(token1).decimals()
		);
		ISlipstreamNonfungiblePositionManager npm = ISlipstreamNonfungiblePositionManager(strategy.nftManager());
		(uint256 mainId,,) = strategy.positionMain();
		(uint256 altId,,) = strategy.positionAlt();
		(uint256 a0, uint256 a1) = _positionAmounts(npm, mainId, fairSqrtPriceX96);
		(uint256 b0, uint256 b1) = _positionAmounts(npm, altId, fairSqrtPriceX96);
		total0 += a0 + b0;
		total1 += a1 + b1;
	}

	function _positionAmounts(ISlipstreamNonfungiblePositionManager npm, uint256 nftId, uint160 fairSqrtPriceX96)
		private
		view
		returns (uint256 amount0, uint256 amount1)
	{
		if (nftId == 0) return (0, 0);
		(,,,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,, uint128 owed0, uint128 owed1) = npm.positions(nftId);
		(amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
			fairSqrtPriceX96, TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidity
		);
		amount0 += owed0;
		amount1 += owed1;
	}

	/// @dev `target`'s answer to a no-argument address getter, or 0 when it has none.
	function _addressCall(address target, bytes memory data) private view returns (address) {
		(bool ok, bytes memory ret) = target.staticcall(data);
		if (!ok || ret.length != 32) return address(0);
		return abi.decode(ret, (address));
	}

	/// @dev Oracle USD rates → the sqrtPrice the pool should have.
	function _fairSqrtPriceX96(uint256 rate0, uint256 rate1, uint256 scale0, uint256 scale1) private pure returns (uint160) {
		uint256 ratioX96 = Math.mulDiv(Math.mulDiv(rate0, Q96, rate1), scale1, scale0);

		uint256 sqrtRatio =
			ratioX96 <= type(uint256).max >> 64 ? Math.sqrt(ratioX96 << 64) << 16 : Math.sqrt(ratioX96) << 48;

		if (sqrtRatio < TickMath.MIN_SQRT_RATIO) return TickMath.MIN_SQRT_RATIO;
		if (sqrtRatio > TickMath.MAX_SQRT_RATIO) return TickMath.MAX_SQRT_RATIO;
		return uint160(sqrtRatio);
	}
}
