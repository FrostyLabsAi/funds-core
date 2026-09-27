// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {IPolicy} from '../src/interfaces/IPolicy.sol';
import {IValueInterpreter} from '../src/interfaces/IValueInterpreter.sol';
import {AggregatorV3Interface} from '../src/interfaces/AggregatorV3Interface.sol';
import {VerantaPerpPositionV2Factory} from '../src/positions/VerantaPerpPositionV2.sol';
import {TwapListingRegistry, IUniswapV3PoolFactory, ISlipstreamPoolFactory} from '../src/pricing/TwapListingRegistry.sol';
import {TwapAggregatorAdapter} from '../src/pricing/TwapAggregatorAdapter.sol';
import {TwapExposurePolicy} from '../src/policies/TwapExposurePolicy.sol';
import {
	IVerantaTradingRouter,
	IVerantaMulticall,
	IVerantaPairStorage,
	IVerantaReferral
} from '../src/interfaces/external/IVeranta.sol';

/// @title DeployWave8VerantaTestnet
/// @notice VERANTA'S TESTNET (their Base fork, chainId 8453) wave after the 2026-09-24 security
///         review + the 2026-09-27 governance settings (commit a3520d4). Side-by-side: the
///         factories 0xf4b3… and 0xd283… and their funds keep running.
///         KEPT — runtime code identical to the committed source (bytecode-compared with
///         immutables masked, 2026-09-27): the swap / 4626 / Slipstream-2 adapters, the Slipstream
///         LP type-7 factory, the RedStone store + adapters + perp markers, the pushed feeds,
///         ProtectRegistry. Also KEPT: the ValueInterpreter — its only change since is the L2
///         sequencer check (config, exercised by the mainnet-genesis fork test), and keeping it
///         keeps its 30 listings, the RedStone pusher and the subgraph's daily closes.
///         NEW: FundFactory + deployers; the V2 perp factory (H-1 isRiskReducing), its pair map
///         + keeper + referral COPIED from the previous one; the TWAP tier (registry, adapters
///         with the ±10% band depth, exposure policy on all four hooks). AERO and tMEME are
///         re-listed: the VI drops the old adapters and takes the new registry's in the same
///         broadcast (a registry refuses an asset the VI already prices). A demo fund.
///         Run: forge script script/DeployWave8VerantaTestnet.s.sol --rpc-url https://devnet-rpc.veranta.xyz \
///              --broadcast --slow
///         Env: VT_DEPLOYER_KEY (owner of the VI + old factories), VT_MANAGER (demo fund owner)
contract DeployWave8VerantaTestnet is Script {
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
	address internal constant TMEME = 0x20495fe07aFcBc431230e4DdaF4D473E6e2eB4F2;
	address internal constant VALUE_INTERPRETER = 0x5E56C3bF43b2214e3fccE9D515Ed684c0315Aa46;
	address internal constant USDC_PUSHED_FEED = 0xcddA7B237A01972AbDc0d7a1FaA289177ca8f386;
	address internal constant UNI_ADAPTER = 0xCC36259BE43997ff83c2b6a5AD6c5B00371F5c83;
	address internal constant ERC4626_ADAPTER = 0x27D18676ED28C28952D5574bB705caF9CeE5fE0B;
	address internal constant SLIPSTREAM2_ADAPTER = 0x4ebCb7110158Aae3add88f2183Ad4188343222F6;
	address internal constant SLIPSTREAM2_LP_FACTORY = 0xC3309779a6A56C4e2a3e9A3DD0d744CBBe167287;
	VerantaPerpPositionV2Factory internal constant OLD_PERPS =
		VerantaPerpPositionV2Factory(0x5EfadE7866A6e46254BCE33bC93040BDe55F9A84);
	address internal constant UNI_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
	address internal constant CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
	address internal constant CL2_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;
	uint32 internal constant TWAP_HEARTBEAT = 1 hours;

	function run() external {
		uint256 key = vm.envUint('VT_DEPLOYER_KEY');
		address manager = vm.envAddress('VT_MANAGER');
		require(block.chainid == 8453, 'Veranta testnet is chainId 8453');
		require(vm.addr(key) == ValueInterpreter(VALUE_INTERPRETER).owner(), 'VT_DEPLOYER_KEY must own the VI');
		ValueInterpreter vi = ValueInterpreter(VALUE_INTERPRETER);

		vm.startBroadcast(key);
		FundFactory factory = new FundFactory(vi, new ComptrollerDeployer(), new SharesVaultDeployer());
		factory.registerAdapter(UNI_ADAPTER);
		factory.registerAdapter(ERC4626_ADAPTER);
		factory.registerAdapter(SLIPSTREAM2_ADAPTER);
		VerantaPerpPositionV2Factory perps = _perps();
		factory.registerPositionType(6, address(perps));
		factory.registerPositionType(7, SLIPSTREAM2_LP_FACTORY);

		TwapListingRegistry registry = new TwapListingRegistry(
			IValueInterpreter(address(vi)),
			IUniswapV3PoolFactory(UNI_FACTORY),
			ISlipstreamPoolFactory(CL_FACTORY),
			ISlipstreamPoolFactory(CL2_FACTORY)
		);
		registry.setQuote(USDC, AggregatorV3Interface(USDC_PUSHED_FEED), 7 days);
		TwapAggregatorAdapter aero = _relist(vi, registry, AERO, TwapListingRegistry.Venue.Slipstream, 100);
		TwapAggregatorAdapter tmeme = _relist(vi, registry, TMEME, TwapListingRegistry.Venue.UniswapV3, 3000);
		TwapExposurePolicy policy = new TwapExposurePolicy(registry);
		factory.setMandatoryPolicies(_mandatory(address(policy)));

		Comptroller fund = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Wave 8 Demo Fund',
					symbol: 'frW8',
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
		vm.stopBroadcast();

		console2.log('fundFactory', address(factory));
		console2.log('startBlock', block.number);
		console2.log('verantaPositionFactory', address(perps));
		console2.log('twapRegistry', address(registry));
		console2.log('aeroAdapter', address(aero));
		console2.log('tmemeAdapter', address(tmeme));
		console2.log('twapExposurePolicy', address(policy));
		console2.log('demoFund', address(fund));
		console2.log('demoVault', address(fund.vault()));
	}

	/// @dev The previous factory's keeper, referral and every mapped pair, onto the new code.
	function _perps() internal returns (VerantaPerpPositionV2Factory perps) {
		perps = new VerantaPerpPositionV2Factory(
			OLD_PERPS.usdc(),
			OLD_PERPS.router(),
			OLD_PERPS.verantaMulticall(),
			OLD_PERPS.tradingStorage(),
			OLD_PERPS.pairStorage(),
			OLD_PERPS.autopilotKeeper()
		);
		uint256 pairs = OLD_PERPS.pairStorage().pairsCount();
		for (uint256 i; i < pairs; ++i) {
			address asset = OLD_PERPS.pairAsset(i);
			if (asset != address(0)) perps.setPairAsset(i, asset);
		}
		perps.setReferral(OLD_PERPS.referral(), OLD_PERPS.referralCode());
	}

	function _relist(
		ValueInterpreter vi,
		TwapListingRegistry registry,
		address asset,
		TwapListingRegistry.Venue venue,
		int24 feeOrSpacing
	) internal returns (TwapAggregatorAdapter adapter) {
		vi.removePrimitive(asset);
		adapter = registry.list(asset, USDC, venue, feeOrSpacing);
		vi.addPrimitive(asset, address(adapter), TWAP_HEARTBEAT);
	}

	function _mandatory(address policy) internal pure returns (FundFactory.PolicyReg[] memory regs) {
		regs = new FundFactory.PolicyReg[](4);
		regs[0] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnIntegration, policy: policy});
		regs[1] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostDepositRequest, policy: policy});
		regs[2] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.CreateExternalPosition, policy: policy});
		regs[3] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnExternalPosition, policy: policy});
	}
}
