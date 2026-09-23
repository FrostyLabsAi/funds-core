// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ERC4626} from '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {UniswapV3SwapAdapter} from '../src/adapters/UniswapV3SwapAdapter.sol';
import {IUniswapV3SwapRouter} from '../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {AggregatorV3Interface} from '../src/interfaces/AggregatorV3Interface.sol';
import {IUniswapV3NonfungiblePositionManager} from
	'../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {MockERC20} from '../test/utils/Mocks.sol';

/// @dev Demo ERC-4626 vault with a configurable name/symbol (MockERC4626Vault hardcodes its
///      name, which doesn't work for a multi-vault Earn table).
contract DemoYieldVault is ERC4626 {
	constructor(string memory name_, string memory symbol_, IERC20 asset_)
		ERC4626(asset_)
		ERC20(name_, symbol_)
	{}
}

/// @title DeployRealFeedAssets
/// @notice Widens the Base Sepolia testnet universe with demo tokens priced by REAL Chainlink
///         aggregators (live moving prices + real round history for charts):
///         tETH, tBTC, tLINK, tDAI. Creates seeded Uni v3 pools vs tUSDC at the live oracle
///         price, plus three named demo yield vaults (different share prices) registered
///         against the existing ERC4626PriceFeed.
///         ALSO redeploys the UniswapV3SwapAdapter against the SwapRouter02 ABI (the
///         original adapter targeted the legacy SwapRouter selector, which does not exist
///         on Base Sepolia's router — fund swaps could never execute) and swaps the
///         factory registration old → new.
/// @dev Deployer must own the ValueInterpreter AND the FundFactory. NO --verify
///      (unverified by design).
///   Env: VALUE_INTERPRETER, ERC4626_FEED, TUSDC, NPM, FACTORY, SWAP_ROUTER, OLD_UNI_ADAPTER.
///   forge script script/DeployRealFeedAssets.s.sol --rpc-url base_sepolia \
///     --private-key $PRIVATE_KEY --broadcast --slow
contract DeployRealFeedAssets is Script {
	// Real Chainlink aggregators on Base Sepolia (docs.chain.link reference data)
	address internal constant ETH_USD = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1; // 20min heartbeat
	address internal constant BTC_USD = 0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298; // 20min heartbeat
	address internal constant LINK_USD = 0xb113F5A928BCfF189C998ab20d753a47F9dE5A61; // 20min heartbeat
	address internal constant DAI_USD = 0xD1092a65338d049DB68D7Be6bD89d17a0929945e; // 24h heartbeat

	// Registered heartbeat gets slack over the feed's own so a stalled testnet round
	// doesn't brick GAV for every fund holding the asset (bytecode cap is 7 days).
	uint32 internal constant HEARTBEAT = 3 days;

	uint256 private constant Q96 = 0x1000000000000000000000000;
	uint24 private constant FEE = 3000;
	int24 private constant TICK_LOWER = -887_220;
	int24 private constant TICK_UPPER = 887_220;

	ValueInterpreter internal interpreter;
	IUniswapV3NonfungiblePositionManager internal positionManager;
	MockERC20 internal usdc;
	address internal erc4626Feed;

	MockERC20 internal tEth;
	MockERC20 internal tBtc;
	MockERC20 internal tLink;
	MockERC20 internal tDai;
	UniswapV3SwapAdapter internal uniAdapter;

	function run() external {
		interpreter = ValueInterpreter(vm.envAddress('VALUE_INTERPRETER'));
		positionManager = IUniswapV3NonfungiblePositionManager(vm.envAddress('NPM'));
		usdc = MockERC20(vm.envAddress('TUSDC'));
		erc4626Feed = vm.envAddress('ERC4626_FEED');

		vm.startBroadcast();
		_deployAndRegisterTokens();
		_createPools();
		_deployYieldVaults();
		_replaceUniAdapter();
		vm.stopBroadcast();
		_log();
	}

	function _deployAndRegisterTokens() internal {
		tEth = new MockERC20('Test Ether (demo)', 'tETH', 18);
		tBtc = new MockERC20('Test Bitcoin (demo)', 'tBTC', 8);
		tLink = new MockERC20('Test Chainlink (demo)', 'tLINK', 18);
		tDai = new MockERC20('Test DAI (demo)', 'tDAI', 18);

		interpreter.addPrimitive(address(tEth), ETH_USD, HEARTBEAT);
		interpreter.addPrimitive(address(tBtc), BTC_USD, HEARTBEAT);
		interpreter.addPrimitive(address(tLink), LINK_USD, HEARTBEAT);
		interpreter.addPrimitive(address(tDai), DAI_USD, HEARTBEAT);
	}

	function _createPools() internal {
		_createPool(tEth, _livePrice18(ETH_USD), 500_000e6);
		_createPool(tBtc, _livePrice18(BTC_USD), 500_000e6);
		_createPool(tLink, _livePrice18(LINK_USD), 250_000e6);
		_createPool(tDai, _livePrice18(DAI_USD), 250_000e6);
	}

	function _deployYieldVaults() internal {
		// Different donated yields → distinct share prices on the Earn table
		_deployVault('Frosty USDC Yield', 'fyUSDC', MockERC20(address(usdc)), 250_000e6, 450); // 4.50%
		_deployVault('Frosty ETH Yield', 'fyETH', tEth, 100e18, 280); // 2.80%
		_deployVault('Frosty DAI Yield', 'fyDAI', tDai, 100_000e18, 720); // 7.20%
	}

	function _deployVault(string memory name, string memory symbol, MockERC20 asset, uint256 seed, uint256 yieldBps)
		internal
	{
		DemoYieldVault vault = new DemoYieldVault(name, symbol, IERC20(address(asset)));
		asset.mint(msg.sender, seed);
		asset.approve(address(vault), seed);
		vault.deposit(seed, msg.sender);
		// Donation raises convertToAssets → share price > 1, read live by ERC4626PriceFeed
		asset.mint(address(vault), (seed * yieldBps) / 10_000);
		interpreter.addDerivative(address(vault), erc4626Feed);
		console2.log(name, address(vault));
	}

	function _replaceUniAdapter() internal {
		FundFactory factory = FundFactory(vm.envAddress('FACTORY'));
		uniAdapter = new UniswapV3SwapAdapter(IUniswapV3SwapRouter(vm.envAddress('SWAP_ROUTER')));
		factory.registerAdapter(address(uniAdapter));
		factory.deregisterAdapter(vm.envAddress('OLD_UNI_ADAPTER'));
	}

	/// @dev Live oracle answer scaled to 1e18 USD (all four aggregators are 8-decimals).
	function _livePrice18(address aggregator) internal view returns (uint256) {
		(, int256 answer,,,) = AggregatorV3Interface(aggregator).latestRoundData();
		require(answer > 0, 'stale/invalid feed');
		return uint256(answer) * 1e10;
	}

	function _createPool(MockERC20 token, uint256 usdPrice18, uint256 usdcAmount) internal {
		// tokenAmount = USD value of the USDC side, converted at the live price
		uint256 tokenAmount = Math.mulDiv(usdcAmount * 1e12, 10 ** token.decimals(), usdPrice18);

		usdc.mint(msg.sender, usdcAmount);
		token.mint(msg.sender, tokenAmount);
		usdc.approve(address(positionManager), usdcAmount);
		token.approve(address(positionManager), tokenAmount);

		(address token0, address token1) = address(usdc) < address(token)
			? (address(usdc), address(token))
			: (address(token), address(usdc));
		(uint256 rate0, uint256 rate1, uint256 scale0, uint256 scale1) = token0 == address(usdc)
			? (uint256(1e18), usdPrice18, uint256(1e6), uint256(10 ** token.decimals()))
			: (usdPrice18, uint256(1e18), uint256(10 ** token.decimals()), uint256(1e6));
		(uint256 amount0, uint256 amount1) =
			token0 == address(usdc) ? (usdcAmount, tokenAmount) : (tokenAmount, usdcAmount);

		uint160 sqrtPriceX96 = _sqrtPriceX96(rate0, rate1, scale0, scale1);
		address pool = positionManager.createAndInitializePoolIfNecessary(token0, token1, FEE, sqrtPriceX96);

		positionManager.mint(
			IUniswapV3NonfungiblePositionManager.MintParams({
				token0: token0,
				token1: token1,
				fee: FEE,
				tickLower: TICK_LOWER,
				tickUpper: TICK_UPPER,
				amount0Desired: amount0,
				amount1Desired: amount1,
				amount0Min: 0,
				amount1Min: 0,
				recipient: msg.sender,
				deadline: block.timestamp + 600
			})
		);
		console2.log('Pool:', pool);
	}

	/// @dev Same fair-sqrt math as CreateUniV3Pools (frosty-core PriceOracle port).
	function _sqrtPriceX96(uint256 rate0, uint256 rate1, uint256 scale0, uint256 scale1)
		internal
		pure
		returns (uint160)
	{
		uint256 ratioX96 = Math.mulDiv(Math.mulDiv(rate0, Q96, rate1), scale1, scale0);
		uint256 sqrtRatio =
			ratioX96 <= type(uint256).max >> 64 ? Math.sqrt(ratioX96 << 64) << 16 : Math.sqrt(ratioX96) << 48;
		return uint160(sqrtRatio);
	}

	function _log() internal view {
		console2.log('tETH: ', address(tEth));
		console2.log('tBTC: ', address(tBtc));
		console2.log('tLINK:', address(tLink));
		console2.log('tDAI: ', address(tDai));
		console2.log('UniV3Adapter (SwapRouter02-correct):', address(uniAdapter));
	}
}
