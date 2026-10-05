// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {IPolicy} from '../../src/interfaces/IPolicy.sol';
import {ComptrollerV2} from '../../src/core/ComptrollerV2.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {IComptrollerDeployer} from '../../src/interfaces/IComptrollerDeployer.sol';
import {AggregatorV3Interface} from '../../src/interfaces/AggregatorV3Interface.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {MinPoolLiquidityPolicy} from '../../src/policies/MinPoolLiquidityPolicy.sol';
import {FundsMainnet} from './FundsMainnet.sol';

/// @notice The live PriceListingModule's governance passthrough (it owns the VI until the takeover).
interface IListingModule {
	function execute(bytes calldata data) external returns (bytes memory);
}

/// @notice The live TwapListingRegistryV2's reads the migration needs.
interface ITwapListingRegistry {
	function getListedAssets() external view returns (address[] memory);
	function listings(address asset)
		external
		view
		returns (address adapter, address pool, address quote, uint64 listedAt, uint64 belowFloorSince);
	function isTwapPriced(address asset) external view returns (bool);
}

/// @title PoolPricing
/// @notice Spot tokens without a list (PLAN_SPOT_NO_LIST_2026-10-04) and fund version 2
///         (PLAN_FUND_V2_2026-10-04), on Base mainnet. Every step is sent by the deployer, which owns
///         the module, the factory and (after `deploy`) the registrar. DeployPoolPricing runs 1;
///         MigratePoolPricing runs 2–6, each step skipping what is already done, so a re-run after
///         an interruption sends only what is missing:
///         1. `deploy` — the registrar (USDC/WETH/cbBTC quotes; Uniswap v3, the three Slipstream
///            deployments, Aerodrome basic), the long-tail policy, and the fund-v2 deployer;
///         2. `takeOverValueInterpreter` — the module hands the VI to the registrar, which accepts;
///         3. `migrateListings` — every token the old TWAP registry still prices moves onto a pool
///            adapter on the same pool; the registry then sees none of them as TWAP-priced, so its
///            delisting and deposit-pause rules stop applying. Coinbase B20 tokens can't run in
///            Foundry's EVM: the script leaves them to migrate-b20-listings.sh (cast);
///         4. `listOnChainlink` — the founder-approved tokens move to their Chainlink USD feeds,
///            each refused unless the feed agrees with the token's pool price within 5%;
///         5. `setMandatoryPolicy` — new funds carry the long-tail policy ($25k buys, no long-tail
///            tokens in positions) instead of TWAP policy V3;
///         6. `setFundVersion` — new funds are ComptrollerV2.
///         The governance handoff later moves the registrar to the timelock with everything else.
library PoolPricing {
	/// @dev Aerodrome's third Slipstream deployment (verified 2026-09-30; TwapListingV2).
	address internal constant CL3_FACTORY = 0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a;
	/// @dev Aerodrome basic PoolFactory = Router(0xcF77…4E43).defaultFactory() (verified 2026-09-30).
	address internal constant AERODROME_POOL_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

	/// @notice A Chainlink feed may replace a token's pool price only within this distance of it.
	uint256 internal constant MAX_FEED_DEVIATION_BPS = 500;

	struct Deployment {
		PoolPriceRegistrar registrar;
		MinPoolLiquidityPolicy policy;
		ComptrollerBlueprintDeployer fundDeployer;
	}

	struct ChainlinkListing {
		address token;
		address feed; // Chainlink's STANDARD proxy, never SVR
		uint32 staleness; // heartbeat + 1 hour
	}

	error FeedDisagreesWithPool(address token, uint256 feedUsd18, uint256 poolUsd18);
	error FeedAnswerNotPositive(address feed);

	function deploy(ValueInterpreter vi, address owner) internal returns (Deployment memory d) {
		address[] memory quotes = new address[](3);
		quotes[0] = FundsMainnet.USDC;
		quotes[1] = FundsMainnet.WETH;
		quotes[2] = FundsMainnet.CBBTC;
		d.registrar = new PoolPriceRegistrar(
			PoolPriceRegistrar.Wiring({
				valueInterpreter: vi,
				uniswapV3Factory: FundsMainnet.UNI_FACTORY,
				slipstreamFactories: [FundsMainnet.CL_FACTORY, FundsMainnet.CL2_FACTORY, CL3_FACTORY],
				aerodromeBasicFactory: AERODROME_POOL_FACTORY,
				quotes: quotes
			}),
			owner
		);
		d.policy = new MinPoolLiquidityPolicy(d.registrar);
		d.fundDeployer = new ComptrollerBlueprintDeployer(type(ComptrollerV2).creationCode, abi.encode(d.registrar));
	}

	function takeOverValueInterpreter(IListingModule module, PoolPriceRegistrar registrar) internal {
		ValueInterpreter vi = registrar.valueInterpreter();
		if (vi.owner() == address(registrar)) return;
		if (vi.pendingOwner() != address(registrar)) {
			module.execute(abi.encodeCall(Ownable.transferOwnership, (address(registrar))));
		}
		registrar.execute(abi.encodeCall(Ownable2Step.acceptOwnership, ()));
	}

	/// @notice Base B20 token (Coinbase's native tokens): byte 0 = 0xB2, bytes 1..8 zero
	///         (base-std docs/architecture.md). Foundry's EVM can't run their native code.
	function isB20(address token) internal pure returns (bool) {
		return uint160(token) >> 88 == 0xB2 << 64;
	}

	/// @dev `assets` without the B20 tokens.
	function withoutB20(address[] memory assets) internal pure returns (address[] memory kept) {
		kept = new address[](assets.length);
		uint256 n;
		for (uint256 i; i < assets.length; ++i) {
			if (!isB20(assets[i])) kept[n++] = assets[i];
		}
		assembly ('memory-safe') {
			mstore(kept, n)
		}
	}

	/// @return moved how many listings were moved (tokens the registry no longer prices are skipped)
	function migrateListings(PoolPriceRegistrar registrar, ITwapListingRegistry registry, address[] memory assets)
		internal
		returns (uint256 moved)
	{
		for (uint256 i; i < assets.length; ++i) {
			if (!registry.isTwapPriced(assets[i])) continue;
			(, address pool,,,) = registry.listings(assets[i]);
			registrar.setPool(assets[i], pool);
			++moved;
		}
	}

	/// @return listed how many moved (tokens already on their feed are skipped)
	function listOnChainlink(PoolPriceRegistrar registrar, ChainlinkListing[] memory listings)
		internal
		returns (uint256 listed)
	{
		ValueInterpreter vi = registrar.valueInterpreter();
		for (uint256 i; i < listings.length; ++i) {
			ChainlinkListing memory l = listings[i];
			(address current,,,) = vi.getAssetInfo(l.token);
			if (current == l.feed) continue;
			uint256 poolUsd18 = vi.calcUsdRate(l.token);
			uint256 feedUsd18 = _feedUsd18(l.feed);
			uint256 gap = feedUsd18 > poolUsd18 ? feedUsd18 - poolUsd18 : poolUsd18 - feedUsd18;
			if (gap * 10_000 > poolUsd18 * MAX_FEED_DEVIATION_BPS) revert FeedDisagreesWithPool(l.token, feedUsd18, poolUsd18);
			registrar.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (l.token, l.feed, l.staleness)));
			++listed;
		}
	}

	/// @dev On every hook the policy implements (trades, and the two position hooks).
	function setMandatoryPolicy(FundFactory factory, MinPoolLiquidityPolicy policy) internal {
		IPolicy.PolicyHook[] memory hooks = policy.implementedHooks();
		FundFactory.PolicyReg[] memory current = factory.getMandatoryPolicies();
		bool same = current.length == hooks.length;
		for (uint256 i; same && i < hooks.length; ++i) {
			same = current[i].hook == hooks[i] && current[i].policy == address(policy);
		}
		if (same) return;

		FundFactory.PolicyReg[] memory mandatory = new FundFactory.PolicyReg[](hooks.length);
		for (uint256 i; i < hooks.length; ++i) {
			mandatory[i] = FundFactory.PolicyReg({hook: hooks[i], policy: address(policy)});
		}
		factory.setMandatoryPolicies(mandatory);
	}

	function setFundVersion(FundFactory factory, ComptrollerBlueprintDeployer fundDeployer) internal {
		if (address(factory.comptrollerDeployer()) == address(fundDeployer)) return;
		factory.setComptrollerDeployer(IComptrollerDeployer(address(fundDeployer)));
	}

	function _feedUsd18(address feed) private view returns (uint256) {
		(, int256 answer,,,) = AggregatorV3Interface(feed).latestRoundData();
		if (answer <= 0) revert FeedAnswerNotPositive(feed);
		return uint256(answer) * 1e18 / 10 ** AggregatorV3Interface(feed).decimals();
	}

	/// @notice The founder-approved Chainlink listings (2026-10-04): every token checked against the
	///         asset its feed tracks (CoinGecko Base address), every feed Chainlink's standard proxy
	///         (Base RDD `proxyAddress`, not SVR), `description()` re-read on-chain. USDT is the
	///         canonical OP-bridge token, approved like DAI and WBTC. Left on pool pricing: SOL and
	///         HYPE (bridged; their feeds price the native asset) and PEPE (0x52b4…777D is
	///         "BasedPepe", ≈ 700× cheaper than the PEPE its feed prices).
	function chainlinkListings() internal pure returns (ChainlinkListing[] memory l) {
		l = new ChainlinkListing[](15);
		l[0] = ChainlinkListing(0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf, 0xaABc55Ca55D70B034e4daA2551A224239890282F, 90_000); // VVV (feed: 18 decimals)
		l[1] = ChainlinkListing(0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2, 0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9, 90_000); // USDT
		l[2] = ChainlinkListing(0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b, 0xEaf310161c9eF7c813A14f8FEF6Fb271434019F7, 90_000); // VIRTUAL
		l[3] = ChainlinkListing(0x63706e401c06ac8513145b7687A14804d17f814b, 0x3d6774EF702A10b20FCa8Ed40FC022f7E4938e07, 90_000); // AAVE
		l[4] = ChainlinkListing(0xA88594D404727625A9437C3f886C7643872296AE, 0xc15d9944dAefE2dB03e53bef8DDA25a56832C5fe, 90_000); // WELL
		l[5] = ChainlinkListing(0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22, 0xd7818272B9e248357d13057AAb0B417aF31E817d, 3_600); // cbETH (20-min feed)
		l[6] = ChainlinkListing(0xBAa5CC21fd487B8Fcc2F632f3F4E8D37262a0842, 0xe95e258bb6615d47515Fc849f8542dA651f12bF6, 90_000); // MORPHO
		l[7] = ChainlinkListing(0xcb585250f852C6c6bf90434AB21A00f02833a4af, 0xEEe1a9D5A0C36d99972C057Cb959267e88Ab9160, 90_000); // cbXRP
		l[8] = ChainlinkListing(0x236aa50979D5f3De3Bd1Eeb40E81137F22ab794b, 0x6D75BFB5A5885f841b132198C9f0bE8c872057BF, 90_000); // tBTC
		l[9] = ChainlinkListing(0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196, 0x17CAb8FE31E32f08326e5E27412894e49B0f9D65, 90_000); // LINK
		l[10] = ChainlinkListing(0x4ed4E862860beD51a9570b96d89aF5E1B0Efefed, 0xE62BcE5D7CB9d16AB8b4D622538bc0A50A5799c2, 90_000); // DEGEN
		l[11] = ChainlinkListing(0x7300B37DfdfAb110d83290A29DfB31B1740219fE, 0xeF7541b388a77C1709a3d44BfBfC5c1ED3F0Ac94, 90_000); // MAMO
		l[12] = ChainlinkListing(0xcbD06E5A2B0C65597161de254AA074E489dEb510, 0x95051De9Db5Cac61682f64505006f2991dEaB3c2, 90_000); // cbDOGE
		l[13] = ChainlinkListing(0x696F9436B67233384889472Cd7cD58A6fB5DF4f1, 0x50997b806B574501cC34a2a6d845e4dc1Bd9Aa8c, 90_000); // AVNT
		l[14] = ChainlinkListing(0x6985884C4392D348587B19cb9eAAf157F13271cd, 0xdc31a4CCfCA039BeC6222e20BE7770E12581bfEB, 90_000); // ZRO
	}
}
