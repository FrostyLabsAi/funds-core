// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {FundFactory} from '../../src/core/FundFactory.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {PoolPriceRegistrarV2} from '../../src/pricing/PoolPriceRegistrarV2.sol';
import {IValueInterpreter} from '../../src/interfaces/IValueInterpreter.sol';
import {ClmVaultAdapter} from '../../src/adapters/ClmVaultAdapter.sol';
import {ClmVaultPriceFeed} from '../../src/pricing/ClmVaultPriceFeed.sol';

/// @notice Plan 2 (2026-10-13): the CLM feed and adapter deploy, as a library so its calls run as the caller (the
///         deployer key under a broadcast, the pranked deployer in DeployClmFundsFork), like FundV6Deploy.
library ClmFundsDeploy {
	address internal constant FUND_FACTORY = 0x42F213d7f6018BF293bF0ecB727C59A25b5029a3;
	address internal constant VALUE_INTERPRETER = 0x3CDbaBE5Bf4E6cfE10A2A326E0ad31b2d16398D4;
	/// @dev Owns today's registrar, which owns the VI (on chain, 2026-10-13).
	address internal constant REGISTRAR_V2 = 0x60338a74c63EDeC7EC020cB9208DD234D9a2146F;
	address internal constant SLIPSTREAM1_ROUTER = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
	address internal constant SLIPSTREAM2_ROUTER = 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F;
	address internal constant SLIPSTREAM3_ROUTER = 0xcbBb8035cAc7D4B3Ca7aBb74cF7BdF900215Ce0D;

	/// @notice Deploys the feed (for `strategyFactory`'s vaults) and the adapter, and registers the adapter.
	function deploy(address strategyFactory) internal returns (ClmVaultPriceFeed feed, ClmVaultAdapter adapter) {
		feed = new ClmVaultPriceFeed(IValueInterpreter(VALUE_INTERPRETER), strategyFactory, REGISTRAR_V2);
		adapter = new ClmVaultAdapter(SLIPSTREAM1_ROUTER, SLIPSTREAM2_ROUTER, SLIPSTREAM3_ROUTER);
		FundFactory(FUND_FACTORY).registerAdapter(address(adapter));
	}

	/// @notice Lists each vault in the VI through registrar V2 → today's registrar.
	function list(ClmVaultPriceFeed feed, address[] memory vaults) internal {
		for (uint256 i; i < vaults.length; ++i) {
			PoolPriceRegistrarV2(REGISTRAR_V2).callOldRegistrar(
				abi.encodeCall(
					PoolPriceRegistrar.execute, (abi.encodeCall(ValueInterpreter.addDerivative, (vaults[i], address(feed))))
				)
			);
		}
	}
}
