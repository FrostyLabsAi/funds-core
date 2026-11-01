// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerV6} from '../../src/core/ComptrollerV6.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {IComptrollerDeployer} from '../../src/interfaces/IComptrollerDeployer.sol';
import {IPoolPriceAdapter} from '../../src/interfaces/IPoolPriceAdapter.sol';
import {IValueInterpreter} from '../../src/interfaces/IValueInterpreter.sol';
import {IPolicy} from '../../src/interfaces/IPolicy.sol';
import {IV4PoolManager, PoolKey} from '../../src/interfaces/external/IUniswapV4.sol';
import {CumulativeSlippageTolerancePolicy} from '../../src/policies/CumulativeSlippageTolerancePolicy.sol';
import {MinPoolLiquidityPolicy} from '../../src/policies/MinPoolLiquidityPolicy.sol';
import {UniswapV4SwapAdapter} from '../../src/adapters/UniswapV4SwapAdapter.sol';
import {ClmVaultPriceFeed} from '../../src/pricing/ClmVaultPriceFeed.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {PoolPriceRegistrarV2} from '../../src/pricing/PoolPriceRegistrarV2.sol';
import {PoolPriceRegistrarV3} from '../../src/pricing/PoolPriceRegistrarV3.sol';
import {PoolPriceRegistrarWindowed} from '../../src/pricing/PoolPriceRegistrarWindowed.sol';
import {FundsMainnet} from './FundsMainnet.sol';
import {V4Pricing} from './V4Pricing.sol';

