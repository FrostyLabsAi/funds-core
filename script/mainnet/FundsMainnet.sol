// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ProtocolFeeReserve} from '../../src/core/ProtocolFeeReserve.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../../src/core/FundComponentDeployers.sol';
import {IUniswapV3SwapRouter} from '../../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {ISlipstreamSwapRouter} from '../../src/interfaces/external/ISlipstreamSwapRouter.sol';
import {IUniswapV3NonfungiblePositionManager} from '../../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {ISlipstreamNonfungiblePositionManager} from '../../src/interfaces/external/ISlipstreamNonfungiblePositionManager.sol';
import {
	IVerantaTradingRouter,
	IVerantaMulticall,
	IVerantaPairStorage,
	IVerantaReferral
} from '../../src/interfaces/external/IVeranta.sol';
import {UniswapV3SwapAdapter} from '../../src/adapters/UniswapV3SwapAdapter.sol';
import {AerodromeSlipstreamSwapAdapter} from '../../src/adapters/AerodromeSlipstreamSwapAdapter.sol';
import {ERC4626Adapter} from '../../src/adapters/ERC4626Adapter.sol';
import {LimitOrderPositionFactory} from '../../src/positions/LimitOrderPosition.sol';
import {UniswapV3LPPositionFactory} from '../../src/positions/UniswapV3LPPosition.sol';
import {SlipstreamLPPositionFactory} from '../../src/positions/SlipstreamLPPosition.sol';
import {VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {ERC4626ExitValueFeed} from '../../src/pricing/ERC4626ExitValueFeed.sol';

/// @title FundsMainnet
/// @notice FrostyFunds genesis on Base mainnet as code — one library the broadcast script
///         (DeployFundsMainnet) and the fork rehearsal (test/fork/FundsMainnetGenesisFork) both
///         run, so what is rehearsed is exactly what ships.
///         Every external address below was read live on Base on 2026-09-24 (factory() links,
///         symbols/decimals, feed descriptions); Chainlink feeds are the STANDARD (non-SVR)
///         proxies from Chainlink's own Base directory — SVR feeds can lag behind for the OEV
///         auction and must never price NAV.
///         Genesis leaves the deployer as owner of everything so the listing batches can run;
///         FundsGovernance then moves every power to the governance timelock with the Safe as
///         guardian, and proves the deployer holds nothing.
///         FROST is OPTIONAL (founder decision 2026-09-28: FrostyFunds launches first). Without it
///         there is no ProtocolFeeReserve and the protocol fee is off; governance turns it on
///         later with one timelock batch — `settleFees()` on every live fund, then
///         `setProtocolFee(bps, reserve)` — so no fund is charged for the time it was off (each
///         fund's fee clock only advances when that fund settles).
///         2026-10-04 (pool-pricing switch-over): genesis also shipped a TWAP tier, TwapListingRegistry
///         v1 + TwapExposurePolicy v1 on all four mandatory hooks. Both are retired and their source is
///         gone; their live addresses stay in deployments/base-mainnet.json (`twapRegistry`, `twapPolicy`),
///         and a rehearsal deploy of this library makes neither.
library FundsMainnet {
	// ─── Base mainnet externals (verified 2026-09-24) ───────────────────────────
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant WETH = 0x4200000000000000000000000000000000000006;
	address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
	address internal constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
	address internal constant EURC = 0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42;

	address internal constant CL_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
	address internal constant CL_ETH_USD = 0x50015f8b17fb2C290Dde41fDc246ed0dcEE93a8b;
	address internal constant CL_CBBTC_USD = 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D;
	address internal constant CL_AERO_USD = 0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0;
	address internal constant CL_EURC_USD = 0xDAe398520e2B67cd3f27aeF9Cf14D93D927f8250;
	address internal constant CL_SEQUENCER_UPTIME = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

	address internal constant UNI_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
	address internal constant UNI_SWAP_ROUTER02 = 0x2626664c2603336E57B271c5C0b26F421741e481;
	address internal constant UNI_NPM = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
	// Aerodrome runs two live Slipstream deployments with liquidity split between them
	address internal constant CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
	address internal constant CL_SWAP_ROUTER = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
	address internal constant CL_NPM = 0x827922686190790b37229fd06084350E74485b72;
	address internal constant CL2_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;
	address internal constant CL2_SWAP_ROUTER = 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F;
	address internal constant CL2_NPM = 0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53;
	/// @dev Slipstream-3's NonfungiblePositionManager (aerodrome-finance/slipstream README, "Gauge Caps
	///      Deployment"); factory() = 0xaDe6…716a, the pool factory CL3_FACTORY names
	///      (read 2026-10-01). Not a genesis venue: the fee compounders use it (CompoundersMainnet).
	address internal constant CL3_NPM = 0xa990C6a764b73BF43cee5Bb40339c3322FB9D55F;
	// ─── later venues (verified 2026-09-30; moved here from the retired TwapListingV2 2026-10-04) ─
	/// @dev Aerodrome's third Slipstream deployment; its router's factory() answers CL3_FACTORY.
	address internal constant CL3_FACTORY = 0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a;
	address internal constant CL3_SWAP_ROUTER = 0xcbBb8035cAc7D4B3Ca7aBb74cF7BdF900215Ce0D;
	/// @dev Uniswap v2 factory = router02 (0x4752…aD24).factory().
	address internal constant UNI_V2_FACTORY = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
	/// @dev Uniswap v2 Router02; its factory() answers UNI_V2_FACTORY.
	address internal constant UNI_V2_ROUTER = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
	/// @dev Aerodrome basic PoolFactory = Router (0xcF77…4E43).defaultFactory().
	address internal constant AERODROME_POOL_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
	/// @dev Aerodrome Router; its defaultFactory() answers AERODROME_POOL_FACTORY.
	address internal constant AERODROME_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;

	address internal constant VERANTA_ROUTER = 0x44914408af82bC9983bbb330e3578E1105e11d4e;
	address internal constant VERANTA_STORAGE = 0x8a311D7048c35985aa31C131B9A13e03a5f7422d;
	address internal constant VERANTA_MULTICALL = 0xA7cFc43872F4D7B0E6141ee8c36f1F7FEe5d099e;
	address internal constant VERANTA_PAIR_STORAGE = 0x5db3772136e5557EFE028Db05EE95C84D76faEC4;
	address internal constant VERANTA_REFERRAL = 0x1A110bBA13A1f16cCa4b79758BD39290f29De82D;
	/// @dev bytes32('frostyfi') — codeOwners() on the Referral contract answers the founder's
	///      Veranta wallet 0xc761…0238 (read 2026-09-24)
	bytes32 internal constant VERANTA_REFERRAL_CODE = 'frostyfi';
	address internal constant AV_USDC = 0x944766f715b51967E56aFdE5f0Aa76cEaCc9E7f9;

	// ─── protocol constants ─────────────────────────────────────────────────────
	uint32 internal constant SEQUENCER_GRACE = 1 hours;
	uint256 internal constant LIMIT_ORDER_TYPE = 2;
	uint256 internal constant UNI_LP_TYPE = 3;
	uint256 internal constant SLIPSTREAM_LP_TYPE = 4;
	uint256 internal constant VERANTA_PERP_TYPE = 6;
	uint256 internal constant SLIPSTREAM2_LP_TYPE = 7;
	uint16 internal constant MAX_PROTOCOL_FEE_BPS = 100;
	uint256 internal constant VERANTA_ETH_PAIR = 0;
	uint256 internal constant VERANTA_BTC_PAIR = 1;

	struct Config {
		address deployer; // the broadcasting EOA — owns everything until FundsGovernance hands off
		address safe; // guardian: one-way OFF switches only
		address frost; // the fee reserve's buyback-and-burn asset; zero = no reserve, fee off
		address autopilotKeeper; // Veranta delegate for funds that opt in
		uint16 protocolFeeBps; // AUM fee, bytecode-capped at 1%
	}

	struct Deployed {
		ValueInterpreter valueInterpreter;
		FundFactory factory;
		ProtocolFeeReserve feeReserve;
		address twapRegistry; // retired (see the title); zero on a rehearsal deploy
		address twapPolicy; // retired; zero on a rehearsal deploy
		VerantaPerpPositionV2Factory verantaFactory;
		address uniAdapter;
		address slipstreamAdapter;
		address slipstream2Adapter;
		address erc4626Adapter;
		address exitValueFeed;
	}

	error BadConfig();

	/// @notice Deploy and wire everything; the caller (deployer EOA) owns it all afterwards.
	function deploy(Config memory cfg) internal returns (Deployed memory d) {
		if (cfg.deployer == address(0) || cfg.safe == address(0) || cfg.autopilotKeeper == address(0)) revert BadConfig();
		if (cfg.autopilotKeeper == cfg.deployer) revert BadConfig();
		if (cfg.protocolFeeBps > MAX_PROTOCOL_FEE_BPS) revert BadConfig();
		// a fee needs its reserve, and the reserve needs FROST
		if (cfg.frost == address(0) && cfg.protocolFeeBps != 0) revert BadConfig();

		_deployPricing(d, cfg);
		_deployFactory(d, cfg);
		_deployVenues(d, cfg);
	}

	function _deployPricing(Deployed memory d, Config memory cfg) private {
		ValueInterpreter vi = new ValueInterpreter(cfg.deployer);
		vi.setSequencerUptimeFeed(CL_SEQUENCER_UPTIME, SEQUENCER_GRACE);
		// VI heartbeat = the feed's own heartbeat + margin (20-min feeds → 1h; daily → 25h)
		vi.addPrimitive(USDC, CL_USDC_USD, 25 hours);
		vi.addPrimitive(WETH, CL_ETH_USD, 1 hours);
		vi.addPrimitive(CBBTC, CL_CBBTC_USD, 1 hours);
		vi.addPrimitive(AERO, CL_AERO_USD, 25 hours);
		vi.addPrimitive(EURC, CL_EURC_USD, 25 hours);
		// Veranta's LP vault, valued at what redeeming actually pays (1.5% exit fee)
		d.exitValueFeed = address(new ERC4626ExitValueFeed());
		vi.addDerivative(AV_USDC, d.exitValueFeed);
		d.valueInterpreter = vi;
	}

	function _deployFactory(Deployed memory d, Config memory cfg) private {
		FundFactory factory = new FundFactory(d.valueInterpreter, new ComptrollerDeployer(), new SharesVaultDeployer());
		if (cfg.frost != address(0)) {
			d.feeReserve = new ProtocolFeeReserve(cfg.frost, cfg.deployer);
			factory.setProtocolFee(cfg.protocolFeeBps, address(d.feeReserve));
		}
		factory.setGuardian(cfg.safe);
		d.factory = factory;
	}

	function _deployVenues(Deployed memory d, Config memory cfg) private {
		FundFactory factory = d.factory;
		d.uniAdapter = address(new UniswapV3SwapAdapter(IUniswapV3SwapRouter(UNI_SWAP_ROUTER02)));
		d.slipstreamAdapter = address(new AerodromeSlipstreamSwapAdapter(ISlipstreamSwapRouter(CL_SWAP_ROUTER)));
		d.slipstream2Adapter = address(new AerodromeSlipstreamSwapAdapter(ISlipstreamSwapRouter(CL2_SWAP_ROUTER)));
		d.erc4626Adapter = address(new ERC4626Adapter());
		factory.registerAdapter(d.uniAdapter);
		factory.registerAdapter(d.slipstreamAdapter);
		factory.registerAdapter(d.slipstream2Adapter);
		factory.registerAdapter(d.erc4626Adapter);

		factory.registerPositionType(LIMIT_ORDER_TYPE, address(new LimitOrderPositionFactory()));
		factory.registerPositionType(
			UNI_LP_TYPE, address(new UniswapV3LPPositionFactory(IUniswapV3NonfungiblePositionManager(UNI_NPM)))
		);
		factory.registerPositionType(
			SLIPSTREAM_LP_TYPE, address(new SlipstreamLPPositionFactory(ISlipstreamNonfungiblePositionManager(CL_NPM)))
		);
		factory.registerPositionType(
			SLIPSTREAM2_LP_TYPE, address(new SlipstreamLPPositionFactory(ISlipstreamNonfungiblePositionManager(CL2_NPM)))
		);

		VerantaPerpPositionV2Factory verantaFactory = new VerantaPerpPositionV2Factory(
			IERC20(USDC),
			IVerantaTradingRouter(VERANTA_ROUTER),
			IVerantaMulticall(VERANTA_MULTICALL),
			VERANTA_STORAGE,
			IVerantaPairStorage(VERANTA_PAIR_STORAGE),
			cfg.autopilotKeeper
		);
		verantaFactory.setReferral(IVerantaReferral(VERANTA_REFERRAL), VERANTA_REFERRAL_CODE);
		// genesis perps whose underlying is a real Base token priced above; the rest are mapped
		// in listing batches (PriceMarkers) before the governance handoff
		verantaFactory.setPairAsset(VERANTA_ETH_PAIR, WETH);
		verantaFactory.setPairAsset(VERANTA_BTC_PAIR, CBBTC);
		factory.registerPositionType(VERANTA_PERP_TYPE, address(verantaFactory));
		d.verantaFactory = verantaFactory;
	}

}
