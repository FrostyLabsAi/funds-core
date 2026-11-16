// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {IComptrollerDeployer} from '../../src/interfaces/IComptrollerDeployer.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/ComptrollerBlueprintDeployer.sol';
import {SharesVaultDeployer} from '../../src/core/SharesVaultDeployer.sol';
import {RedemptionQueue} from '../../src/redemption/RedemptionQueue.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {V4PriceSampler} from '../../src/pricing/V4PriceSampler.sol';
import {VerantaPriceStore} from '../../src/pricing/VerantaPriceStore.sol';
import {ClmVaultPriceFeed} from '../../src/pricing/ClmVaultPriceFeed.sol';
import {ERC4626PriceFeed} from '../../src/pricing/ERC4626PriceFeed.sol';
import {ERC4626ExitValueFeed} from '../../src/pricing/ERC4626ExitValueFeed.sol';
import {VerantaPerpConfig} from '../../src/positions/VerantaPerpConfig.sol';
import {VerantaPerpPositionFactory} from '../../src/positions/VerantaPerpPositionFactory.sol';
import {MinPoolLiquidityPolicy} from '../../src/policies/MinPoolLiquidityPolicy.sol';
import {CumulativeSlippageTolerancePolicy} from '../../src/policies/CumulativeSlippageTolerancePolicy.sol';
import {UniswapV3SwapAdapter} from '../../src/adapters/UniswapV3SwapAdapter.sol';
import {UniswapV4SwapAdapter} from '../../src/adapters/UniswapV4SwapAdapter.sol';
import {AerodromeSlipstreamSwapAdapter} from '../../src/adapters/AerodromeSlipstreamSwapAdapter.sol';
import {AerodromeBasicSwapAdapter} from '../../src/adapters/AerodromeBasicSwapAdapter.sol';
import {ViaWethSellAdapter} from '../../src/adapters/ViaWethSellAdapter.sol';
import {ClmVaultAdapter} from '../../src/adapters/ClmVaultAdapter.sol';
import {ClmVaultExitAdapter} from '../../src/adapters/ClmVaultExitAdapter.sol';
import {ERC4626Adapter} from '../../src/adapters/ERC4626Adapter.sol';
import {ERC4626ExitAdapter} from '../../src/adapters/ERC4626ExitAdapter.sol';
import {ProtectRegistry} from '../../src/protect/ProtectRegistry.sol';
import {AdvisorRegistry} from '../../src/protect/AdvisorRegistry.sol';
import {FundProfileRegistry} from '../../src/profile/FundProfileRegistry.sol';
import {IPolicy} from '../../src/interfaces/IPolicy.sol';
import {IValueInterpreterAdmin} from '../../src/interfaces/IValueInterpreterAdmin.sol';
import {IUniswapV3SwapRouter} from '../../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {ISlipstreamSwapRouter} from '../../src/interfaces/external/ISlipstreamSwapRouter.sol';
import {IAerodromeRouter} from '../../src/interfaces/external/IAerodromeRouter.sol';
import {IPythLazerVerifier} from '../../src/interfaces/external/IPythLazerVerifier.sol';
import {IV4PoolManager, IV4StateView} from '../../src/interfaces/external/IUniswapV4.sol';
import {
	IVerantaTradingRouter,
	IVerantaMulticall,
	IVerantaPairStorage,
	IVerantaReferral
} from '../../src/interfaces/external/IVeranta.sol';
import {BaseMainnet} from './BaseMainnet.sol';

