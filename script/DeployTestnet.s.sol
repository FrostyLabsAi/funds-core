// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ProtocolFeeReserve} from '../src/core/ProtocolFeeReserve.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {UniswapV3SwapAdapter} from '../src/adapters/UniswapV3SwapAdapter.sol';
import {AerodromeSlipstreamSwapAdapter} from '../src/adapters/AerodromeSlipstreamSwapAdapter.sol';
import {ERC4626Adapter} from '../src/adapters/ERC4626Adapter.sol';
import {ERC4626PriceFeed} from '../src/pricing/ERC4626PriceFeed.sol';
import {IUniswapV3SwapRouter} from '../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {ISlipstreamSwapRouter} from '../src/interfaces/external/ISlipstreamSwapRouter.sol';
import {MockERC20, MockAggregator, MockSwapRouter, MockERC4626Vault} from '../test/utils/Mocks.sol';

/// @title DeployTestnet
/// @notice Full Base Sepolia deployment of the FrostyFunds protocol: pricing (primitives +
///         4626 derivative feed + side-pocket class), FundFactory, and trading adapters
///         (Uni v3 + Slipstream + ERC-4626). Mocks stand in for assets/feeds/router — swap
///         real addresses in via env as they become available. External-position types are
///         registered by their own venue scripts (DeployLpVenue, DeployVerantaDemoVenue,
///         DeployRetail).
/// @dev Run (NO --verify flag: contracts deploy unverified by design):
///   forge script script/DeployTestnet.s.sol --rpc-url base_sepolia --account <keystore> --broadcast
///   Env overrides (optional): SWAP_ROUTER.
contract DeployTestnet is Script {
	ValueInterpreter internal interpreter;
	FundFactory internal factory;
	MockERC20 internal usdc;
	MockERC20 internal gpux;
	MockERC20 internal evrx;
	MockERC20 internal moonDemo;
	address internal frostAddress;
	ProtocolFeeReserve internal feeReserve;
	MockERC4626Vault internal demoYieldVault;
	address internal routerAddress;
	UniswapV3SwapAdapter internal uniAdapter;
	AerodromeSlipstreamSwapAdapter internal aeroAdapter;
	ERC4626Adapter internal erc4626Adapter;
	ERC4626PriceFeed internal erc4626Feed;

	function run() external {
		vm.startBroadcast();
		_deployPricingAndAssets();
		factory = new FundFactory(interpreter, new ComptrollerDeployer(), new SharesVaultDeployer());
		_deployProtocolFee();
		_deployTrading();
		vm.stopBroadcast();
		_log();
	}

	function _deployPricingAndAssets() internal {
		interpreter = new ValueInterpreter(msg.sender);

		// REAL_USDC (Circle Base Sepolia USDC) is REQUIRED if CCTP_TOKEN_MESSENGER is real:
		// CCTP only burns canonical USDC. Default: mintable mock.
		address realUsdc = vm.envOr('REAL_USDC', address(0));
		usdc = realUsdc == address(0) ? new MockERC20('Test USD Coin', 'tUSDC', 6) : MockERC20(realUsdc);
		gpux = new MockERC20('GigaPU Wrapper (demo)', 'GPUx', 18);
		evrx = new MockERC20('Evermotors Wrapper (demo)', 'EVRx', 18);
		moonDemo = new MockERC20('Moon Machine (demo)', 'MOONM', 18);

		interpreter.addPrimitive(address(usdc), address(new MockAggregator(8, 1e8)), 7 days);
		interpreter.addPrimitive(address(gpux), address(new MockAggregator(8, 182_50e6)), 7 days);
		interpreter.addPrimitive(address(evrx), address(new MockAggregator(8, 46_75e6)), 7 days);

		// Side-pocket demo asset (moonshot class: valued at zero until realized)
		interpreter.addZeroPricedAsset(address(moonDemo));
	}

	/// @dev Protocol AUM fee (25 bps/yr, Enzyme-precedented) paid to the ProtocolFeeReserve,
	///      which prices the 50% FROST-burn buyback. FROST_TOKEN env = the real token
	///      (mainnet: also register its VI feed); default is a mintable mock + $0.50 feed
	///      so the buyback path is exercisable on testnet.
	function _deployProtocolFee() internal {
		frostAddress = vm.envOr('FROST_TOKEN', address(0));
		if (frostAddress == address(0)) {
			frostAddress = address(new MockERC20('Test Frosty', 'tFROST', 18));
			interpreter.addPrimitive(frostAddress, address(new MockAggregator(8, 5e7)), 7 days);
		}
		feeReserve = new ProtocolFeeReserve(frostAddress, msg.sender);
		factory.setProtocolFee(25, address(feeReserve));
	}

	function _deployTrading() internal {
		routerAddress = vm.envOr('SWAP_ROUTER', address(0));
		if (routerAddress == address(0)) {
			routerAddress = address(new MockSwapRouter());
		}
		uniAdapter = new UniswapV3SwapAdapter(IUniswapV3SwapRouter(routerAddress));
		aeroAdapter = new AerodromeSlipstreamSwapAdapter(ISlipstreamSwapRouter(routerAddress));
		erc4626Adapter = new ERC4626Adapter();
		factory.registerAdapter(address(uniAdapter));
		factory.registerAdapter(address(aeroAdapter));
		factory.registerAdapter(address(erc4626Adapter));

		// ERC-4626 yield world: feed + a demo yield vault
		erc4626Feed = new ERC4626PriceFeed();
		demoYieldVault = new MockERC4626Vault(IERC20(address(usdc)));
		interpreter.addDerivative(address(demoYieldVault), address(erc4626Feed));
	}

	function _log() internal view {
		console2.log('ValueInterpreter:', address(interpreter));
		console2.log('FundFactory:     ', address(factory));
		console2.log('tUSDC:           ', address(usdc));
		console2.log('GPUx:            ', address(gpux));
		console2.log('EVRx:            ', address(evrx));
		console2.log('MOONM (demo):    ', address(moonDemo));
		console2.log('FROST (burn):    ', frostAddress);
		console2.log('FeeReserve:      ', address(feeReserve));
		console2.log('SwapRouter:      ', routerAddress);
		console2.log('UniV3Adapter:    ', address(uniAdapter));
		console2.log('AeroAdapter:     ', address(aeroAdapter));
		console2.log('ERC4626Adapter:  ', address(erc4626Adapter));
		console2.log('ERC4626Feed:     ', address(erc4626Feed));
		console2.log('DemoYieldVault:  ', address(demoYieldVault));
	}
}
