// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerV6} from '../../src/core/ComptrollerV6.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {PoolPriceRegistrarV2} from '../../src/pricing/PoolPriceRegistrarV2.sol';
import {IValueInterpreter} from '../../src/interfaces/IValueInterpreter.sol';
import {IFrostyClmVault} from '../../src/interfaces/external/IFrostyClm.sol';
import {ClmVaultAdapter} from '../../src/adapters/ClmVaultAdapter.sol';
import {ClmVaultPriceFeed} from '../../src/pricing/ClmVaultPriceFeed.sol';
import {FundV6Deploy} from '../../script/mainnet/FundV6Deploy.sol';
import {ClmFixture, MockClmVi} from './utils/ClmFixture.sol';

/// @notice A real v6 fund deposits into and leaves FrostyFi's real CLM vault through ClmVaultAdapter, valued by
///         ClmVaultPriceFeed in the real VI (Base fork, block 52,385,115: the fund v6 rehearsal's block). Plus a
///         Slipstream-1 pair with no USDC side, exited to USDC in one action.
contract ClmVaultAdapterForkTest is ClmFixture {
	uint256 internal constant FORK_BLOCK = 52_385_115;
	address internal constant SLIPSTREAM2_SWAP_ADAPTER = 0xB09f3467eE7039bcA58F4b2E778E2bE3C7Cf7C1E;
	bool internal ready;
	address internal deployer;
	FundFactory internal factory;
	address internal registrarV2;
	address internal perpConfig;
	address internal vi;
	address internal poolDeployer;
	FundV6Deploy.Deployed internal d;
	ClmVaultAdapter internal adapter;
	ClmVaultPriceFeed internal feed;
	address internal clmVault;
	address internal clmStrategy;
	address internal manager = makeAddr('manager');
	address internal investor = makeAddr('investor');
	address internal keeper = makeAddr('keeper');

	function setUp() public virtual {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0 || !_clmReady()) return;
		vm.createSelectFork(rpc, FORK_BLOCK);
		ready = true;
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		deployer = vm.parseJsonAddress(genesis, '.deployer');
		factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		perpConfig = vm.parseJsonAddress(genesis, '.verantaFactory');
		vi = vm.parseJsonAddress(genesis, '.valueInterpreter');
		registrarV2 = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-v4.json'), '.registrar');

		address strategyFactory;
		(strategyFactory, poolDeployer) = _deployClm(keeper, address(new MockClmVi()));
		(clmVault, clmStrategy) = _deployCbBtcVault(poolDeployer);
		feed = new ClmVaultPriceFeed(IValueInterpreter(vi), strategyFactory, registrarV2);
		adapter = new ClmVaultAdapter(SLIPSTREAM1_ROUTER, SLIPSTREAM2_ROUTER, SLIPSTREAM3_ROUTER);

		vm.startPrank(deployer);
		d = FundV6Deploy.deploy(deployer, address(factory), registrarV2, perpConfig, keeper);
		factory.setComptrollerDeployer(d.fundV6Deployer);
		factory.registerAdapter(address(adapter));
		// The mainnet VI admin path: registrar V2 → today's registrar → VI.
		PoolPriceRegistrarV2(registrarV2).callOldRegistrar(
			abi.encodeCall(PoolPriceRegistrar.execute, (abi.encodeCall(ValueInterpreter.addDerivative, (clmVault, address(feed)))))
		);
		vm.stopPrank();
	}

	/// @dev The exit route for the cbBTC vault: cbBTC → USDC on its own Slipstream-2 pool (ts50).
	function _cbBtcExit(uint256 shares) internal view returns (bytes memory) {
		ClmVaultAdapter.Route[] memory routes = new ClmVaultAdapter.Route[](1);
		routes[0] = ClmVaultAdapter.Route(SLIPSTREAM2_ROUTER, abi.encodePacked(CBBTC, int24(50), USDC));
		return abi.encode(uint8(2), clmVault, shares, uint256(0), USDC, routes);
	}

	function _fund(uint256 amount) internal returns (ComptrollerV6 fund) {
		fund = ComptrollerV6(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'CLM fund',
					symbol: 'frCLM',
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
		fund.requestDeposit(amount, type(uint256).max);
		vm.stopPrank();
		vm.warp(block.timestamp + 1 minutes);
		vm.roll(block.number + 30);
		fund.executeDepositRequest(investor);
	}

	/// @dev The manager buys cbBTC with part of the USDC, then deposits both into the CLM vault.
	function _managerDeposits(ComptrollerV6 fund, uint256 usdcForBtc) internal {
		vm.startPrank(manager);
		fund.callOnIntegration(SLIPSTREAM2_SWAP_ADAPTER, abi.encode(USDC, CBBTC, int24(50), usdcForBtc, uint256(0)));
		_settle(clmStrategy);
		address v = address(fund.vault());
		fund.callOnIntegration(
			address(adapter),
			abi.encode(uint8(0), clmVault, IERC20(USDC).balanceOf(v), IERC20(CBBTC).balanceOf(v), uint256(0))
		);
		vm.stopPrank();
	}

	function test_deposit_returnsLeftoversAndKeepsNothing() public {
		vm.skip(!ready);
		// Seed the vault first: an empty vault's first deposit takes both amounts whole, so nothing would be left over.
		deal(USDC, address(this), 10_000e6);
		_buyCbBtc(address(this), 0.05e8);
		_settle(clmStrategy);
		IERC20(USDC).approve(clmVault, type(uint256).max);
		IERC20(CBBTC).approve(clmVault, type(uint256).max);
		IFrostyClmVault(clmVault).deposit(IERC20(USDC).balanceOf(address(this)), 0.05e8, 0);
		_settle(clmStrategy);

		ComptrollerV6 fund = _fund(20_000e6);
		uint256 gavBefore = fund.calcGav();
		_managerDeposits(fund, 5_000e6); // ~15k USDC + ~5k of cbBTC: the vault's ratio leaves USDC over
		address v = address(fund.vault());
		assertGt(IFrostyClmVault(clmVault).balanceOf(v), 0, 'the fund holds vault shares');
		assertGt(IERC20(USDC).balanceOf(v), 0, 'the USDC the ratio did not take came back to the fund');
		assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
		assertEq(IERC20(CBBTC).balanceOf(address(adapter)), 0);
		assertEq(IFrostyClmVault(clmVault).balanceOf(address(adapter)), 0);
		// The swap's pool fee and the vault's imbalance fee cost a little: within 0.5% of GAV.
		assertApproxEqRel(fund.calcGav(), gavBefore, 0.005e18, 'NAV carries the vault shares at oracle value');
	}

	function test_withdraw_bringsBothTokensBack() public {
		vm.skip(!ready);
		ComptrollerV6 fund = _fund(20_000e6);
		_managerDeposits(fund, 10_000e6);
		address v = address(fund.vault());
		uint256 shares = IFrostyClmVault(clmVault).balanceOf(v);
		_settle(clmStrategy);
		uint256 gavBefore = fund.calcGav();
		vm.prank(manager);
		fund.callOnIntegration(address(adapter), abi.encode(uint8(1), clmVault, shares, uint256(0), uint256(0)));
		assertEq(IFrostyClmVault(clmVault).balanceOf(v), 0);
		assertApproxEqRel(fund.calcGav(), gavBefore, 0.003e18);
	}

	function test_exit_sellsTheOtherSideIntoUsdc() public {
		vm.skip(!ready);
		ComptrollerV6 fund = _fund(20_000e6);
		_managerDeposits(fund, 10_000e6);
		address v = address(fund.vault());
		uint256 btcBefore = IERC20(CBBTC).balanceOf(v);
		uint256 shares = IFrostyClmVault(clmVault).balanceOf(v);
		_settle(clmStrategy);
		vm.prank(manager);
		fund.callOnIntegration(address(adapter), _cbBtcExit(shares));
		assertEq(IFrostyClmVault(clmVault).balanceOf(v), 0);
		assertEq(IERC20(CBBTC).balanceOf(v), btcBefore, 'no cbBTC came back: it was sold');
		assertEq(IERC20(CBBTC).balanceOf(address(adapter)), 0);
	}

	/// @dev Slipstream-1 WETH/cbLTC (no USDC side), straight through the adapter as the Comptroller would call it:
	///      cbLTC → WETH → USDC and WETH → USDC on Slipstream-1, one action, nothing left behind.
	function test_exit_routesANonUsdcPairToUsdc() public {
		vm.skip(!ready);
		(address s1Vault, address s1Strategy) = _deployWethCbLtcVault(poolDeployer);
		deal(WETH, address(this), 5e18);
		_buyCbLtc(address(this), 50e8);
		_settle(s1Strategy);
		IERC20(WETH).approve(s1Vault, type(uint256).max);
		IERC20(CBLTC).approve(s1Vault, type(uint256).max);
		IFrostyClmVault(s1Vault).deposit(IERC20(WETH).balanceOf(address(this)), IERC20(CBLTC).balanceOf(address(this)), 0);
		uint256 shares = IFrostyClmVault(s1Vault).balanceOf(address(this));
		_settle(s1Strategy);

		ClmVaultAdapter.Route[] memory routes = new ClmVaultAdapter.Route[](2);
		routes[0] = ClmVaultAdapter.Route(SLIPSTREAM1_ROUTER, abi.encodePacked(CBLTC, int24(200), WETH, int24(100), USDC));
		routes[1] = ClmVaultAdapter.Route(SLIPSTREAM1_ROUTER, abi.encodePacked(WETH, int24(100), USDC));
		IERC20(s1Vault).transfer(address(adapter), shares); // what the Comptroller does before executeAction
		uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
		uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
		adapter.executeAction(address(this), abi.encode(uint8(2), s1Vault, shares, uint256(0), USDC, routes));

		assertGt(IERC20(USDC).balanceOf(address(this)) - usdcBefore, 0, 'paid in USDC');
		assertEq(IERC20(WETH).balanceOf(address(this)), wethBefore, 'no WETH came back');
		assertEq(IERC20(WETH).balanceOf(address(adapter)), 0);
		assertEq(IERC20(CBLTC).balanceOf(address(adapter)), 0);
		assertEq(IERC20(s1Vault).balanceOf(address(adapter)), 0);
	}

	function test_exit_withAMissingRouteReverts() public {
		vm.skip(!ready);
		ComptrollerV6 fund = _fund(20_000e6);
		_managerDeposits(fund, 10_000e6);
		uint256 shares = IFrostyClmVault(clmVault).balanceOf(address(fund.vault()));
		_settle(clmStrategy);
		ClmVaultAdapter.Route[] memory none = new ClmVaultAdapter.Route[](0);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(ClmVaultAdapter.Unsold.selector, CBBTC));
		fund.callOnIntegration(address(adapter), abi.encode(uint8(2), clmVault, shares, uint256(0), USDC, none));
	}
}
