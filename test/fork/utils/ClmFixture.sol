// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {TickMath} from '../../../src/libraries/TickMath.sol';

/// @dev funds-yield's ClmPoolDeployer.PoolConfig (plan 1b), same field order.
struct ClmPoolConfig {
	address compoundToken;
	address gauge;
	int56 maxTickDeviation;
	address pool;
	int24 positionWidth;
	string symbol;
	uint32 twapInterval;
}

interface IClmStrategyFactoryAdmin {
	function addStrategy(string calldata name, address implementation) external;
	function addRebalancer(address rebalancer) external;
}

interface IClmPoolDeployer {
	function deployPool(ClmPoolConfig calldata cfg) external returns (address strategy, address vault);
}

interface IClmHarvest {
	function harvest() external;
	function twapInterval() external view returns (uint32);
	function lockedProfit() external view returns (uint256 locked0, uint256 locked1);
	function fees() external view returns (uint256);
}

interface ICLPoolLike {
	function token0() external view returns (address);
	function token1() external view returns (address);
	function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, bool);
	function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
		external
		returns (int256 amount0, int256 amount1);
}

/// @notice Stands in for FrostyFi's VI where a fork test skips time (Chainlink goes stale): fixed USD rates, and the
///         one value call the funds-yield strategy makes when it sells AERO.
contract MockClmVi {
	mapping(address => uint256) public usdRate; // 1e18 USD per whole token
	mapping(address => uint8) public decimalsOf;

	function set(address token, uint256 rate, uint8 decimals) external {
		usdRate[token] = rate;
		decimalsOf[token] = decimals;
	}

	/// @dev Like ValueInterpreter.getAssetInfo: a non-zero aggregator means a priced token.
	function getAssetInfo(address asset) external view returns (address aggregator, uint32, uint8, uint8) {
		aggregator = usdRate[asset] == 0 ? address(0) : address(1);
	}

	function calcUsdRate(address asset) external view returns (uint256) {
		require(usdRate[asset] != 0, 'no rate');
		return usdRate[asset];
	}

	function calcCanonicalAssetValue(address base, uint256 amount, address quote) external view returns (uint256) {
		return amount * usdRate[base] / 10 ** decimalsOf[base] * 10 ** decimalsOf[quote] / usdRate[quote];
	}
}

