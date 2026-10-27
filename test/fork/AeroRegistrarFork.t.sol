// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerV6} from '../../src/core/ComptrollerV6.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {PoolPriceRegistrarV2} from '../../src/pricing/PoolPriceRegistrarV2.sol';
import {PoolPriceRegistrarV3} from '../../src/pricing/PoolPriceRegistrarV3.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {AeroRegistrar} from '../../script/mainnet/AeroRegistrar.sol';
import {ListingModuleBook, ViAdmin} from '../../script/mainnet/ListingModuleBook.sol';
import {ClmFundsDeploy} from '../../script/mainnet/ClmFundsDeploy.sol';
import {ClmVaultPriceFeed} from '../../src/pricing/ClmVaultPriceFeed.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

/// @dev A CLM vault and strategy as ClmFundsDeploy.list reads them (vault.strategy(), strategy.lpToken0/1()).
contract FakeClmStrategy {
	address public lpToken0;
	address public lpToken1;

	constructor(address a, address b) {
		(lpToken0, lpToken1) = (a, b);
	}
}

contract FakeClmVault {
	address public strategy;

	constructor(address s) {
		strategy = s;
	}
}

/// @dev Runs ClmFundsDeploy.list (internal library code) as a caller.
contract ClmListHarness {
	function list(address[] memory vaults) external {
		ClmFundsDeploy.list(ClmVaultPriceFeed(address(1)), vaults);
	}
}

interface IAeroMetaquoter {
	/// @dev Declared view in Aero's ABI, but it simulates the swap (state changes it reverts): call it, never staticcall
	function quoteExactInputSingleV3(address pool, address tokenIn, uint256 amountIn, uint160 sqrtPriceLimitX96)
		external
		returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed);
}

