// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console} from 'forge-std/Script.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ERC4626ExitAdapter} from '../../src/adapters/ERC4626ExitAdapter.sol';
import {ClmVaultExitAdapter} from '../../src/adapters/ClmVaultExitAdapter.sol';
import {AerodromeSlipstreamSwapAdapterV2} from '../../src/adapters/AerodromeSlipstreamSwapAdapterV2.sol';
import {ViaWethSellAdapterV2} from '../../src/adapters/ViaWethSellAdapterV2.sol';
import {ISlipstreamSwapRouter} from '../../src/interfaces/external/ISlipstreamSwapRouter.sol';
import {ClmFundsDeploy} from './ClmFundsDeploy.sol';
import {FundsMainnet} from './FundsMainnet.sol';
import {V4Pricing} from './V4Pricing.sol';

/// @notice The adapters that reach Aero's pools (FrostyFi 2026-10-25): since the Aero upgrade (2026-10-22) the liquidity
///         of most pools, the stock tokens' first, is in Aero's Slipstream pools, which the three Aerodrome routers
///         can't reach.
///         - The v6 keeper's exit adapters again: same code as DeployExitAdapters (2026-10-14); the router set is Aero's
///           and the two Aerodrome deployments whose pools still hold liquidity (Slipstream-1 ≈ $2.4M and -2 ≈ $2.3M of
///           pool-pricing liquidity on 2026-10-25; Slipstream-3 ≈ $0.19M). Each router takes the token | int24
///           tickSpacing | token exactInput path. The 2026-10-14 adapters stay registered.
///         - A spot adapter on Aero's router, for managers' trades and the keeper's direct sales: the fee-taking
///           AerodromeSlipstreamSwapAdapterV2 (V4Pricing's: 5 bps to the Treasury Safe, owner-set 0–10), whose
///           exactInputSingle params Aero's SwapRouter takes unchanged (metadex-slipstream-public ISwapRouter).
///         - ViaWethSellAdapterV2: the keeper's sale through WETH with Aero as a hop venue, on DeployViaWethSell's
///           routers plus Aero's, same fee. The 2026-10-14 ViaWethSellAdapter stays registered.
///         Rehearsed in test/fork/ClmV2AeroLiquidationFork.t.sol. Touches no stock token.
///         Run: forge script script/mainnet/DeployAeroAdapters.s.sol --rpc-url base --account frosty-main
///              --sender <deployer> --broadcast --slow --verify
///         Then the keeper: LIQUIDATION_ADAPTERS.erc4626Exit = `erc4626Exit`, .aero = `aeroSwap`, .viaWeth = `viaWeth`,
///         CLM_ADAPTER = `clmExit`; the terminal: npx tsx indexer/mainnet-deployments.ts.
contract DeployAeroAdapters is Script {
	/// @notice Aero's Slipstream SwapRouter (Dromos-Labs metadex-slipstream-public deployment-addresses/cl-base.json;
	///         its factory() is Aero's CL factory 0x9CB2…7a76, checked 2026-10-25).
	address public constant AERO_SWAP_ROUTER = 0x9Ee35Bf1bd69a03c6F0393582030fCe8Bb93D418;
	string public constant OUTPUT_PATH = 'deployments/base-mainnet-aero-adapters.json';

	struct Adapters {
		ERC4626ExitAdapter erc4626Exit;
		ClmVaultExitAdapter clmExit;
		AerodromeSlipstreamSwapAdapterV2 aeroSwap;
		ViaWethSellAdapterV2 viaWeth;
	}

	function run() external {
		vm.startBroadcast();
		Adapters memory a = deployAdapters(msg.sender);
		FundFactory(ClmFundsDeploy.FUND_FACTORY).registerAdapter(address(a.erc4626Exit));
		FundFactory(ClmFundsDeploy.FUND_FACTORY).registerAdapter(address(a.clmExit));
		FundFactory(ClmFundsDeploy.FUND_FACTORY).registerAdapter(address(a.aeroSwap));
		FundFactory(ClmFundsDeploy.FUND_FACTORY).registerAdapter(address(a.viaWeth));
		vm.stopBroadcast();
		vm.serializeAddress('aeroAdapters', 'erc4626Exit', address(a.erc4626Exit));
		vm.serializeAddress('aeroAdapters', 'clmExit', address(a.clmExit));
		vm.serializeAddress('aeroAdapters', 'aeroSwap', address(a.aeroSwap));
		vm.writeJson(vm.serializeAddress('aeroAdapters', 'viaWeth', address(a.viaWeth)), OUTPUT_PATH);
		console.log('wrote', OUTPUT_PATH);
	}

	/// @param owner the fee-taking adapters' owner (it sets the fee): the genesis deployer until the governance handoff
	function deployAdapters(address owner) public returns (Adapters memory a) {
		a.erc4626Exit = new ERC4626ExitAdapter(AERO_SWAP_ROUTER, ClmFundsDeploy.SLIPSTREAM1_ROUTER, ClmFundsDeploy.SLIPSTREAM2_ROUTER);
		a.clmExit = new ClmVaultExitAdapter(AERO_SWAP_ROUTER, ClmFundsDeploy.SLIPSTREAM1_ROUTER, ClmFundsDeploy.SLIPSTREAM2_ROUTER);
		a.aeroSwap = new AerodromeSlipstreamSwapAdapterV2(
			ISlipstreamSwapRouter(AERO_SWAP_ROUTER), V4Pricing.TREASURY, V4Pricing.FEE_BPS, owner
		);
		a.viaWeth = new ViaWethSellAdapterV2(
			FundsMainnet.WETH,
			FundsMainnet.UNI_SWAP_ROUTER02,
			FundsMainnet.CL_SWAP_ROUTER,
			FundsMainnet.CL2_SWAP_ROUTER,
			FundsMainnet.CL3_SWAP_ROUTER,
			FundsMainnet.AERODROME_ROUTER,
			FundsMainnet.AERODROME_POOL_FACTORY,
			AERO_SWAP_ROUTER,
			V4Pricing.TREASURY,
			V4Pricing.FEE_BPS,
			owner
		);
	}
}