/// @notice The PRICING-POOL-01 rollout (red team 2026-10-27; founder 2026-11-01). A fresh registrar chain on the fixed
///         adapters takes the VI over from the old one, every pool-priced token moves onto a fixed clone, and what new
///         funds are built on follows it. Shared by DeployWindowedPricing.s.sol, WindowedPricingOwnerSteps.s.sol and
///         test/fork/WindowedPricingFork.t.sol, so what is rehearsed is what ships.
/// @dev Why a new chain: a registrar counts a token as pool-priced only while the VI's feed is its own clone, and each
///      clones one fixed implementation, so the old three can't hold a fixed clone. Old funds read those three and stop
///      seeing moved tokens as long-tail. They are test funds (founder 2026-11-01), and no fund v6 exists on the old
///      chain. Listed CLM vaults stay on their feed: the VI asks a feed only when listing. New listings use `clmFeed`.
library WindowedPricing {
	address internal constant OLD_V1 = 0x34AcBA229Aeaf7F1c0f442633F35E26Bc94b4e2A; // base-mainnet-pool-pricing.json
	address internal constant OLD_V2 = 0x60338a74c63EDeC7EC020cB9208DD234D9a2146F; // base-mainnet-v4.json
	address internal constant OLD_V3 = 0xF867a01419d805A76A4637304f13d486EcB5749c; // base-mainnet-aero-registrar.json
	/// @notice The mandatory long-tail policy on old V3 (base-mainnet-aero-registrar.json), replaced wherever listed.
	address internal constant OLD_POLICY = 0xA6Ac6C8c3FFcdB6a1b85747289bd7049e2A7fcF3;
	/// @dev The one pool approver on old V2 (its PoolApproverSet log, scanned 2026-11-01): the Admin Safe.
	address internal constant ADMIN_SAFE = 0xB0f37bE90a8BD82D991Bf694F960C67198778B8B;
	/// @dev A stock quote approved on old V2 after V4Pricing (its QuoteSet log, block 53,173,767).
	address internal constant AMZNC = 0xb200000000000000000000d9192b6B456483C2E8;
	/// @notice The most value every new fund's trades may lose against the oracle, in bps of GAV, replenishing over 7 days:
	///         without it a manager could trade a whole fund away to themselves in one transaction (red-team ADAPTERS-02,
	///         2026-10-27). A fund's own policy can be tighter. README §5's example is 10%/7d; set at 5% on 2026-11-01.
	uint256 internal constant MANDATORY_SLIPPAGE_BPS = 500;

	struct Deployed {
		PoolPriceRegistrarWindowed base;
		PoolPriceRegistrarV2 registrarV2;
		PoolPriceRegistrarV3 registrar;
		MinPoolLiquidityPolicy policy;
		CumulativeSlippageTolerancePolicy slippage;
		UniswapV4SwapAdapter v4Adapter;
		ClmVaultPriceFeed clmFeed;
		ComptrollerBlueprintDeployer fundV6Deployer;
	}

	error MandatoryPolicyNotFound(address policy);

	/// @param owner every registrar's and the v4 adapter's owner (the genesis deployer until the governance handoff)
	/// @param queueV2 fund v6's RedemptionQueueV2 (deployments/base-mainnet-fund-v6.json)
	/// @param perpConfig what every perp account names as positionFactory() (deployments/base-mainnet.json verantaFactory)
	/// @param clmStrategyFactory the CLM strategy factory the live feed names (funds-yield base-mainnet-clm-v2.json)
	function deploy(address owner, address queueV2, address perpConfig, address clmStrategyFactory)
		internal
		returns (Deployed memory d)
	{
		PoolPriceRegistrar oldV1 = PoolPriceRegistrar(OLD_V1);
		PoolPriceRegistrarV2 oldV2 = PoolPriceRegistrarV2(OLD_V2);
		address[] memory quotes = new address[](3);
		quotes[0] = FundsMainnet.USDC;
		quotes[1] = FundsMainnet.WETH;
		quotes[2] = FundsMainnet.CBBTC;
		d.base = new PoolPriceRegistrarWindowed(
			PoolPriceRegistrarWindowed.Wiring({
				valueInterpreter: oldV1.valueInterpreter(),
				uniswapV3Factory: oldV1.uniswapV3Factory(),
				slipstreamFactories: [oldV1.slipstreamFactory1(), oldV1.slipstreamFactory2(), oldV1.slipstreamFactory3()],
				aerodromeBasicFactory: oldV1.aerodromeBasicFactory(),
				quotes: quotes
			}),
			owner
		);
		// V2 and V3 call only what PoolPriceRegistrar and the windowed base share (same selectors, same answers)
		d.registrarV2 = new PoolPriceRegistrarV2(
			PoolPriceRegistrar(address(d.base)), oldV2.stateView(), oldV2.poolManager(), oldV2.sampler(), oldV2.weth(), quotes, owner
		);
		d.registrar = new PoolPriceRegistrarV3(d.registrarV2, PoolPriceRegistrarV3(OLD_V3).aeroFactory(), owner);
		// as AeroRegistrar.deploy: the policy and ComptrollerV6 call only poolPricedAdapter and MIN_LIQUIDITY_USD
		PoolPriceRegistrar asRegistrar = PoolPriceRegistrar(address(d.registrar));
		d.policy = new MinPoolLiquidityPolicy(asRegistrar);
		d.slippage = new CumulativeSlippageTolerancePolicy(MANDATORY_SLIPPAGE_BPS);
		d.v4Adapter = new UniswapV4SwapAdapter(
			IV4PoolManager(V4Pricing.POOL_MANAGER),
			PoolPriceRegistrarV2(address(d.registrar)),
			FundsMainnet.WETH,
			V4Pricing.TREASURY,
			V4Pricing.FEE_BPS,
			owner
		);
		d.clmFeed = new ClmVaultPriceFeed(IValueInterpreter(address(oldV1.valueInterpreter())), clmStrategyFactory, address(d.registrar));
		d.fundV6Deployer =
			new ComptrollerBlueprintDeployer(type(ComptrollerV6).creationCode, abi.encode(asRegistrar, queueV2, perpConfig));
	}

	/// @notice Base under V2 under V3, with old V2's quotes, hooks, approver and approved pools replayed (its logs, scanned
	///         to block 53,380,623 on 2026-11-01). Re-runnable. Run as the owner of the new chain.
	function wire(Deployed memory d) internal {
		if (d.base.owner() != address(d.registrarV2)) {
			if (d.base.pendingOwner() != address(d.registrarV2)) d.base.transferOwnership(address(d.registrarV2));
			d.registrarV2.acceptOldRegistrar();
		}
		if (d.registrarV2.owner() == address(d.registrar)) return;
		_replayV2Config(d.registrarV2);
		if (d.registrarV2.pendingOwner() != address(d.registrar)) d.registrarV2.transferOwnership(address(d.registrar));
		d.registrar.acceptRegistrarV2();
	}

	function _replayV2Config(PoolPriceRegistrarV2 v2) private {
		PoolPriceRegistrarV2 old = PoolPriceRegistrarV2(OLD_V2);
		address[3] memory hooks = [V4Pricing.STOCKIFY_HOOK, V4Pricing.O1_HOOK_1, V4Pricing.O1_HOOK_2];
		for (uint256 i; i < hooks.length; ++i) {
			(bool approved, bytes memory hookData) = old.hookOf(hooks[i]);
			if (approved && !v2.isHookAllowed(hooks[i])) v2.setHook(hooks[i], true, hookData);
		}
		address[6] memory quotes = [V4Pricing.NVDAC, V4Pricing.SPCXC, V4Pricing.AAPLC, V4Pricing.GOOGLC, V4Pricing.METAC, AMZNC];
		for (uint256 i; i < quotes.length; ++i) {
			if (old.isQuote(quotes[i]) && !v2.isQuote(quotes[i])) v2.setQuote(quotes[i], true);
		}
		if (old.isPoolApprover(ADMIN_SAFE) && !v2.isPoolApprover(ADMIN_SAFE)) v2.setPoolApprover(ADMIN_SAFE, true);
		bytes32[5] memory pools = [
			V4Pricing.STFY_POOL_ID,
			V4Pricing.BLUECHIP_POOL_ID,
			V4Pricing.RAWR_POOL_ID,
			V4Pricing.MOONBASE_POOL_ID,
			V4Pricing.BASEASS_POOL_ID
		];
		for (uint256 i; i < pools.length; ++i) {
			if (old.isPoolApproved(pools[i]) && !v2.isPoolApproved(pools[i])) v2.setPoolApproved(pools[i], true);
		}
	}

	/// @notice The VI, from the old V1 to the windowed base (Ownable2Step). Every old public `register` ends in the old
	///         V1's call to the VI, so this closes all three at once. Re-runnable. Run as the owner of both chains.
	function handOverVi(Deployed memory d) internal {
		Ownable2Step vi = Ownable2Step(address(d.base.valueInterpreter()));
		if (vi.owner() == address(d.base)) return;
		if (vi.pendingOwner() != address(d.base)) {
			PoolPriceRegistrarV3(OLD_V3).callOldRegistrar(
				abi.encodeCall(PoolPriceRegistrar.execute, (abi.encodeCall(Ownable2Step.transferOwnership, (address(d.base)))))
			);
		}
		d.registrar.callOldRegistrar(
			abi.encodeCall(PoolPriceRegistrarWindowed.execute, (abi.encodeCall(Ownable2Step.acceptOwnership, ())))
		);
	}

	/// @notice Moves `asset` onto a fixed clone of the same pool, if it is still on an old clone. Re-runnable: a moved token
	///         answers 0 on the old chain. Reverts in a forge script for a B20 token or quote, whose decimals() Foundry
	///         can't run: `moveAll` skips those, and script/mainnet/migrate-windowed-b20.sh sends them with cast.
	function moveToken(Deployed memory d, address asset) internal returns (bool moved) {
		PoolPriceRegistrarV3 old = PoolPriceRegistrarV3(OLD_V3);
		address adapter = old.poolPricedAdapter(asset);
		if (adapter == address(0)) return false;
		address pool = IPoolPriceAdapter(adapter).config().pool;
		if (old.adapterOf(asset) == adapter) {
			d.registrar.setPool(asset, pool); // an Aero CL pool: only V3 knows that venue
			return true;
		}
		(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) = old.v4KeyOf(asset);
		d.registrar.callRegistrarV2(
			tickSpacing != 0
				? abi.encodeCall(PoolPriceRegistrarV2.setPoolV4, (asset, PoolKey(currency0, currency1, fee, tickSpacing, hooks)))
				: abi.encodeCall(PoolPriceRegistrarV2.setPool, (asset, pool))
		);
		return true;
	}

	/// @notice Every token still on an old clone, except those a forge script can't run (B20 token or quote).
	/// @return moved how many this call moved
	/// @return left how many remain for migrate-windowed-b20.sh
	function moveAll(Deployed memory d) internal returns (uint256 moved, uint256 left) {
		PoolPriceRegistrarV3 old = PoolPriceRegistrarV3(OLD_V3);
		address[] memory assets = old.getRegisteredAssets();
		for (uint256 i; i < assets.length; ++i) {
			address adapter = old.poolPricedAdapter(assets[i]);
			if (adapter == address(0)) continue;
			if (isB20(assets[i]) || isB20(IPoolPriceAdapter(adapter).config().quoteAsset)) {
				++left;
				continue;
			}
			if (moveToken(d, assets[i])) ++moved;
		}
	}

	/// @dev On Base a B20 token's account code is the single byte 0xef (test/utils/B20Mirror.sol).
	function isB20(address token) internal view returns (bool) {
		return keccak256(token.code) == keccak256(hex'ef');
	}

	/// @notice New funds onto the new chain: the v4 adapter registered, the new long-tail policy mandatory in the old one's
	///         place and the slippage policy mandatory beside it, the new deployer set. Re-runnable. Run as the factory's
	///         owner, once no token is left on an old clone.
	function switchNewFunds(Deployed memory d, FundFactory factory) internal {
		if (!factory.isAdapterRegistered(address(d.v4Adapter))) factory.registerAdapter(address(d.v4Adapter));
		_replaceMandatoryPolicy(factory, OLD_POLICY, address(d.policy));
		_addMandatorySlippage(factory, address(d.slippage));
		if (address(factory.comptrollerDeployer()) != address(d.fundV6Deployer)) {
			factory.setComptrollerDeployer(IComptrollerDeployer(address(d.fundV6Deployer)));
		}
	}

	/// @dev On both hooks the policy measures: trades and external-position calls share one budget.
	function _addMandatorySlippage(FundFactory factory, address slippage) private {
		FundFactory.PolicyReg[] memory regs = factory.getMandatoryPolicies();
		for (uint256 i; i < regs.length; ++i) {
			if (regs[i].policy == slippage) return;
		}
		FundFactory.PolicyReg[] memory all = new FundFactory.PolicyReg[](regs.length + 2);
		for (uint256 i; i < regs.length; ++i) {
			all[i] = regs[i];
		}
		all[regs.length] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnIntegration, policy: slippage});
		all[regs.length + 1] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnExternalPosition, policy: slippage});
		factory.setMandatoryPolicies(all);
	}

	/// @dev AeroRegistrar._replaceMandatoryPolicy: same hooks, other mandatory policies kept; reverts unless the new policy
	///      ends up mandatory (final review 2026-10-08, L1).
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
