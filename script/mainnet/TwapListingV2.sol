// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {IValueInterpreter} from '../../src/interfaces/IValueInterpreter.sol';
import {AggregatorV3Interface} from '../../src/interfaces/AggregatorV3Interface.sol';
import {ISlipstreamSwapRouter} from '../../src/interfaces/external/ISlipstreamSwapRouter.sol';
import {AerodromeSlipstreamSwapAdapter} from '../../src/adapters/AerodromeSlipstreamSwapAdapter.sol';
import {IUniswapV3PoolFactory, ISlipstreamPoolFactory} from '../../src/pricing/TwapListingRegistry.sol';
import {TwapListingRegistryV2} from '../../src/pricing/TwapListingRegistryV2.sol';
import {PriceListingModule} from '../../src/pricing/PriceListingModule.sol';
import {TwapFloorLensV2} from '../../src/pricing/TwapFloorLensV2.sol';
import {TwapExposurePolicyV2} from '../../src/policies/TwapExposurePolicyV2.sol';
import {FundsMainnet} from './FundsMainnet.sol';

/// @notice The Slipstream router's pool factory (not part of ISlipstreamSwapRouter).
interface ISlipstreamRouterFactory {
	function factory() external view returns (address);
}

/// @title TwapListingV2
/// @notice TWAP listing v2 wired into the LIVE Base genesis as code — one library the broadcast
///         script (DeployTwapListingV2) and the fork rehearsal (test/fork/TwapListingV2Fork) both
///         run, so what is rehearsed is exactly what ships. The caller is the genesis deployer,
///         which still owns the ValueInterpreter and the FundFactory:
///           1. TwapListingRegistryV2 over the four canonical pool factories, quoting USDC and
///              WETH (WETH on the STANDARD Chainlink proxy, never SVR);
///           2. PriceListingModule, made the registry's lister (plus the keeper, when given);
///           3. TwapExposurePolicyV2 and TwapFloorLensV2;
///           4. a swap adapter for the third Slipstream deployment, registered on the factory;
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

	uint32 internal constant USDC_QUOTE_HEARTBEAT = 90_000;
	uint32 internal constant WETH_HEARTBEAT = 3600;
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
	}

	error BadConfig();
	error WrongOwner(address target, address owner);
	error StillPending(address target, address pending);
	error ListerMismatch(address account, bool isLister);
	error KeeperNotSet(address keeper);
	error QuoteMismatch(address quote, address feed, uint32 heartbeat);
	error WrongRegistry(address registry);
	error WrongRouter(address router);
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
		d.slipstream3Adapter = address(new AerodromeSlipstreamSwapAdapter(ISlipstreamSwapRouter(CL3_SWAP_ROUTER)));
		cfg.factory.registerAdapter(d.slipstream3Adapter);
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
		if (address(d.policy.registry()) != address(d.registry)) revert WrongRegistry(address(d.policy.registry()));

		if (address(AerodromeSlipstreamSwapAdapter(d.slipstream3Adapter).router()) != CL3_SWAP_ROUTER) {
			revert WrongRouter(address(AerodromeSlipstreamSwapAdapter(d.slipstream3Adapter).router()));
		}
		if (!cfg.factory.isAdapterRegistered(d.slipstream3Adapter)) revert AdapterNotRegistered(d.slipstream3Adapter);

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
		d.registry = new TwapListingRegistryV2(
			IValueInterpreter(address(cfg.valueInterpreter)),
			IUniswapV3PoolFactory(FundsMainnet.UNI_FACTORY),
			ISlipstreamPoolFactory(FundsMainnet.CL_FACTORY),
			ISlipstreamPoolFactory(FundsMainnet.CL2_FACTORY),
			ISlipstreamPoolFactory(CL3_FACTORY)
		);
		d.registry.setQuote(FundsMainnet.USDC, AggregatorV3Interface(FundsMainnet.CL_USDC_USD), USDC_QUOTE_HEARTBEAT);
		d.registry.setQuote(FundsMainnet.WETH, AggregatorV3Interface(FundsMainnet.CL_ETH_USD), WETH_HEARTBEAT);
	}

	function _deployModule(Deployed memory d, Config memory cfg) private {
		d.module = new PriceListingModule(cfg.valueInterpreter, d.registry);
		d.registry.setLister(address(d.module), true);
		if (cfg.keeper != address(0)) d.module.setKeeper(cfg.keeper, true);
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

	function _checkQuote(TwapListingRegistryV2 registry, address quote, address feed, uint32 heartbeat) private view {
		(AggregatorV3Interface storedFeed, uint32 storedHeartbeat) = registry.quotes(quote);
		if (address(storedFeed) != feed || storedHeartbeat != heartbeat) {
			revert QuoteMismatch(quote, address(storedFeed), storedHeartbeat);
		}
	}
}
