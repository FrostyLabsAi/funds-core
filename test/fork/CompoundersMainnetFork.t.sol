// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test, Vm} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {TimelockController} from '@openzeppelin/contracts/governance/TimelockController.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {ProtocolFeeReserve} from '../../src/core/ProtocolFeeReserve.sol';
import {IExternalPosition} from '../../src/interfaces/IExternalPosition.sol';
import {AggregatorV3Interface} from '../../src/interfaces/AggregatorV3Interface.sol';
import {ICLGauge} from '../../src/interfaces/external/ICLGauge.sol';
import {IUniswapV3SwapRouter} from '../../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {ISlipstreamSwapRouter} from '../../src/interfaces/external/ISlipstreamSwapRouter.sol';
import {IUniswapV3NonfungiblePositionManager} from
	'../../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {ISlipstreamNonfungiblePositionManager} from
	'../../src/interfaces/external/ISlipstreamNonfungiblePositionManager.sol';
import {IVerantaReferral} from '../../src/interfaces/external/IVeranta.sol';
import {TwapListingRegistry} from '../../src/pricing/TwapListingRegistry.sol';
import {TwapExposurePolicy} from '../../src/policies/TwapExposurePolicy.sol';
import {TwapListingRegistryV2} from '../../src/pricing/TwapListingRegistryV2.sol';
import {PriceListingModule} from '../../src/pricing/PriceListingModule.sol';
import {CompounderFactory} from '../../src/yield/CompounderFactory.sol';
import {FeeCompounderBase} from '../../src/yield/FeeCompounderBase.sol';
import {SlipstreamLPPositionV2, SlipstreamLPPositionV2Factory} from '../../src/positions/SlipstreamLPPositionV2.sol';
import {VerantaPerpPositionV2, VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {VerantaPerpPositionV3, VerantaPerpPositionV3Factory} from '../../src/positions/VerantaPerpPositionV3.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {TwapListingV2} from '../../script/mainnet/TwapListingV2.sol';
import {CompoundersMainnet} from '../../script/mainnet/CompoundersMainnet.sol';
import {FundsGovernance} from '../../script/mainnet/FundsGovernance.sol';

/// @notice The live Veranta Referral (proxy 0x1A11…E82D, impl 0xE0c6…053F, Referral.sol verified on
///         Blockscout, solc 0.8.13): the code registry and the two-step code transfer.
interface IReferralCodes {
	function codeOwners(bytes32 code) external view returns (address);
	function codes(address account) external view returns (bytes32);
	function referrerTiers(address referrer) external view returns (uint256);
	function registerCode(bytes32 code) external;
	function setPendingCodeOwnershipTransfer(bytes32 code, address newAccount) external;
	function acceptCodeOwnership(bytes32 code) external;
	function traderReferralCodes(address trader) external view returns (bytes32);
	function getTraderReferralInfo(address account) external view returns (bytes32 code, address referrer);
}

interface IVaultPool {
	function pool() external view returns (address);
}

interface IPoolGauge {
	function gauge() external view returns (address);
}

/// @notice Foundry's EVM has no B20 precompile: on Base a B20 token's account code is the one byte
///         0xef, which reverts here. This stand-in answers ONLY what the test loaded from the real
///         chain (eth_call through `vm.rpc` at the fork block) and reverts for any other holder, so
///         no value is invented. Used for ALPHA's tokenized-stock holdings at live head.
contract B20ChainSnapshot {
	uint8 public decimals;
	mapping(address => uint256) internal balances;
	mapping(address => bool) internal loaded;

	error HolderNotLoaded(address holder);

	function setDecimals(uint8 decimals_) external {
		decimals = decimals_;
	}

	function load(address holder, uint256 amount) external {
		balances[holder] = amount;
		loaded[holder] = true;
	}

	function balanceOf(address holder) external view returns (uint256) {
		if (!loaded[holder]) revert HolderNotLoaded(holder);
		return balances[holder];
	}
}

/// @notice THE FEE-COMPOUNDERS ACCEPTANCE TEST, on a Base fork against the LIVE genesis: setUp runs
///         TwapListingV2.deploy (what DeployTwapListingV2 broadcasts) as the real genesis deployer;
///         each test then does the founder's referral ops exactly as they will be sent and runs
///         CompoundersMainnet.deploy — what DeployCompoundersMainnet broadcasts. Real pools, routers,
///         position managers, gauges, Chainlink feeds and the real Veranta Referral; no mocks, `deal`
///         only funds balances.
///         Proven: the deploy refuses until the DAO Treasury Safe owns `frostydao` and the V2 perp
///         factory points at it (including the live-head state where the Admin Safe holds the code);
///         the keeper creates and lists vaults on all four venues, and a TWAP-priced token's pool is
///         refused; a fresh non-degen fund deposits through the new adapter on every venue, real
///         swaps make fees, the workflow wallet compounds, the Safe gets exactly 10% and NAV rises by
///         the fund's share of the net harvest; new type-4 / type-7 positions are V2 and their AERO
///         claim AND unstake pay the Safe 10%; a new type-6 account is a V3 linked to (frostydao, Safe);
///         ALPHA's existing positions value the same across the re-points and its LinkReferral op
///         links its V2 perp; the governance handoff moves every new ownable to the timelock and
///         {FundsGovernance.verify} catches each compounder regression.
///         Facts, each read with `cast` (pinned 52014634 and live head 52049046 unless noted):
///         - FundFactory 0x42F2…29a3: owner = deployer 0xaE51…802a, pendingOwner = timelock 0xd50A…83Ba;
///           types 4 / 7 / 6 = 0x7542…8176 / 0xa205…B62e (V1 Slipstream LP) / 0x6B15…D8a9 (V2 perp).
///         - Timelock 0xd50A…83Ba: delay 172800, the Admin (guardian) Safe 0xB0f3…8B8B proposes, open execution.
///         - DAO Treasury Safe 0x47b7…fF0A: Safe 1.4.1, threshold 2.
///         - Referral: `frostydao` unregistered at 52014634; at 52049381 owned by the ADMIN Safe (tier 1),
///           the Treasury Safe holds no code. The fix is setPendingCodeOwnershipTransfer from the
///           Admin Safe, then acceptCodeOwnership from the Treasury Safe (verified source: the tier
///           carries over). The V2 perp factory's code is still `frostyfi` at both blocks.
///         - Pools (getPool): Uniswap WETH/USDC 3000 0x6c56…1372; Slipstream-1 WETH/USDC ts100
///           0xb2cc…DC59 (gauge 0xF33a…e0c8) and cbBTC/USDC ts100 0x4e96…E778; Slipstream-2 WETH/USDC
///           ts50 0x3FE0…392A (gauge 0xA0B6…2D28); Slipstream-3 WETH/USDC ts50 0xc758…54e0; Uniswap
///           VIRTUAL/USDC 3000 0x529d…017C (VIRTUAL unpriced in the live VI; test/fork/TwapListingV2Fork).
///         - ALPHA 0x833A…dE9 (degen): at 52014634 one V2 perp 0x33C7…844d; at live head also two V1
///           type-7 LPs 0x3Fbd…d674 (USDC/MSTRc, staked) and 0x236E…fe2c (USDC/METAc) — typeId 7 in their
///           ExternalPositionCreated events (blocks 52037778 / 52038094) — and it tracks two B20 stocks.
///         Run: BASE_MAINNET_RPC=<url> [BASE_FORK_BLOCK=52014634] forge test --match-path test/fork/CompoundersMainnetFork.t.sol -j 1 -vv
contract CompoundersMainnetForkTest is Test {
	string internal constant GENESIS_FILE = 'deployments/base-mainnet.json';

	address internal constant WETH = FundsMainnet.WETH;
	address internal constant USDC = FundsMainnet.USDC;
	address internal constant CBBTC = FundsMainnet.CBBTC;
	address internal constant AERO = FundsMainnet.AERO;
	address internal constant REFERRAL = FundsMainnet.VERANTA_REFERRAL;
	address internal constant DAO_SAFE = 0x47b7702a4789912d0dfFDadC07c50395c293fF0A;
	address internal constant ADMIN_SAFE = 0xB0f37bE90a8BD82D991Bf694F960C67198778B8B;
	address internal constant TIMELOCK = 0xd50AF6A924f23AC6944fB8eBc981E006B07D83Ba;
	address internal constant ALPHA = 0x833A506d761A4756AF279ABC24183Db407823dE9;
	bytes32 internal constant FROSTYDAO = 'frostydao';
	bytes32 internal constant FROSTYFI = 'frostyfi';
	/// @dev the genesis type factories the deploy re-points
	address internal constant V1_CL1_LP_FACTORY = 0x7542c62565f48520A34Cf79884656efDEdD38176;
	address internal constant V1_CL2_LP_FACTORY = 0xa205812D1748ea91e4563253ca2af2F66fD3B62e;

	address internal constant UNI_WETH_USDC_3000 = 0x6c561B446416E1A00E8E93E221854d6eA4171372;
	address internal constant SLIP1_WETH_USDC_100 = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
	address internal constant SLIP1_CBBTC_USDC_100 = 0x4e962BB3889Bf030368F56810A9c96B83CB3E778;
	address internal constant SLIP2_WETH_USDC_50 = 0x3FE04A59Ebd38cF06080a6F60a98D124eb59392A;
	address internal constant SLIP3_WETH_USDC_50 = 0xc758d81B9b81A6FCDAd075bD471874A2c46B54e0;
	address internal constant VIRTUAL = 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b;
	address internal constant VIRTUAL_USDC_3000 = 0x529d2863a1521d0b57db028168fdE2E97120017C;

	uint16 internal constant FEE_BPS = 1000;
	/// @dev ±1,000 ticks (≈ ±10%) around spot for the gauge positions: in range, so they earn emissions
	int24 internal constant HALF_RANGE = 1000;

	struct Pool {
		string label;
		CompounderFactory.Venue venue;
		int24 tier;
		address pool;
		address npm;
		address router;
		uint256 fundUsdc; // the fund's deposit
		uint256 buyWethUsdc; // USDC it swaps to WETH first
		uint256 vaultUsdc; // USDC it sends the vault (with all its WETH)
		uint256 churnWeth; // WETH per swap leg that makes the fees
	}

	struct Harvest {
		bool found;
		uint256 harvested0;
		uint256 harvested1;
		uint256 fee0;
		uint256 fee1;
		uint128 added;
	}

	/// @dev One gauge payout (a claim or an unstake), measured.
	struct Payout {
		uint256 earned;
		uint256 toTreasury;
		uint256 toVault;
		uint256 onPosition;
	}

	bool internal forked;
	address internal deployer;
	ValueInterpreter internal vi;
	FundFactory internal factory;
	address internal uniAdapter;
	VerantaPerpPositionV2Factory internal v2Perp;
	IReferralCodes internal referral = IReferralCodes(REFERRAL);
	TwapListingV2.Deployed internal twap;
	CompoundersMainnet.Deployed internal c;

	/// @dev the funds-keeper wallet: PriceListingModule keeper AND CompounderFactory creator (plan)
	address internal keeper = makeAddr('fundsKeeper');
	/// @dev the FrostyFi workflow wallet: the CompounderFactory compounder role
	address internal workflow = makeAddr('workflowVaultWallet');
	address internal manager = makeAddr('manager');
	address internal investor = makeAddr('investor');
	address internal stranger = makeAddr('stranger');
	address internal swapper = makeAddr('swapper');

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		uint256 blockNumber = vm.envOr('BASE_FORK_BLOCK', uint256(0));
		if (blockNumber > 0) vm.createSelectFork(rpc, blockNumber);
		else vm.createSelectFork(rpc);
		forked = true;

		string memory genesis = vm.readFile(GENESIS_FILE);
		deployer = vm.parseJsonAddress(genesis, '.deployer');
		vi = ValueInterpreter(vm.parseJsonAddress(genesis, '.valueInterpreter'));
		factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		uniAdapter = vm.parseJsonAddress(genesis, '.uniAdapter');
		v2Perp = VerantaPerpPositionV2Factory(vm.parseJsonAddress(genesis, '.verantaFactory'));

		// TWAP listing v2 first, exactly as DeployTwapListingV2 broadcasts it
		vm.startPrank(deployer);
		twap = TwapListingV2.deploy(
			TwapListingV2.Config({
				deployer: deployer,
				valueInterpreter: vi,
				factory: factory,
				twapPolicyV1: vm.parseJsonAddress(genesis, '.twapPolicy'),
				keeper: keeper
			})
		);
		vm.stopPrank();
	}

	// ─── the deploy ──────────────────────────────────────────────────────────────

	function test_fork_deployWiresEverything() public {
		vm.skip(!forked);
		assertEq(factory.positionTypeFactories(4), V1_CL1_LP_FACTORY, 'before: type 4 is the genesis V1 LP');
		assertEq(factory.positionTypeFactories(7), V1_CL2_LP_FACTORY, 'before: type 7 is the genesis V1 LP');
		assertEq(factory.positionTypeFactories(6), address(v2Perp), 'before: type 6 is the V2 perp');
		assertEq(Ownable(address(factory)).owner(), deployer);
		_foundersOps();
		_deploy();

		// the adapter and the module's listing
		assertTrue(factory.isAdapterRegistered(address(c.adapter)));
		assertEq(address(twap.module.compounderFactory()), address(c.compounderFactory));
		assertEq(twap.module.compounderFeed(), address(c.feed));
		assertEq(address(c.feed.valueInterpreter()), address(vi));
		// the factory: four venues, each NPM minting into its own pool factory, 10% to the DAO Safe
		CompounderFactory f = c.compounderFactory;
		_assertVenue(f.uniswapV3Factory(), f.uniswapV3Npm(), FundsMainnet.UNI_FACTORY, FundsMainnet.UNI_NPM);
		_assertVenue(f.slipstreamFactory(), f.slipstreamNpm(), FundsMainnet.CL_FACTORY, FundsMainnet.CL_NPM);
		_assertVenue(f.slipstream2Factory(), f.slipstream2Npm(), FundsMainnet.CL2_FACTORY, FundsMainnet.CL2_NPM);
		_assertVenue(f.slipstream3Factory(), f.slipstream3Npm(), TwapListingV2.CL3_FACTORY, FundsMainnet.CL3_NPM);
		assertEq(f.defaultPerfFeeBps(), FEE_BPS);
		assertEq(f.treasury(), DAO_SAFE);
		assertTrue(f.creators(keeper));
		assertTrue(f.compounders(workflow));
		assertFalse(f.creators(deployer), 'the deployer creates nothing');
		assertFalse(f.compounders(deployer), 'the deployer compounds nothing');
		// the re-points
		assertEq(factory.positionTypeFactories(4), address(c.slipstreamLp));
		assertEq(factory.positionTypeFactories(7), address(c.slipstream2Lp));
		assertEq(factory.positionTypeFactories(6), address(c.perpV3));
		assertEq(address(c.slipstreamLp.positionManager()), FundsMainnet.CL_NPM);
		assertEq(address(c.slipstream2Lp.positionManager()), FundsMainnet.CL2_NPM);
		assertEq(c.slipstreamLp.aeroFeeBps(), FEE_BPS);
		assertEq(c.slipstream2Lp.aeroFeeBps(), FEE_BPS);
		assertEq(c.slipstreamLp.treasury(), DAO_SAFE);
		assertEq(c.slipstream2Lp.treasury(), DAO_SAFE);
		assertEq(address(c.perpV3.config()), address(v2Perp));
		// owners until the handoff; nothing else answers owner()
		assertEq(f.owner(), deployer);
		assertEq(c.slipstreamLp.owner(), deployer);
		assertEq(c.slipstream2Lp.owner(), deployer);
		assertFalse(_hasOwner(address(c.perpV3)), 'the V3 perp factory is ownerless');
		assertFalse(_hasOwner(address(c.feed)));
		assertFalse(_hasOwner(address(c.adapter)));
		assertFalse(_hasOwner(address(f.uniswapV3Deployer())));
		assertFalse(_hasOwner(address(f.slipstreamDeployer())));
		// the referral the deploy required
		assertEq(referral.codeOwners(FROSTYDAO), DAO_SAFE);
		assertEq(referral.codes(DAO_SAFE), FROSTYDAO);
		assertEq(referral.referrerTiers(DAO_SAFE), 1, 'tier 1, as registered');
		assertEq(v2Perp.referralCode(), FROSTYDAO);
		assertEq(address(v2Perp.referral()), REFERRAL);
		this.verifyDeploy();
	}

	/// The deploy fails closed on every missing founder op, with the op that fixes it; the live-head
	/// state (the Admin Safe holds `frostydao`) is refused too. A refused deploy changes nothing.
	function test_fork_deployRefusesUntilTheReferralOpsAreDone() public {
		vm.skip(!forked);
		_recreateTheAdminSafeState();
		_expectReferralNotReady('founder op 1 missing', vm.toLowercase(vm.toString(ADMIN_SAFE)));
		// op 2 alone does not help while the Admin Safe holds the code
		vm.prank(deployer);
		v2Perp.setReferral(IVerantaReferral(REFERRAL), FROSTYDAO);
		_expectReferralNotReady('founder op 1 missing', vm.toLowercase(vm.toString(ADMIN_SAFE)));

		// the two-step transfer to the Treasury Safe fixes op 1
		_transferCodeToTreasury();
		assertEq(referral.codeOwners(FROSTYDAO), DAO_SAFE);
		// op 2 undone: the factory still on frostyfi, then on another referral contract
		vm.prank(deployer);
		v2Perp.setReferral(IVerantaReferral(REFERRAL), FROSTYFI);
		_expectReferralNotReady('founder op 2 missing: the V2 perp factory referralCode()', '');
		vm.prank(deployer);
		v2Perp.setReferral(IVerantaReferral(stranger), FROSTYDAO);
		_expectReferralNotReady('founder op 2 missing: the V2 perp factory referral()', '');
		assertEq(factory.positionTypeFactories(4), V1_CL1_LP_FACTORY, 'a refused deploy changed nothing');
		assertEq(address(twap.module.compounderFactory()), address(0));

		// all ops done: it deploys
		vm.prank(deployer);
		v2Perp.setReferral(IVerantaReferral(REFERRAL), FROSTYDAO);
		_deploy();
		assertEq(factory.positionTypeFactories(4), address(c.slipstreamLp));
	}

	/// An unregistered code (the pinned block) is refused, naming the zero owner; the Treasury
	/// Safe registering it directly is the other valid op 1.
	function test_fork_deployRefusesAnUnregisteredOrForeignCode() public {
		vm.skip(!forked);
		vm.prank(deployer);
		v2Perp.setReferral(IVerantaReferral(REFERRAL), FROSTYDAO);
		address codeOwner = referral.codeOwners(FROSTYDAO);
		if (codeOwner == address(0)) {
			_expectReferralNotReady('founder op 1 missing', vm.toString(address(0)));
			vm.prank(DAO_SAFE);
			referral.registerCode(FROSTYDAO);
		} else if (codeOwner == ADMIN_SAFE) {
			_transferCodeToTreasury();
		}
		_deploy();
		// after the deploy, verify still guards the referral: the code moved away from the Safe is caught
		vm.prank(DAO_SAFE);
		referral.setPendingCodeOwnershipTransfer(FROSTYDAO, stranger);
		vm.prank(stranger);
		referral.acceptCodeOwnership(FROSTYDAO);
		bytes memory err = _revertOf(abi.encodeCall(this.verifyDeploy, ()));
		_assertReferralNotReady(err, 'founder op 1 missing', vm.toLowercase(vm.toString(stranger)));
	}

	/// Fail closed means first: without the founder ops the deploy stops before its first call — no
	/// adapter registered, no listing wired, no type re-pointed (not merely reverted at the end).
	function test_fork_refusedDeployCallsNothing() public {
		vm.skip(!forked);
		_recreateTheAdminSafeState();
		vm.expectCall(address(factory), abi.encodeWithSelector(FundFactory.registerAdapter.selector), 0);
		vm.expectCall(address(twap.module), abi.encodeWithSelector(PriceListingModule.setCompounderListing.selector), 0);
		vm.expectCall(address(factory), abi.encodeWithSelector(FundFactory.registerPositionType.selector), 0);
		_assertReferralNotReady(_revertOf(abi.encodeCall(this.deployCompounders, ())), 'founder op 1 missing', '');
	}

	/// After the deploy its verify keeps proving the referral: the factory moved back off frostydao is caught.
	function test_fork_verifyCatchesAReferralRegression() public {
		vm.skip(!forked);
		_foundersOps();
		_deploy();
		this.verifyDeploy();
		vm.prank(deployer);
		v2Perp.setReferral(IVerantaReferral(REFERRAL), FROSTYFI);
		_assertReferralNotReady(
			_revertOf(abi.encodeCall(this.verifyDeploy, ())), 'founder op 2 missing: the V2 perp factory referralCode()', ''
		);
		vm.prank(deployer);
		v2Perp.setReferral(IVerantaReferral(address(0)), FROSTYDAO);
		_assertReferralNotReady(
			_revertOf(abi.encodeCall(this.verifyDeploy, ())), 'founder op 2 missing: the V2 perp factory referral()', ''
		);
	}

	// ─── vaults: create, list, refuse ────────────────────────────────────────────

	function test_fork_keeperCreatesAndListsOnEveryVenue() public {
		vm.skip(!forked);
		_foundersOps();
		_deploy();
		CompounderFactory f = c.compounderFactory;

		// only the creator creates; only the module keeper lists
		vm.prank(stranger);
		vm.expectRevert(CompounderFactory.NotCreator.selector);
		f.create(CompounderFactory.Venue.UniswapV3, WETH, USDC, 3000);
		vm.prank(deployer);
		vm.expectRevert(CompounderFactory.NotCreator.selector);
		f.create(CompounderFactory.Venue.UniswapV3, WETH, USDC, 3000);

		address uni = _createAndList(CompounderFactory.Venue.UniswapV3, WETH, USDC, 3000, UNI_WETH_USDC_3000);
		_createAndList(CompounderFactory.Venue.Slipstream, WETH, USDC, 100, SLIP1_WETH_USDC_100);
		_createAndList(CompounderFactory.Venue.Slipstream, CBBTC, USDC, 100, SLIP1_CBBTC_USDC_100);
		_createAndList(CompounderFactory.Venue.Slipstream2, WETH, USDC, 50, SLIP2_WETH_USDC_50);
		_createAndList(CompounderFactory.Venue.Slipstream3, WETH, USDC, 50, SLIP3_WETH_USDC_50);
		assertEq(f.compounderCount(), 5);
		assertEq(FeeCompounderBase(uni).name(), 'Frosty Compounding WETH-USDC');

		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(CompounderFactory.AlreadyExists.selector, UNI_WETH_USDC_3000, uni));
		f.create(CompounderFactory.Venue.UniswapV3, USDC, WETH, 3000);
		vm.prank(stranger);
		vm.expectRevert(PriceListingModule.NotKeeper.selector);
		twap.module.listCompounder(uni);

		// a governance delist sticks (ruling C6): removeDerivative + block, and the keeper can't re-list
		vm.startPrank(deployer);
		twap.module.execute(abi.encodeCall(ValueInterpreter.removeDerivative, (uni)));
		twap.module.setCompounderBlocked(uni, true);
		vm.stopPrank();
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(PriceListingModule.CompounderBlocked.selector, uni));
		twap.module.listCompounder(uni);
		assertFalse(vi.isSupportedAsset(uni));
	}

	/// The cap-bypass guard on real pools: a vault over a TWAP-priced token is refused at listing (and
	/// over a token the VI doesn't price at all, before it is listed).
	function test_fork_twapTokenPoolRefusedAtListing() public {
		vm.skip(!forked);
		_foundersOps();
		_deploy();
		vm.prank(keeper);
		address vault = c.compounderFactory.create(CompounderFactory.Venue.UniswapV3, VIRTUAL, USDC, 3000);
		assertEq(IVaultPool(vault).pool(), VIRTUAL_USDC_3000);

		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(PriceListingModule.UnpricedUnderlying.selector, VIRTUAL));
		twap.module.listCompounder(vault);

		// the keeper lists VIRTUAL on the TWAP tier (the deepest USDC pool, its oracle ring is 600)
		vm.prank(keeper);
		twap.module.list(VIRTUAL, USDC, TwapListingRegistryV2.Venue.UniswapV3, 3000);
		assertTrue(twap.registry.isTwapPriced(VIRTUAL));
		(address aggregator,,,) = vi.getAssetInfo(VIRTUAL);
		assertTrue(aggregator != address(0), 'VIRTUAL is now a VI primitive');

		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(PriceListingModule.TwapUnderlying.selector, VIRTUAL));
		twap.module.listCompounder(vault);
		assertFalse(vi.isSupportedAsset(vault), 'never priced: no cap bypass');
	}

	// ─── a fund compounds on every venue ─────────────────────────────────────────

	function test_fork_uni_fundCompoundsTenPercentToTheSafe() public {
		vm.skip(!forked);
		_fundCompounds(_uni());
	}

	function test_fork_slip1_fundCompoundsTenPercentToTheSafe() public {
		vm.skip(!forked);
		_fundCompounds(_slip1());
	}

	function test_fork_slip2_fundCompoundsTenPercentToTheSafe() public {
		vm.skip(!forked);
		_fundCompounds(_slip2());
	}

	function test_fork_slip3_fundCompoundsTenPercentToTheSafe() public {
		vm.skip(!forked);
		_fundCompounds(_slip3());
	}

	/// A fresh NON-degen fund deposits through the new adapter; real swaps make fees; the workflow
	/// wallet compounds; the Safe gets exactly 10% of the harvest; NAV rises by the fund's share of
	/// the net harvest (reinvested liquidity + tracked idle); the exit moves value, not NAV.
	function _fundCompounds(Pool memory p) internal {
		_foundersOps();
		_deploy();
		address vault = _createAndList(p.venue, WETH, USDC, p.tier, p.pool);
		FeeCompounderBase cv = FeeCompounderBase(vault);
		assertEq(cv.perfFeeBps(), FEE_BPS);
		assertEq(cv.treasury(), DAO_SAFE);

		Comptroller fund = _fund(string.concat('Compounder acceptance ', p.label), p.fundUsdc);
		assertFalse(fund.allowRiskyAssets(), 'a non-degen fund');
		vm.prank(manager);
		fund.callOnIntegration(uniAdapter, abi.encode(USDC, WETH, uint24(500), p.buyWethUsdc, uint256(0)));
		uint256 shares = _fundDeposits(fund, vault, p.vaultUsdc);

		(uint160 sqrtP0,) = _slot0(p.pool);
		_churn(p, 2);
		_restore(p, sqrtP0);
		_refusesStrangers(cv);
		_compoundPaysTheSafe(fund, p, cv, shares);
		_fundExits(fund, vault, shares);
	}

	function _fundDeposits(Comptroller fund, address vault, uint256 usdc) internal returns (uint256 shares) {
		address fv = address(fund.vault());
		uint256 wethHeld = IERC20(WETH).balanceOf(fv); // read before the prank: an argument call would consume it
		uint256 gav0 = fund.calcGav();
		vm.prank(manager);
		fund.callOnIntegration(address(c.adapter), abi.encode(uint8(0), vault, wethHeld, usdc, uint256(1)));
		shares = IERC20(vault).balanceOf(fv);
		assertGt(shares, 0, 'shares landed in the fund vault');
		_assertNothingStuck(vault);
		assertApproxEqRel(fund.calcGav(), gav0, 0.01e18, 'depositing moves value, not NAV');
		emit log_named_decimal_uint('GAV before deposit (USDC)', gav0, 6);
		emit log_named_decimal_uint('GAV after deposit (USDC) ', fund.calcGav(), 6);
	}

	function _refusesStrangers(FeeCompounderBase cv) internal {
		address[3] memory refused = [stranger, keeper, deployer];
		for (uint256 i; i < refused.length; ++i) {
			vm.prank(refused[i]);
			vm.expectRevert(FeeCompounderBase.NotCompounder.selector);
			cv.compound();
		}
	}

	function _compoundPaysTheSafe(Comptroller fund, Pool memory p, FeeCompounderBase cv, uint256 shares) internal {
		(uint256 e0, uint256 e1) = _collectable(p, cv);
		uint256 t0 = IERC20(WETH).balanceOf(DAO_SAFE);
		uint256 t1 = IERC20(USDC).balanceOf(DAO_SAFE);
		(uint128 liquidityBefore,,) = cv.positionState();
		uint256 gav2 = fund.calcGav();

		vm.recordLogs();
		vm.prank(workflow);
		cv.compound();
		Harvest memory h = _harvestIn(vm.getRecordedLogs(), address(cv));

		assertTrue(h.found, 'a Compounded event');
		assertGt(h.harvested0, 0, 'real swaps paid WETH fees');
		assertGt(h.harvested1, 0, 'real swaps paid USDC fees');
		assertEq(h.harvested0, e0, 'harvested every WETH fee the position was owed');
		assertEq(h.harvested1, e1, 'harvested every USDC fee the position was owed');
		assertEq(h.fee0, (h.harvested0 * FEE_BPS) / 10_000, '10% of the WETH harvest');
		assertEq(h.fee1, (h.harvested1 * FEE_BPS) / 10_000, '10% of the USDC harvest');
		assertEq(IERC20(WETH).balanceOf(DAO_SAFE) - t0, h.fee0, 'the Safe received exactly the WETH fee');
		assertEq(IERC20(USDC).balanceOf(DAO_SAFE) - t1, h.fee1, 'the Safe received exactly the USDC fee');
		(uint128 liquidityAfter,,) = cv.positionState();
		assertGt(h.added, 0, 'fees reinvested');
		assertEq(liquidityAfter - liquidityBefore, h.added, 'the position grew by exactly the reinvest');

		uint256 gav3 = fund.calcGav();
		uint256 netUsdc = vi.calcCanonicalAssetValue(WETH, h.harvested0 - h.fee0, USDC) + (h.harvested1 - h.fee1);
		uint256 fundShare = Math.mulDiv(netUsdc, shares, cv.totalSupply());
		assertGt(gav3, gav2, 'NAV rises at compound');
		assertApproxEqRel(gav3 - gav2, fundShare, 0.01e18, "NAV rises by the fund's share of the net harvest");
		emit log_named_string('venue', p.label);
		emit log_named_decimal_uint('  harvested WETH            ', h.harvested0, 18);
		emit log_named_decimal_uint('  harvested USDC            ', h.harvested1, 6);
		emit log_named_decimal_uint('  Safe WETH (10%)           ', h.fee0, 18);
		emit log_named_decimal_uint('  Safe USDC (10%)           ', h.fee1, 6);
		emit log_named_decimal_uint('  fund share of net (USDC)  ', fundShare, 6);
		emit log_named_decimal_uint('  GAV step at compound      ', gav3 - gav2, 6);
	}

	function _fundExits(Comptroller fund, address vault, uint256 shares) internal {
		uint256 gav = fund.calcGav();
		vm.prank(manager);
		fund.callOnIntegration(address(c.adapter), abi.encode(uint8(1), vault, shares, uint256(1), uint256(1)));
		assertEq(IERC20(vault).balanceOf(address(fund.vault())), 0, 'every share redeemed');
		_assertNothingStuck(vault);
		assertApproxEqRel(fund.calcGav(), gav, 0.001e18, 'withdrawing moves value, not NAV');
	}

	// ─── re-pointed position types ───────────────────────────────────────────────

	function test_fork_newType4PositionIsV2AndPaysTheSafe() public {
		vm.skip(!forked);
		_foundersOps();
		_deploy();
		_lpPaysTheSafe(FundsMainnet.SLIPSTREAM_LP_TYPE, SLIP1_WETH_USDC_100, 100, FundsMainnet.CL_NPM, c.slipstreamLp);
	}

	function test_fork_newType7PositionIsV2AndPaysTheSafe() public {
		vm.skip(!forked);
		_foundersOps();
		_deploy();
		_lpPaysTheSafe(FundsMainnet.SLIPSTREAM2_LP_TYPE, SLIP2_WETH_USDC_50, 50, FundsMainnet.CL2_NPM, c.slipstream2Lp);
	}

	/// A new position under the re-pointed type is a V2 of the new factory; its AERO claim pays the
	/// Safe exactly 10% (the vault the rest), and so does its unstake (the rest stays on the position).
	function _lpPaysTheSafe(uint256 typeId, address pool, int24 spacing, address npm, SlipstreamLPPositionV2Factory lpFactory)
		internal
	{
		address gauge = IPoolGauge(pool).gauge();
		Comptroller fund = _fund(string.concat('LP type ', vm.toString(typeId)), 400_000e6);
		vm.prank(manager);
		fund.callOnIntegration(uniAdapter, abi.encode(USDC, WETH, uint24(500), uint256(150_000e6), uint256(0)));
		vm.prank(manager);
		address position = fund.createExternalPosition(typeId, abi.encode(WETH, USDC, spacing, gauge));
		assertEq(address(SlipstreamLPPositionV2(position).factory()), address(lpFactory), 'a V2 of the new factory');
		_mintAndStake(fund, position, pool, spacing);
		assertEq(IERC721(npm).ownerOf(SlipstreamLPPositionV2(position).tokenId()), gauge, 'staked in the pool gauge');

		_accrue(10 minutes);
		address[] memory receiveAero = new address[](1);
		receiveAero[0] = AERO;
		Payout memory claim = _gaugePayout(fund, position, gauge, uint8(SlipstreamLPPositionV2.Action.ClaimRewards), receiveAero);
		assertGt(claim.earned, 0, 'the gauge owed AERO');
		assertEq(claim.toTreasury, claim.earned * FEE_BPS / 10_000, 'claim: the Safe gets exactly 10%');
		assertEq(claim.toVault, claim.earned - claim.toTreasury, 'claim: the vault gets the rest');

		_accrue(5 minutes);
		Payout memory unstake =
			_gaugePayout(fund, position, gauge, uint8(SlipstreamLPPositionV2.Action.Unstake), new address[](0));
		assertGt(unstake.earned, 0, 'the gauge owed AERO again');
		assertEq(unstake.toTreasury, unstake.earned * FEE_BPS / 10_000, 'unstake: the Safe gets exactly 10%');
		assertEq(unstake.onPosition, unstake.earned - unstake.toTreasury, 'unstake: the rest stays on the position');
		assertEq(IERC721(npm).ownerOf(SlipstreamLPPositionV2(position).tokenId()), position, 'unstaked');
		emit log_named_uint('type', typeId);
		emit log_named_decimal_uint('  claim AERO   ', claim.earned, 18);
		emit log_named_decimal_uint('  claim Safe   ', claim.toTreasury, 18);
		emit log_named_decimal_uint('  unstake AERO ', unstake.earned, 18);
		emit log_named_decimal_uint('  unstake Safe ', unstake.toTreasury, 18);
	}

	function test_fork_newType6AccountIsV3LinkedToTheSafe() public {
		vm.skip(!forked);
		_foundersOps();
		_deploy();
		Comptroller fund = _fund('Perp V3 acceptance', 10_000e6);
		vm.recordLogs();
		vm.prank(manager);
		address account = fund.createExternalPosition(FundsMainnet.VERANTA_PERP_TYPE, '');
		Vm.Log[] memory logs = vm.getRecordedLogs();
		assertEq(address(VerantaPerpPositionV3(account).positionFactory()), address(v2Perp), 'a V3 on the live config');
		bool linked;
		for (uint256 i; i < logs.length; ++i) {
			if (logs[i].emitter == account && logs[i].topics[0] == VerantaPerpPositionV3.ReferralLinked.selector) {
				assertEq(logs[i].topics[1], FROSTYDAO);
				linked = true;
			}
		}
		assertTrue(linked, 'ReferralLinked at creation');
		assertEq(referral.traderReferralCodes(account), FROSTYDAO);
		(bytes32 code, address referrer) = referral.getTraderReferralInfo(account);
		assertEq(code, FROSTYDAO);
		assertEq(referrer, DAO_SAFE, 'rebates route to the DAO Treasury Safe');
	}

	/// ALPHA's existing positions keep their contracts and value across the re-points; its V2 perp
	/// links (frostydao, Safe) through the fund owner's LinkReferral; GAV is unchanged throughout.
	function test_fork_alphaKeepsValueAcrossTheRepointsAndLinks() public {
		vm.skip(!forked);
		Comptroller alpha = Comptroller(ALPHA);
		uint256 mirrored = _mirrorB20s(alpha);
		emit log_named_uint('B20 stocks mirrored from the chain', mirrored);
		_foundersOps();

		address[] memory positions = alpha.getExternalPositions();
		bytes32[] memory before_ = new bytes32[](positions.length);
		for (uint256 i; i < positions.length; ++i) {
			before_[i] = _valueHash(positions[i]);
		}
		uint256 gav0 = alpha.calcGav();

		_deploy();
		assertEq(alpha.calcGav(), gav0, 'same GAV after the re-points');
		address perp;
		for (uint256 i; i < positions.length; ++i) {
			assertEq(_valueHash(positions[i]), before_[i], 'each position reports the same');
			(bool isV2Lp,) = positions[i].staticcall(abi.encodeWithSignature('factory()'));
			assertFalse(isV2Lp, 'an existing position keeps its contract');
			(bool ok, bytes memory ret) = positions[i].staticcall(abi.encodeWithSignature('positionFactory()'));
			if (ok && ret.length == 32 && abi.decode(ret, (address)) == address(v2Perp)) perp = positions[i];
		}
		assertTrue(perp != address(0), "ALPHA's V2 perp");
		(bool hasLink,) = perp.call(abi.encodeWithSignature('linkReferral()'));
		assertFalse(hasLink, 'a V2 account links only through the fund owner');

		// the founder's ALPHA op (runbook step 3): LinkReferral on its V2 perp
		bytes memory actionData = abi.encode(uint8(VerantaPerpPositionV2.Action.LinkReferral), bytes(''));
		vm.prank(alpha.fundOwner());
		alpha.callOnExternalPosition(perp, new address[](0), new uint256[](0), new address[](0), actionData);
		(bytes32 code, address referrer) = referral.getTraderReferralInfo(perp);
		assertEq(code, FROSTYDAO);
		assertEq(referrer, DAO_SAFE);
		assertEq(alpha.calcGav(), gav0, 'linking moves no value');
		emit log_named_uint('ALPHA external positions', positions.length);
		emit log_named_decimal_uint('ALPHA GAV (USDC)', gav0, 6);
	}

	/// The B20 stand-in returns exactly what the chain's precompile answers (a Coinbase stock token's
	///      decimals and a real holder's balance, read through eth_call), and refuses unloaded holders.
	function test_fork_b20MirrorAnswersWhatTheChainAnswers() public {
		vm.skip(!forked);
		// Coinbase NVDA (test/fork/TwapListingV2Fork); `cast`: decimals 8, and 0x4985…2b2b (a receiver in its
		// Transfer logs before block 52014634) held 184975916224 = 1,849.75916224 NVDAc at that block
		address nvdac = 0xb20000000000000000000078ee7ce2fE4908108C;
		address holder = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
		assertEq(keccak256(nvdac.code), keccak256(hex'ef'), 'a B20 precompile account');
		address[] memory holders = new address[](1);
		holders[0] = holder;
		_mirror(nvdac, holders);
		assertEq(B20ChainSnapshot(nvdac).decimals(), 8);
		uint256 chainBalance = abi.decode(_chainCall(nvdac, abi.encodeCall(IERC20.balanceOf, (holder))), (uint256));
		assertGt(chainBalance, 0);
		assertEq(IERC20(nvdac).balanceOf(holder), chainBalance, 'what the chain answers');
		if (block.number == 52014634) assertEq(chainBalance, 184975916224, 'the cast reading');
		vm.expectRevert(abi.encodeWithSelector(B20ChainSnapshot.HolderNotLoaded.selector, stranger));
		IERC20(nvdac).balanceOf(stranger);
	}

	// ─── governance handoff ──────────────────────────────────────────────────────

	/// StartFundsGovernance → the Admin Safe schedules → 2 days → anyone executes → verify: every
	/// ownable either deploy made is the timelock's, the deployer holds nothing, and verify catches
	/// each compounder regression.
	function test_fork_handoffMovesEveryNewOwnableToTheTimelock() public {
		vm.skip(!forked);
		_foundersOps();
		_deploy();
		(FundsMainnet.Deployed memory g, FundsGovernance.TwapV2 memory v2, FundsGovernance.Compounders memory comp) =
			_governanceBooks();

		// a handoff that leaves the compounders out is refused before anything moves
		FundsGovernance.Compounders memory none;
		vm.expectRevert(
			abi.encodeWithSelector(FundsGovernance.CompounderListingNotWired.selector, address(comp.factory), comp.feed)
		);
		this.startGovernance(g, v2, none);

		vm.startPrank(deployer);
		FundsGovernance.start(g, v2, comp, TIMELOCK, deployer);
		vm.stopPrank();
		(address[] memory targets, uint256[] memory values, bytes[] memory payloads) = FundsGovernance.acceptBatch(g, v2, comp);
		assertEq(targets.length, 8, 'module, registry v2, factory, v1 registry, Veranta config, compounder + 2 LP factories');
		bytes32 salt = keccak256('compounders-acceptance');
		vm.prank(ADMIN_SAFE);
		TimelockController(payable(TIMELOCK)).scheduleBatch(targets, values, payloads, bytes32(0), salt, 2 days);
		skip(2 days);
		TimelockController(payable(TIMELOCK)).executeBatch(targets, values, payloads, bytes32(0), salt);
		this.verifyGovernance(g, v2, comp);

		_assertEveryOwnableHandedOff(targets);
		_assertDeployerPowerless();
		_assertVerifyCatchesCompounderRegressions(g, v2, comp);
	}

	// ─── external wrappers (library calls are inlined; a revert needs a call frame) ──

	function deployCompounders() external returns (CompoundersMainnet.Deployed memory d) {
		vm.startPrank(deployer);
		d = CompoundersMainnet.deploy(_config());
		vm.stopPrank();
	}

	function verifyDeploy() external view {
		CompoundersMainnet.verify(_config(), c);
	}

	function startGovernance(
		FundsMainnet.Deployed memory g,
		FundsGovernance.TwapV2 memory v2,
		FundsGovernance.Compounders memory comp
	) external {
		FundsGovernance.start(g, v2, comp, TIMELOCK, deployer);
	}

	function verifyGovernance(
		FundsMainnet.Deployed memory g,
		FundsGovernance.TwapV2 memory v2,
		FundsGovernance.Compounders memory comp
	) external view {
		FundsGovernance.verify(
			g, v2, comp, TIMELOCK, ADMIN_SAFE, deployer, vm.parseJsonAddress(vm.readFile(GENESIS_FILE), '.autopilotKeeper')
		);
	}

	// ─── founder ops + deploy ────────────────────────────────────────────────────

	/// @dev The founder's referral ops from whatever state the chain is in: unregistered → the
	///      Treasury Safe registers; held by the Admin Safe (live head) → setPending + accept; already
	///      the Treasury Safe's → nothing. Then the deployer points the V2 perp factory at it.
	function _foundersOps() internal {
		address codeOwner = referral.codeOwners(FROSTYDAO);
		if (codeOwner == address(0)) {
			vm.prank(DAO_SAFE);
			referral.registerCode(FROSTYDAO);
		} else if (codeOwner == ADMIN_SAFE) {
			_transferCodeToTreasury();
		} else {
			assertEq(codeOwner, DAO_SAFE, 'frostydao is held by an unexpected account');
		}
		assertEq(referral.codeOwners(FROSTYDAO), DAO_SAFE);
		if (address(v2Perp.referral()) != REFERRAL || v2Perp.referralCode() != FROSTYDAO) {
			vm.prank(deployer);
			v2Perp.setReferral(IVerantaReferral(REFERRAL), FROSTYDAO);
		}
	}

	/// @dev The state the founder's first op left (block 52049381): `frostydao` held by the ADMIN Safe and
	///      the V2 perp factory still on `frostyfi` — recreated from whatever state the chain is in
	///      (unregistered at 52014634; already fixed on the Treasury Safe from block ~52050000).
	function _recreateTheAdminSafeState() internal {
		address codeOwner = referral.codeOwners(FROSTYDAO);
		if (codeOwner == address(0)) {
			vm.prank(ADMIN_SAFE);
			referral.registerCode(FROSTYDAO);
		} else if (codeOwner == DAO_SAFE) {
			vm.prank(DAO_SAFE);
			referral.setPendingCodeOwnershipTransfer(FROSTYDAO, ADMIN_SAFE);
			vm.prank(ADMIN_SAFE);
			referral.acceptCodeOwnership(FROSTYDAO);
		}
		assertEq(referral.codeOwners(FROSTYDAO), ADMIN_SAFE);
		vm.prank(deployer);
		v2Perp.setReferral(IVerantaReferral(REFERRAL), FROSTYFI);
	}

	/// @dev The fix-up for the live state: the Admin Safe proposes, the Treasury Safe accepts.
	function _transferCodeToTreasury() internal {
		assertEq(referral.codeOwners(FROSTYDAO), ADMIN_SAFE);
		assertEq(referral.codes(DAO_SAFE), bytes32(0), 'the Treasury Safe holds no other code');
		uint256 tier = referral.referrerTiers(ADMIN_SAFE);
		vm.prank(ADMIN_SAFE);
		referral.setPendingCodeOwnershipTransfer(FROSTYDAO, DAO_SAFE);
		vm.prank(DAO_SAFE);
		referral.acceptCodeOwnership(FROSTYDAO);
		assertEq(referral.codeOwners(FROSTYDAO), DAO_SAFE);
		assertEq(referral.codes(ADMIN_SAFE), bytes32(0));
		assertEq(referral.referrerTiers(DAO_SAFE), tier, 'the tier moves with the code');
	}

	function _deploy() internal {
		c = this.deployCompounders();
	}

	function _config() internal view returns (CompoundersMainnet.Config memory) {
		return CompoundersMainnet.Config({
			deployer: deployer,
			valueInterpreter: vi,
			factory: factory,
			module: twap.module,
			verantaFactory: v2Perp,
			creator: keeper,
			compounder: workflow
		});
	}

	function _expectReferralNotReady(string memory prefix, string memory mustContain) internal {
		_assertReferralNotReady(_revertOf(abi.encodeCall(this.deployCompounders, ())), prefix, mustContain);
	}

	function _assertReferralNotReady(bytes memory err, string memory prefix, string memory mustContain) internal pure {
		assertEq(bytes4(err), CompoundersMainnet.ReferralNotReady.selector, 'ReferralNotReady');
		bytes memory body = new bytes(err.length - 4);
		for (uint256 i; i < body.length; ++i) {
			body[i] = err[i + 4];
		}
		string memory reason = abi.decode(body, (string));
		assertTrue(_startsWith(reason, prefix), reason);
		if (bytes(mustContain).length != 0) assertTrue(_contains(reason, mustContain), reason);
	}

	/// @dev The revert data of a self-call that must revert.
	function _revertOf(bytes memory callData) internal returns (bytes memory err) {
		bool ok;
		(ok, err) = address(this).call(callData);
		assertFalse(ok, 'expected a revert');
	}

	// ─── governance helpers ──────────────────────────────────────────────────────

	function _governanceBooks()
		internal
		view
		returns (FundsMainnet.Deployed memory g, FundsGovernance.TwapV2 memory v2, FundsGovernance.Compounders memory comp)
	{
		string memory json = vm.readFile(GENESIS_FILE);
		g.valueInterpreter = vi;
		g.factory = factory;
		g.feeReserve = ProtocolFeeReserve(vm.parseJsonAddress(json, '.feeReserve'));
		g.twapRegistry = TwapListingRegistry(vm.parseJsonAddress(json, '.twapRegistry'));
		g.twapPolicy = TwapExposurePolicy(vm.parseJsonAddress(json, '.twapPolicy'));
		g.verantaFactory = v2Perp;
		v2 = FundsGovernance.TwapV2({module: twap.module, registry: twap.registry, policy: address(twap.policy)});
		comp = FundsGovernance.Compounders({
			factory: c.compounderFactory,
			feed: address(c.feed),
			slipstreamLp: c.slipstreamLp,
			slipstream2Lp: c.slipstream2Lp,
			perpV3: c.perpV3
		});
	}

	/// @dev Every contract TWAP v2 and this deploy made: each one that answers owner() is in the
	///      handoff batch and now the timelock's (proved here, not by the list itself).
	function _assertEveryOwnableHandedOff(address[] memory handedOff) internal view {
		address[] memory made = _everythingDeployed();
		uint256 ownables;
		for (uint256 i; i < made.length; ++i) {
			if (!_hasOwner(made[i])) continue;
			++ownables;
			assertTrue(_in(handedOff, made[i]), 'an ownable left out of the handoff');
			assertEq(Ownable(made[i]).owner(), TIMELOCK, 'owned by the timelock');
		}
		assertEq(ownables, 5, 'module, registry v2, compounder factory, 2 LP factories');
		assertEq(c.compounderFactory.owner(), TIMELOCK);
		assertEq(c.slipstreamLp.owner(), TIMELOCK);
		assertEq(c.slipstream2Lp.owner(), TIMELOCK);
		assertEq(twap.module.owner(), TIMELOCK);
		assertEq(twap.registry.owner(), TIMELOCK);
		assertFalse(_hasOwner(address(c.perpV3)), 'the V3 perp factory is ownerless');
	}

	function _everythingDeployed() internal view returns (address[] memory made) {
		made = new address[](19);
		made[0] = address(twap.registry);
		made[1] = address(twap.module);
		made[2] = address(twap.policy);
		made[3] = address(twap.lens);
		made[4] = twap.slipstream3Adapter;
		made[5] = address(twap.recorder);
		made[6] = address(twap.clDeployer);
		made[7] = address(twap.v2Deployer);
		made[8] = address(twap.aeroDeployer);
		made[9] = twap.uniswapV2Adapter;
		made[10] = twap.aerodromeBasicAdapter;
		made[11] = address(c.feed);
		made[12] = address(c.adapter);
		made[13] = address(c.compounderFactory);
		made[14] = address(c.compounderFactory.uniswapV3Deployer());
		made[15] = address(c.compounderFactory.slipstreamDeployer());
		made[16] = address(c.slipstreamLp);
		made[17] = address(c.slipstream2Lp);
		made[18] = address(c.perpV3);
	}

	function _assertDeployerPowerless() internal {
		bytes memory notOwner = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer);
		vm.startPrank(deployer);
		vm.expectRevert(notOwner);
		c.compounderFactory.setCreator(deployer, true);
		vm.expectRevert(notOwner);
		c.compounderFactory.setPerfFee(address(1), 2000);
		vm.expectRevert(notOwner);
		c.slipstreamLp.setAeroFee(2000);
		vm.expectRevert(notOwner);
		c.slipstream2Lp.setTreasury(deployer);
		vm.expectRevert(notOwner);
		twap.module.setCompounderBlocked(address(1), true);
		vm.expectRevert(notOwner);
		factory.registerPositionType(FundsMainnet.SLIPSTREAM_LP_TYPE, V1_CL1_LP_FACTORY);
		vm.stopPrank();
		// the timelock holds those powers now
		vm.prank(TIMELOCK);
		twap.module.setCompounderBlocked(address(1), true);
		assertTrue(twap.module.compounderBlocked(address(1)));
	}

	/// @dev Each compounder check in FundsGovernance.verify fires on its own regression (each undone after).
	function _assertVerifyCatchesCompounderRegressions(
		FundsMainnet.Deployed memory g,
		FundsGovernance.TwapV2 memory v2,
		FundsGovernance.Compounders memory comp
	) internal {
		vm.startPrank(TIMELOCK);
		c.compounderFactory.setCreator(deployer, true);
		vm.expectRevert(FundsGovernance.DeployerHoldsCompounderRole.selector);
		this.verifyGovernance(g, v2, comp);
		c.compounderFactory.setCreator(deployer, false);
		c.compounderFactory.setCompounder(deployer, true);
		vm.expectRevert(FundsGovernance.DeployerHoldsCompounderRole.selector);
		this.verifyGovernance(g, v2, comp);
		c.compounderFactory.setCompounder(deployer, false);

		factory.registerPositionType(FundsMainnet.SLIPSTREAM_LP_TYPE, V1_CL1_LP_FACTORY);
		vm.expectRevert(
			abi.encodeWithSelector(FundsGovernance.PositionTypeNotRepointed.selector, uint256(4), V1_CL1_LP_FACTORY)
		);
		this.verifyGovernance(g, v2, comp);
		factory.registerPositionType(FundsMainnet.SLIPSTREAM_LP_TYPE, address(c.slipstreamLp));

		// type 6 on a factory that has an owner
		factory.registerPositionType(FundsMainnet.VERANTA_PERP_TYPE, address(c.slipstreamLp));
		FundsGovernance.Compounders memory ownedPerp = _withPerp(comp, VerantaPerpPositionV3Factory(address(c.slipstreamLp)));
		vm.expectRevert(abi.encodeWithSelector(FundsGovernance.PerpFactoryHasOwner.selector, address(c.slipstreamLp)));
		this.verifyGovernance(g, v2, ownedPerp);

		// type 6 on a V3 factory over another config
		VerantaPerpPositionV3Factory foreign = new VerantaPerpPositionV3Factory(VerantaPerpPositionV2Factory(stranger));
		factory.registerPositionType(FundsMainnet.VERANTA_PERP_TYPE, address(foreign));
		FundsGovernance.Compounders memory foreignPerp = _withPerp(comp, foreign);
		vm.expectRevert(abi.encodeWithSelector(FundsGovernance.PerpConfigMismatch.selector, stranger));
		this.verifyGovernance(g, v2, foreignPerp);
		factory.registerPositionType(FundsMainnet.VERANTA_PERP_TYPE, address(c.perpV3));
		vm.stopPrank();

		// a verify that leaves the compounders out is refused while the module lists them
		FundsGovernance.Compounders memory none;
		vm.expectRevert(
			abi.encodeWithSelector(FundsGovernance.CompounderListingNotWired.selector, address(comp.factory), comp.feed)
		);
		this.verifyGovernance(g, v2, none);
		this.verifyGovernance(g, v2, comp);
	}

	/// @dev A copy of `comp` with another type-6 factory (a memory struct assignment would alias it).
	function _withPerp(FundsGovernance.Compounders memory comp, VerantaPerpPositionV3Factory perp)
		internal
		pure
		returns (FundsGovernance.Compounders memory)
	{
		return FundsGovernance.Compounders({
			factory: comp.factory,
			feed: comp.feed,
			slipstreamLp: comp.slipstreamLp,
			slipstream2Lp: comp.slipstream2Lp,
			perpV3: perp
		});
	}

	// ─── vault helpers ───────────────────────────────────────────────────────────

	function _createAndList(CompounderFactory.Venue venue, address tokenA, address tokenB, int24 tier, address pool)
		internal
		returns (address vault)
	{
		vm.prank(keeper);
		vault = c.compounderFactory.create(venue, tokenA, tokenB, tier);
		assertEq(IVaultPool(vault).pool(), pool, 'the canonical pool');
		assertEq(c.compounderFactory.compounderOf(pool), vault);
		assertEq(FeeCompounderBase(vault).owner(), address(c.compounderFactory));
		assertFalse(vi.isSupportedAsset(vault));
		vm.prank(keeper);
		twap.module.listCompounder(vault);
		assertTrue(vi.isSupportedAsset(vault), 'listed');
		(address aggregator,,,) = vi.getAssetInfo(vault);
		assertEq(aggregator, address(0), 'a derivative, priced through the feed');
		assertEq(vi.calcUsdRate(vault), 0, 'an empty vault is worth nothing, without reverting');
	}

	function _uni() internal pure returns (Pool memory) {
		return Pool({
			label: 'Uniswap v3 WETH/USDC 0.3%',
			venue: CompounderFactory.Venue.UniswapV3,
			tier: 3000,
			pool: UNI_WETH_USDC_3000,
			npm: FundsMainnet.UNI_NPM,
			router: FundsMainnet.UNI_SWAP_ROUTER02,
			fundUsdc: 400_000e6,
			buyWethUsdc: 150_000e6,
			vaultUsdc: 200_000e6,
			churnWeth: 1_000 ether
		});
	}

	function _slip1() internal pure returns (Pool memory) {
		return Pool({
			label: 'Slipstream-1 WETH/USDC ts100',
			venue: CompounderFactory.Venue.Slipstream,
			tier: 100,
			pool: SLIP1_WETH_USDC_100,
			npm: FundsMainnet.CL_NPM,
			router: FundsMainnet.CL_SWAP_ROUTER,
			fundUsdc: 400_000e6,
			buyWethUsdc: 150_000e6,
			vaultUsdc: 200_000e6,
			churnWeth: 300 ether
		});
	}

	function _slip2() internal pure returns (Pool memory) {
		return Pool({
			label: 'Slipstream-2 WETH/USDC ts50',
			venue: CompounderFactory.Venue.Slipstream2,
			tier: 50,
			pool: SLIP2_WETH_USDC_50,
			npm: FundsMainnet.CL2_NPM,
			router: FundsMainnet.CL2_SWAP_ROUTER,
			fundUsdc: 400_000e6,
			buyWethUsdc: 150_000e6,
			vaultUsdc: 200_000e6,
			churnWeth: 300 ether
		});
	}

	/// @dev Slipstream-3's WETH/USDC pool is small (0.52 WETH + 4,137 USDC at block 52014634): small sizes.
	function _slip3() internal pure returns (Pool memory) {
		return Pool({
			label: 'Slipstream-3 WETH/USDC ts50',
			venue: CompounderFactory.Venue.Slipstream3,
			tier: 50,
			pool: SLIP3_WETH_USDC_50,
			npm: FundsMainnet.CL3_NPM,
			router: TwapListingV2.CL3_SWAP_ROUTER,
			fundUsdc: 10_000e6,
			buyWethUsdc: 1_000e6,
			vaultUsdc: 2_000e6,
			churnWeth: 0.1 ether
		});
	}

	/// @dev Real swaps both ways through the venue's own router.
	function _churn(Pool memory p, uint256 rounds) internal {
		for (uint256 i; i < rounds; ++i) {
			uint256 usdcOut = _swap(p, WETH, USDC, p.churnWeth, 0);
			_swap(p, USDC, WETH, usdcOut, 0);
		}
	}

	/// @dev Real swaps up to an exact price limit put the pool back at `target`.
	function _restore(Pool memory p, uint160 target) internal {
		(uint160 sqrtNow,) = _slot0(p.pool);
		if (sqrtNow > target) _swap(p, WETH, USDC, 1_000_000 ether, target);
		else if (sqrtNow < target) _swap(p, USDC, WETH, 10_000_000_000e6, target);
		(sqrtNow,) = _slot0(p.pool);
		assertEq(sqrtNow, target, 'the pool price is back exactly');
	}

	function _swap(Pool memory p, address tokenIn, address tokenOut, uint256 amountIn, uint160 limit)
		internal
		returns (uint256 amountOut)
	{
		deal(tokenIn, swapper, amountIn);
		uint256 before_ = IERC20(tokenOut).balanceOf(swapper);
		vm.startPrank(swapper);
		IERC20(tokenIn).approve(p.router, amountIn);
		if (p.venue == CompounderFactory.Venue.UniswapV3) {
			IUniswapV3SwapRouter(p.router).exactInputSingle(
				IUniswapV3SwapRouter.ExactInputSingleParams({
					tokenIn: tokenIn,
					tokenOut: tokenOut,
					fee: uint24(p.tier),
					recipient: swapper,
					amountIn: amountIn,
					amountOutMinimum: 0,
					sqrtPriceLimitX96: limit
				})
			);
		} else {
			ISlipstreamSwapRouter(p.router).exactInputSingle(
				ISlipstreamSwapRouter.ExactInputSingleParams({
					tokenIn: tokenIn,
					tokenOut: tokenOut,
					tickSpacing: p.tier,
					recipient: swapper,
					deadline: block.timestamp,
					amountIn: amountIn,
					amountOutMinimum: 0,
					sqrtPriceLimitX96: limit
				})
			);
		}
		vm.stopPrank();
		amountOut = IERC20(tokenOut).balanceOf(swapper) - before_;
	}

	/// @dev What the vault's position could collect right now (the NPM itself, state rolled back):
	///      the independent source for "harvested".
	function _collectable(Pool memory p, FeeCompounderBase cv) internal returns (uint256 c0, uint256 c1) {
		uint256 id = cv.tokenId(); // read before the prank: an argument call would consume it
		uint256 snap = vm.snapshotState();
		vm.prank(address(cv));
		if (p.venue == CompounderFactory.Venue.UniswapV3) {
			(c0, c1) = IUniswapV3NonfungiblePositionManager(p.npm).collect(
				IUniswapV3NonfungiblePositionManager.CollectParams({
					tokenId: id,
					recipient: address(cv),
					amount0Max: type(uint128).max,
					amount1Max: type(uint128).max
				})
			);
		} else {
			(c0, c1) = ISlipstreamNonfungiblePositionManager(p.npm).collect(
				ISlipstreamNonfungiblePositionManager.CollectParams({
					tokenId: id,
					recipient: address(cv),
					amount0Max: type(uint128).max,
					amount1Max: type(uint128).max
				})
			);
		}
		vm.revertToState(snap);
	}

	function _harvestIn(Vm.Log[] memory logs, address vault) internal pure returns (Harvest memory h) {
		for (uint256 i; i < logs.length; ++i) {
			if (logs[i].emitter == vault && logs[i].topics[0] == FeeCompounderBase.Compounded.selector) {
				h.found = true;
				(h.harvested0, h.harvested1, h.fee0, h.fee1, h.added) =
					abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint128));
			}
		}
	}

	function _assertNothingStuck(address vault) internal view {
		assertEq(IERC20(WETH).balanceOf(address(c.adapter)), 0, 'no WETH left in the adapter');
		assertEq(IERC20(USDC).balanceOf(address(c.adapter)), 0, 'no USDC left in the adapter');
		assertEq(IERC20(vault).balanceOf(address(c.adapter)), 0, 'no shares left in the adapter');
	}

	// ─── position helpers ────────────────────────────────────────────────────────

	function _mintAndStake(Comptroller fund, address position, address pool, int24 spacing) internal {
		(, int24 tick) = _slot0(pool);
		int24 base = _floor(tick, spacing);
		address[] memory send = new address[](2);
		send[0] = WETH;
		send[1] = USDC;
		uint256[] memory amounts = new uint256[](2);
		amounts[0] = 20 ether;
		amounts[1] = 60_000e6;
		bytes memory mint = abi.encode(
			uint8(SlipstreamLPPositionV2.Action.Mint),
			abi.encode(base - HALF_RANGE, base + HALF_RANGE, amounts[0], amounts[1], uint256(0), uint256(0))
		);
		vm.prank(manager);
		fund.callOnExternalPosition(position, send, amounts, new address[](0), mint);
		vm.prank(manager);
		fund.callOnExternalPosition(
			position,
			new address[](0),
			new uint256[](0),
			new address[](0),
			abi.encode(uint8(SlipstreamLPPositionV2.Action.Stake), bytes(''))
		);
	}

	/// @dev One action that makes the gauge pay, measured: the gauge's own earned() just before, and
	///      where the AERO went.
	function _gaugePayout(Comptroller fund, address position, address gauge, uint8 action, address[] memory receive_)
		internal
		returns (Payout memory p)
	{
		address fv = address(fund.vault());
		p.earned = ICLGauge(gauge).earned(position, SlipstreamLPPositionV2(position).tokenId());
		uint256 t0 = IERC20(AERO).balanceOf(DAO_SAFE);
		uint256 v0 = IERC20(AERO).balanceOf(fv);
		uint256 p0 = IERC20(AERO).balanceOf(position);
		vm.prank(manager);
		fund.callOnExternalPosition(position, new address[](0), new uint256[](0), receive_, abi.encode(action, bytes('')));
		p.toTreasury = IERC20(AERO).balanceOf(DAO_SAFE) - t0;
		p.toVault = IERC20(AERO).balanceOf(fv) - v0;
		p.onPosition = IERC20(AERO).balanceOf(position) - p0;
	}

	/// @dev A fork gets no new oracle rounds: every warp must stay inside the WETH feed's heartbeat.
	function _accrue(uint256 secs) internal {
		vm.warp(block.timestamp + secs);
		vm.roll(block.number + secs / 2); // Base: 2 s blocks
		(address aggregator, uint32 heartbeat,,) = vi.getAssetInfo(WETH);
		(,,, uint256 updatedAt,) = AggregatorV3Interface(aggregator).latestRoundData();
		assertLe(block.timestamp, updatedAt + heartbeat, 'inside the WETH feed heartbeat');
	}

	/// @dev Hash of what a position reports (managed + debt assets and amounts).
	function _valueHash(address position) internal returns (bytes32) {
		(address[] memory m, uint256[] memory ma) = IExternalPosition(position).getManagedAssets();
		(address[] memory d, uint256[] memory da) = IExternalPosition(position).getDebtAssets();
		for (uint256 i; i < m.length; ++i) {
			emit log_named_address('  managed asset', m[i]);
			emit log_named_uint('  managed amount', ma[i]);
		}
		return keccak256(abi.encode(m, ma, d, da));
	}

	// ─── funds ───────────────────────────────────────────────────────────────────

	/// @dev A fresh non-degen USDC fund on the live factory with `amount` deposited.
	function _fund(string memory name, uint256 amount) internal returns (Comptroller fund) {
		fund = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: name,
					symbol: 'frCMP',
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
		deal(USDC, investor, amount);
		vm.startPrank(investor);
		IERC20(USDC).approve(address(fund), amount);
		fund.requestDeposit(amount);
		vm.stopPrank();
		_accrue(1 minutes);
		fund.executeDepositRequest(investor);
	}

	// ─── B20 mirror (Foundry has no B20 precompile) ──────────────────────────────

	/// @dev Every B20 token `fund` holds or its positions pair, answered from the chain for the
	///      fund's vault and each of its external positions. Returns how many were mirrored.
	function _mirrorB20s(Comptroller fund) internal returns (uint256 mirrored) {
		address[] memory positions = fund.getExternalPositions();
		address[] memory holders = new address[](positions.length + 1);
		holders[0] = address(fund.vault());
		for (uint256 i; i < positions.length; ++i) {
			holders[i + 1] = positions[i];
		}
		address[] memory tracked = fund.getTrackedAssets();
		for (uint256 i; i < tracked.length; ++i) {
			if (_isB20(tracked[i])) mirrored += _mirror(tracked[i], holders);
		}
		for (uint256 i; i < positions.length; ++i) {
			address[2] memory pair = [_addressView(positions[i], 'token0()'), _addressView(positions[i], 'token1()')];
			for (uint256 j; j < 2; ++j) {
				if (pair[j] != address(0) && _isB20(pair[j])) mirrored += _mirror(pair[j], holders);
			}
		}
	}

	function _mirror(address token, address[] memory holders) internal returns (uint256) {
		uint8 decimals = abi.decode(_chainCall(token, abi.encodeWithSignature('decimals()')), (uint8));
		vm.etch(token, type(B20ChainSnapshot).runtimeCode);
		B20ChainSnapshot(token).setDecimals(decimals);
		for (uint256 i; i < holders.length; ++i) {
			uint256 balance = abi.decode(_chainCall(token, abi.encodeCall(IERC20.balanceOf, (holders[i]))), (uint256));
			B20ChainSnapshot(token).load(holders[i], balance);
			emit log_named_address('B20 mirrored', token);
			emit log_named_address('  holder', holders[i]);
			emit log_named_uint('  balance (chain)', balance);
		}
		return 1;
	}

	/// @dev eth_call against the real chain at the fork block (the node runs the precompile).
	function _chainCall(address to, bytes memory data) internal returns (bytes memory) {
		string memory params = string.concat(
			'[{"to":"', vm.toString(to), '","data":"', vm.toString(data), '"},"', _hexQuantity(block.number), '"]'
		);
		return vm.rpc('eth_call', params);
	}

	function _isB20(address token) internal view returns (bool) {
		return keccak256(token.code) == keccak256(hex'ef');
	}

	// ─── small utils ─────────────────────────────────────────────────────────────

	function _assertVenue(address poolFactory, address npm, address expectedFactory, address expectedNpm) internal view {
		assertEq(poolFactory, expectedFactory);
		assertEq(npm, expectedNpm);
		(bool ok, bytes memory ret) = npm.staticcall(abi.encodeWithSignature('factory()'));
		assertTrue(ok);
		assertEq(abi.decode(ret, (address)), expectedFactory, 'the NPM mints into this pool factory');
	}

	function _hasOwner(address target) internal view returns (bool) {
		(bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature('owner()'));
		return ok && ret.length == 32;
	}

	function _addressView(address target, string memory signature) internal view returns (address) {
		(bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(signature));
		return ok && ret.length == 32 ? abi.decode(ret, (address)) : address(0);
	}

	function _in(address[] memory list, address a) internal pure returns (bool) {
		for (uint256 i; i < list.length; ++i) {
			if (list[i] == a) return true;
		}
		return false;
	}

	function _slot0(address pool) internal view returns (uint160 sqrtPriceX96, int24 tick) {
		(bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature('slot0()'));
		assertTrue(ok);
		(sqrtPriceX96, tick) = abi.decode(data, (uint160, int24));
	}

	/// @dev Round toward negative infinity to a multiple of `spacing`.
	function _floor(int24 tick, int24 spacing) internal pure returns (int24) {
		int24 r = tick % spacing;
		return r < 0 ? tick - r - spacing : tick - r;
	}

	function _hexQuantity(uint256 n) internal pure returns (string memory) {
		if (n == 0) return '0x0';
		bytes16 digits = '0123456789abcdef';
		uint256 len;
		for (uint256 t = n; t != 0; t >>= 4) {
			++len;
		}
		bytes memory out = new bytes(len + 2);
		out[0] = '0';
		out[1] = 'x';
		for (uint256 i = len + 1; i > 1; --i) {
			out[i] = digits[n & 0xf];
			n >>= 4;
		}
		return string(out);
	}

	function _startsWith(string memory s, string memory prefix) internal pure returns (bool) {
		bytes memory a = bytes(s);
		bytes memory b = bytes(prefix);
		if (b.length > a.length) return false;
		for (uint256 i; i < b.length; ++i) {
			if (a[i] != b[i]) return false;
		}
		return true;
	}

	function _contains(string memory s, string memory part) internal pure returns (bool) {
		bytes memory a = bytes(s);
		bytes memory b = bytes(part);
		if (b.length > a.length) return false;
		for (uint256 i; i + b.length <= a.length; ++i) {
			bool hit = true;
			for (uint256 j; j < b.length; ++j) {
				if (a[i + j] != b[j]) {
					hit = false;
					break;
				}
			}
			if (hit) return true;
		}
		return false;
	}
}
