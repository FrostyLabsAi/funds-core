// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerV4} from '../../src/core/ComptrollerV4.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {IV4PoolManager, IV4StateView} from '../../src/interfaces/external/IUniswapV4.sol';
import {IUniswapV3SwapRouter} from '../../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {ISlipstreamSwapRouter} from '../../src/interfaces/external/ISlipstreamSwapRouter.sol';
import {IAerodromeRouter} from '../../src/interfaces/external/IAerodromeRouter.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {PoolPriceRegistrarV2} from '../../src/pricing/PoolPriceRegistrarV2.sol';
import {V4PriceSampler} from '../../src/pricing/V4PriceSampler.sol';
import {MinPoolLiquidityPolicy} from '../../src/policies/MinPoolLiquidityPolicy.sol';
import {UniswapV4SwapAdapter} from '../../src/adapters/UniswapV4SwapAdapter.sol';
import {UniswapV3SwapAdapterV2} from '../../src/adapters/UniswapV3SwapAdapterV2.sol';
import {AerodromeSlipstreamSwapAdapterV2} from '../../src/adapters/AerodromeSlipstreamSwapAdapterV2.sol';
import {AerodromeBasicSwapAdapterV2} from '../../src/adapters/AerodromeBasicSwapAdapterV2.sol';
import {FundsMainnet} from './FundsMainnet.sol';

