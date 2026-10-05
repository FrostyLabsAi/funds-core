// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test, console} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {IPolicy} from '../../src/interfaces/IPolicy.sol';
import {AggregatorV3Interface} from '../../src/interfaces/AggregatorV3Interface.sol';
import {IPoolPriceAdapter} from '../../src/interfaces/IPoolPriceAdapter.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {MinPoolLiquidityPolicy} from '../../src/policies/MinPoolLiquidityPolicy.sol';
import {ComptrollerV2} from '../../src/core/ComptrollerV2.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {IUniswapV3SwapRouter} from '../../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {PoolPricing, IListingModule, ITwapListingRegistry} from '../../script/mainnet/PoolPricing.sol';

interface IUniswapV3PoolState {
	function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

/// @notice Spot tokens without a list, rehearsed on a pinned Base fork against the LIVE contracts:
///         the VI, the FundFactory, the PriceListingModule and TwapListingRegistryV2, the Uniswap
///         v3 swap adapter and real pools on every venue. setUp runs PoolPricing.deploy and
///         takeOverValueInterpreter as the real deployer. No mocks; `deal` only funds balances.
///         Run: BASE_MAINNET_RPC=<url> [BASE_FORK_BLOCK=52168120] forge test --match-path test/fork/PoolPricingFork.t.sol -j 1 -vv
contract PoolPricingForkTest is Test {
	string internal constant GENESIS_FILE = 'deployments/base-mainnet.json';
	string internal constant TWAP_V2_FILE = 'deployments/base-mainnet-twap-v2.json';
	/// @dev 162 assets in TwapListingRegistryV2, mandatory = TWAP policy V3, one fund (ALPHA) (cast 2026-10-04).
	uint256 internal constant PINNED_BLOCK = 52_168_120;
	/// @dev "MENTE" (18 dp), unpriced in the live VI. Its Uniswap v3 USDC 0.3% pool holds
	///      140,189 USDC and stores ONE observation (cardinality 1) (cast at the pinned block).
	address internal constant MENTE = 0x4CD9a847f39106E19A4E41Aea8a232E915C82aF5;
	address internal constant MENTE_USDC_3000 = 0xD76D44875716a708DBd55cd8Ffc3eb1f94aCBCe3;
	/// @dev One live TWAP listing per venue (registry V2 `listings`, cast 2026-10-04).
	address internal constant BORED = 0x70737489DFDf1A29b7584d40500d3561bD4Fe196; // Uniswap v3 / WETH
	address internal constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf; // Slipstream / WETH
	address internal constant LAPTOP = 0xB095274743941e953c746F9C228DA9c18Bb6ec29; // Slipstream 2 / USDC
	address internal constant CBETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22; // Slipstream 3 / cbBTC
	address internal constant KTA = 0xc0634090F2Fe6c6d75e61Be2b949464aBB498973; // Aerodrome basic / WETH
	/// @dev "BasedPepe", not Ethereum's PEPE — the PEPE / USD feed prices the latter ≈ 700× higher.
	address internal constant BASED_PEPE = 0x52b492a33E447Cdb854c7FC19F1e57E8BfA1777D;
	address internal constant PEPE_USD_FEED = 0xB48ac6409C0c3718b956089b0fFE295A10ACDdad;
	/// @dev EIP-7825's per-transaction gas cap; a registration must fit one transaction anywhere.
	uint256 internal constant TX_GAS_CAP = 1 << 24;

	bool internal forked;
	address internal deployer;
	ValueInterpreter internal vi;
	FundFactory internal factory;
	ITwapListingRegistry internal registry;
	IListingModule internal module;
	address internal uniAdapter;
	PoolPriceRegistrar internal registrar;
	MinPoolLiquidityPolicy internal policy;
	PoolPricing.Deployment internal d;

	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, vm.envOr('BASE_FORK_BLOCK', PINNED_BLOCK));
		forked = true;

		string memory genesis = vm.readFile(GENESIS_FILE);
		string memory twapV2 = vm.readFile(TWAP_V2_FILE);
		deployer = vm.parseJsonAddress(genesis, '.deployer');
		vi = ValueInterpreter(vm.parseJsonAddress(genesis, '.valueInterpreter'));
		factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		uniAdapter = vm.parseJsonAddress(genesis, '.uniAdapter');
		registry = ITwapListingRegistry(vm.parseJsonAddress(twapV2, '.registry'));
		module = IListingModule(vm.parseJsonAddress(twapV2, '.module'));

