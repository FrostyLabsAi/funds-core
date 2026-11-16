// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {FundHost} from './utils/FundHost.sol';
import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {SharesVaultDeployer} from '../src/core/SharesVaultDeployer.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {UniswapV3SwapAdapter} from '../src/adapters/UniswapV3SwapAdapter.sol';
import {IUniswapV3SwapRouter} from '../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {MockERC20, MockAggregator, MockSwapRouter} from './utils/Mocks.sol';

contract SidePocketTest is Test {
	FundFactory internal factory;
	ValueInterpreter internal interpreter;
	Comptroller internal degenFund;
	Comptroller internal conservativeFund;
	MockERC20 internal usdc;
	MockERC20 internal moon; // fresh-launch memecoin: no defensible price
	MockSwapRouter internal router;
	UniswapV3SwapAdapter internal adapter;

	address internal admin = makeAddr('admin');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');

	function setUp() public {
		vm.warp(30 days);
		interpreter = new ValueInterpreter(admin);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		moon = new MockERC20('Moon Machine (demo)', 'MOONM', 18);
		MockAggregator usdcFeed = new MockAggregator(8, 1e8);
		vm.startPrank(admin);
		interpreter.addPrimitive(address(usdc), address(usdcFeed), 7 days);
		interpreter.addZeroPricedAsset(address(moon)); // the side-pocket class
		vm.stopPrank();

		factory = new FundFactory(interpreter, FundHost.deployer(), new SharesVaultDeployer());
		router = new MockSwapRouter();
		adapter = new UniswapV3SwapAdapter(IUniswapV3SwapRouter(address(router)), address(0xFEE), 0, address(this));
		factory.registerAdapter(address(adapter));

		degenFund = Comptroller(factory.createFund(_config('Degen Moonshots (demo)', 'frMOON', true)));
		conservativeFund = Comptroller(factory.createFund(_config('Sensible Yield (demo)', 'frSAFE', false)));

		usdc.mint(alice, 20_000e6);
		_seed(degenFund, 10_000e6);
		_seed(conservativeFund, 10_000e6);
	}

	function _config(string memory name, string memory symbol, bool risky)
		internal
		view
		returns (FundFactory.FundConfig memory)
	{
		return FundFactory.FundConfig({
			name: name,
			symbol: symbol,
			denominationAsset: IERC20(address(usdc)),
			fundOwner: manager,
			mgmtScaledPerSecondRate: 0,
			perfFeeBps: 1500,
			sharesActionTimelock: 0,
			minRequestDuration: 30 minutes,
			executionWindow: 1 days,
			allowRiskyAssets: risky
		});
	}

	function _seed(Comptroller comptroller, uint256 assets) internal {
		vm.startPrank(alice);
		usdc.approve(address(comptroller), assets);
		comptroller.requestDeposit(assets, type(uint256).max);
		vm.stopPrank();
		skip(30 minutes);
		comptroller.executeDepositRequest(alice);
	}

	function _swapData(uint256 amountIn, uint256 minOut, bool buyMoon) internal view returns (bytes memory) {
		return buyMoon
			? abi.encode(address(usdc), address(moon), uint24(10000), amountIn, minOut)
			: abi.encode(address(moon), address(usdc), uint24(10000), amountIn, minOut);
	}

	function test_zeroPriced_registryRules() public {
		assertTrue(interpreter.isSupportedAsset(address(moon)));
		assertTrue(interpreter.isZeroPricedAsset(address(moon)));
		assertEq(interpreter.calcUsdRate(address(moon)), 0);
		assertEq(interpreter.calcCanonicalAssetValue(address(moon), 1_000_000e18, address(usdc)), 0);

		// Exactly one class per asset: cannot also become a primitive
		MockAggregator feed = new MockAggregator(8, 1e8);
		vm.prank(admin);
		vm.expectRevert(abi.encodeWithSelector(ValueInterpreter.AlreadyRegistered.selector, address(moon)));
		interpreter.addPrimitive(address(moon), address(feed), 1 days);
	}

	function test_conservativeFund_cannotTouchMoonshots() public {
		// Explicit tracking blocked
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(Comptroller.RiskyAssetsNotAllowed.selector, address(moon)));
		conservativeFund.addTrackedAsset(address(moon));

		// And the trade path is blocked at auto-tracking
		router.setNextAmountOut(1_000_000e18);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(Comptroller.RiskyAssetsNotAllowed.selector, address(moon)));
		conservativeFund.callOnIntegration(address(adapter), _swapData(500e6, 0, true));
	}

	function test_degenFund_moonshotLifecycle_gainsOnRealizationOnly() public {
		assertTrue(degenFund.allowRiskyAssets());

		// Buy: 500 USDC → 1M MOONM. GAV drops by the full spend (moonbag worth zero).
		router.setNextAmountOut(1_000_000e18);
		vm.prank(manager);
		degenFund.callOnIntegration(address(adapter), _swapData(500e6, 1_000_000e18, true));

		assertEq(moon.balanceOf(address(degenFund.vault())), 1_000_000e18);
		assertEq(degenFund.calcGav(), 9500e6);
		assertEq(degenFund.calcAssetGav(address(moon)), 0);

		// No fees can crystallize on paper: settle at the drawdown mints nothing
		degenFund.settleFees();
		assertEq(degenFund.shares().balanceOf(manager), 0);

		// Moon does a 4x — sell the bag: 1M MOONM → 2000 USDC. Gain is REALIZED.
		router.setNextAmountOut(2000e6);
		vm.prank(manager);
		degenFund.callOnIntegration(address(adapter), _swapData(1_000_000e18, 2000e6, false));

		assertEq(degenFund.calcGav(), 11_500e6);

		// Performance fee only now, on the realized gain above HWM (1.15 > 1.0)
		degenFund.settleFees();
		assertGt(degenFund.shares().balanceOf(manager), 0);
	}

	/// Fund v6 pays exits in USDC only: a zero-priced bag counts for nothing, so an exit takes its USDC share and the
	/// bag stays with who remains.
	function test_anExitPaysItsUsdcShare_andTheMoonbagStays() public {
		router.setNextAmountOut(1_000_000e18);
		vm.prank(manager);
		degenFund.callOnIntegration(address(adapter), _swapData(500e6, 0, true));

		vm.prank(alice);
		degenFund.redeemShares(1000e18);

		assertEq(usdc.balanceOf(alice), 950e6);
		assertEq(moon.balanceOf(alice), 0);
	}
}
