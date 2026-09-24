// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {VerantaPerpPositionV2Factory} from '../src/positions/VerantaPerpPositionV2.sol';
import {
	IVerantaTradingRouter,
	IVerantaMulticall,
	IVerantaPairStorage,
	IVerantaReferral
} from '../src/interfaces/external/IVeranta.sol';
import {MockAggregator} from '../test/utils/Mocks.sol';

/// @notice Minimal perp stack on VERANTA'S TESTNET — their Base fork (chainId 8453, the
///         mainnet contract addresses, the staging operator; RPC devnet-rpc.veranta.xyz).
///         Purpose: prove what no mock or local fork can — operator fills for a CONTRACT
///         trader, delegate-signed TP/SL + partial TP/SL, referral discount — with no real money.
///         Chainlink on that fork is frozen at the fork block (≈38 days stale on 2026-09-23)
///         while the operator prices live, so NAV reads PUSHED feeds (MockAggregator,
///         refreshed from Veranta's own price feed) — the Base Sepolia pattern.
///         Testnet-only keys (VT_*). Same chainId as Base: never reuse these keys on mainnet.
///         Run: forge script script/DeployVerantaTestnet.s.sol --rpc-url https://devnet-rpc.veranta.xyz --broadcast
///         Env: VT_DEPLOYER_KEY, VT_KEEPER (address), VT_MANAGER (address), VT_ETH_PRICE_8DP
contract DeployVerantaTestnet is Script {
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant WETH = 0x4200000000000000000000000000000000000006;
	address internal constant VERANTA_ROUTER = 0x44914408af82bC9983bbb330e3578E1105e11d4e;
	address internal constant VERANTA_STORAGE = 0x8a311D7048c35985aa31C131B9A13e03a5f7422d;
	address internal constant VERANTA_MULTICALL = 0xA7cFc43872F4D7B0E6141ee8c36f1F7FEe5d099e;
	address internal constant VERANTA_PAIR_STORAGE = 0x5db3772136e5557EFE028Db05EE95C84D76faEC4;
	address internal constant VERANTA_REFERRAL = 0x1A110bBA13A1f16cCa4b79758BD39290f29De82D;
	bytes32 internal constant REFERRAL_CODE = 'frostyfi';
	uint256 internal constant ETH_PAIR = 0;
	uint256 internal constant VERANTA_TYPE_ID = 6;

	function run() external {
		uint256 deployerKey = vm.envUint('VT_DEPLOYER_KEY');
		address deployer = vm.addr(deployerKey);
		address keeper = vm.envAddress('VT_KEEPER');
		address manager = vm.envAddress('VT_MANAGER');
		int256 ethPrice = vm.envInt('VT_ETH_PRICE_8DP');
		require(block.chainid == 8453, 'Veranta testnet is chainId 8453');

		vm.startBroadcast(deployerKey);

		MockAggregator usdcFeed = new MockAggregator(8, 1e8);
		MockAggregator ethFeed = new MockAggregator(8, ethPrice);
		ValueInterpreter interpreter = new ValueInterpreter(deployer);
		interpreter.addPrimitive(USDC, address(usdcFeed), 7 days);
		interpreter.addPrimitive(WETH, address(ethFeed), 1 days);

		FundFactory factory = new FundFactory(interpreter, new ComptrollerDeployer(), new SharesVaultDeployer());
		VerantaPerpPositionV2Factory perps = new VerantaPerpPositionV2Factory(
			IERC20(USDC),
			IVerantaTradingRouter(VERANTA_ROUTER),
			IVerantaMulticall(VERANTA_MULTICALL),
			VERANTA_STORAGE,
			IVerantaPairStorage(VERANTA_PAIR_STORAGE),
			keeper
		);
		perps.setPairAsset(ETH_PAIR, WETH);
		// The fork predates 'frostyfi' (registered on mainnet 2026-09-22): register it here
		// from the deployer so the fund-side discount can be exercised
		if (IVerantaReferralOwner(VERANTA_REFERRAL).codeOwners(REFERRAL_CODE) == address(0)) {
			IVerantaReferralOwner(VERANTA_REFERRAL).registerCode(REFERRAL_CODE);
		}
		perps.setReferral(IVerantaReferral(VERANTA_REFERRAL), REFERRAL_CODE);
		factory.registerPositionType(VERANTA_TYPE_ID, address(perps));

		Comptroller comptroller = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Veranta Testnet Fund',
					symbol: 'frVT',
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

		console2.log('usdcFeed', address(usdcFeed));
		console2.log('ethFeed', address(ethFeed));
		console2.log('valueInterpreter', address(interpreter));
		console2.log('fundFactory', address(factory));
		console2.log('verantaPositionFactory', address(perps));
		console2.log('comptroller', address(comptroller));
		console2.log('vault', address(comptroller.vault()));
	}
}

/// @dev Referral registration + lookup (selectors read from the live impl, see IVeranta.sol).
interface IVerantaReferralOwner {
	function registerCode(bytes32 code) external;
	function codeOwners(bytes32 code) external view returns (address);
}