		vm.startPrank(deployer);
		d = PoolPricing.deploy(vi, deployer);
		PoolPricing.takeOverValueInterpreter(module, d.registrar);
		vm.stopPrank();
		registrar = d.registrar;
		policy = d.policy;
	}

	// ─── takeover ────────────────────────────────────────────────────────────────

	function test_fork_theRegistrarOwnsTheValueInterpreter() public {
		vm.skip(!forked);
		assertEq(Ownable(address(vi)).owner(), address(registrar));
		assertEq(registrar.owner(), deployer);
	}

	// ─── register ────────────────────────────────────────────────────────────────

	/// Anyone prices MENTE from its real pool, whose single stored price is grown to 450 slots in
	/// the same transaction, inside one transaction's gas cap; the price is the pool's.
	function test_fork_anyoneRegistersATokenOnAPoolWithOneStoredPrice() public {
		vm.skip(!forked);
		(,,, uint16 cardinality,,,) = IUniswapV3PoolState(MENTE_USDC_3000).slot0();
		assertEq(cardinality, 1, 'pinned state: one stored price');

		uint256 before = gasleft();
		vm.prank(alice);
		registrar.register(MENTE, MENTE_USDC_3000);
		uint256 used = before - gasleft();
		console.log('register MENTE gas', used);

		assertLt(used, TX_GAS_CAP);
		(,,,, uint16 next,,) = IUniswapV3PoolState(MENTE_USDC_3000).slot0();
		assertEq(next, registrar.OBSERVATION_SLOTS());
		// the VI price is within 10% of the pool's own spot (MENTE token0, both at 18 vs 6 dp)
		assertApproxEqRel(vi.calcUsdRate(MENTE), _spotUsdcPerToken0(MENTE_USDC_3000, 18, 6), 0.1e18);
	}

	// ─── migration ───────────────────────────────────────────────────────────────

	/// One listing per venue moves onto a pool adapter on the same pool, at the price its old
	/// adapter gives (same 30-minute window, same quote feed), and leaves the TWAP registry's rules.
	function test_fork_migratesAListingOnEachVenueAtItsOldPrice() public {
		vm.skip(!forked);
		address[5] memory assets = [BORED, VVV, LAPTOP, CBETH, KTA];
		for (uint256 i; i < assets.length; ++i) {
			(address oldAdapter, address pool,,,) = registry.listings(assets[i]);
			assertTrue(registry.isTwapPriced(assets[i]), 'pinned state: TWAP-priced');
			(bool oldAnswers, uint256 oldPrice) = _tryPrice(oldAdapter);

			vm.prank(deployer);
			registrar.setPool(assets[i], pool);

			assertEq(IPoolPriceAdapter(registrar.poolPricedAdapter(assets[i])).config().pool, pool);
			assertFalse(registry.isTwapPriced(assets[i]), 'out of the TWAP registry');
			uint256 newPrice = vi.calcUsdRate(assets[i]);
			if (oldAnswers) assertApproxEqRel(newPrice, oldPrice, 0.01e18);
			console.log('migrated', assets[i], newPrice, oldAnswers ? oldPrice : 0);
		}
	}

	/// Every token the TWAP registry still prices migrates, and every one prices afterwards
	/// (157 listings, ≈ 95M gas in all, one transaction each on mainnet). Coinbase's B20 stock
	/// tokens are left out here only: their native code (0xef…) can't run on a fork, so their
	/// `decimals()` fails here while it answers on Base (cast: PLTRc → 8).
	function test_fork_migratesEveryTwapPricedListing() public {
		vm.skip(!forked);
		address[] memory listed = registry.getListedAssets();
		address[] memory assets = PoolPricing.withoutB20(listed);

		vm.startPrank(deployer);
		uint256 moved = PoolPricing.migrateListings(registrar, registry, assets);
		vm.stopPrank();
		console.log('listed', listed.length, 'moved', moved);

		assertGt(moved, 150);
		for (uint256 i; i < assets.length; ++i) {
			assertFalse(registry.isTwapPriced(assets[i]), 'nothing left on the TWAP registry');
			vi.calcUsdRate(assets[i]); // reverts if any migrated price can't be read
		}
	}

	// ─── Chainlink, and the whole switch-over ────────────────────────────────────

	/// The 5% guard: BasedPepe's pool says ≈ $6e-9, the PEPE / USD feed ≈ $4.3e-6 — refused.
	function test_fork_aFeedFarFromThePoolPriceIsRefused() public {
		vm.skip(!forked);
		(, address pool,,,) = registry.listings(BASED_PEPE);
		vm.prank(deployer);
		registrar.setPool(BASED_PEPE, pool);
		PoolPricing.ChainlinkListing[] memory pepe = new PoolPricing.ChainlinkListing[](1);
		pepe[0] = PoolPricing.ChainlinkListing(BASED_PEPE, PEPE_USD_FEED, 90_000);

		vm.expectPartialRevert(PoolPricing.FeedDisagreesWithPool.selector);
		this.listOnChainlinkAsDeployer(pepe);
	}

	/// MigratePoolPricing's steps in its order: every non-B20 listing moves to a pool adapter,
	/// the 15 approved tokens to Chainlink, new funds get the long-tail policy and fund v2. A second
	/// run changes nothing.
	function test_fork_theWholeSwitchOverAndARerunThatSendsNothing() public {
		vm.skip(!forked);
		PoolPricing.ChainlinkListing[] memory feeds = PoolPricing.chainlinkListings();

		(uint256 moved, uint256 chainlinked) = this.switchOverAsDeployer();
		assertGt(moved, 150);
		assertEq(chainlinked, feeds.length);

		for (uint256 i; i < feeds.length; ++i) {
			(address aggregator,,,) = vi.getAssetInfo(feeds[i].token);
			assertEq(aggregator, feeds[i].feed);
			assertEq(registrar.poolPricedAdapter(feeds[i].token), address(0));
		}
		assertTrue(registrar.poolPricedAdapter(BASED_PEPE) != address(0), 'BasedPepe stays pool-priced');
		assertEq(address(factory.comptrollerDeployer()), address(d.fundDeployer));
		assertEq(factory.getMandatoryPolicies().length, 3);

		(moved, chainlinked) = this.switchOverAsDeployer();
		assertEq(moved, 0, 'nothing left to migrate');
		assertEq(chainlinked, 0, 'every feed already set');
	}

	function listOnChainlinkAsDeployer(PoolPricing.ChainlinkListing[] memory listings) external returns (uint256) {
		vm.startPrank(deployer);
		uint256 listed = PoolPricing.listOnChainlink(registrar, listings);
		vm.stopPrank();
		return listed;
	}

	function switchOverAsDeployer() external returns (uint256 moved, uint256 chainlinked) {
		vm.startPrank(deployer);
		PoolPricing.takeOverValueInterpreter(module, registrar);
		moved = PoolPricing.migrateListings(registrar, registry, PoolPricing.withoutB20(registry.getListedAssets()));
		chainlinked = PoolPricing.listOnChainlink(registrar, PoolPricing.chainlinkListings());
		PoolPricing.setMandatoryPolicy(factory, policy);
		PoolPricing.setFundVersion(factory, d.fundDeployer);
		vm.stopPrank();
	}

	// ─── a real fund ─────────────────────────────────────────────────────────────

	/// With the buy policy mandatory, a new fund carries only it on the trade hook, buys MENTE
	/// through the real Uniswap router once it is registered, and values it in NAV.
	function test_fork_aNewFundBuysARegisteredTokenThroughTheRealRouter() public {
		vm.skip(!forked);
		vm.startPrank(deployer);
		PoolPricing.setMandatoryPolicy(factory, policy);
		vm.stopPrank();
		registrar.register(MENTE, MENTE_USDC_3000);
		Comptroller fund = _fund();

		// the trade hook: the no-ruleset mandate marker every such fund gets, plus the buy policy
		address[] memory tradeHook = fund.getPolicies(IPolicy.PolicyHook.PostCallOnIntegration);
		assertEq(tradeHook.length, 2);
		assertEq(tradeHook[1], address(policy));
		assertEq(fund.getPolicies(IPolicy.PolicyHook.CreateExternalPosition)[0], address(policy));
		assertEq(fund.getPolicies(IPolicy.PolicyHook.PostDepositRequest).length, 0, 'no deposit rules');

		vm.prank(manager);
		fund.callOnIntegration(uniAdapter, abi.encode(FundsMainnet.USDC, MENTE, uint24(3000), uint256(500e6), uint256(1)));

		uint256 held = IERC20(MENTE).balanceOf(address(fund.vault()));
		assertGt(held, 0);
		// NAV counts it: ≈ the 500 USDC spent (fee and slippage aside)
		assertApproxEqRel(vi.calcCanonicalAssetValue(MENTE, held, FundsMainnet.USDC), 500e6, 0.05e18);
	}

	// ─── fund version 2 ──────────────────────────────────────────────────────────

	/// A v2 fund holds MENTE; an attacker pumps MENTE's real pool with real swaps and holds it for
	/// the whole 30-minute window. NAV reads the pump, but a redeemer's cash is exactly their share
	/// of the fund's USDC (MENTE comes in kind), and a deposit capped at the pre-pump price can't be
	/// filled at the pumped one.
	function test_fork_v2AFundsCashCannotBeDrainedByAPumpedPool() public {
		vm.skip(!forked);
		vm.startPrank(deployer);
		PoolPricing.setMandatoryPolicy(factory, policy);
		factory.setComptrollerDeployer(
			new ComptrollerBlueprintDeployer(type(ComptrollerV2).creationCode, abi.encode(registrar))
		);
		vm.stopPrank();
		registrar.register(MENTE, MENTE_USDC_3000);
		ComptrollerV2 fund = _v2Fund();

		vm.prank(manager);
		fund.callOnIntegration(uniAdapter, abi.encode(FundsMainnet.USDC, MENTE, uint24(3000), uint256(2_000e6), uint256(1)));
		uint256 sharePriceBefore = fund.calcGrossShareValue();
		_requestV2(fund, makeAddr('bob'), 1_000e6, sharePriceBefore * 101 / 100);

		_pump(MENTE, 200_000e6);
		skip(30 minutes);
		// 200k USDC into the 140k-USDC pool lifts MENTE enough to move this fund's NAV ≈ +4.7%
		assertGt(fund.calcGrossShareValue(), sharePriceBefore * 102 / 100, 'the pump reached NAV');

		vm.expectPartialRevert(ComptrollerV2.SharePriceAboveMax.selector);
		fund.executeDepositRequest(makeAddr('bob'));

		uint256 vaultUsdc = IERC20(FundsMainnet.USDC).balanceOf(address(fund.vault()));
		uint256 shares = fund.shares().balanceOf(alice);
		uint256 supply = fund.shares().totalSupply();
		vm.prank(alice);
		fund.redeemShares(shares / 2);

		assertEq(IERC20(FundsMainnet.USDC).balanceOf(alice), vaultUsdc * (shares / 2) / supply, 'cash = share of USDC');
		assertGt(IERC20(MENTE).balanceOf(alice), 0, 'MENTE in kind');
	}

	function _v2Fund() internal returns (ComptrollerV2 fund) {
		fund = ComptrollerV2(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Pool Pricing V2 Rehearsal',
					symbol: 'PP2',
					denominationAsset: IERC20(FundsMainnet.USDC),
					fundOwner: manager,
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: 2_000,
					sharesActionTimelock: 0,
					minRequestDuration: 1 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				})
			)
		);
		_requestV2(fund, alice, 10_000e6, type(uint256).max);
		fund.executeDepositRequest(alice);
	}

	function _requestV2(ComptrollerV2 fund, address who, uint256 amount, uint256 maxSharePrice) internal {
		deal(FundsMainnet.USDC, who, amount);
		vm.startPrank(who);
		IERC20(FundsMainnet.USDC).approve(address(fund), amount);
		fund.requestDeposit(amount, maxSharePrice);
		vm.stopPrank();
		skip(1 minutes);
	}

	/// @dev Buys `token` with `usdcIn` through the real Uniswap router (its USDC 0.3% pool).
	function _pump(address token, uint256 usdcIn) internal {
		address pumper = makeAddr('pumper');
		deal(FundsMainnet.USDC, pumper, usdcIn);
		vm.startPrank(pumper);
		IERC20(FundsMainnet.USDC).approve(FundsMainnet.UNI_SWAP_ROUTER02, usdcIn);
		IUniswapV3SwapRouter(FundsMainnet.UNI_SWAP_ROUTER02).exactInputSingle(
			IUniswapV3SwapRouter.ExactInputSingleParams({
				tokenIn: FundsMainnet.USDC,
				tokenOut: token,
				fee: 3000,
				recipient: pumper,
				amountIn: usdcIn,
				amountOutMinimum: 0,
				sqrtPriceLimitX96: 0
			})
		);
		vm.stopPrank();
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	function _fund() internal returns (Comptroller fund) {
		fund = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Pool Pricing Rehearsal',
					symbol: 'PPR',
					denominationAsset: IERC20(FundsMainnet.USDC),
					fundOwner: manager,
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: 0,
					sharesActionTimelock: 0,
					minRequestDuration: 1 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				})
			)
		);
		deal(FundsMainnet.USDC, alice, 10_000e6);
		vm.startPrank(alice);
		IERC20(FundsMainnet.USDC).approve(address(fund), 10_000e6);
		fund.requestDeposit(10_000e6);
		vm.stopPrank();
		skip(1 minutes);
		fund.executeDepositRequest(alice);
	}

	function _tryPrice(address adapter) internal view returns (bool, uint256) {
		try AggregatorV3Interface(adapter).latestRoundData() returns (uint80, int256 answer, uint256, uint256, uint80) {
			return (true, uint256(answer));
		} catch {
			return (false, 0);
		}
	}

	/// @dev USD (18 dp, USDC at $1) per whole token0 from the pool's spot: (√P / 2^96)² raw USDC per
	///      raw token0, scaled by the decimals — computed here, independent of the adapters.
	function _spotUsdcPerToken0(address pool, uint8 token0Decimals, uint8 usdcDecimals) internal view returns (uint256) {
		(uint160 sqrtP,,,,,,) = IUniswapV3PoolState(pool).slot0();
		uint256 rawX96 = (uint256(sqrtP) * uint256(sqrtP)) >> 96;
		return (rawX96 * 10 ** token0Decimals * 1e18 / 10 ** usdcDecimals) >> 96;
	}
}
