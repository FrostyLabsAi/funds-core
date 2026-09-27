// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {IPolicy} from '../src/interfaces/IPolicy.sol';
import {IValueInterpreter} from '../src/interfaces/IValueInterpreter.sol';
import {AggregatorV3Interface} from '../src/interfaces/AggregatorV3Interface.sol';
import {IUniswapV3SwapRouter} from '../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {UniswapV3SwapAdapter} from '../src/adapters/UniswapV3SwapAdapter.sol';
import {TwapListingRegistry, IUniswapV3PoolFactory, ISlipstreamPoolFactory} from '../src/pricing/TwapListingRegistry.sol';
import {TwapAggregatorAdapter} from '../src/pricing/TwapAggregatorAdapter.sol';
import {TwapExposurePolicy} from '../src/policies/TwapExposurePolicy.sol';

/// @notice The TWAP price tier on VERANTA'S TESTNET (their Base fork, chainId 8453): a new
///         FundFactory with protocol-mandatory policies (the TwapExposurePolicy on every new
///         fund), the listing registry, AERO listed from its real Aerodrome AERO/USDC pool,
///         and a demo fund owned by the founder's test wallet. Reuses the testnet
///         ValueInterpreter, 4626 adapter and V2 perp factory (DeployVerantaTestnet +
///         2026-09-24 avUSDC wiring). The old factory 0xf4b3… and its funds keep running.
///         Chainlink on this fork is frozen at the fork block, so the USDC quote leg reads the
///         PUSHED USDC feed (vt-price-pusher), exactly like the VI does here.
///         Run: forge script script/DeployTwapTierVerantaTestnet.s.sol --rpc-url https://devnet-rpc.veranta.xyz --broadcast
///         Env: VT_DEPLOYER_KEY, VT_MANAGER
contract DeployTwapTierVerantaTestnet is Script {
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
	address internal constant VALUE_INTERPRETER = 0x5E56C3bF43b2214e3fccE9D515Ed684c0315Aa46;
	address internal constant USDC_PUSHED_FEED = 0xcddA7B237A01972AbDc0d7a1FaA289177ca8f386;
	address internal constant ERC4626_ADAPTER = 0x27D18676ED28C28952D5574bB705caF9CeE5fE0B;
	address internal constant VERANTA_V2_FACTORY = 0x5EfadE7866A6e46254BCE33bC93040BDe55F9A84;
	address internal constant SWAP_ROUTER02 = 0x2626664c2603336E57B271c5C0b26F421741e481;
	address internal constant UNI_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
	address internal constant CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
	address internal constant CL2_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef; // Aerodrome's newer Slipstream

	function run() external {
		uint256 key = vm.envUint('VT_DEPLOYER_KEY');
		address manager = vm.envAddress('VT_MANAGER');
		require(block.chainid == 8453, 'Veranta testnet is chainId 8453');
		ValueInterpreter vi = ValueInterpreter(VALUE_INTERPRETER);

		vm.startBroadcast(key);

		FundFactory factory = new FundFactory(vi, new ComptrollerDeployer(), new SharesVaultDeployer());
		UniswapV3SwapAdapter uniAdapter = new UniswapV3SwapAdapter(IUniswapV3SwapRouter(SWAP_ROUTER02));
		factory.registerAdapter(address(uniAdapter));
		factory.registerAdapter(ERC4626_ADAPTER);
		factory.registerPositionType(6, VERANTA_V2_FACTORY);

		TwapListingRegistry registry = new TwapListingRegistry(
			IValueInterpreter(address(vi)), IUniswapV3PoolFactory(UNI_FACTORY), ISlipstreamPoolFactory(CL_FACTORY), ISlipstreamPoolFactory(CL2_FACTORY)
		);
		registry.setQuote(USDC, AggregatorV3Interface(USDC_PUSHED_FEED), 7 days);
		TwapAggregatorAdapter aero = registry.list(AERO, USDC, TwapListingRegistry.Venue.Slipstream, 100);
		vi.addPrimitive(AERO, address(aero), 1 hours); // the VI owner's step

		TwapExposurePolicy policy = new TwapExposurePolicy(registry);
		FundFactory.PolicyReg[] memory mandatory = new FundFactory.PolicyReg[](4);
		mandatory[0] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnIntegration, policy: address(policy)});
		mandatory[1] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostDepositRequest, policy: address(policy)});
		mandatory[2] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.CreateExternalPosition, policy: address(policy)});
		mandatory[3] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnExternalPosition, policy: address(policy)});
		factory.setMandatoryPolicies(mandatory);

		Comptroller fund = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'TWAP Demo Fund',
					symbol: 'frTW',
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
		console2.log('uniAdapter', address(uniAdapter));
		console2.log('twapRegistry', address(registry));
		console2.log('aeroAdapter', address(aero));
		console2.log('twapExposurePolicy', address(policy));
		console2.log('twapDemoFund', address(fund));
		console2.log('aeroDepthUsd18', aero.poolDepthUsd());
	}
}
