// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {IPolicy} from '../src/interfaces/IPolicy.sol';
import {IUniswapV3SwapRouter} from '../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {ISlipstreamSwapRouter} from '../src/interfaces/external/ISlipstreamSwapRouter.sol';
import {UniswapV3SwapAdapter} from '../src/adapters/UniswapV3SwapAdapter.sol';
import {AerodromeSlipstreamSwapAdapter} from '../src/adapters/AerodromeSlipstreamSwapAdapter.sol';
import {MaxConcentrationPolicy} from '../src/policies/MaxConcentrationPolicy.sol';
import {CumulativeSlippageTolerancePolicy} from '../src/policies/CumulativeSlippageTolerancePolicy.sol';
import {AllowedAdapterIncomingAssetsPolicy} from '../src/policies/AllowedAdapterIncomingAssetsPolicy.sol';
import {DisallowedAdapterIncomingAssetsPolicy} from '../src/policies/DisallowedAdapterIncomingAssetsPolicy.sol';
import {MockERC20, MockAggregator, MockSwapRouter} from './utils/Mocks.sol';

contract IntegrationTest is Test {
	FundFactory internal factory;
	ValueInterpreter internal interpreter;
	Comptroller internal comptroller;
	MockERC20 internal usdc;
	MockERC20 internal nvdax;
	MockAggregator internal usdcFeed;
	MockAggregator internal nvdaxFeed;
	MockSwapRouter internal router;
	UniswapV3SwapAdapter internal uniAdapter;
	AerodromeSlipstreamSwapAdapter internal aeroAdapter;

	address internal admin = makeAddr('admin');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');

	function setUp() public {
		vm.warp(30 days);
		interpreter = new ValueInterpreter(admin);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		nvdax = new MockERC20('NVDA Wrapper', 'NVDAx', 18);
		usdcFeed = new MockAggregator(8, 1e8);
		nvdaxFeed = new MockAggregator(8, 180e8);
		vm.startPrank(admin);
		interpreter.addPrimitive(address(usdc), address(usdcFeed), 7 days);
		interpreter.addPrimitive(address(nvdax), address(nvdaxFeed), 7 days);
		vm.stopPrank();

		factory = new FundFactory(interpreter, new ComptrollerDeployer(), new SharesVaultDeployer()); // this test = factory owner
		router = new MockSwapRouter();
		uniAdapter = new UniswapV3SwapAdapter(IUniswapV3SwapRouter(address(router)));
		aeroAdapter = new AerodromeSlipstreamSwapAdapter(ISlipstreamSwapRouter(address(router)));
		factory.registerAdapter(address(uniAdapter));
		factory.registerAdapter(address(aeroAdapter));

		comptroller = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Frosty Alpha',
					symbol: 'frALPHA',
					denominationAsset: IERC20(address(usdc)),
					fundOwner: manager,
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: 0,
					sharesActionTimelock: 0,
					minRequestDuration: 30 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				})
			)
		);

		// Seed the fund: 10,000 USDC from alice
		usdc.mint(alice, 10_000e6);
		vm.startPrank(alice);
		usdc.approve(address(comptroller), 10_000e6);
		comptroller.requestDeposit(10_000e6);
		vm.stopPrank();
		skip(30 minutes);
		comptroller.executeDepositRequest(alice);
	}

	function _uniSwapData(uint256 amountIn, uint256 minOut) internal view returns (bytes memory) {
		return abi.encode(address(usdc), address(nvdax), uint24(500), amountIn, minOut);
	}

	// ─── Happy path ──────────────────────────────────────────────────────────────

	function test_swapViaUniV3Adapter() public {
		// 1800 USDC → 10 NVDAx (fair value at $180)
		router.setNextAmountOut(10e18);

		vm.prank(manager);
		comptroller.callOnIntegration(address(uniAdapter), _uniSwapData(1800e6, 9.9e18));

		address vault = address(comptroller.vault());
		assertEq(usdc.balanceOf(vault), 8200e6);
		assertEq(nvdax.balanceOf(vault), 10e18);
		assertEq(router.lastFee(), 500);
		assertEq(router.lastRecipient(), vault);

		// Incoming asset auto-tracked → GAV includes it (8200 + 1800 = 10,000)
		address[] memory tracked = comptroller.getTrackedAssets();
		assertEq(tracked.length, 2);
		assertEq(comptroller.calcGav(), 10_000e6);
	}

	function test_swapViaSlipstreamAdapter() public {
		router.setNextAmountOut(10e18);
		bytes memory data = abi.encode(address(usdc), address(nvdax), int24(100), uint256(1800e6), uint256(9.9e18));

		vm.prank(manager);
		comptroller.callOnIntegration(address(aeroAdapter), data);

		assertEq(router.lastTickSpacing(), 100);
		assertEq(nvdax.balanceOf(address(comptroller.vault())), 10e18);
	}

	// ─── Safety gates ────────────────────────────────────────────────────────────

	function test_unregisteredAdapter_reverts() public {
		UniswapV3SwapAdapter rogue = new UniswapV3SwapAdapter(IUniswapV3SwapRouter(address(router)));
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(Comptroller.AdapterNotRegistered.selector, address(rogue)));
		comptroller.callOnIntegration(address(rogue), _uniSwapData(1800e6, 0));
	}

	function test_deregisteredAdapter_reverts_guardianCanDeregister() public {
		address guardian = makeAddr('guardian');
		factory.setGuardian(guardian);

		vm.prank(guardian);
		factory.deregisterAdapter(address(uniAdapter));

		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(Comptroller.AdapterNotRegistered.selector, address(uniAdapter)));
		comptroller.callOnIntegration(address(uniAdapter), _uniSwapData(1800e6, 0));

		// Random accounts cannot touch the registry
		vm.prank(alice);
		vm.expectRevert(FundFactory.OnlyGuardian.selector);
		factory.deregisterAdapter(address(aeroAdapter));
	}

	function test_onlyFundOwner_trades() public {
		vm.prank(alice);
		vm.expectRevert(Comptroller.OnlyFundOwner.selector);
		comptroller.callOnIntegration(address(uniAdapter), _uniSwapData(1800e6, 0));
	}

	function test_minIncoming_enforcedByBalanceDelta() public {
		// Router pays only 9 NVDAx (and ignores minOut); the comptroller's balance-delta
		// check demands the 9.9 encoded in the action.
		router.setNextAmountOut(9e18);
		vm.prank(manager);
		vm.expectRevert(
			abi.encodeWithSelector(Comptroller.MinIncomingAmountNotMet.selector, address(nvdax), 9e18, 9.9e18)
		);
		comptroller.callOnIntegration(address(uniAdapter), _uniSwapData(1800e6, 9.9e18));
	}

	// ─── Trading policies ────────────────────────────────────────────────────────

	function test_maxConcentrationPolicy_blocksOverweightPosition() public {
		MaxConcentrationPolicy policy = new MaxConcentrationPolicy(2000); // 20%
		vm.prank(address(factory)); // set-once: only the factory registers policies (behavior test shortcut)
		comptroller.addPolicy(IPolicy.PolicyHook.PostCallOnIntegration, address(policy));

		// 18% of GAV into NVDAx: fine
		router.setNextAmountOut(10e18);
		vm.prank(manager);
		comptroller.callOnIntegration(address(uniAdapter), _uniSwapData(1800e6, 10e18));

		// Another 18% → NVDAx would be ~36% of GAV: blocked
		router.setNextAmountOut(10e18);
		vm.prank(manager);
		vm.expectRevert(
			abi.encodeWithSelector(MaxConcentrationPolicy.MaxConcentrationExceeded.selector, address(nvdax), 3600)
		);
		comptroller.callOnIntegration(address(uniAdapter), _uniSwapData(1800e6, 10e18));
	}

	function test_assetListPolicies_gateIncomingAssets() public {
		// Whitelist that does NOT include NVDAx
		address[] memory onlyUsdc = new address[](1);
		onlyUsdc[0] = address(usdc);
		AllowedAdapterIncomingAssetsPolicy whitelist = new AllowedAdapterIncomingAssetsPolicy(onlyUsdc);
		vm.prank(address(factory)); // set-once: only the factory registers policies (behavior test shortcut)
		comptroller.addPolicy(IPolicy.PolicyHook.PostCallOnIntegration, address(whitelist));

		router.setNextAmountOut(10e18);
		vm.prank(manager);
		vm.expectRevert(
			abi.encodeWithSelector(AllowedAdapterIncomingAssetsPolicy.IncomingAssetNotAllowed.selector, address(nvdax))
		);
		comptroller.callOnIntegration(address(uniAdapter), _uniSwapData(1800e6, 10e18));
	}

	function test_blacklistPolicy_blocksDisallowedAsset() public {
		address[] memory banned = new address[](1);
		banned[0] = address(nvdax);
		DisallowedAdapterIncomingAssetsPolicy blacklist = new DisallowedAdapterIncomingAssetsPolicy(banned);
		vm.prank(address(factory)); // set-once: only the factory registers policies (behavior test shortcut)
		comptroller.addPolicy(IPolicy.PolicyHook.PostCallOnIntegration, address(blacklist));

		router.setNextAmountOut(10e18);
		vm.prank(manager);
		vm.expectRevert(
			abi.encodeWithSelector(DisallowedAdapterIncomingAssetsPolicy.IncomingAssetDisallowed.selector, address(nvdax))
		);
		comptroller.callOnIntegration(address(uniAdapter), _uniSwapData(1800e6, 10e18));
	}

	function test_cumulativeSlippagePolicy_rateLimitsDraining() public {
		CumulativeSlippageTolerancePolicy policy = new CumulativeSlippageTolerancePolicy(1000); // 10% / 7d
		vm.prank(address(factory)); // set-once: only the factory registers policies (behavior test shortcut)
		comptroller.addPolicy(IPolicy.PolicyHook.PostCallOnIntegration, address(policy));

		// Trade 1: spend 1800 USDC, receive 5 NVDAx ($900) → ~9% loss of fund value. Passes.
		router.setNextAmountOut(5e18);
		vm.prank(manager);
		comptroller.callOnIntegration(address(uniAdapter), _uniSwapData(1800e6, 0));

		// Trade 2 immediately: same bleed → cumulative ~18% > 10%. Blocked.
		router.setNextAmountOut(5e18);
		vm.prank(manager);
		vm.expectRevert(); // CumulativeSlippageExceeded
		comptroller.callOnIntegration(address(uniAdapter), _uniSwapData(1800e6, 0));

		// After a full tolerance period the budget replenishes and trading resumes.
		skip(7 days);
		usdcFeed.setAnswer(1e8); // fresh oracle round after the warp
		nvdaxFeed.setAnswer(180e8);
		router.setNextAmountOut(5e18);
		vm.prank(manager);
		comptroller.callOnIntegration(address(uniAdapter), _uniSwapData(1800e6, 0));

		// Fair-value trades never consume budget
		router.setNextAmountOut(10e18);
		vm.prank(manager);
		comptroller.callOnIntegration(address(uniAdapter), _uniSwapData(1800e6, 0));
	}
}