/// @title V4Pricing
/// @notice Uniswap v4 and memestocks on Base (spec docs/superpowers/specs/2026-10-08-uniswap-v4-memestocks-design.md;
///         founder 2026-10-08) as code: DeployV4Pricing runs `deploy`, V4PricingOwnerSteps runs `ownerSteps`, and
///         test/fork/V4PricingRolloutFork.t.sol rehearses both, so what is rehearsed is what ships.
///         1. `deploy` — the keeper-only price sampler, PoolPriceRegistrarV2 (v4 pools + stock-token quotes, on top of
///            today's registrar), the v4 swap adapter and the three fee-taking V2 spot adapters (Uniswap v3, the three
///            Slipstream deployments, Aerodrome basic; 5 bps to the Treasury Safe, owner-set 0–10), the long-tail policy
///            on registrar V2, and the blueprint deployer that makes new funds ComptrollerV4 (no in-kind exit that
///            forfeits, founder 2026-10-09) on registrar V2.
///         2. `ownerSteps` — today's registrar (owner of the VI) moves under registrar V2; the hooks, quotes and keeper
///            are approved; the Admin Safe becomes a pool approver and the launch v4 pools are approved; the adapters are
///            registered; new funds get the new policy and fund deployer. Each step skips what is already done, so a
///            re-run after an interruption sends only what is missing.
///         Every v4 pool is approved before it can be registered or traded (founder 2026-10-08, after the final review's
///         H1): by the owner or a pool approver — the Admin Safe, so after the governance handoff an approval is one Safe
///         transaction, not a timelock proposal.
///         Every owner here is the genesis deployer until the governance handoff (FundsGovernance) moves them all to
///         the timelock. Today's fee-free spot adapters stay registered until the terminal has moved (later step).
///         `owner` must be the broadcaster (script) or the pranked caller (tests): ownerSteps' calls are sent by it.
library V4Pricing {
	/// @dev Uniswap v4 on Base (docs.uniswap.org deployments; `StateView.poolManager()` checked 2026-10-08).
	address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
	address internal constant STATE_VIEW = 0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71;
	/// @dev The FrostyDAO Treasury Safe (CompoundersMainnet.DAO_TREASURY): protocol fees and the o1 referrer share.
	address internal constant TREASURY = 0x47b7702a4789912d0dfFDadC07c50395c293fF0A;
	/// @dev The keepers' thirdweb Engine wallet (autopilotKeeper in compose.production.yml); it signs `sample`.
	address internal constant KEEPER = 0x659fb4AD2e3BD86Df7e9B364a8a5aEb281A96C1c;
	/// @notice Protocol fee at deployment (founder 2026-10-08: 0–10 bps, 5 at deployment).
	uint16 internal constant FEE_BPS = 5;

	/// @dev STFY's one-pool hook (verified source; 3% ETH fee to its DividendVault). Takes no hookData.
	address internal constant STOCKIFY_HOOK = 0x47Ec48C74f3069e9Ae69406197821996d80200cC;
	/// @dev o1's two LaunchHook deployments: the first (BLUECHIP, RAWR) and the second, newer one (MOONBASE, BASEASS, and
	///      the ETH-paired launches). Each reads the referrer
	///      from the first 32 bytes of hookData and credits it in its own FeeEscrow (`feeEscrow()`, cast 2026-10-08).
	address internal constant O1_HOOK_1 = 0x3b2b979DF21036CEe51B8debB13100e2CB8DeaCC;
	address internal constant O1_HOOK_2 = 0x1f91c998e7c2F4b690D75BDBf6502BDcD6e02AcC;

	/// @dev Coinbase B20 stock tokens memestocks pair against, each a Chainlink-priced VI primitive (cast 2026-10-08).
	address internal constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C;
	address internal constant SPCXC = 0xb2000000000000000000007b9fcbd005511aCBd5;
	address internal constant AAPLC = 0xb200000000000000000000C2e324d24d7eEcd1fb;
	/// @dev RAWR and BASEASS pair against these (Chainlink-priced VI primitives, the STFY payout index).
	address internal constant GOOGLC = 0xb2000000000000000000002D0BA3164cc74f58B7;
	address internal constant METAC = 0xb2000000000000000000008bC8786B856E61707C;

	/// @dev The v4 pools approved at launch (founder 2026-10-08). Keys read from each pool's Initialize log and hashed back
	///      to the id; all fee 0 / tick spacing 200 on o1 except STFY's. Quote-side liquidity as the registrar measures it,
	///      2026-10-08: STFY / native ETH (StockifyFeeHook, fee 1%) ≈ $47k; BLUECHIP / NVDAc (o1 first hook) ≈ $166k; RAWR /
	///      GOOGLc (o1 first) ≈ $20k; MOONBASE / SPCXc (o1 second) ≈ $19k; BASEASS / METAc (o1 second) ≈ $16k — approval
	///      doesn't lower the $25k floor: the last three register and take buys once their quote side reaches it. Others are
	///      approved one by one (owner or the Admin Safe).
	bytes32 internal constant STFY_POOL_ID = 0xa6979745954ea4976d4c94a5957c225801de74b4ef6ab22d122854fb09405e06;
	bytes32 internal constant BLUECHIP_POOL_ID = 0x41084f2d35b54dc0d070fbf76aa52c46f5d9c7e36c163252064b6b184d9429d9;
	bytes32 internal constant RAWR_POOL_ID = 0x69bbadafdb28b6952c2910bed1d49fb1b11a222cbf36143fc1aca3c26b35c28e;
	bytes32 internal constant MOONBASE_POOL_ID = 0x63d8d458d63d18a7a5941575105f5c6521170854d85c141de96afdeaaa803776;
	bytes32 internal constant BASEASS_POOL_ID = 0x442f76f734fc93e2bd307b1a434574f99c3508eddb62b7719c3eac8f9eb1d460;

	/// @dev BLUECHIP is priced from its USDC pool on Slipstream (CL2 factory, tick spacing 200; ≈ $49.6k of USDC in it,
	///      2026-10-08), not its o1 pool (founder 2026-10-08): no stock feed in between, which freezes outside US market
	///      hours while both tokens keep trading, and a liquidity figure capped by the USDC the pool really holds. Its o1
	///      pool stays approved for trading (the referrer share). The owner sends `setPool(BLUECHIP, BLUECHIP_USDC_POOL)`
	///      with cast right after the owner steps: BLUECHIP is a B20 token, whose decimals() Foundry can't run, so a forge
	///      script can't simulate it (runbook; rehearsed with stand-in code in V4PricingRolloutFork).
	address internal constant BLUECHIP = 0xB200000000000000000000cFbdF64a8706a94a01;
	address internal constant BLUECHIP_USDC_POOL = 0x3dfDeCc334A8f2618321C78A9dE0E9428438F871;
	error MandatoryPolicyNotFound(address oldPolicy);

	struct Deployment {
		V4PriceSampler sampler;
		PoolPriceRegistrarV2 registrar;
		UniswapV4SwapAdapter v4Adapter;
		UniswapV3SwapAdapterV2 uniAdapter;
		AerodromeSlipstreamSwapAdapterV2 slipstreamAdapter;
		AerodromeSlipstreamSwapAdapterV2 slipstream2Adapter;
		AerodromeSlipstreamSwapAdapterV2 slipstream3Adapter;
		AerodromeBasicSwapAdapterV2 aerodromeBasicAdapter;
		MinPoolLiquidityPolicy policy;
		ComptrollerBlueprintDeployer fundDeployer;
	}

	function deploy(address owner, PoolPriceRegistrar oldRegistrar, address redemptionQueue)
		internal
		returns (Deployment memory d)
	{
		address[] memory quotes = new address[](3);
		quotes[0] = FundsMainnet.USDC;
		quotes[1] = FundsMainnet.WETH;
		quotes[2] = FundsMainnet.CBBTC;
		d.sampler = new V4PriceSampler(IV4StateView(STATE_VIEW), owner);
		d.registrar = new PoolPriceRegistrarV2(
			oldRegistrar, IV4StateView(STATE_VIEW), POOL_MANAGER, d.sampler, FundsMainnet.WETH, quotes, owner
		);
		d.v4Adapter =
			new UniswapV4SwapAdapter(IV4PoolManager(POOL_MANAGER), d.registrar, FundsMainnet.WETH, TREASURY, FEE_BPS, owner);
		d.uniAdapter =
			new UniswapV3SwapAdapterV2(IUniswapV3SwapRouter(FundsMainnet.UNI_SWAP_ROUTER02), TREASURY, FEE_BPS, owner);
		d.slipstreamAdapter =
			new AerodromeSlipstreamSwapAdapterV2(ISlipstreamSwapRouter(FundsMainnet.CL_SWAP_ROUTER), TREASURY, FEE_BPS, owner);
		d.slipstream2Adapter =
			new AerodromeSlipstreamSwapAdapterV2(ISlipstreamSwapRouter(FundsMainnet.CL2_SWAP_ROUTER), TREASURY, FEE_BPS, owner);
		d.slipstream3Adapter =
			new AerodromeSlipstreamSwapAdapterV2(ISlipstreamSwapRouter(FundsMainnet.CL3_SWAP_ROUTER), TREASURY, FEE_BPS, owner);
		d.aerodromeBasicAdapter = new AerodromeBasicSwapAdapterV2(
			IAerodromeRouter(FundsMainnet.AERODROME_ROUTER), FundsMainnet.AERODROME_POOL_FACTORY, TREASURY, FEE_BPS, owner
		);
		// the policy and ComptrollerV4 only call poolPricedAdapter and MIN_LIQUIDITY_USD, which registrar V2 answers
		PoolPriceRegistrar asRegistrar = PoolPriceRegistrar(address(d.registrar));
		d.policy = new MinPoolLiquidityPolicy(asRegistrar);
		d.fundDeployer =
			new ComptrollerBlueprintDeployer(type(ComptrollerV4).creationCode, abi.encode(asRegistrar, redemptionQueue));
	}

	/// @param oldPolicy today's mandatory long-tail policy (on today's registrar), replaced wherever it is listed
	/// @param poolApprover the Admin Safe (deployments/base-mainnet.json `safe`): approves v4 pools without the timelock
	function ownerSteps(Deployment memory d, FundFactory factory, address oldPolicy, address poolApprover) internal {
		_takeOverOldRegistrar(d.registrar);
		_approveHook(d.registrar, STOCKIFY_HOOK, '');
		_approveHook(d.registrar, O1_HOOK_1, abi.encode(TREASURY));
		_approveHook(d.registrar, O1_HOOK_2, abi.encode(TREASURY));
		_approveQuote(d.registrar, NVDAC);
		_approveQuote(d.registrar, SPCXC);
		_approveQuote(d.registrar, AAPLC);
		_approveQuote(d.registrar, GOOGLC);
		_approveQuote(d.registrar, METAC);
		if (!d.registrar.isPoolApprover(poolApprover)) d.registrar.setPoolApprover(poolApprover, true);
		bytes32[5] memory pools = launchPools();
		for (uint256 i; i < pools.length; ++i) {
			if (!d.registrar.isPoolApproved(pools[i])) d.registrar.setPoolApproved(pools[i], true);
		}
		if (!d.sampler.isKeeper(KEEPER)) d.sampler.setKeeper(KEEPER, true);
		address[6] memory adapters = adaptersOf(d);
		for (uint256 i; i < adapters.length; ++i) {
			if (!factory.isAdapterRegistered(adapters[i])) factory.registerAdapter(adapters[i]);
		}
		_replaceMandatoryPolicy(factory, oldPolicy, address(d.policy));
		if (address(factory.comptrollerDeployer()) != address(d.fundDeployer)) {
			factory.setComptrollerDeployer(d.fundDeployer);
		}
	}

	function launchPools() internal pure returns (bytes32[5] memory) {
		return [STFY_POOL_ID, BLUECHIP_POOL_ID, RAWR_POOL_ID, MOONBASE_POOL_ID, BASEASS_POOL_ID];
	}

	function adaptersOf(Deployment memory d) internal pure returns (address[6] memory) {
		return [
			address(d.v4Adapter),
			address(d.uniAdapter),
			address(d.slipstreamAdapter),
			address(d.slipstream2Adapter),
			address(d.slipstream3Adapter),
			address(d.aerodromeBasicAdapter)
		];
	}

	/// @dev Today's registrar (owner of the VI) proposes registrar V2, which accepts (Ownable2Step).
	function _takeOverOldRegistrar(PoolPriceRegistrarV2 registrar) private {
		PoolPriceRegistrar old = registrar.oldRegistrar();
		if (old.owner() == address(registrar)) return;
		if (old.pendingOwner() != address(registrar)) old.transferOwnership(address(registrar));
		registrar.acceptOldRegistrar();
	}

	function _approveHook(PoolPriceRegistrarV2 registrar, address hook, bytes memory hookData) private {
		(bool approved, bytes memory current) = registrar.hookOf(hook);
		if (approved && keccak256(current) == keccak256(hookData)) return;
		registrar.setHook(hook, true, hookData);
	}

	function _approveQuote(PoolPriceRegistrarV2 registrar, address token) private {
		if (!registrar.isQuote(token)) registrar.setQuote(token, true);
	}

	/// @dev Same hooks, the new policy in the old one's place; other mandatory policies are kept as they are. Reverts
	///      unless the new policy ends up mandatory: with a stale `oldPolicy` nothing would be replaced, yet the next step
	///      would still put new funds on registrar V2 — behind today's policy, which doesn't see v4 tokens, for good
	///      (policies are copied at creation) (final review 2026-10-08, L1). A re-run finds it already there.
	function _replaceMandatoryPolicy(FundFactory factory, address oldPolicy, address newPolicy) private {
		FundFactory.PolicyReg[] memory regs = factory.getMandatoryPolicies();
		bool changed;
		bool present;
		for (uint256 i; i < regs.length; ++i) {
			if (regs[i].policy == oldPolicy) {
				regs[i].policy = newPolicy;
				changed = true;
			}
			if (regs[i].policy == newPolicy) present = true;
		}
		if (!present) revert MandatoryPolicyNotFound(oldPolicy);
		if (changed) factory.setMandatoryPolicies(regs);
	}
}