/// @notice Rehearsal of DeployAeroRegistrar + AeroRegistrarOwnerSteps on live Base (block 53,091,601, Sunday
///         2026-10-25, three days after the Aero upgrade), as the genesis deployer: registrar V2 handed to V3, new funds
///         built on V3, then the new AERO token — unpriced, $4.1M in its Aero AERO/USDC pool — priced from that pool by
///         anyone, and the long-tail tokens of V2 and today's registrar still seen as long-tail through V3.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/AeroRegistrarFork.t.sol -vv
contract AeroRegistrarForkTest is Test {
	uint256 internal constant FORK_BLOCK = 53_091_601;
	address internal constant USDC = FundsMainnet.USDC;
	/// @dev Aero's new AERO (2026-10-22) and its deepest USDC pool on Aero (tick spacing per the pool, $4.1M on 2026-10-25)
	address internal constant AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;
	address internal constant AERO_USDC_POOL = 0xD0Acf293547457Fb4fE9eE32CA93e89497626816;
	IAeroMetaquoter internal constant METAQUOTER = IAeroMetaquoter(0x1dDfeC5058180C207F55BB77D95AcDd0d8227868);
	/// @dev A v4 token registrar V2 priced (BLUECHIP / NVDAc on o1, 2026-10-08) and one today's registrar priced (BRETT)
	address internal constant BLUECHIP = 0xB200000000000000000000cFbdF64a8706a94a01;
	address internal constant BRETT = 0x532f27101965dd16442E59d40670FaF5eBB142E4;

	bool internal forked;
	address internal deployer;
	FundFactory internal factory;
	ValueInterpreter internal vi;
	PoolPriceRegistrarV2 internal v2;
	AeroRegistrar.Deployed internal d;
	address internal manager = makeAddr('manager');
	address internal anyone = makeAddr('anyone');

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, FORK_BLOCK);
		forked = true;
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		deployer = vm.parseJsonAddress(genesis, '.deployer');
		factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		vi = ValueInterpreter(vm.parseJsonAddress(genesis, '.valueInterpreter'));
		v2 = PoolPriceRegistrarV2(AeroRegistrar.REGISTRAR_V2);
		address queueV2 = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-fund-v6.json'), '.queueV2');
		address perpConfig = vm.parseJsonAddress(genesis, '.verantaFactory');

		vm.startPrank(deployer);
		d = AeroRegistrar.deploy(deployer, queueV2, perpConfig);
		AeroRegistrar.ownerSteps(d, factory);
		vm.stopPrank();
	}

	function test_fork_ownerStepsHandV2ToV3AndBuildNewFundsOnIt() public {
		vm.skip(!forked);
		assertEq(v2.owner(), address(d.registrar), 'V2 belongs to V3');
		assertEq(d.registrar.owner(), deployer);
		assertEq(address(factory.comptrollerDeployer()), address(d.fundV6Deployer), 'new funds deploy on V3');
		assertTrue(factory.isAdapterRegistered(address(d.v4Adapter)));
		FundFactory.PolicyReg[] memory regs = factory.getMandatoryPolicies();
		bool hasNew;
		for (uint256 i; i < regs.length; ++i) {
			assertTrue(regs[i].policy != AeroRegistrar.V2_POLICY, 'V2\'s long-tail policy replaced');
			if (regs[i].policy == address(d.policy)) hasNew = true;
		}
		assertTrue(hasNew, 'V3\'s long-tail policy mandatory');

		ComptrollerV6 fund = _fund('Aero V3 fund');
		assertEq(address(fund.registrar()), address(d.registrar), 'the fund reads long-tail status from V3');
		assertEq(address(d.v4Adapter.registrar()), address(d.registrar), 'V3\'s v4 adapter takes it (NotANewFund check)');
		assertTrue(address(fund.registrar()) != v2Address(), 'V2\'s v4 adapter would refuse it');
		assertEq(address(d.policy.registrar()), address(d.registrar));

		vm.prank(deployer);
		AeroRegistrar.ownerSteps(d, factory); // re-runnable
	}

	function test_fork_anyonePricesAeroFromItsAeroPool() public {
		vm.skip(!forked);
		assertFalse(vi.isSupportedAsset(AERO), 'unpriced before');
		vm.prank(anyone);
		address adapter = d.registrar.register(AERO, AERO_USDC_POOL);

		assertEq(d.registrar.poolPricedAdapter(AERO), adapter, 'long-tail for funds on V3');
		assertEq(v2.poolPricedAdapter(AERO), address(0), 'V2 does not know it (funds on V2: none on 2026-10-25)');
		(address aggregator, uint32 heartbeat,,) = vi.getAssetInfo(AERO);
		assertEq(aggregator, adapter);
		assertEq(heartbeat, 1 hours);

		// the 30-minute average against the pool's own spot: one AERO for USDC
		uint256 twapUsd = vi.calcUsdRate(AERO); // 1e18 = $1
		(uint256 spotUsdc,,) = METAQUOTER.quoteExactInputSingleV3(AERO_USDC_POOL, AERO, 1e18, 0);
		emit log_named_uint('AERO 30-min average, USD 1e18', twapUsd);
		emit log_named_uint('AERO pool spot for 1 AERO, USDC 1e6', spotUsdc);
		assertApproxEqRel(twapUsd, spotUsdc * 1e12, 0.03e18, 'within 3% of the pool spot');
	}

	function test_fork_refusesAnotherVenuesPool() public {
		vm.skip(!forked);
		// AERO's pool on Aerodrome's old Slipstream-3 factory, if any, is V2's venue: V3 is Aero's only
		address cl3 = v2.slipstreamFactory3();
		vm.mockCall(AERO_USDC_POOL, abi.encodeWithSignature('factory()'), abi.encode(cl3));
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrarV3.NotAeroPool.selector, cl3));
		d.registrar.register(AERO, AERO_USDC_POOL);
	}

	function test_fork_v2AndV1LongTailTokensStayLongTail() public {
		vm.skip(!forked);
		address bluechip = v2.poolPricedAdapter(BLUECHIP);
		address brett = v2.poolPricedAdapter(BRETT);
		assertTrue(bluechip != address(0) && brett != address(0), 'both pool-priced on Base today');
		assertEq(d.registrar.poolPricedAdapter(BLUECHIP), bluechip, 'a V2 (v4) token');
		assertEq(d.registrar.poolPricedAdapter(BRETT), brett, 'a token from today\'s registrar');
		assertEq(d.registrar.poolPricedAdapter(USDC), address(0), 'a Chainlink token is not long-tail');
		assertEq(d.registrar.getRegisteredAssets().length, v2.getRegisteredAssets().length, 'nothing of its own yet');
		assertTrue(d.registrar.isQuote(USDC));
	}

	/// Every listing script sends VI admin calls through ListingModuleBook: after the handoff it must pick V3 (the
	/// deployer no longer owns V2), and the call must still land.
	function test_fork_listingScriptsGoThroughV3AfterTheHandoff() public {
		vm.skip(!forked);
		string memory tmp = 'deployments/.aero-registrar-fork-test.json'; // the book DeployAeroRegistrar writes
		vm.writeJson(vm.serializeAddress('aeroBook', 'registrar', address(d.registrar)), tmp);
		vm.setEnv('AERO_REGISTRAR_FILE', tmp);
		ViAdmin memory admin = ListingModuleBook.admin(vm, vm.readFile('deployments/base-mainnet.json'));
		vm.removeFile(tmp);
		assertEq(address(admin.registrarV2), address(d.registrar), 'through V3');

		(address aggregator, uint32 heartbeat,,) = vi.getAssetInfo(USDC);
		vm.prank(deployer);
		admin.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (USDC, aggregator, heartbeat + 1)));
		(, uint32 after_,,) = vi.getAssetInfo(USDC);
		assertEq(after_, heartbeat + 1, 'the VI admin call landed');
	}

	/// Review 2026-10-25: the CLM feed asks registrar V2, which can't see V3's Aero tokens — ListClmVaults refuses a
	/// vault holding one, and lets an ordinary pair through to the listing call.
	function test_fork_clmListingRefusesAVaultOnAnAeroPricedToken() public {
		vm.skip(!forked);
		d.registrar.register(AERO, AERO_USDC_POOL);
		ClmListHarness harness = new ClmListHarness();
		address[] memory vaults = new address[](1);
		vaults[0] = address(new FakeClmVault(address(new FakeClmStrategy(AERO, USDC))));
		vm.expectRevert(abi.encodeWithSelector(ClmFundsDeploy.ClmVaultOnLongTailToken.selector, vaults[0], AERO));
		harness.list(vaults);

		vaults[0] = address(new FakeClmVault(address(new FakeClmStrategy(FundsMainnet.WETH, USDC))));
		// past the check, at the listing itself (the harness isn't V3's owner)
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(harness)));
		harness.list(vaults);
	}

	function v2Address() internal pure returns (address) {
		return AeroRegistrar.REGISTRAR_V2;
	}

	function _fund(string memory name) internal returns (ComptrollerV6) {
		return ComptrollerV6(
			factory.createFund(
				FundFactory.FundConfig({
					name: name,
					symbol: 'frV3',
					denominationAsset: IERC20(USDC),
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
	}
}
