// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {IPolicy} from '../../src/interfaces/IPolicy.sol';
import {IUniswapV3SwapRouter} from '../../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {TickMath} from '../../src/libraries/TickMath.sol';
import {TwapListingRegistry} from '../../src/pricing/TwapListingRegistry.sol';
import {TwapListingRegistryV2} from '../../src/pricing/TwapListingRegistryV2.sol';
import {PriceListingModule} from '../../src/pricing/PriceListingModule.sol';
import {TwapExposurePolicy} from '../../src/policies/TwapExposurePolicy.sol';
import {TwapExposurePolicyV3} from '../../src/policies/TwapExposurePolicyV3.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {TwapPolicyV3} from '../../script/mainnet/TwapPolicyV3.sol';

/// @notice TWAP EXPOSURE POLICY V3 on a pinned Base fork against the LIVE contracts: the factory,
///         TwapListingRegistryV2 + PriceListingModule, TwapExposurePolicyV2, the Uniswap v3 swap
///         adapter, the limit-order and Uniswap LP position types, and ALPHA. setUp runs
///         TwapPolicyV3.deploy — the exact wiring DeployTwapPolicyV3 broadcasts — as the real
///         deployer. A test keeper lists VVV on its real USDC 0.3% pool; real sells drain it under
///         the floor; a stranger's poke starts the clock; 72 h pass. No mocks; `deal` only funds
///         balances.
///         Chainlink USDC/USD (25 h heartbeat in the TWAP adapter) is stale after the 72 h warp, so
///         every check after it uses paths that read no price: the buy/sell policy check, in-kind
///         redemption, deposit requests and risk-reducing limit-order calls.
///         Run: BASE_MAINNET_RPC=<url> [BASE_FORK_BLOCK=52066028] forge test --match-path test/fork/TwapPolicyV3Fork.t.sol -j 1 -vv
contract TwapPolicyV3ForkTest is Test {
	string internal constant GENESIS_FILE = 'deployments/base-mainnet.json';
	string internal constant TWAP_V2_FILE = 'deployments/base-mainnet-twap-v2.json';
	/// @dev TWAP v2 and the fee compounders live, nothing TWAP-listed yet, mandatory = V2 on hooks
	///      4/0/5/6, one fund (ALPHA), no module keeper (cast 2026-10-02).
	uint256 internal constant PINNED_BLOCK = 52_066_028;

	address internal constant USDC = FundsMainnet.USDC;
	address internal constant WETH = FundsMainnet.WETH;
	address internal constant UNI_ROUTER = FundsMainnet.UNI_SWAP_ROUTER02;
	/// @dev "VVV" (Venice Token, 18 dp), unpriced in the live VI (isSupportedAsset = false, cast).
	address internal constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;
	/// @dev Uniswap getPool(VVV, USDC, 3000), USDC token0: 331,208 USDC, observation cardinality 360 (cast).
	address internal constant VVV_USDC_3000 = 0x67A11022B7B6ed66f81233F6C8Ed6e48F7826530;
	/// @dev The live degen fund: fundOwner = the deployer; TwapExposurePolicy V1 on hooks 0/4/5/6.
	address internal constant ALPHA = 0x833A506d761A4756AF279ABC24183Db407823dE9;
	/// @dev Real sells moving VVV's spot this many ticks drain its pool's USDC far under the $25k
	///      floor (TwapListingV2Fork: $285,310 → $2,601 at block 52014634).
	int24 internal constant UNDER_FLOOR_TICKS = 20_000;
	uint256 internal constant DEPOSIT = 10_000e6;
	uint256 internal constant BUY = 1_000e6;

	bool internal forked;
	address internal deployer;
	FundFactory internal factory;
	ValueInterpreter internal vi;
	TwapListingRegistryV2 internal registry;
	PriceListingModule internal module;
	address internal uniAdapter;
	address internal policyV1;
	address internal policyV2;
	TwapExposurePolicyV3 internal policyV3;
	Comptroller internal degenV2;
	Comptroller internal normalV2;
	Comptroller internal degenV3;
	Comptroller internal normalV3;
	address internal keeper = makeAddr('twapKeeper');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');
	address internal stranger = makeAddr('stranger');

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, vm.envOr('BASE_FORK_BLOCK', PINNED_BLOCK));
		forked = true;

		string memory genesis = vm.readFile(GENESIS_FILE);
		string memory twapV2 = vm.readFile(TWAP_V2_FILE);
		deployer = vm.parseJsonAddress(genesis, '.deployer');
		factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		vi = ValueInterpreter(vm.parseJsonAddress(genesis, '.valueInterpreter'));
		uniAdapter = vm.parseJsonAddress(genesis, '.uniAdapter');
		policyV1 = vm.parseJsonAddress(genesis, '.twapPolicy');
		registry = TwapListingRegistryV2(vm.parseJsonAddress(twapV2, '.registry'));
		module = PriceListingModule(vm.parseJsonAddress(twapV2, '.module'));
		policyV2 = vm.parseJsonAddress(twapV2, '.policy');

		// the keeper role Plan B will hold (no keeper is set on mainnet yet)
		vm.prank(deployer);
		module.setKeeper(keeper, true);

		// controls: funds created before the switch keep V2
		degenV2 = _fund('V3 Rehearsal Degen Control', 'v2DGN', true);
		normalV2 = _fund('V3 Rehearsal Normal Control', 'v2NRM', false);

		// the switch, exactly as DeployTwapPolicyV3 broadcasts it
		vm.startPrank(deployer);
		policyV3 = TwapPolicyV3.deploy(_v3Config());
		vm.stopPrank();

		degenV3 = _fund('V3 Rehearsal Degen', 'v3DGN', true);
		normalV3 = _fund('V3 Rehearsal Normal', 'v3NRM', false);
	}

	// ─── wiring ──────────────────────────────────────────────────────────────────

	/// New funds run V3 (never V2) on the four hooks, even when a manager names V2 itself; V1 and V2
	/// funds may opt into V3; V3 has no owner; a second deploy run stops before sending anything.
	function test_fork_wiring() public {
		vm.skip(!forked);
		FundFactory.PolicyReg[] memory mandatory = factory.getMandatoryPolicies();
		uint8[4] memory hooks = [uint8(4), 0, 5, 6];
		assertEq(mandatory.length, 4);
		for (uint256 i; i < 4; ++i) {
			assertEq(uint8(mandatory[i].hook), hooks[i], 'hooks kept in genesis order');
			assertEq(mandatory[i].policy, address(policyV3));
		}
		assertEq(factory.policyReplacements(policyV1), address(policyV3), 'V1 funds may opt in');
		assertEq(factory.policyReplacements(policyV2), address(policyV3), 'V2 funds may opt in');
		assertEq(address(policyV3.registry()), address(registry));
		(bool hasOwner,) = address(policyV3).staticcall(abi.encodeWithSignature('owner()'));
		assertFalse(hasOwner, 'no admin surface');

		_assertRuns(degenV3, address(policyV3), policyV2);
		_assertRuns(normalV3, address(policyV3), policyV2);
		_assertRuns(degenV2, policyV2, address(policyV3));

		// naming V2 in its own ruleset doesn't keep a fund off V3
		FundFactory.PolicyReg[] memory own = new FundFactory.PolicyReg[](1);
		own[0] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnIntegration, policy: policyV2});
		Comptroller dodger = Comptroller(factory.createFund(_config('V3 Rehearsal Dodger', 'v3DDG', true), own));
		assertEq(
			_count(dodger.getPolicies(IPolicy.PolicyHook.PostCallOnIntegration), address(policyV3)), 1, 'V3 attached anyway'
		);

		vm.expectRevert(
			abi.encodeWithSelector(TwapPolicyV3.MandatoryPolicyMismatch.selector, uint256(0), uint8(4), address(policyV3))
		);
		this.deployAgain();
	}

	// ─── the gap ─────────────────────────────────────────────────────────────────

	/// THE RED CASE. Listed and healthy: degen and normal funds buy. Drained under the floor for
	/// 72 h: a V2 degen fund still buys (the gap); a V3 degen fund can't; normal funds can't (as before).
	function test_fork_degenCannotBuyADelistedToken() public {
		vm.skip(!forked);
		_listVvv();
		_buyOk(degenV3);
		_buyOk(normalV3);
		_delistVvv();

		_buyOk(degenV2); // the gap V3 closes
		bytes memory delisted = abi.encodeWithSelector(TwapExposurePolicyV3.BuyingDelistedAsset.selector, VVV);
		_buyRefused(degenV3, delisted);
		_buyRefused(normalV3, delisted);
		_buyRefused(normalV2, delisted);
	}

	/// Scope (founder 2026-10-02): delisted only. Under the floor with the clock running, a degen
	/// fund still buys; the refusal starts at exactly DELIST_GRACE.
	function test_fork_clockRunningIsNotDelisted() public {
		vm.skip(!forked);
		_listVvv();
		_drain();
		vm.prank(stranger);
		assertTrue(registry.pokeFloor(VVV), 'the clock starts');
		_warpRoll(registry.DELIST_GRACE() - 1);
		assertFalse(registry.isDelisted(VVV));
		_buyOk(degenV3);
		_warpRoll(1);
		assertTrue(registry.isDelisted(VVV));
		_buyRefused(degenV3, abi.encodeWithSelector(TwapExposurePolicyV3.BuyingDelistedAsset.selector, VVV));
	}

	// ─── exits ───────────────────────────────────────────────────────────────────

	/// A degen fund holding a delisted token can always get out: deposits pause (as in V2), an
	/// investor redeems in kind (no policy runs), the manager sells the rest, deposits reopen.
	function test_fork_degenExitsADelistedHolding() public {
		vm.skip(!forked);
		_listVvv();
		_buyOk(degenV3);
		_delistVvv();
		address vault = address(degenV3.vault());

		deal(USDC, alice, 100e6);
		vm.startPrank(alice);
		IERC20(USDC).approve(address(degenV3), 100e6);
		vm.expectRevert(abi.encodeWithSelector(TwapExposurePolicyV3.DepositsPausedDelistedHolding.selector, VVV));
		degenV3.requestDeposit(100e6);
		degenV3.redeemSharesInKind(degenV3.shares().balanceOf(alice) / 2);
		vm.stopPrank();
		assertGt(IERC20(VVV).balanceOf(alice), 0, 'in kind pays out the delisted token');

		uint256 rest = IERC20(VVV).balanceOf(vault);
		uint256 usdcBefore = IERC20(USDC).balanceOf(vault);
		vm.prank(manager);
		degenV3.callOnIntegration(uniAdapter, abi.encode(VVV, USDC, uint24(3000), rest, uint256(0)));
		assertEq(IERC20(VVV).balanceOf(vault), 0, 'sold out');
		assertGt(IERC20(USDC).balanceOf(vault), usdcBefore, 'for USDC');

		vm.prank(alice);
		degenV3.requestDeposit(100e6); // nothing delisted held any more: deposits reopen
	}

	/// A degen fund's resting buy of VVV placed while listed: once VVV is delisted, other calls on
	/// that limit-order position are refused until the order is cancelled; cancelling always passes.
	function test_fork_degenRestingBuyOrderMustBeCancelledFirst() public {
		vm.skip(!forked);
		_listVvv();
		vm.prank(manager);
		address position = degenV3.createExternalPosition(FundsMainnet.LIMIT_ORDER_TYPE, '');
		// at the oracle rate (the position refuses anything worse than 1% under it)
		uint128 minVvv = uint128(vi.calcCanonicalAssetValue(USDC, BUY, VVV));
		bytes memory place = abi.encode(
			uint8(0), abi.encode(USDC, VVV, uint128(BUY), minVvv, uint64(block.timestamp + 7 days))
		);
		_onPosition(degenV3, position, _one(USDC), _oneAmount(BUY + 100e6), new address[](0), place);
		_delistVvv();

		bytes memory returnFree = abi.encode(uint8(2), abi.encode(USDC, uint256(100e6)));
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(TwapExposurePolicyV3.BuyingDelistedAsset.selector, VVV));
		degenV3.callOnExternalPosition(position, new address[](0), new uint256[](0), _one(USDC), returnFree);

		bytes memory cancel = abi.encode(uint8(1), abi.encode(uint256(1)));
		_onPosition(degenV3, position, new address[](0), new uint256[](0), new address[](0), cancel);
		uint256 before = IERC20(USDC).balanceOf(address(degenV3.vault()));
		bytes memory returnAll = abi.encode(uint8(2), abi.encode(USDC, BUY + 100e6));
		_onPosition(degenV3, position, new address[](0), new uint256[](0), _one(USDC), returnAll);
		assertEq(IERC20(USDC).balanceOf(address(degenV3.vault())), before + BUY + 100e6, 'every USDC back in the vault');
	}

	/// Listed: a degen fund may open an LP on VVV (V2's rule for degen funds, kept); a normal fund
	/// never may (unchanged). Delisted: the degen fund can't open one either, and the normal fund is
	/// still refused with V2's error.
	function test_fork_degenCannotOpenAnLpOnADelistedToken() public {
		vm.skip(!forked);
		_listVvv();
		bytes memory pair = abi.encode(USDC, VVV, uint24(3000));
		vm.prank(manager);
		degenV3.createExternalPosition(FundsMainnet.UNI_LP_TYPE, pair);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(TwapExposurePolicyV3.TwapAssetInExternalPosition.selector, VVV));
		normalV3.createExternalPosition(FundsMainnet.UNI_LP_TYPE, pair);

		_delistVvv();
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(TwapExposurePolicyV3.BuyingDelistedAsset.selector, VVV));
		degenV3.createExternalPosition(FundsMainnet.UNI_LP_TYPE, pair);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(TwapExposurePolicyV3.TwapAssetInExternalPosition.selector, VVV));
		normalV3.createExternalPosition(FundsMainnet.UNI_LP_TYPE, pair);
	}

	/// The delisted rule covers only what the registry still prices: once governance re-points a
	/// delisted token to a Chainlink feed of its own (addPrimitive overwrites the aggregator), it is
	/// no longer TWAP-priced and a degen fund may buy it again.
	function test_fork_degenBuysADelistedTokenOnceRepriced() public {
		vm.skip(!forked);
		_listVvv();
		_delistVvv();
		_buyRefused(degenV3, abi.encodeWithSelector(TwapExposurePolicyV3.BuyingDelistedAsset.selector, VVV));

		// any real feed will do: only the aggregator swap matters to the gate
		vm.prank(deployer);
		module.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (VVV, FundsMainnet.CL_USDC_USD, 25 hours)));
		assertTrue(registry.isDelisted(VVV), 'the delist clock is untouched');
		assertFalse(registry.isTwapPriced(VVV), 'no longer TWAP-priced');
		_buyOk(degenV3);
	}

	// ─── normal funds: V2's rules ────────────────────────────────────────────────

	/// Non-degen paths are V2's: the same refusal, byte for byte, from the same state.
	function test_fork_normalFundRulesUnchanged() public {
		vm.skip(!forked);
		_listVvv();
		// 30% of GAV into one TWAP token: over the 20% line (or the pool cap, if the band is thin) for both
		bytes memory v2Err = _buyErr(normalV2, 3_000e6);
		bytes memory v3Err = _buyErr(normalV3, 3_000e6);
		bytes4 sel = bytes4(v3Err);
		assertTrue(
			sel == TwapExposurePolicyV3.TwapShareOfGavExceeded.selector || sel == TwapExposurePolicyV3.PoolShareExceeded.selector,
			'a cap refused it'
		);
		assertEq(v3Err, v2Err, 'same rule, same numbers');
	}

	/// A normal fund can't place a limit order buying a TWAP-priced token: V2's rule and error, under both.
	function test_fork_normalLimitOrderUnchanged() public {
		vm.skip(!forked);
		_listVvv();
		uint128 minVvv = uint128(vi.calcCanonicalAssetValue(USDC, BUY, VVV));
		bytes memory place = abi.encode(
			uint8(0), abi.encode(USDC, VVV, uint128(BUY), minVvv, uint64(block.timestamp + 7 days))
		);
		bytes memory expected = abi.encodeWithSelector(TwapExposurePolicyV3.TwapAssetInExternalPosition.selector, VVV);
		Comptroller[2] memory fs = [normalV2, normalV3];
		for (uint256 i; i < 2; ++i) {
			vm.prank(manager);
			address position = fs[i].createExternalPosition(FundsMainnet.LIMIT_ORDER_TYPE, '');
			vm.prank(manager);
			vm.expectRevert(expected);
			fs[i].callOnExternalPosition(position, _one(USDC), _oneAmount(BUY), new address[](0), place);
		}
	}

	// ─── existing funds: the opt-in path ─────────────────────────────────────────

	/// ALPHA (the only existing fund; degen) runs V1, which reads the empty v1 registry. Its owner
	/// can opt into V3 (V1 → V3 approved) behind the 2-day window, but execution is refused until
	/// its external positions are wound down: positions hold the old Comptroller immutably.
	function test_fork_alphaOptInNeedsItsPositionsWoundDown() public {
		vm.skip(!forked);
		Comptroller alpha = Comptroller(ALPHA);
		assertTrue(alpha.allowRiskyAssets(), 'a degen fund');
		assertEq(_count(alpha.getPolicies(IPolicy.PolicyHook.PostCallOnIntegration), policyV1), 1, 'runs V1');
		TwapListingRegistry v1Registry = TwapExposurePolicy(policyV1).registry();
		assertEq(v1Registry.getListedAssets().length, 0, 'V1 reads the empty v1 registry');
		uint256 positions = alpha.getExternalPositions().length;
		assertGt(positions, 0, 'live positions');
		emit log_named_uint('ALPHA external positions', positions);

		// read before the prank: _configOf's own calls would take it
		FundFactory.FundConfig memory terms = _configOf(alpha);
		vm.prank(deployer);
		address fresh = factory.createReconfigurationRequest(ALPHA, terms, _one(policyV1));
		(address requested, uint64 executableAt) = factory.reconfigurationRequests(ALPHA);
		assertEq(requested, fresh);
		assertEq(uint256(executableAt), block.timestamp + 2 days, 'max(2 days, its 1-day shares timelock)');
		FundFactory.PolicySwap[] memory swaps = factory.getRequestedPolicySwaps(ALPHA);
		assertEq(swaps.length, 1);
		assertEq(swaps[0].from, policyV1);
		assertEq(swaps[0].to, address(policyV3));

		skip(2 days);
		vm.prank(deployer);
		vm.expectRevert(FundFactory.ExternalPositionsStillActive.selector);
		factory.executeReconfiguration(ALPHA);
	}

	/// A fund created before the switch (V2) opts in: after the window its new Comptroller runs V3
	/// exactly once on every hook and V2 nowhere; its mandate carries over.
	function test_fork_reconfigurationSwapsV2ForV3() public {
		vm.skip(!forked);
		// read before the prank: _configOf's own calls would take it
		FundFactory.FundConfig memory terms = _configOf(normalV2);
		vm.prank(manager);
		address fresh = factory.createReconfigurationRequest(address(normalV2), terms, _one(policyV2));
		skip(2 days);
		vm.prank(manager);
		factory.executeReconfiguration(address(normalV2));
		_assertRuns(Comptroller(fresh), address(policyV3), policyV2);
		assertEq(
			_count(Comptroller(fresh).getPolicies(IPolicy.PolicyHook.PostCallOnIntegration), factory.unrestrictedMandate()),
			1,
			'the mandate carries over'
		);
	}

	// ─── gas ─────────────────────────────────────────────────────────────────────

	/// What the new check costs, every read slot cold: a degen fund's buy pays one registry read
	/// more than under V2; a normal fund's path costs the same.
	function test_fork_gasOfTheNewCheck() public {
		vm.skip(!forked);
		_listVvv();
		uint256 degenV2Gas = _validateGas(policyV2, degenV2, VVV);
		uint256 degenV3Gas = _validateGas(address(policyV3), degenV3, VVV);
		uint256 normalV2Gas = _validateGas(policyV2, normalV2, WETH);
		uint256 normalV3Gas = _validateGas(address(policyV3), normalV3, WETH);
		emit log_named_uint('degen buy of a listed TWAP token, V2 (gas)', degenV2Gas);
		emit log_named_uint('degen buy of a listed TWAP token, V3 (gas)', degenV3Gas);
		emit log_named_uint('normal buy of a non-TWAP token, V2 (gas)  ', normalV2Gas);
		emit log_named_uint('normal buy of a non-TWAP token, V3 (gas)  ', normalV3Gas);
		// at least one cold storage read (EIP-2929: 2,100) more; memory growth alone moves a later
		// measurement by a gas or two, so a bare `>` would pass with identical code
		assertGt(degenV3Gas, degenV2Gas + 2_100, 'V3 reads what V2 skipped for degen funds');
		assertLt(degenV3Gas - degenV2Gas, 10_000, 'one cold registry read');
		assertApproxEqAbs(normalV3Gas, normalV2Gas, 300, 'the normal path is V2s');
	}

	// ─── external wrapper (a library revert needs a call frame) ──────────────────

	function deployAgain() external {
		TwapPolicyV3.deploy(_v3Config());
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	function _v3Config() internal view returns (TwapPolicyV3.Config memory) {
		return TwapPolicyV3.Config({
			deployer: deployer, factory: factory, registry: registry, policyV1: policyV1, policyV2: policyV2
		});
	}

	function _config(string memory name, string memory symbol, bool degen)
		internal
		view
		returns (FundFactory.FundConfig memory)
	{
		return FundFactory.FundConfig({
			name: name,
			symbol: symbol,
			denominationAsset: IERC20(USDC),
			fundOwner: manager,
			mgmtScaledPerSecondRate: 0,
			perfFeeBps: 0,
			sharesActionTimelock: 0,
			minRequestDuration: 1 minutes,
			executionWindow: 1 days,
			allowRiskyAssets: degen
		});
	}

	/// @dev A fresh fund (manager-owned) holding DEPOSIT USDC of alice's.
	function _fund(string memory name, string memory symbol, bool degen) internal returns (Comptroller fund) {
		fund = Comptroller(factory.createFund(_config(name, symbol, degen)));
		deal(USDC, alice, DEPOSIT);
		vm.startPrank(alice);
		IERC20(USDC).approve(address(fund), DEPOSIT);
		fund.requestDeposit(DEPOSIT);
		vm.stopPrank();
		skip(1 minutes);
		fund.executeDepositRequest(alice);
	}

	/// @dev A fund's own terms, read back (a reconfiguration keeps owner and denomination).
	function _configOf(Comptroller fund) internal view returns (FundFactory.FundConfig memory) {
		(uint128 mgmt, uint16 perf) = fund.feeConfig();
		return FundFactory.FundConfig({
			name: fund.shares().name(),
			symbol: fund.shares().symbol(),
			denominationAsset: fund.denominationAsset(),
			fundOwner: fund.fundOwner(),
			mgmtScaledPerSecondRate: mgmt,
			perfFeeBps: perf,
			sharesActionTimelock: uint64(fund.sharesActionTimelock()),
			minRequestDuration: uint64(fund.minRequestDuration()),
			executionWindow: uint64(fund.executionWindow()),
			allowRiskyAssets: fund.allowRiskyAssets()
		});
	}

	function _listVvv() internal {
		vm.prank(keeper);
		module.list(VVV, USDC, TwapListingRegistryV2.Venue.UniswapV3, 3000);
		assertTrue(registry.isTwapPriced(VVV), 'listed: the VI prices VVV through the registry');
	}

	/// @dev Real sells of VVV into its USDC 0.3% pool until spot has moved UNDER_FLOOR_TICKS against
	///      it (USDC is token0, so selling VVV raises the tick), paid out of the pool's USDC.
	function _drain() internal {
		(, int24 spot) = _slot0(VVV_USDC_3000);
		uint160 limit = TickMath.getSqrtRatioAtTick(spot + UNDER_FLOOR_TICKS);
		uint256 amount = 100_000_000e18;
		deal(VVV, address(this), amount);
		IERC20(VVV).approve(UNI_ROUTER, amount);
		IUniswapV3SwapRouter(UNI_ROUTER).exactInputSingle(
			IUniswapV3SwapRouter.ExactInputSingleParams({
				tokenIn: VVV,
				tokenOut: USDC,
				fee: 3000,
				recipient: address(this),
				amountIn: amount,
				amountOutMinimum: 0,
				sqrtPriceLimitX96: limit
			})
		);
		(uint160 sqrtAfter,) = _slot0(VVV_USDC_3000);
		assertEq(sqrtAfter, limit, 'the sells reached the limit');
	}

	function _delistVvv() internal {
		_drain();
		vm.prank(stranger);
		assertTrue(registry.pokeFloor(VVV), 'the drained pool reads under the floor: a stranger starts the clock');
		_warpRoll(registry.DELIST_GRACE());
		assertTrue(registry.isDelisted(VVV), '72 hours under the floor: delisted');
	}

	/// @dev UniswapV3SwapAdapter data: `usdcIn` USDC → VVV through its USDC 0.3% pool.
	function _buy(uint256 usdcIn) internal pure returns (bytes memory) {
		return abi.encode(USDC, VVV, uint24(3000), usdcIn, uint256(0));
	}

	function _buyOk(Comptroller fund) internal {
		address vault = address(fund.vault());
		uint256 before = IERC20(VVV).balanceOf(vault);
		vm.prank(manager);
		fund.callOnIntegration(uniAdapter, _buy(BUY));
		assertGt(IERC20(VVV).balanceOf(vault), before, 'bought');
	}

	function _buyRefused(Comptroller fund, bytes memory expected) internal {
		vm.prank(manager);
		vm.expectRevert(expected);
		fund.callOnIntegration(uniAdapter, _buy(BUY));
	}

	/// @dev The revert data of a buy that must fail (state is unchanged after it).
	function _buyErr(Comptroller fund, uint256 usdcIn) internal returns (bytes memory) {
		vm.prank(manager);
		(bool ok, bytes memory ret) =
			address(fund).call(abi.encodeCall(Comptroller.callOnIntegration, (uniAdapter, _buy(usdcIn))));
		assertFalse(ok, 'expected a revert');
		return ret;
	}

	function _onPosition(
		Comptroller fund,
		address position,
		address[] memory send,
		uint256[] memory amounts,
		address[] memory back,
		bytes memory action
	) internal {
		vm.prank(manager);
		fund.callOnExternalPosition(position, send, amounts, back, action);
	}

	/// @dev Gas of one PostCallOnIntegration validate with every slot it reads cold. vm.cool re-cools
	///      storage but not an account already touched in this test (the registry, by _listVvv): a
	///      transaction that hasn't touched the registry pays 2,500 more for its first call.
	function _validateGas(address policy, Comptroller fund, address incoming) internal returns (uint256 used) {
		bytes memory data =
			abi.encode(uniAdapter, new address[](0), new uint256[](0), _one(incoming), new uint256[](1));
		vm.cool(policy);
		vm.cool(address(fund));
		vm.cool(address(registry));
		vm.cool(address(vi));
		vm.prank(address(fund));
		uint256 before = gasleft();
		IPolicy(policy).validate(IPolicy.PolicyHook.PostCallOnIntegration, data);
		used = before - gasleft();
	}

	/// @dev On each of the four TWAP hooks: `expected` exactly once, `absent` never.
	function _assertRuns(Comptroller fund, address expected, address absent) internal view {
		IPolicy.PolicyHook[4] memory hooks = [
			IPolicy.PolicyHook.PostCallOnIntegration,
			IPolicy.PolicyHook.PostDepositRequest,
			IPolicy.PolicyHook.CreateExternalPosition,
			IPolicy.PolicyHook.PostCallOnExternalPosition
		];
		for (uint256 h; h < 4; ++h) {
			address[] memory policies = fund.getPolicies(hooks[h]);
			assertEq(_count(policies, expected), 1, 'runs exactly once');
			assertEq(_count(policies, absent), 0, 'never the other version');
		}
	}

	function _count(address[] memory list, address a) internal pure returns (uint256 n) {
		for (uint256 i; i < list.length; ++i) {
			if (list[i] == a) ++n;
		}
	}

	function _one(address a) internal pure returns (address[] memory list) {
		list = new address[](1);
		list[0] = a;
	}

	function _oneAmount(uint256 a) internal pure returns (uint256[] memory list) {
		list = new uint256[](1);
		list[0] = a;
	}

	function _slot0(address pool) internal view returns (uint160 sqrtPriceX96, int24 tick) {
		(bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature('slot0()'));
		assertTrue(ok);
		(sqrtPriceX96, tick) = abi.decode(data, (uint160, int24));
	}

	/// @dev Time passes on Base: ~2-second blocks.
	function _warpRoll(uint256 secs) internal {
		vm.warp(block.timestamp + secs);
		vm.roll(block.number + secs / 2);
	}
}
