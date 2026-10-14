// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {ViAdmin} from './ListingModuleBook.sol';

/// @title YieldListing
/// @notice The yield vaults funds can deposit into through the generic ERC4626Adapter,
///         registered as ValueInterpreter derivatives on one ERC4626PriceFeed. Every address
///         was read on-chain 2026-09-27 (`asset()`, `name()`, `decimals()`):
///         - Aave V3 static aTokens (aave-address-book AaveV3Base) — non-rebasing 4626 wrappers
///         - Morpho MetaMorpho vaults on the terminal's Yield page (Morpho API)
///         - IPOR Fusion "carry trade" vaults whose asset() is a Coinbase stock token — the
///           stock-token yields beyond Aerodrome/Uniswap LPs (which need no listing: they are
///           LP positions on stocks the stock script already prices)
///         A vault is listed only when its underlying is already priced, so on mainnet this
///         runs AFTER list-coinbase-stocks.sh. Already-listed vaults are skipped.
///         Each derivative is added through the VI's owner (`admin.execute`: the pool-pricing
///         registrar, or the TWAP v2 module before the switch-over; its owner only).
library YieldListing {
	address internal constant AAVE_STATIC_USDC = 0xC768c589647798a6EE01A91FdE98EF2ed046DBD6;
	address internal constant AAVE_STATIC_WETH = 0xe298b938631f750DD409fB18227C4a23dCdaab9b;
	address internal constant AAVE_STATIC_EURC = 0x729F75Aff28c726e32403e80cef2aFb518CFbfa7;
	address internal constant AAVE_STATIC_CBBTC = 0xFA2A03b6f4A65fB1Af64f7d935fDBf78693df9aF;
	address internal constant MORPHO_GAUNTLET_USDC_PRIME = 0xeE8F4eC5672F09119b96Ab6fB59C27E1b7e44b61;
	address internal constant MORPHO_STEAKHOUSE_USDC = 0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183;
	address internal constant MORPHO_MOONWELL_FLAGSHIP_USDC = 0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca;

	address internal constant IPOR_GOOGL_CARRY = 0x01DBDB9748ECf71B1fFbb62f5cB41318531bA362;
	address internal constant IPOR_META_CARRY = 0xCd19f18884bf388b866D05cDd1ae351133821F01;
	address internal constant IPOR_AAPL_CARRY = 0x31744E44d6aF88225C1dBEFbe5Df8308fAeA641B;
	address internal constant IPOR_NVDA_CARRY = 0xFb132f4C6d9DCF4f80483Ea7D96C5A5dccfcFE83;
	address internal constant GOOGLC = 0xb2000000000000000000002D0BA3164cc74f58B7;

	error UnderlyingNotPriced(address vault, address asset);

	function nonStockVaults() internal pure returns (address[] memory v) {
		v = new address[](7);
		v[0] = AAVE_STATIC_USDC;
		v[1] = AAVE_STATIC_WETH;
		v[2] = AAVE_STATIC_EURC;
		v[3] = AAVE_STATIC_CBBTC;
		v[4] = MORPHO_GAUNTLET_USDC_PRIME;
		v[5] = MORPHO_STEAKHOUSE_USDC;
		v[6] = MORPHO_MOONWELL_FLAGSHIP_USDC;
	}

	function stockVaults() internal pure returns (address[] memory v) {
		v = new address[](4);
		v[0] = IPOR_GOOGL_CARRY;
		v[1] = IPOR_META_CARRY;
		v[2] = IPOR_AAPL_CARRY;
		v[3] = IPOR_NVDA_CARRY;
	}

	function listAll(ViAdmin memory admin, ValueInterpreter vi, address feed, address[] memory vaults)
		internal
		returns (uint256 listed)
	{
		for (uint256 i; i < vaults.length; ++i) {
			if (vi.isSupportedAsset(vaults[i])) continue;
			address asset = IERC4626(vaults[i]).asset();
			if (!vi.isSupportedAsset(asset)) revert UnderlyingNotPriced(vaults[i], asset);
			admin.execute(abi.encodeCall(ValueInterpreter.addDerivative, (vaults[i], feed)));
			++listed;
		}
	}
}
