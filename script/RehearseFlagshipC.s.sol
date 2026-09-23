// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {UniswapV3LPPosition} from '../src/positions/UniswapV3LPPosition.sol';

/// @notice Phase C — REALLY de-risk the long leg (first draft only unstaked LP → the
///         keeper correctly said "exposure unchanged, within band" — the collected tETH
///         still sat in the vault as long exposure; the brain out-argued the test):
///         decrease half the LP, collect to the vault, then SELL the vault's tETH for
///         tUSDC through the fund's swap adapter. Env: RIG_COMPTROLLER, RIG_LP, UNI_ADAPTER.
contract RehearseFlagshipC is Script {
	function run() external {
		Comptroller comptroller = Comptroller(vm.envAddress('RIG_COMPTROLLER'));
		UniswapV3LPPosition lp = UniswapV3LPPosition(vm.envAddress('RIG_LP'));
		address uniAdapter = vm.envAddress('UNI_ADAPTER');
		address tUsdc = vm.envAddress('TUSDC');
		address tEth = vm.envAddress('TETH');
		address vault = address(comptroller.vault());

		(,,,,,,, uint128 liquidity,,,,) = lp.positionManager().positions(lp.tokenId());

		vm.startBroadcast();
		comptroller.callOnExternalPosition(
			address(lp),
			new address[](0),
			new uint256[](0),
			new address[](0),
			abi.encode(uint8(2), abi.encode(uint128(liquidity / 2), uint256(0), uint256(0))) // DecreaseLiquidity half
		);
		comptroller.callOnExternalPosition(
			address(lp),
			new address[](0),
			new uint256[](0),
			new address[](0),
			abi.encode(uint8(3), '') // Collect → straight to vault
		);
		// The actual de-risk: sell ALL vault tETH → tUSDC (0.30% pool, minOut 0 — testnet)
		uint256 ethBalance = IERC20(tEth).balanceOf(vault);
		comptroller.callOnIntegration(uniAdapter, abi.encode(tEth, tUsdc, uint24(3000), ethBalance, uint256(0)));
		vm.stopBroadcast();

		console2.log('RIG_SOLD_TETH', ethBalance);
		console2.log('RIG_GAV_AFTER_DERISK', comptroller.calcGav());
	}
}
