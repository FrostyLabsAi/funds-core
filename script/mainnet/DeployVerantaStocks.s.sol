// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console} from 'forge-std/Script.sol';
import {IPythLazerVerifier, IVerantaLazerPairs} from '../../src/pricing/VerantaPriceStore.sol';
import {VerantaPriceStoreV2} from '../../src/pricing/VerantaPriceStoreV2.sol';
import {B20VerantaPriceAdapter} from '../../src/pricing/B20VerantaPriceAdapter.sol';

/// @notice Seven Coinbase stocks with no Chainlink feed, priced from Veranta's Pyth-signed prices (founder 2026-10-25):
///         the weekend-proof VerantaPriceStoreV2 and one B20VerantaPriceAdapter per stock. Lists nothing: the owner
///         lists each stock with script/mainnet/list-veranta-stocks.sh (cast — `addPrimitive` reads the B20 token's
///         decimals(), which Foundry can't run). Touches no token: B20 tokens are a Base precompile.
///         Each stock had a USDC pool of $198k+ on Aero filling a $10k buy within 1.1% (2026-10-25) and a Veranta perp.
///         Rehearsed in test/fork/VerantaPriceStoreV2Fork.t.sol.
///         Run: forge script script/mainnet/DeployVerantaStocks.s.sol --rpc-url base --account frosty-main
///              --sender <deployer> --broadcast --slow --verify
///         Then: list-veranta-stocks.sh; the keeper's VERANTA_PRICE_STORES gets `store` appended.
contract DeployVerantaStocks is Script {
	IPythLazerVerifier public constant LAZER = IPythLazerVerifier(0xACeA761c27A909d4D3895128EBe6370FDE2dF481);
	IVerantaLazerPairs public constant VERANTA_PAIRS = IVerantaLazerPairs(0x5db3772136e5557EFE028Db05EE95C84D76faEC4);
	/// @notice A price must have been confirmed by Pyth within 2 minutes … (review 2026-10-25: v6 funds pay instant USDC
	///         exits at the stored price, so the window a stored price can be used in is the window it can be picked in;
	///         the perps' 10 minutes, 2026-10-05, never reached an instant exit)
	uint32 public constant MAX_PUSH_AGE = 120;
	/// @notice … and traded within 5 days: outlives a weekend plus a holiday (longest closure seen ≈ 92.5 h).
	uint32 public constant MAX_FEED_AGE = 432_000;
	string public constant OUTPUT_PATH = 'deployments/base-mainnet-veranta-stocks.json';

	struct Stock {
		string symbol;
		address token;
		uint256 pair; // Veranta pair index
	}

	struct Deployed {
		VerantaPriceStoreV2 store;
		B20VerantaPriceAdapter[] adapters; // in stocks() order
	}

	/// @notice Coinbase's token addresses (api.coinbase.com/v1/tokenized-stocks) and Veranta's pair indexes
	///         (data.veranta.xyz/v2/trading), 2026-10-25.
	function stocks() public pure returns (Stock[] memory s) {
		s = new Stock[](7);
		s[0] = Stock('MUc', 0xb200000000000000000000Fd2f87532B90095211, 100);
		s[1] = Stock('PLTRc', 0xb2000000000000000000007d16372840dF4dAbbe, 110);
		s[2] = Stock('NFLXc', 0xb20000000000000000000058B8c947e44011dFE6, 112);
		s[3] = Stock('AMDc', 0xB2000000000000000000000d8Ce462E99ee7A47B, 98);
		s[4] = Stock('AVGOc', 0xB200000000000000000000Fc737aeA6196aB5a4c, 111);
		s[5] = Stock('MRVLc', 0xB200000000000000000000eC3c4c7395Cc609813, 107);
		s[6] = Stock('LLYc', 0xB200000000000000000000f1a0F91e34892E4718, 120);
	}

	function run() external {
		vm.startBroadcast();
		Deployed memory d = deploy();
		vm.stopBroadcast();
		Stock[] memory s = stocks();
		string memory json;
		for (uint256 i; i < s.length; ++i) {
			json = vm.serializeAddress('verantaStocks', s[i].symbol, address(d.adapters[i]));
		}
		vm.writeJson(vm.serializeAddress('verantaStocks', 'store', address(d.store)), OUTPUT_PATH);
		console.log('wrote', OUTPUT_PATH);
	}

	function deploy() public returns (Deployed memory d) {
		d.store = new VerantaPriceStoreV2(LAZER, VERANTA_PAIRS);
		Stock[] memory s = stocks();
		d.adapters = new B20VerantaPriceAdapter[](s.length);
		for (uint256 i; i < s.length; ++i) {
			d.adapters[i] = new B20VerantaPriceAdapter(
				d.store, s[i].pair, s[i].token, MAX_PUSH_AGE, MAX_FEED_AGE, string.concat(s[i].symbol, ' / USD (Veranta x multiplier)')
			);
		}
	}
}
