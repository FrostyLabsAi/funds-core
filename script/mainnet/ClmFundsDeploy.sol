// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {FundFactory} from '../../src/core/FundFactory.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {PoolPriceRegistrarV2} from '../../src/pricing/PoolPriceRegistrarV2.sol';
import {PoolPriceRegistrarV3} from '../../src/pricing/PoolPriceRegistrarV3.sol';
import {IFrostyClmVault, IFrostyClmStrategy} from '../../src/interfaces/external/IFrostyClm.sol';
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

	/// @notice Lists the vaults the VI doesn't price yet (vaults deployed after DeployClmFunds, 2026-10-14), so a rerun
	///         lists nothing. The VI refuses a vault the feed doesn't support (FeedDoesNotSupportAsset).
	function listUnpriced(ClmVaultPriceFeed feed, address[] memory vaults) internal returns (uint256 listed) {
		address[] memory unpriced = new address[](vaults.length);
		for (uint256 i; i < vaults.length; ++i) {
			if (!ValueInterpreter(VALUE_INTERPRETER).isSupportedAsset(vaults[i])) unpriced[listed++] = vaults[i];
		}
		assembly ('memory-safe') {
			mstore(unpriced, listed)
		}
		list(feed, unpriced);
	}

	/// @notice Lists each vault in the VI through registrar V2 → today's registrar — through registrar V3 first once V3
	///         owns V2 (the Aero venue, 2026-10-25: V3's callOldRegistrar is V2's, one hop further; the deployer owns V3).
	///         With V3 in place a vault holding a token V3 prices from an Aero pool is refused: the feed's own check
	///         (ClmVaultPriceFeed._oracleFed) asks registrar V2, which can't see it, and the vault share would carry a
	///         long-tail token without the long-tail rules (final review 2026-10-08, I1; review 2026-10-25).
	function list(ClmVaultPriceFeed feed, address[] memory vaults) internal {
		address v2Owner = PoolPriceRegistrarV2(REGISTRAR_V2).owner();
		// an EOA with an EIP-7702 delegation has code too, `0xef0100 || delegate` (23 bytes): the deployer has had
		// MetaMask's, so this read it as registrar V3 before V3 existed (2026-11-01, four fork tests)
		bytes memory ownerCode = v2Owner.code;
		bool viaV3 = ownerCode.length > 0 && !(ownerCode.length == 23 && bytes3(ownerCode) == 0xef0100);
		PoolPriceRegistrarV2 via = PoolPriceRegistrarV2(viaV3 ? v2Owner : REGISTRAR_V2);
		for (uint256 i; i < vaults.length; ++i) {
			if (viaV3) _refuseLongTail(PoolPriceRegistrarV3(v2Owner), vaults[i]);
			via.callOldRegistrar(
				abi.encodeCall(
					PoolPriceRegistrar.execute, (abi.encodeCall(ValueInterpreter.addDerivative, (vaults[i], address(feed))))
				)
			);
		}
	}

	error ClmVaultOnLongTailToken(address vault, address token);

	function _refuseLongTail(PoolPriceRegistrarV3 v3, address vault) private view {
		IFrostyClmStrategy strategy = IFrostyClmStrategy(IFrostyClmVault(vault).strategy());
		address[2] memory tokens = [strategy.lpToken0(), strategy.lpToken1()];
		for (uint256 i; i < 2; ++i) {
			if (v3.poolPricedAdapter(tokens[i]) != address(0)) revert ClmVaultOnLongTailToken(vault, tokens[i]);
		}
	}
}
