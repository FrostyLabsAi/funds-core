// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ProtocolFeeReserve} from '../../src/core/ProtocolFeeReserve.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../../src/core/FundComponentDeployers.sol';
import {IPolicy} from '../../src/interfaces/IPolicy.sol';
import {IValueInterpreter} from '../../src/interfaces/IValueInterpreter.sol';
import {AggregatorV3Interface} from '../../src/interfaces/AggregatorV3Interface.sol';
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
import {RedstonePriceStore} from '../../src/pricing/RedstonePriceStore.sol';
import {TwapListingRegistry, IUniswapV3PoolFactory, ISlipstreamPoolFactory} from '../../src/pricing/TwapListingRegistry.sol';
import {TwapExposurePolicy} from '../../src/policies/TwapExposurePolicy.sol';

/// @title FundsMainnet
/// @notice FrostyFunds genesis on Base mainnet as code — one library the broadcast script
///         (DeployFundsMainnet) and the fork rehearsal (test/fork/FundsMainnetGenesisFork) both
///         run, so what is rehearsed is exactly what ships.
///         Every external address below was read live on Base on 2026-09-24 (factory() links,
///         symbols/decimals, feed descriptions); Chainlink feeds are the STANDARD (non-SVR)
///         proxies from Chainlink's own Base directory — SVR feeds can lag behind for the OEV
///         auction and must never price NAV.
///         Genesis leaves the deployer as owner of everything so the listing batches can run;
///         FundsGovernance then moves every power to the (FROST-shared) timelock with the Safe
///         as guardian, and proves the deployer holds nothing.
library FundsMainnet {
	// ─── Base mainnet externals (verified 2026-09-24) ───────────────────────────
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant WETH = 0x4200000000000000000000000000000000000006;
	address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
	address internal constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
	address internal constant EURC = 0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42;

	address internal constant CL_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
	address internal constant CL_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
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
		address frost; // the fee reserve's buyback-and-burn asset
		address autopilotKeeper; // Veranta delegate for funds that opt in
		uint16 protocolFeeBps; // AUM fee, bytecode-capped at 1%
	}

	struct Deployed {
		ValueInterpreter valueInterpreter;
		FundFactory factory;
		ProtocolFeeReserve feeReserve;
		TwapListingRegistry twapRegistry;
		TwapExposurePolicy twapPolicy;
		VerantaPerpPositionV2Factory verantaFactory;
		RedstonePriceStore redstoneStore;
		address uniAdapter;
		address slipstreamAdapter;
		address slipstream2Adapter;
		address erc4626Adapter;
		address exitValueFeed;
	}

	error BadConfig();

	/// @notice Deploy and wire everything; the caller (deployer EOA) owns it all afterwards.
	function deploy(Config memory cfg) internal returns (Deployed memory d) {
		if (cfg.deployer == address(0) || cfg.safe == address(0) || cfg.frost == address(0) || cfg.autopilotKeeper == address(0)) {
			revert BadConfig();
		}
		if (cfg.autopilotKeeper == cfg.deployer) revert BadConfig();
		if (cfg.protocolFeeBps > MAX_PROTOCOL_FEE_BPS) revert BadConfig();

		_deployPricing(d, cfg);
		_deployFactory(d, cfg);
		_deployVenues(d, cfg);
		_deployTwapTier(d);
		d.redstoneStore = new RedstonePriceStore('redstone-primary-prod', primaryProdSigners(), 3);
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
		d.feeReserve = new ProtocolFeeReserve(cfg.frost, cfg.deployer);
		factory.setProtocolFee(cfg.protocolFeeBps, address(d.feeReserve));
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

	function _deployTwapTier(Deployed memory d) private {
		TwapListingRegistry registry = new TwapListingRegistry(
			IValueInterpreter(address(d.valueInterpreter)),
			IUniswapV3PoolFactory(UNI_FACTORY),
			ISlipstreamPoolFactory(CL_FACTORY),
			ISlipstreamPoolFactory(CL2_FACTORY)
		);
		registry.setQuote(USDC, AggregatorV3Interface(CL_USDC_USD), 25 hours);
		registry.setQuote(WETH, AggregatorV3Interface(CL_ETH_USD), 1 hours);
		TwapExposurePolicy policy = new TwapExposurePolicy(registry);

		FundFactory.PolicyReg[] memory mandatory = new FundFactory.PolicyReg[](4);
		mandatory[0] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnIntegration, policy: address(policy)});
		mandatory[1] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostDepositRequest, policy: address(policy)});
		mandatory[2] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.CreateExternalPosition, policy: address(policy)});
		mandatory[3] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnExternalPosition, policy: address(policy)});
		d.factory.setMandatoryPolicies(mandatory);

		d.twapRegistry = registry;
		d.twapPolicy = policy;
	}

	/// @notice redstone-primary-prod, threshold 3 — RedStone's PrimaryProdDataServiceConsumerBase
	///         (read 2026-09-24), the same five seen signing on the gateway.
	function primaryProdSigners() internal pure returns (address[] memory s) {
		s = new address[](5);
		s[0] = 0x8BB8F32Df04c8b654987DAaeD53D6B6091e3B774;
		s[1] = 0xdEB22f54738d54976C4c0fe5ce6d408E40d88499;
		s[2] = 0x51Ce04Be4b3E32572C4Ec9135221d0691Ba7d202;
		s[3] = 0xDD682daEC5A90dD295d14DA4b0bec9281017b5bE;
		s[4] = 0x9c5AE89C4Af6aA32cE58588DBaF90d18a855B6de;
	}
}
