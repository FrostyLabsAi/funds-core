// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ProtocolFeeReserve} from '../src/core/ProtocolFeeReserve.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {UniswapV3SwapAdapter} from '../src/adapters/UniswapV3SwapAdapter.sol';
import {ERC4626Adapter} from '../src/adapters/ERC4626Adapter.sol';
import {CompounderAdapter} from '../src/adapters/CompounderAdapter.sol';
import {ERC4626PriceFeed} from '../src/pricing/ERC4626PriceFeed.sol';
import {CompounderPriceFeed} from '../src/pricing/CompounderPriceFeed.sol';
import {IValueInterpreter} from '../src/interfaces/IValueInterpreter.sol';
import {FrostyCompounder} from '../src/yield/FrostyCompounder.sol';
import {LimitOrderPositionFactory} from '../src/positions/LimitOrderPosition.sol';
import {UniswapV3LPPositionFactory} from '../src/positions/UniswapV3LPPosition.sol';
import {VerantaPerpPositionV2Factory} from '../src/positions/VerantaPerpPositionV2.sol';
import {AdvisorRegistry} from '../src/protect/AdvisorRegistry.sol';
import {IUniswapV3SwapRouter} from '../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {IUniswapV3NonfungiblePositionManager} from
	'../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {IVerantaTradingRouter, IVerantaMulticall, IVerantaPairStorage} from '../src/interfaces/external/IVeranta.sol';
import {AggregatorV3Interface} from '../src/interfaces/AggregatorV3Interface.sol';
import {MockERC20, MockAggregator} from '../test/utils/Mocks.sol';
import {MockVeranta} from '../test/utils/MockVeranta.sol';

