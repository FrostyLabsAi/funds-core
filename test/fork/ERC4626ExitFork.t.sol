// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {ComptrollerV6} from '../../src/core/ComptrollerV6.sol';
import {RedemptionQueueV2} from '../../src/redemption/RedemptionQueueV2.sol';
import {ComptrollerV6Lib} from '../../src/core/ComptrollerV6Lib.sol';
import {ERC4626ExitAdapter} from '../../src/adapters/ERC4626ExitAdapter.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {ClmFundsDeploy} from '../../script/mainnet/ClmFundsDeploy.sol';
import {RedemptionQueueV2ShortDeadline} from '../utils/RedemptionQueueV2ShortDeadline.sol';

/// @notice A ghosted v6 fund's ERC-4626 shares (founder 2026-10-14): the keeper exits Aave's static USDC vault (no
///         route: the redeem pays USDC) and static WETH vault (redeem, then WETH → USDC on Slipstream-1) through
///         ERC4626ExitAdapter, within the 3% cap, and the leaver is paid in USDC. Live Base (block 52,607,800: fund v6
///         deployed, both vaults priced in the VI, ERC4626Adapter registered); a 1-second deadline queue as FundV6Fork's.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/ERC4626ExitFork.t.sol -vv
contract ERC4626ExitForkTest is Test {
	uint256 internal constant FORK_BLOCK = 52_607_800;
	address internal constant USDC = FundsMainnet.USDC;
	address internal constant WETH = FundsMainnet.WETH;
	address internal constant STATIC_USDC = 0xC768c589647798a6EE01A91FdE98EF2ed046DBD6;
	address internal constant STATIC_WETH = 0xe298b938631f750DD409fB18227C4a23dCdaab9b;
	address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

	bool internal forked;
	address internal deployer;
	FundFactory internal factory;
	address internal uniAdapter;
	address internal erc4626Adapter;
	RedemptionQueueV2 internal queue;
	ERC4626ExitAdapter internal exitAdapter;
	address internal manager = makeAddr('manager');
	address internal investor = makeAddr('investor');
	address internal keeper = makeAddr('keeper');

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, FORK_BLOCK);
		forked = true;
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		deployer = vm.parseJsonAddress(genesis, '.deployer');
		factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		uniAdapter = vm.parseJsonAddress(genesis, '.uniAdapter');
		erc4626Adapter = vm.parseJsonAddress(genesis, '.erc4626Adapter');
		address registrarV2 = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-v4.json'), '.registrar');
		address perpConfig = vm.parseJsonAddress(genesis, '.verantaFactory');

		queue = new RedemptionQueueV2ShortDeadline(address(this));
		queue.setFactory(address(factory));
		queue.setKeeper(keeper, true);
		ComptrollerBlueprintDeployer shortDeployer =
			new ComptrollerBlueprintDeployer(type(ComptrollerV6).creationCode, abi.encode(registrarV2, queue, perpConfig));
		exitAdapter = new ERC4626ExitAdapter(
			ClmFundsDeploy.SLIPSTREAM1_ROUTER, ClmFundsDeploy.SLIPSTREAM2_ROUTER, ClmFundsDeploy.SLIPSTREAM3_ROUTER
		);
		vm.startPrank(deployer);
		factory.setComptrollerDeployer(shortDeployer);
		factory.registerAdapter(address(exitAdapter));
		vm.stopPrank();
	}

	function test_fork_keeperExitsUsdcAndWethVaultSharesIntoUsdc() public {
		vm.skip(!forked);
		ComptrollerV6 fund = _fundIn4626Vaults();
		address v = address(fund.vault());
		uint256 usdcShares = IERC20(STATIC_USDC).balanceOf(v);
		uint256 wethShares = IERC20(STATIC_WETH).balanceOf(v);
		_overdueRedemption(fund);

		uint256 gavBefore = fund.calcGav();
		vm.startPrank(keeper);
		queue.liquidate(address(fund), address(exitAdapter), _exit(STATIC_USDC, usdcShares, new ERC4626ExitAdapter.Route[](0)));
		queue.liquidate(address(fund), address(exitAdapter), _exit(STATIC_WETH, wethShares, _wethToUsdc()));
		vm.stopPrank();
		assertEq(IERC20(STATIC_USDC).balanceOf(v), 0, 'every static USDC share exited');
		assertEq(IERC20(STATIC_WETH).balanceOf(v), 0, 'every static WETH share exited');
		assertEq(IERC20(WETH).balanceOf(v), 0, 'no WETH came back: it was sold');
		assertEq(IERC20(WETH).balanceOf(address(exitAdapter)), 0);
		assertEq(IERC20(USDC).balanceOf(address(exitAdapter)), 0);
		uint256 gavAfter = fund.calcGav();
		emit log_named_int('exit cost vs oracle value (USDC, 6 decimals)', int256(gavBefore) - int256(gavAfter));
		assertGt(gavAfter, gavBefore * 9_970 / 10_000, 'within the 3% cap, and far under it');
		assertApproxEqAbs(IERC20(USDC).balanceOf(v), gavAfter, 1, 'the fund is all USDC');

		uint256 shares = fund.shares().balanceOf(address(queue));
		uint256 supply = fund.shares().totalSupply();
		vm.prank(keeper);
		assertEq(queue.settle(address(fund), 1), 1);
		assertApproxEqAbs(IERC20(USDC).balanceOf(investor), gavAfter * shares / supply, 2, 'paid in USDC');
	}

	/// Two hops, WETH → cbBTC → USDC on Slipstream-1's ts100 pools: SlipstreamSell's router check passes on a whole fill
	/// and nothing stays in the router (review 2026-10-14).
	function test_fork_aTwoHopRouteExitsAndLeavesNothingInTheRouter() public {
		vm.skip(!forked);
		ComptrollerV6 fund = _fundIn4626Vaults();
		address v = address(fund.vault());
		uint256 wethShares = IERC20(STATIC_WETH).balanceOf(v);
		_overdueRedemption(fund);
		ERC4626ExitAdapter.Route[] memory routes = new ERC4626ExitAdapter.Route[](1);
		routes[0] = ERC4626ExitAdapter.Route(
			ClmFundsDeploy.SLIPSTREAM1_ROUTER, abi.encodePacked(WETH, int24(100), CBBTC, int24(100), USDC)
		);
		uint256 routerBtc = IERC20(CBBTC).balanceOf(ClmFundsDeploy.SLIPSTREAM1_ROUTER);
		uint256 gavBefore = fund.calcGav();
		vm.prank(keeper);
		queue.liquidate(address(fund), address(exitAdapter), _exit(STATIC_WETH, wethShares, routes));
		assertEq(IERC20(STATIC_WETH).balanceOf(v), 0);
		assertEq(IERC20(CBBTC).balanceOf(v), 0, 'no cbBTC came back');
		assertEq(IERC20(CBBTC).balanceOf(ClmFundsDeploy.SLIPSTREAM1_ROUTER), routerBtc, 'none left in the router');
		emit log_named_int('exit cost vs oracle value (USDC, 6 decimals)', int256(gavBefore) - int256(fund.calcGav()));
		assertGt(fund.calcGav(), gavBefore * 9_970 / 10_000, 'within the 3% cap, and far under it');
	}

	/// The plain ERC4626Adapter redeem returns WETH, which isn't a sale (ComptrollerV6Lib._checkSale): why this adapter.
	function test_fork_aPlainRedeemIntoWethIsNotASale() public {
		vm.skip(!forked);
		ComptrollerV6 fund = _fundIn4626Vaults();
		uint256 wethShares = IERC20(STATIC_WETH).balanceOf(address(fund.vault()));
		_overdueRedemption(fund);
		vm.prank(keeper);
		vm.expectRevert(ComptrollerV6Lib.NotASale.selector);
		queue.liquidate(address(fund), erc4626Adapter, abi.encode(uint8(1), STATIC_WETH, wethShares, uint256(0)));
	}

	function _exit(address vault4626, uint256 shares, ERC4626ExitAdapter.Route[] memory routes)
		internal
		pure
		returns (bytes memory)
	{
		return abi.encode(vault4626, shares, uint256(0), USDC, routes);
	}

	/// @dev WETH → USDC on Slipstream-1's ts100 pool.
	function _wethToUsdc() internal pure returns (ERC4626ExitAdapter.Route[] memory routes) {
		routes = new ERC4626ExitAdapter.Route[](1);
		routes[0] = ERC4626ExitAdapter.Route(ClmFundsDeploy.SLIPSTREAM1_ROUTER, abi.encodePacked(WETH, int24(100), USDC));
	}

	/// @dev 20k USDC in; the manager puts 8k in Aave's static USDC vault and buys ~8k of WETH for the static WETH vault.
	function _fundIn4626Vaults() internal returns (ComptrollerV6 fund) {
		fund = ComptrollerV6(
			factory.createFund(
				FundFactory.FundConfig({
					name: '4626 fund',
					symbol: 'fr4626',
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
		deal(USDC, investor, 20_000e6);
		vm.startPrank(investor);
		IERC20(USDC).approve(address(fund), 20_000e6);
		fund.requestDeposit(20_000e6, type(uint256).max);
		vm.stopPrank();
		vm.warp(block.timestamp + 1 minutes);
		vm.roll(block.number + 30);
		fund.executeDepositRequest(investor);

		address v = address(fund.vault());
		vm.startPrank(manager);
		fund.callOnIntegration(erc4626Adapter, abi.encode(uint8(0), STATIC_USDC, uint256(8_000e6), uint256(0)));
		fund.callOnIntegration(uniAdapter, abi.encode(USDC, WETH, uint24(500), uint256(8_000e6), uint256(0)));
		fund.callOnIntegration(erc4626Adapter, abi.encode(uint8(0), STATIC_WETH, IERC20(WETH).balanceOf(v), uint256(0)));
		vm.stopPrank();
		assertGt(IERC20(STATIC_USDC).balanceOf(v), 0);
		assertGt(IERC20(STATIC_WETH).balanceOf(v), 0);
		assertEq(IERC20(WETH).balanceOf(v), 0);
	}

	/// @dev The investor asks for half; the 1-second deadline passes.
	function _overdueRedemption(ComptrollerV6 fund) internal {
		uint256 shares = fund.shares().balanceOf(investor) / 2;
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(address(queue), shares);
		queue.requestRedeem(address(fund), shares);
		vm.stopPrank();
		vm.warp(block.timestamp + 2);
		vm.roll(block.number + 1);
		assertTrue(queue.isOverdue(address(fund)));
	}
}