/// @notice Deploys FrostyFi's real CLM contracts (funds-yield, compiled to ../funds-yield/out) on a Base fork, over the
///         USDC/cbBTC Slipstream-2 pool: USDC is token0 as in the stock pools, and cbBTC, unlike stock tokens (B20),
///         runs on a fork. Addresses read 2026-10-11/13 with `cast`.
abstract contract ClmFixture is Test {
	string internal constant OUT = '../funds-yield/out/';
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
	address internal constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
	address internal constant CLM_POOL = 0x160D7E9d948B16c163332a277b393c288408eb12; // USDC/cbBTC ts50, Slipstream-2
	address internal constant CLM_GAUGE = 0x7B0f1103746648FBfce9222f1266f79B934E16b2;
	address internal constant WETH = 0x4200000000000000000000000000000000000006;
	address internal constant CBLTC = 0xcb17C9Db87B595717C857a08468793f5bAb6445F;
	address internal constant S1_POOL_WETH_CBLTC = 0x200681425b0C8D78C6a467512C5D49FA56BaC88A; // ts200, no USDC side
	address internal constant S1_GAUGE_WETH_CBLTC = 0x88040de1F5811090b638Fa70633B24a3e319D06f;
	address internal constant SLIPSTREAM1_ROUTER = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
	address internal constant SLIPSTREAM2_ROUTER = 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F;
	address internal constant SLIPSTREAM3_ROUTER = 0xcbBb8035cAc7D4B3Ca7aBb74cF7BdF900215Ce0D;
	address internal constant TREASURY = 0x47b7702a4789912d0dfFDadC07c50395c293fF0A;
	string internal constant STRATEGY_NAME = 'FrostyClmStrategy-v1';

	/// @dev True when funds-yield has been built; fork tests skip otherwise.
	function _clmReady() internal view returns (bool) {
		return vm.exists(string.concat(OUT, 'ClmPoolDeployer.sol/ClmPoolDeployer.json'));
	}

	function _deployClm(address keeper, address strategyVi) internal returns (address strategyFactory, address poolDeployer) {
		strategyFactory = vm.deployCode(
			string.concat(OUT, 'FrostyClmStrategyFactory.sol/FrostyClmStrategyFactory.json'),
			abi.encode(keeper, TREASURY, strategyVi, uint256(950))
		);
		address vaultFactory =
			vm.deployCode(string.concat(OUT, 'FrostyClmVaultFactory.sol/FrostyClmVaultFactory.json'), abi.encode(address(0)));
		poolDeployer = vm.deployCode(
			string.concat(OUT, 'ClmPoolDeployer.sol/ClmPoolDeployer.json'), abi.encode(strategyFactory, vaultFactory, address(this))
		);
		IClmStrategyFactoryAdmin(strategyFactory).addStrategy(
			STRATEGY_NAME, vm.deployCode(string.concat(OUT, 'FrostyClmStrategy.sol/FrostyClmStrategy.json'))
		);
		IClmStrategyFactoryAdmin(strategyFactory).addRebalancer(keeper);
	}

	function _deployCbBtcVault(address poolDeployer) internal returns (address vault, address strategy) {
		(strategy, vault) = IClmPoolDeployer(poolDeployer).deployPool(
			ClmPoolConfig({
				compoundToken: USDC,
				gauge: CLM_GAUGE,
				maxTickDeviation: 5,
				pool: CLM_POOL,
				positionWidth: 30,
				symbol: 'USDC-cbBTC',
				twapInterval: 120
			})
		);
	}

	/// @dev Slipstream-1 WETH/cbLTC: no USDC side; the strategy compounds into WETH.
	function _deployWethCbLtcVault(address poolDeployer) internal returns (address vault, address strategy) {
		(strategy, vault) = IClmPoolDeployer(poolDeployer).deployPool(
			ClmPoolConfig({
				compoundToken: WETH,
				gauge: S1_GAUGE_WETH_CBLTC,
				maxTickDeviation: 20,
				pool: S1_POOL_WETH_CBLTC,
				positionWidth: 8,
				symbol: 'WETH-cbLTC',
				twapInterval: 120
			})
		);
	}

	/// @dev Buys exactly `amountOut` cbBTC for `to` on the CLM pool with dealt USDC.
	function _buyCbBtc(address to, uint256 amountOut) internal {
		ICLPoolLike(CLM_POOL).swap(to, true, -int256(amountOut), TickMath.MIN_SQRT_RATIO + 1, abi.encode(CLM_POOL));
	}

	/// @dev Buys exactly `amountOut` cbLTC for `to` on the Slipstream-1 WETH/cbLTC pool with dealt WETH.
	function _buyCbLtc(address to, uint256 amountOut) internal {
		ICLPoolLike(S1_POOL_WETH_CBLTC).swap(to, true, -int256(amountOut), TickMath.MIN_SQRT_RATIO + 1, abi.encode(S1_POOL_WETH_CBLTC));
	}

	/// @dev Moves the pool's tick by about `ticks` (negative: sells USDC).
	function _pushPrice(int24 ticks) internal {
		(, int24 tick,,,,) = ICLPoolLike(CLM_POOL).slot0();
		ICLPoolLike(CLM_POOL).swap(
			address(this), ticks < 0, type(int128).max, TickMath.getSqrtRatioAtTick(tick + ticks), abi.encode(CLM_POOL)
		);
	}

	/// @dev Time with no swaps: the pool's TWAP converges (calm) and the gauge's 30 s minimum stake time passes.
	function _settle(address strategy) internal {
		skip(uint256(IClmHarvest(strategy).twapInterval()) + 1);
	}

	function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
		address pool = abi.decode(data, (address));
		require(msg.sender == pool, 'not the pool');
		if (amount0Delta > 0) _pay(ICLPoolLike(pool).token0(), uint256(amount0Delta));
		if (amount1Delta > 0) _pay(ICLPoolLike(pool).token1(), uint256(amount1Delta));
	}

	function _pay(address token, uint256 amount) private {
		require(token == USDC || token == WETH, 'only USDC and WETH are dealt');
		deal(token, address(this), IERC20(token).balanceOf(address(this)) + amount);
		IERC20(token).transfer(msg.sender, amount);
	}
}
