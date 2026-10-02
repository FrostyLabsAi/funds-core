// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {IValueInterpreter} from '../../src/interfaces/IValueInterpreter.sol';
import {AggregatorV3Interface} from '../../src/interfaces/AggregatorV3Interface.sol';
import {ISlipstreamSwapRouter} from '../../src/interfaces/external/ISlipstreamSwapRouter.sol';
import {AerodromeSlipstreamSwapAdapter} from '../../src/adapters/AerodromeSlipstreamSwapAdapter.sol';
import {IUniswapV2Router02} from '../../src/interfaces/external/IUniswapV2Router02.sol';
import {UniswapV2SwapAdapter} from '../../src/adapters/UniswapV2SwapAdapter.sol';
import {IAerodromeRouter} from '../../src/interfaces/external/IAerodromeRouter.sol';
import {AerodromeBasicSwapAdapter} from '../../src/adapters/AerodromeBasicSwapAdapter.sol';
import {IUniswapV3PoolFactory, ISlipstreamPoolFactory} from '../../src/pricing/TwapListingRegistry.sol';
import {
	TwapListingRegistryV2, IUniswapV2Factory, IAerodromeBasicFactory
} from '../../src/pricing/TwapListingRegistryV2.sol';
import {UniswapV2ObservationRecorder} from '../../src/pricing/UniswapV2ObservationRecorder.sol';
import {
	ConcentratedTwapAdapterDeployer,
	UniswapV2TwapAdapterDeployer,
	AerodromeBasicTwapAdapterDeployer
} from '../../src/pricing/TwapAdapterDeployers.sol';
import {PriceListingModule} from '../../src/pricing/PriceListingModule.sol';
import {TwapFloorLensV2} from '../../src/pricing/TwapFloorLensV2.sol';
import {TwapExposurePolicyV2} from '../../src/policies/TwapExposurePolicyV2.sol';
import {FundsMainnet} from './FundsMainnet.sol';

/// @notice The Slipstream router's pool factory (not part of ISlipstreamSwapRouter).
interface ISlipstreamRouterFactory {
	function factory() external view returns (address);
}

/// @notice The Uniswap v2 Router02's pair factory (not part of IUniswapV2Router02).
interface IUniswapV2RouterFactory {
	function factory() external view returns (address);
}

/// @notice The Aerodrome Router's basic-pool factory (not part of IAerodromeRouter).
interface IAerodromeRouterFactory {
	function defaultFactory() external view returns (address);
}