/// @title Release
/// @notice The clean release (2026-11-15): every contract a fund uses, deployed fresh and wired together, on a fresh
///         ValueInterpreter. Shared by script/release/DeployRelease.s.sol and the fork tests, so what is rehearsed is what
///         ships. Listings (Chainlink feeds beyond the three quotes, pool-priced tokens, Veranta pairs, B20 stocks, CLM
///         vaults, v4 approvals and hooks) are a separate step, ReleaseListings.
/// @dev Every contract is owned by `owner` (the deployer) until governance takes it over. Runs as `owner`: the caller is
///      the VI's and the factory's owner while it wires them.
library Release {
	struct Config {
		/// @dev The owner of every owned contract (the deployer).
		address owner;
		/// @dev The protocol's swap-fee recipient.
		address treasury;
		/// @dev The factory's guardian (instant deposit pause) and the v4 pool approver.
		address guardian;
		/// @dev The redemption queue's keeper, the v4 sampler's keeper and the perp autopilot's keeper.
		address keeper;
	}

	struct Deployed {
		ValueInterpreter valueInterpreter;
		PoolPriceRegistrar registrar;
		V4PriceSampler sampler;
		RedemptionQueue queue;
		VerantaPerpConfig perpConfig;
		VerantaPerpPositionFactory perpFactory;
		ComptrollerBlueprintDeployer comptrollerDeployer;
		SharesVaultDeployer sharesVaultDeployer;
		FundFactory factory;
		MinPoolLiquidityPolicy minPoolLiquidity;
		CumulativeSlippageTolerancePolicy slippage;
		VerantaPriceStore verantaStore;
		ClmVaultPriceFeed clmFeed;
		ERC4626PriceFeed erc4626Feed;
		ERC4626ExitValueFeed erc4626ExitFeed;
		Adapters adapters;
		ProtectRegistry protectRegistry;
		AdvisorRegistry advisorRegistry;
		FundProfileRegistry profileRegistry;
	}

	struct Adapters {
		UniswapV3SwapAdapter uniswapV3;
		UniswapV4SwapAdapter uniswapV4;
		AerodromeSlipstreamSwapAdapter slipstream1;
		AerodromeSlipstreamSwapAdapter slipstream2;
		AerodromeSlipstreamSwapAdapter slipstream3;
		AerodromeSlipstreamSwapAdapter aero;
		AerodromeBasicSwapAdapter aerodromeBasic;
		ViaWethSellAdapter viaWeth;
		ClmVaultAdapter clm;
		ClmVaultExitAdapter clmExit;
		ERC4626Adapter erc4626;
		ERC4626ExitAdapter erc4626Exit;
	}

	error NotTheOwner(address caller, address owner);

	function deploy(Config memory cfg) internal returns (Deployed memory d) {
		// every owned contract's first owner is its deployer, and the wiring below needs that to be `cfg.owner`
		if (msg.sender != cfg.owner && address(this) != cfg.owner) revert NotTheOwner(msg.sender, cfg.owner);
		_deployPricing(d, cfg);
		_deployFunds(d, cfg);
		_deployAdapters(d, cfg);
		_deployPerps(d, cfg);
		// last: createFund is open to anyone, and a fund keeps the policies it was created with (see _deployFunds)
		d.factory.setComptrollerDeployer(d.comptrollerDeployer);
		_deployRegistries(d);
	}

	/// @dev A fresh VI with the sequencer check and the three quotes' Chainlink feeds, then the registrar, which takes it
	///      over. The three quotes must be priced before the registrar is built: it checks each one.
	function _deployPricing(Deployed memory d, Config memory cfg) private {
		ValueInterpreter vi = new ValueInterpreter(cfg.owner);
		vi.setSequencerUptimeFeed(BaseMainnet.CL_SEQUENCER_UPTIME, BaseMainnet.SEQUENCER_GRACE);
		vi.addPrimitive(BaseMainnet.USDC, BaseMainnet.CL_USDC_USD, BaseMainnet.USDC_HEARTBEAT);
		vi.addPrimitive(BaseMainnet.WETH, BaseMainnet.CL_ETH_USD, BaseMainnet.ETH_HEARTBEAT);
		vi.addPrimitive(BaseMainnet.CBBTC, BaseMainnet.CL_CBBTC_USD, BaseMainnet.CBBTC_HEARTBEAT);
		d.valueInterpreter = vi;

		d.sampler = new V4PriceSampler(IV4StateView(BaseMainnet.UNI_V4_STATE_VIEW), cfg.owner);
		d.sampler.setKeeper(cfg.keeper, true);

		address[] memory quotes = new address[](3);
		quotes[0] = BaseMainnet.USDC;
		quotes[1] = BaseMainnet.WETH;
		quotes[2] = BaseMainnet.CBBTC;
		d.registrar = new PoolPriceRegistrar(
			PoolPriceRegistrar.Wiring({
				valueInterpreter: IValueInterpreterAdmin(address(vi)),
				uniswapV3Factory: BaseMainnet.UNI_FACTORY,
				slipstreamFactories: [BaseMainnet.CL_FACTORY, BaseMainnet.CL2_FACTORY, BaseMainnet.CL3_FACTORY],
				aerodromeBasicFactory: BaseMainnet.AERODROME_POOL_FACTORY,
				aeroFactory: BaseMainnet.AERO_FACTORY,
				stateView: IV4StateView(BaseMainnet.UNI_V4_STATE_VIEW),
				poolManager: BaseMainnet.UNI_V4_POOL_MANAGER,
				sampler: d.sampler,
				weth: BaseMainnet.WETH,
				quotes: quotes
			}),
			cfg.owner
		);
		d.registrar.setPoolApprover(cfg.guardian, true);

		d.verantaStore = new VerantaPriceStore(
			IPythLazerVerifier(BaseMainnet.PYTH_LAZER_VERIFIER), IVerantaPairStorage(BaseMainnet.VERANTA_PAIR_STORAGE)
		);
		d.clmFeed = new ClmVaultPriceFeed(vi, BaseMainnet.CLM_STRATEGY_FACTORY, address(d.registrar));
		d.erc4626Feed = new ERC4626PriceFeed();
		d.erc4626ExitFeed = new ERC4626ExitValueFeed();
	}

	/// @dev The queue, the perp config every fund names, the comptroller build, the factory, and the two mandatory policies.
	///      The VI stays with the deployer, who lists the feeds on it (ReleaseListings.list) before the registrar takes it.
	function _deployFunds(Deployed memory d, Config memory cfg) private {
		d.queue = new RedemptionQueue(cfg.owner);
		d.perpConfig = new VerantaPerpConfig(
			IERC20(BaseMainnet.USDC),
			IVerantaTradingRouter(BaseMainnet.VERANTA_ROUTER),
			IVerantaMulticall(BaseMainnet.VERANTA_MULTICALL),
			BaseMainnet.VERANTA_STORAGE,
			IVerantaPairStorage(BaseMainnet.VERANTA_PAIR_STORAGE),
			cfg.keeper
		);
		d.perpConfig.setReferral(IVerantaReferral(BaseMainnet.VERANTA_REFERRAL), BaseMainnet.VERANTA_REFERRAL_CODE);
		d.comptrollerDeployer = new ComptrollerBlueprintDeployer(
			type(Comptroller).creationCode, abi.encode(d.registrar, d.queue, d.perpConfig)
		);
		d.sharesVaultDeployer = new SharesVaultDeployer();
		// The factory starts with the VI in the comptroller deployer's place: it has no deploy(), so createFund reverts
		// until Release.deploy sets the real one, after the guardian, the mandatory policies, the adapters and the perp
		// type. Otherwise a fund created between this transaction and setMandatoryPolicies would stay in the registry
		// for good without the liquidity floor and the slippage budget (review 2026-11-16).
		d.factory = new FundFactory(d.valueInterpreter, IComptrollerDeployer(address(d.valueInterpreter)), d.sharesVaultDeployer);
		d.factory.setGuardian(cfg.guardian);
		d.queue.setFactory(address(d.factory));
		d.queue.setKeeper(cfg.keeper, true);

		d.minPoolLiquidity = new MinPoolLiquidityPolicy(d.registrar);
		d.slippage = new CumulativeSlippageTolerancePolicy(BaseMainnet.MANDATORY_SLIPPAGE_BPS);
		FundFactory.PolicyReg[] memory mandatory = new FundFactory.PolicyReg[](3);
		mandatory[0] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnIntegration, policy: address(d.minPoolLiquidity)});
		// trades and external-position calls share one loss budget
		mandatory[1] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnIntegration, policy: address(d.slippage)});
		mandatory[2] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnExternalPosition, policy: address(d.slippage)});
		d.factory.setMandatoryPolicies(mandatory);
	}

	function _deployAdapters(Deployed memory d, Config memory cfg) private {
		Adapters memory a;
		uint16 fee = BaseMainnet.SWAP_FEE_BPS;
		a.uniswapV3 = new UniswapV3SwapAdapter(IUniswapV3SwapRouter(BaseMainnet.UNI_SWAP_ROUTER02), cfg.treasury, fee, cfg.owner);
		a.uniswapV4 = new UniswapV4SwapAdapter(
			IV4PoolManager(BaseMainnet.UNI_V4_POOL_MANAGER), d.registrar, BaseMainnet.WETH, cfg.treasury, fee, cfg.owner
		);
		a.slipstream1 = new AerodromeSlipstreamSwapAdapter(ISlipstreamSwapRouter(BaseMainnet.CL_SWAP_ROUTER), cfg.treasury, fee, cfg.owner);
		a.slipstream2 = new AerodromeSlipstreamSwapAdapter(ISlipstreamSwapRouter(BaseMainnet.CL2_SWAP_ROUTER), cfg.treasury, fee, cfg.owner);
		a.slipstream3 = new AerodromeSlipstreamSwapAdapter(ISlipstreamSwapRouter(BaseMainnet.CL3_SWAP_ROUTER), cfg.treasury, fee, cfg.owner);
		a.aero = new AerodromeSlipstreamSwapAdapter(ISlipstreamSwapRouter(BaseMainnet.AERO_SWAP_ROUTER), cfg.treasury, fee, cfg.owner);
		a.aerodromeBasic = new AerodromeBasicSwapAdapter(
			IAerodromeRouter(BaseMainnet.AERODROME_ROUTER), BaseMainnet.AERODROME_POOL_FACTORY, cfg.treasury, fee, cfg.owner
		);
		a.viaWeth = new ViaWethSellAdapter(
			BaseMainnet.WETH,
			BaseMainnet.UNI_SWAP_ROUTER02,
			BaseMainnet.CL_SWAP_ROUTER,
			BaseMainnet.CL2_SWAP_ROUTER,
			BaseMainnet.CL3_SWAP_ROUTER,
			BaseMainnet.AERODROME_ROUTER,
			BaseMainnet.AERODROME_POOL_FACTORY,
			BaseMainnet.AERO_SWAP_ROUTER,
			cfg.treasury,
			fee,
			cfg.owner
		);
		// the CLM vaults live on Aero's CL factory (2026-10-25): its router first, then the two Slipstream routers
		a.clm = new ClmVaultAdapter(BaseMainnet.AERO_SWAP_ROUTER, BaseMainnet.CL_SWAP_ROUTER, BaseMainnet.CL2_SWAP_ROUTER);
		a.clmExit = new ClmVaultExitAdapter(BaseMainnet.AERO_SWAP_ROUTER, BaseMainnet.CL_SWAP_ROUTER, BaseMainnet.CL2_SWAP_ROUTER);
		a.erc4626 = new ERC4626Adapter();
		a.erc4626Exit = new ERC4626ExitAdapter(BaseMainnet.AERO_SWAP_ROUTER, BaseMainnet.CL_SWAP_ROUTER, BaseMainnet.CL2_SWAP_ROUTER);
		d.adapters = a;

		address[12] memory all = [
			address(a.uniswapV3), address(a.uniswapV4), address(a.slipstream1), address(a.slipstream2), address(a.slipstream3),
			address(a.aero), address(a.aerodromeBasic), address(a.viaWeth), address(a.clm), address(a.clmExit),
			address(a.erc4626), address(a.erc4626Exit)
		];
		for (uint256 i; i < all.length; ++i) {
			d.factory.registerAdapter(all[i]);
		}
	}

	function _deployPerps(Deployed memory d, Config memory) private {
		d.perpFactory = new VerantaPerpPositionFactory(d.perpConfig);
		d.factory.registerPositionType(BaseMainnet.VERANTA_PERP_TYPE, address(d.perpFactory));
	}

	function _deployRegistries(Deployed memory d) private {
		d.protectRegistry = new ProtectRegistry();
		d.advisorRegistry = new AdvisorRegistry();
		d.profileRegistry = new FundProfileRegistry();
	}

	/// @notice The VI goes to the registrar: from here every listing goes through `registrar.execute`, and anyone can
	///         `register` a pool. ReleaseListings.list calls it once the feeds and vaults are listed on the VI directly.
	function handOverValueInterpreter(Deployed memory d) internal {
		d.valueInterpreter.transferOwnership(address(d.registrar));
		d.registrar.acceptValueInterpreter();
	}
}