/// @title DeployWave7
/// @notice Base Sepolia redeploy of the WHOLE protocol after the 2026-09-22 security
///         review (Comptroller, FundFactory, ValueInterpreter, all four position types,
///         slippage policy, compounder + adapter changed; protocol AUM fee + FROST buyback
///         added). ONE broadcast.
///         KEPT (unchanged contracts, so the terminal token list, the demo Uniswap pools
///         and the protect keeper need no changes): the demo tokens, their real Chainlink
///         feeds, the Uniswap pools, the four demo ERC-4626 vaults, ProtectRegistry.
///         NEW: ValueInterpreter (fresh mock feeds — the old tUSDC mock went stale),
///         FundFactory + deployers, swap/4626/compounder adapters, position types 2/3/6
///         (Veranta demo venue included), fcETH/fcBTC compounders (bootstrap-seeded so
///         fund deposits have a price to guard against), tFROST + ProtocolFeeReserve at
///         25 bps, AdvisorRegistry.
/// @dev NO --verify (unverified by design). The broadcaster becomes owner of everything.
///   Env: KEEPER (protect/autopilot keeper address).
///   forge script script/DeployWave7.s.sol:DeployWave7 --rpc-url base_sepolia \
///     --account <keystore> --broadcast --slow
///   Mock feeds (tUSDC/GPUx/EVRx/tFROST) freeze their timestamp at deploy; the VI bytecode
///   caps heartbeats at 7 days, so refresh them weekly: `cast send <feed> "setAnswer(int256)" <same answer>`.
contract DeployWave7 is Script {
	// ── kept: demo tokens (MockERC20, open mint) ─────────────────────────────────
	address internal constant TUSDC = 0x75F31B7C00E6282CDCFd7B4124d8ab327bE3Ab4D;
	address internal constant TETH = 0xB949122bF2991edA2d660A2E99f2393ffE74Ae01;
	address internal constant TBTC = 0x7b78764b39A56F52b0b983C4e279D1F4564Abe39;
	address internal constant TLINK = 0x7766e0742e710B0cD43cE770a5CD443d8a314323;
	address internal constant TDAI = 0xd7dd447E89f7f6f2052f3f578db95D9b9cB41ABA;
	address internal constant GPUX = 0x88abDbFa9e96183fe7b60466954FE700244b48a3;
	address internal constant EVRX = 0x49c470FDD3ca20fEB9c65F9E8a0f610cC6ab41Ff;
	address internal constant MOONM = 0x94b403FFAA3E09CD6A98DCc67e2895c40998410E;

	// ── kept: real Chainlink aggregators on Base Sepolia ─────────────────────────
	address internal constant ETH_USD = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;
	address internal constant BTC_USD = 0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298;
	address internal constant LINK_USD = 0xb113F5A928BCfF189C998ab20d753a47F9dE5A61;
	address internal constant DAI_USD = 0xD1092a65338d049DB68D7Be6bD89d17a0929945e;
	uint32 internal constant REAL_FEED_HEARTBEAT = 3 days; // slack over the feeds' own
	uint32 internal constant MOCK_FEED_HEARTBEAT = 7 days; // VI bytecode max

	// ── kept: demo ERC-4626 vaults (OZ ERC4626, unchanged) ───────────────────────
	address internal constant FY_USDC = 0x25Eb3Cf58C5082f495644b50C76f0C1d632f3668;
	address internal constant FY_DAI = 0x3476e690cf45bF2ce7992efa6722ba29f08b60FD;
	address internal constant FY_ETH = 0xC811D0056dE972C418d2D817E008A6CE77f6c875;
	address internal constant Y_USDC = 0x3880cdd4583b0cE323D55a899664177E4E844c73;

	// ── external infra (real Uniswap on Base Sepolia) ────────────────────────────
	address internal constant SWAP_ROUTER02 = 0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4;
	IUniswapV3NonfungiblePositionManager internal constant NPM =
		IUniswapV3NonfungiblePositionManager(0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2);

	uint16 internal constant PROTOCOL_FEE_BPS = 25;
	uint256 internal constant COMPOUNDER_SEED_USDC = 1_000e6;

	ValueInterpreter internal interpreter;
	FundFactory internal factory;
	address internal frost;
	ProtocolFeeReserve internal feeReserve;
	address internal erc4626Feed;
	address internal compounderFeed;
	address internal uniAdapter;
	address internal erc4626Adapter;
	address internal compounderAdapter;
	address internal limitOrderFactory;
	address internal lpFactory;
	address internal verantaFactory;
	address internal verantaVenue;
	FrostyCompounder internal fcEth;
	FrostyCompounder internal fcBtc;
	address internal advisorRegistry;

	function run() external {
		address keeper = vm.envAddress('KEEPER');
		vm.startBroadcast();
		_pricing();
		factory = new FundFactory(interpreter, new ComptrollerDeployer(), new SharesVaultDeployer());
		_protocolFee();
		_adapters();
		_positionTypes(keeper);
		_compounders();
		advisorRegistry = address(new AdvisorRegistry());
		vm.stopBroadcast();
		_log(keeper);
	}

	function _pricing() internal {
		interpreter = new ValueInterpreter(msg.sender);
		interpreter.addPrimitive(TUSDC, address(new MockAggregator(8, 1e8)), MOCK_FEED_HEARTBEAT);
		interpreter.addPrimitive(GPUX, address(new MockAggregator(8, 182_50e6)), MOCK_FEED_HEARTBEAT);
		interpreter.addPrimitive(EVRX, address(new MockAggregator(8, 46_75e6)), MOCK_FEED_HEARTBEAT);
		interpreter.addPrimitive(TETH, ETH_USD, REAL_FEED_HEARTBEAT);
		interpreter.addPrimitive(TBTC, BTC_USD, REAL_FEED_HEARTBEAT);
		interpreter.addPrimitive(TLINK, LINK_USD, REAL_FEED_HEARTBEAT);
		interpreter.addPrimitive(TDAI, DAI_USD, REAL_FEED_HEARTBEAT);
		interpreter.addZeroPricedAsset(MOONM);

		erc4626Feed = address(new ERC4626PriceFeed());
		interpreter.addDerivative(FY_USDC, erc4626Feed);
		interpreter.addDerivative(FY_DAI, erc4626Feed);
		interpreter.addDerivative(FY_ETH, erc4626Feed);
		interpreter.addDerivative(Y_USDC, erc4626Feed);
	}

	/// @dev 25 bps/yr AUM fee to the reserve, which prices the 50% FROST-burn buyback.
	///      Testnet FROST is a mintable mock on a $0.50 mock feed.
	function _protocolFee() internal {
		frost = address(new MockERC20('Test Frosty', 'tFROST', 18));
		interpreter.addPrimitive(frost, address(new MockAggregator(8, 5e7)), MOCK_FEED_HEARTBEAT);
		feeReserve = new ProtocolFeeReserve(frost, msg.sender);
		factory.setProtocolFee(PROTOCOL_FEE_BPS, address(feeReserve));
	}

	function _adapters() internal {
		uniAdapter = address(new UniswapV3SwapAdapter(IUniswapV3SwapRouter(SWAP_ROUTER02)));
		erc4626Adapter = address(new ERC4626Adapter());
		compounderAdapter = address(new CompounderAdapter());
		factory.registerAdapter(uniAdapter);
		factory.registerAdapter(erc4626Adapter);
		factory.registerAdapter(compounderAdapter);
	}

	function _positionTypes(address keeper) internal {
		limitOrderFactory = address(new LimitOrderPositionFactory());
		factory.registerPositionType(2, limitOrderFactory);

		lpFactory = address(new UniswapV3LPPositionFactory(NPM));
		factory.registerPositionType(3, lpFactory);

		// Veranta is Base-mainnet only: the demo venue plays router + multicall + storage,
		// filled by the operator bot. Pair 0 = tETH (VI-priced, so GAV can value it).
		MockVeranta venue = new MockVeranta(IERC20(TUSDC));
		verantaVenue = address(venue);
		// V2 position (bounded valuation read); the mock also plays PairStorage
		VerantaPerpPositionV2Factory vFactory = new VerantaPerpPositionV2Factory(
			IERC20(TUSDC),
			IVerantaTradingRouter(verantaVenue),
			IVerantaMulticall(verantaVenue),
			verantaVenue,
			IVerantaPairStorage(verantaVenue),
			keeper
		);
		vFactory.setPairAsset(0, TETH);
		verantaFactory = address(vFactory);
		factory.registerPositionType(6, verantaFactory);
	}

	function _compounders() internal {
		fcEth = new FrostyCompounder(
			'Frosty Compounding tETH-tUSDC', 'fcETH', NPM, IERC20(TUSDC), IERC20(TETH), 3000, 887220, 1500, msg.sender
		);
		fcBtc = new FrostyCompounder(
			'Frosty Compounding tBTC-tUSDC', 'fcBTC', NPM, IERC20(TUSDC), IERC20(TBTC), 3000, 887220, 1500, msg.sender
		);
		compounderFeed = address(new CompounderPriceFeed(IValueInterpreter(address(interpreter))));
		interpreter.addDerivative(address(fcEth), compounderFeed);
		interpreter.addDerivative(address(fcBtc), compounderFeed);
		_seed(fcEth, TETH, ETH_USD);
		_seed(fcBtc, TBTC, BTC_USD);
	}

	/// @dev First deposit bootstraps the share supply (dead shares minted to 0xdEaD), so a
	///      fund's first deposit has a supply to compute its oracle min-shares against —
	///      the terminal fails closed on an unseeded compounder. Surplus is refunded.
	function _seed(FrostyCompounder compounder, address token, address aggregator) internal {
		(, int256 answer,,,) = AggregatorV3Interface(aggregator).latestRoundData();
		require(answer > 0, 'stale/invalid feed');
		uint8 decimals = MockERC20(token).decimals();
		// token side at the oracle price, +10% so the pool ratio decides and refunds the rest
		uint256 tokenAmount = Math.mulDiv(COMPOUNDER_SEED_USDC * 1e2, 10 ** decimals, uint256(answer)) * 11 / 10;
		MockERC20(TUSDC).mint(msg.sender, COMPOUNDER_SEED_USDC);
		MockERC20(token).mint(msg.sender, tokenAmount);
		IERC20(TUSDC).approve(address(compounder), COMPOUNDER_SEED_USDC);
		IERC20(token).approve(address(compounder), tokenAmount);
		compounder.deposit(COMPOUNDER_SEED_USDC, tokenAmount, 0, 0, 1);
	}

	function _log(address keeper) internal view {
		console2.log('VALUE_INTERPRETER     ', address(interpreter));
		console2.log('FUND_FACTORY          ', address(factory));
		console2.log('START_BLOCK           ', block.number);
		console2.log('TFROST                ', frost);
		console2.log('PROTOCOL_FEE_RESERVE  ', address(feeReserve));
		console2.log('UNI_ADAPTER           ', uniAdapter);
		console2.log('ERC4626_ADAPTER       ', erc4626Adapter);
		console2.log('COMPOUNDER_ADAPTER    ', compounderAdapter);
		console2.log('ERC4626_FEED          ', erc4626Feed);
		console2.log('COMPOUNDER_FEED       ', compounderFeed);
		console2.log('LIMIT_ORDER_FACTORY   ', limitOrderFactory);
		console2.log('LP_FACTORY            ', lpFactory);
		console2.log('VERANTA_FACTORY       ', verantaFactory);
		console2.log('VERANTA_VENUE         ', verantaVenue);
		console2.log('COMPOUNDER_ETH        ', address(fcEth));
		console2.log('COMPOUNDER_BTC        ', address(fcBtc));
		console2.log('ADVISOR_REGISTRY      ', advisorRegistry);
		console2.log('KEEPER                ', keeper);
	}
}