/// @title TwapListingV2
/// @notice TWAP listing v2 wired into the LIVE Base genesis as code — one library the broadcast
///         script (DeployTwapListingV2) and the fork rehearsal (test/fork/TwapListingV2Fork) both
///         run, so what is rehearsed is exactly what ships. The caller is the genesis deployer,
///         which still owns the ValueInterpreter and the FundFactory:
///           1. TwapListingRegistryV2 over the six canonical pool factories (Uniswap v3, three
///              Slipstream, Uniswap v2, Aerodrome basic) with its Uniswap v2 observation recorder
///              and three adapter deployers (Concentrated, UniswapV2, AerodromeBasic), quoting
///              USDC, WETH (on the STANDARD Chainlink proxy, never SVR) and cbBTC (the VI's own
///              cbBTC / USD feed and 1-hour heartbeat);
///           2. PriceListingModule, made the registry's lister (plus the keeper, when given);
///           3. TwapExposurePolicyV2 and TwapFloorLensV2;
///           4. swap adapters for the third Slipstream deployment, Uniswap v2 (Router02) and
///              Aerodrome basic volatile pools (Router + PoolFactory), each registered on the factory;
///           5. every mandatory TwapExposurePolicy v1 entry swapped for v2, hooks kept;
///           6. the VI's WETH feed moved off the SVR proxy genesis shipped with;
///           7. the VI handed to the module (two-step, accepted through `module.execute`).
///         {verify} then proves the end state or reverts. The deployer ends as owner of the module
///         (so of every VI admin call), the registry and the factory; the governance handoff
///         moves them on.
/// @dev Known limit: funds created BEFORE this runs keep TwapExposurePolicy v1, which reads the
///      empty v1 registry — V2 listings are uncapped for them and the delisted-buy block does not
///      apply. Today that is only the founder's degen fund, where caps are skipped anyway. Once
///      the factory owner approves `setPolicyReplacement(v1, v2)`, the fund owner's
///      `createReconfigurationRequest` moves such a fund to v2.
library TwapListingV2 {
	// ─── Base mainnet externals (verified 2026-09-30) ───────────────────────────
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

	uint32 internal constant USDC_QUOTE_HEARTBEAT = 90_000;
	uint32 internal constant WETH_HEARTBEAT = 3600;
	/// @dev 1 hour, the same as the VI's cbBTC primitive (FundsMainnet genesis).
	uint32 internal constant CBBTC_HEARTBEAT = 3600;
	/// @notice Mainnet's mandatory list: TwapExposurePolicy v1 on hooks 4, 0, 5, 6 (read 2026-09-30).
	uint256 internal constant MANDATORY_TWAP_ENTRIES = 4;

	struct Config {
		address deployer; // the broadcasting EOA — owns the VI and the factory until this runs
		ValueInterpreter valueInterpreter;
		FundFactory factory;
		address twapPolicyV1; // genesis TwapExposurePolicy, replaced in the mandatory list
		address keeper; // the auto-lister (PriceListingModule keeper); zero = set later
	}

	struct Deployed {
		TwapListingRegistryV2 registry;
		PriceListingModule module;
		TwapExposurePolicyV2 policy;
		TwapFloorLensV2 lens;
		address slipstream3Adapter;
		UniswapV2ObservationRecorder recorder;
		ConcentratedTwapAdapterDeployer clDeployer;
		UniswapV2TwapAdapterDeployer v2Deployer;
		AerodromeBasicTwapAdapterDeployer aeroDeployer;
		address uniswapV2Adapter;
		address aerodromeBasicAdapter;
	}

	error BadConfig();
	error WrongOwner(address target, address owner);
	error StillPending(address target, address pending);
	error ListerMismatch(address account, bool isLister);
	error KeeperNotSet(address keeper);
	error QuoteMismatch(address quote, address feed, uint32 heartbeat);
	error WrongRegistry(address registry);
	error WrongRouter(address router);
	error WrongPoolFactory(address poolFactory);
	error RegistryMismatch(string immutableName, address stored, address expected);
	error AdapterNotRegistered(address adapter);
	error MandatoryPoliciesMismatch(uint256 count, uint256 replaced);
	error MandatoryPolicyMismatch(uint256 index, uint8 hook, address policy);
	error WethFeedMismatch(address aggregator, uint32 heartbeat);

	/// @notice Deploy and wire everything (steps 1–7), then {verify}.
	function deploy(Config memory cfg) internal returns (Deployed memory d) {
		if (
			cfg.deployer == address(0) || address(cfg.valueInterpreter) == address(0)
				|| address(cfg.factory) == address(0) || cfg.twapPolicyV1 == address(0)
		) revert BadConfig();
		// the deployer's powers all move to governance; it must not keep a listing role
		if (cfg.keeper == cfg.deployer) revert BadConfig();
		if (ISlipstreamRouterFactory(CL3_SWAP_ROUTER).factory() != CL3_FACTORY) revert WrongRouter(CL3_SWAP_ROUTER);

		_deployRegistry(d, cfg);
		_deployModule(d, cfg);
		d.policy = new TwapExposurePolicyV2(d.registry);
		d.lens = new TwapFloorLensV2();
		_deploySwapAdapters(d, cfg);
		_swapMandatoryPolicy(d, cfg);
		cfg.valueInterpreter.addPrimitive(FundsMainnet.WETH, FundsMainnet.CL_ETH_USD, WETH_HEARTBEAT);
		cfg.valueInterpreter.transferOwnership(address(d.module));
		d.module.execute(abi.encodeCall(Ownable2Step.acceptOwnership, ()));

		verify(cfg, d);
	}

	/// @notice Revert on the first thing not where the wiring says it must be.
	function verify(Config memory cfg, Deployed memory d) internal view {
		ValueInterpreter vi = cfg.valueInterpreter;
		address module = address(d.module);
		if (vi.owner() != module) revert WrongOwner(address(vi), vi.owner());
		if (vi.pendingOwner() != address(0)) revert StillPending(address(vi), vi.pendingOwner());
		if (d.module.owner() != cfg.deployer) revert WrongOwner(module, d.module.owner());
		if (d.registry.owner() != cfg.deployer) revert WrongOwner(address(d.registry), d.registry.owner());
		if (!d.registry.listers(module)) revert ListerMismatch(module, false);
		if (d.registry.listers(cfg.deployer)) revert ListerMismatch(cfg.deployer, true);
		if (cfg.keeper != address(0) && !d.module.keepers(cfg.keeper)) revert KeeperNotSet(cfg.keeper);

		_checkQuote(d.registry, FundsMainnet.USDC, FundsMainnet.CL_USDC_USD, USDC_QUOTE_HEARTBEAT);
		_checkQuote(d.registry, FundsMainnet.WETH, FundsMainnet.CL_ETH_USD, WETH_HEARTBEAT);
		_checkQuote(d.registry, FundsMainnet.CBBTC, FundsMainnet.CL_CBBTC_USD, CBBTC_HEARTBEAT);
		_checkRegistryImmutables(cfg, d);
		if (address(d.policy.registry()) != address(d.registry)) revert WrongRegistry(address(d.policy.registry()));

		if (address(AerodromeSlipstreamSwapAdapter(d.slipstream3Adapter).router()) != CL3_SWAP_ROUTER) {
			revert WrongRouter(address(AerodromeSlipstreamSwapAdapter(d.slipstream3Adapter).router()));
		}
		if (!cfg.factory.isAdapterRegistered(d.slipstream3Adapter)) revert AdapterNotRegistered(d.slipstream3Adapter);
		_checkV2SwapAdapters(cfg, d);

		FundFactory.PolicyReg[] memory mandatory = cfg.factory.getMandatoryPolicies();
		if (mandatory.length != MANDATORY_TWAP_ENTRIES) revert MandatoryPoliciesMismatch(mandatory.length, 0);
		for (uint256 i; i < mandatory.length; ++i) {
			if (mandatory[i].policy != address(d.policy)) {
				revert MandatoryPolicyMismatch(i, uint8(mandatory[i].hook), mandatory[i].policy);
			}
		}

		(address aggregator, uint32 heartbeat,,) = vi.getAssetInfo(FundsMainnet.WETH);
		if (aggregator != FundsMainnet.CL_ETH_USD || heartbeat != WETH_HEARTBEAT) revert WethFeedMismatch(aggregator, heartbeat);
	}

	function _deployRegistry(Deployed memory d, Config memory cfg) private {
		d.recorder = new UniswapV2ObservationRecorder();
		d.clDeployer = new ConcentratedTwapAdapterDeployer();
		d.v2Deployer = new UniswapV2TwapAdapterDeployer();
		d.aeroDeployer = new AerodromeBasicTwapAdapterDeployer();
		d.registry = new TwapListingRegistryV2(
			TwapListingRegistryV2.Venues({
				valueInterpreter: IValueInterpreter(address(cfg.valueInterpreter)),
				uniswapV3: IUniswapV3PoolFactory(FundsMainnet.UNI_FACTORY),
				slipstream: ISlipstreamPoolFactory(FundsMainnet.CL_FACTORY),
				slipstream2: ISlipstreamPoolFactory(FundsMainnet.CL2_FACTORY),
				slipstream3: ISlipstreamPoolFactory(CL3_FACTORY),
				uniswapV2: IUniswapV2Factory(UNI_V2_FACTORY),
				aerodromeBasic: IAerodromeBasicFactory(AERODROME_POOL_FACTORY),
				recorder: d.recorder,
				clDeployer: d.clDeployer,
				v2Deployer: d.v2Deployer,
				aeroDeployer: d.aeroDeployer
			})
		);
		d.registry.setQuote(FundsMainnet.USDC, AggregatorV3Interface(FundsMainnet.CL_USDC_USD), USDC_QUOTE_HEARTBEAT);
		d.registry.setQuote(FundsMainnet.WETH, AggregatorV3Interface(FundsMainnet.CL_ETH_USD), WETH_HEARTBEAT);
		d.registry.setQuote(FundsMainnet.CBBTC, AggregatorV3Interface(FundsMainnet.CL_CBBTC_USD), CBBTC_HEARTBEAT);
	}

	function _deployModule(Deployed memory d, Config memory cfg) private {
		d.module = new PriceListingModule(cfg.valueInterpreter, d.registry);
		d.registry.setLister(address(d.module), true);
		if (cfg.keeper != address(0)) d.module.setKeeper(cfg.keeper, true);
	}

	/// @dev One swap adapter per venue the registry adds over genesis, each registered on the factory.
	function _deploySwapAdapters(Deployed memory d, Config memory cfg) private {
		d.slipstream3Adapter = address(new AerodromeSlipstreamSwapAdapter(ISlipstreamSwapRouter(CL3_SWAP_ROUTER)));
		cfg.factory.registerAdapter(d.slipstream3Adapter);
		d.uniswapV2Adapter = address(new UniswapV2SwapAdapter(IUniswapV2Router02(UNI_V2_ROUTER)));
		cfg.factory.registerAdapter(d.uniswapV2Adapter);
		d.aerodromeBasicAdapter =
			address(new AerodromeBasicSwapAdapter(IAerodromeRouter(AERODROME_ROUTER), AERODROME_POOL_FACTORY));
		cfg.factory.registerAdapter(d.aerodromeBasicAdapter);
	}

	/// @dev Every entry naming v1 becomes v2 on the same hook; anything else stays as it is.
	///      Exactly MANDATORY_TWAP_ENTRIES replacements in a list of that length, before and after.
	function _swapMandatoryPolicy(Deployed memory d, Config memory cfg) private {
		FundFactory.PolicyReg[] memory current = cfg.factory.getMandatoryPolicies();
		FundFactory.PolicyReg[] memory next = new FundFactory.PolicyReg[](current.length);
		uint256 replaced;
		for (uint256 i; i < current.length; ++i) {
			bool isV1 = current[i].policy == cfg.twapPolicyV1;
			if (isV1) ++replaced;
			next[i] = FundFactory.PolicyReg({hook: current[i].hook, policy: isV1 ? address(d.policy) : current[i].policy});
		}
		if (current.length != MANDATORY_TWAP_ENTRIES || replaced != MANDATORY_TWAP_ENTRIES) {
			revert MandatoryPoliciesMismatch(current.length, replaced);
		}
		cfg.factory.setMandatoryPolicies(next);

		FundFactory.PolicyReg[] memory stored = cfg.factory.getMandatoryPolicies();
		if (stored.length != current.length) revert MandatoryPoliciesMismatch(stored.length, replaced);
		for (uint256 i; i < stored.length; ++i) {
			if (stored[i].hook != current[i].hook || stored[i].policy != next[i].policy) {
				revert MandatoryPolicyMismatch(i, uint8(stored[i].hook), stored[i].policy);
			}
		}
	}

	/// @dev Every registry immutable is the address this library passed: the genesis VI, the six venue
	///      factories, and the recorder and three adapter deployers it deployed.
	function _checkRegistryImmutables(Config memory cfg, Deployed memory d) private view {
		TwapListingRegistryV2 r = d.registry;
		_checkImmutable('valueInterpreter', address(r.valueInterpreter()), address(cfg.valueInterpreter));
		_checkImmutable('uniswapFactory', address(r.uniswapFactory()), FundsMainnet.UNI_FACTORY);
		_checkImmutable('slipstreamFactory', address(r.slipstreamFactory()), FundsMainnet.CL_FACTORY);
		_checkImmutable('slipstream2Factory', address(r.slipstream2Factory()), FundsMainnet.CL2_FACTORY);
		_checkImmutable('slipstream3Factory', address(r.slipstream3Factory()), CL3_FACTORY);
		_checkImmutable('uniswapV2Factory', address(r.uniswapV2Factory()), UNI_V2_FACTORY);
		_checkImmutable('aerodromeBasicFactory', address(r.aerodromeBasicFactory()), AERODROME_POOL_FACTORY);
		_checkImmutable('recorder', address(r.recorder()), address(d.recorder));
		_checkImmutable('clDeployer', address(r.clDeployer()), address(d.clDeployer));
		_checkImmutable('v2Deployer', address(r.v2Deployer()), address(d.v2Deployer));
		_checkImmutable('aeroDeployer', address(r.aeroDeployer()), address(d.aeroDeployer));
	}

	/// @dev Each router answers the factory the registry lists from, each adapter stores the
	///      constants, and both are registered.
	function _checkV2SwapAdapters(Config memory cfg, Deployed memory d) private view {
		if (IUniswapV2RouterFactory(UNI_V2_ROUTER).factory() != UNI_V2_FACTORY) revert WrongRouter(UNI_V2_ROUTER);
		if (IAerodromeRouterFactory(AERODROME_ROUTER).defaultFactory() != AERODROME_POOL_FACTORY) {
			revert WrongRouter(AERODROME_ROUTER);
		}

		UniswapV2SwapAdapter uniV2 = UniswapV2SwapAdapter(d.uniswapV2Adapter);
		if (address(uniV2.router()) != UNI_V2_ROUTER) revert WrongRouter(address(uniV2.router()));
		AerodromeBasicSwapAdapter aero = AerodromeBasicSwapAdapter(d.aerodromeBasicAdapter);
		if (address(aero.router()) != AERODROME_ROUTER) revert WrongRouter(address(aero.router()));
		if (aero.poolFactory() != AERODROME_POOL_FACTORY) revert WrongPoolFactory(aero.poolFactory());

		if (!cfg.factory.isAdapterRegistered(d.uniswapV2Adapter)) revert AdapterNotRegistered(d.uniswapV2Adapter);
		if (!cfg.factory.isAdapterRegistered(d.aerodromeBasicAdapter)) revert AdapterNotRegistered(d.aerodromeBasicAdapter);
	}

	function _checkImmutable(string memory immutableName, address stored, address expected) private pure {
		if (stored != expected) revert RegistryMismatch(immutableName, stored, expected);
	}

	function _checkQuote(TwapListingRegistryV2 registry, address quote, address feed, uint32 heartbeat) private view {
		(AggregatorV3Interface storedFeed, uint32 storedHeartbeat) = registry.quotes(quote);
		if (address(storedFeed) != feed || storedHeartbeat != heartbeat) {
			revert QuoteMismatch(quote, address(storedFeed), storedHeartbeat);
		}
	}
}
