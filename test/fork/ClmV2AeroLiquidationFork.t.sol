// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerV6} from '../../src/core/ComptrollerV6.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {RedemptionQueueV2} from '../../src/redemption/RedemptionQueueV2.sol';
import {ClmVaultPriceFeed} from '../../src/pricing/ClmVaultPriceFeed.sol';
import {ClmVaultExitAdapter} from '../../src/adapters/ClmVaultExitAdapter.sol';
import {IFrostyClmVault} from '../../src/interfaces/external/IFrostyClm.sol';
import {ClmFundsDeploy} from '../../script/mainnet/ClmFundsDeploy.sol';
import {AerodromeSlipstreamSwapAdapterV2} from '../../src/adapters/AerodromeSlipstreamSwapAdapterV2.sol';
import {ViaWethSellAdapterV2} from '../../src/adapters/ViaWethSellAdapterV2.sol';
import {DeployAeroAdapters} from '../../script/mainnet/DeployAeroAdapters.s.sol';
import {V4Pricing} from '../../script/mainnet/V4Pricing.sol';
import {RedemptionQueueV2ShortDeadline} from '../utils/RedemptionQueueV2ShortDeadline.sol';
import {B20Mirror, B20StandIn} from '../utils/B20Mirror.sol';

/// @dev funds-yield's ClmPoolDeployerV2.PoolConfig (no gauge), same field order.
struct ClmPoolConfigV2 {
	address compoundToken;
	int56 maxTickDeviation;
	address pool;
	int24 positionWidth;
	string symbol;
	uint32 twapInterval;
}

interface IClmPoolDeployerV2 {
	function STRATEGY_NAME() external view returns (string memory);
	function deployPool(ClmPoolConfigV2 calldata cfg) external returns (address strategy, address vault);
}

interface IClmStrategyFactoryLike {
	function addStrategy(string calldata name, address implementation) external;
}

interface IClmVaultPreview {
	function previewDeposit(uint256 amount0, uint256 amount1) external view returns (uint256 shares, uint256, uint256, uint256, uint256);
	function previewWithdraw(uint256 shares) external view returns (uint256 amount0, uint256 amount1);
}

/// @notice CLM v2 on Aero (FrostyFi 2026-10-25) with fund v6, on Base after the Aero upgrade, against the live contracts:
///         v2 added to v1's strategy factory and a USDC-WETH vault on Aero's pool (funds-yield, from ../funds-yield/out),
///         listed on the live ClmVaultPriceFeed, which must price it as it does v1's; a live v6 fund buys WETH and deposits
///         through the live ClmVaultAdapter; and once its leaver is overdue the keeper exits the vault shares into USDC
///         through DeployAeroAdapters' ClmVaultExitAdapter, selling WETH on Aero's router. The same script's spot adapter
///         trades on Aero's pool for a manager and sells for the keeper, and its ViaWethSellAdapterV2 sells a WETH-paired
///         token (cbETH) through WETH on Aero's pools. The same flows run on a stock, MSTRc (B20: Base's node runs it, Foundry
///         can't), against a stand-in holding the Aero pool's real reserves (B20Mirror._standIn), with the real token's
///         transfer rules read from Base for every contract that moves it; the fork block is a Sunday, so the stock's
///         Chainlink feed holds Friday's close while the pool trades. The live queue's code is swapped for its
///         1-second-deadline test twin (storage kept: the subclass only overrides deadline()).
///         Run: (cd ../funds-yield && forge build) && BASE_MAINNET_RPC=<archive url> forge test --match-contract ClmV2AeroLiquidationFork -vv
contract ClmV2AeroLiquidationForkTest is B20Mirror {
	uint256 internal constant FORK_BLOCK = 53_075_000; // 2026-10-25, three days after the upgrade
	string internal constant OUT = '../funds-yield/out/';
	address internal constant DEPLOYER = 0xaE51f2EfE70e57b994BE8F7f97C4dC824c51802a; // every owner here
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant WETH = 0x4200000000000000000000000000000000000006;
	address internal constant AERO_POOL_WETH_USDC = 0x4A7af46bC8aBc00048c6c7920a1488DAF568366c; // WETH token0, tick spacing 50
	address internal constant CBETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22; // Aero cbETH/WETH: tick spacing 1
	address internal constant MSTRC = 0xb2000000000000000000004884b426556b92883d; // B20, 8 decimals, Chainlink-priced
	address internal constant AERO_POOL_MSTRC_USDC = 0x66DCd42E6314B287110922AE36cB2a8bdEECc153; // USDC token0, tick spacing 10
	address internal constant AERO_NFT_MANAGER = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
	address internal constant QUEUE = 0x3d1fA56CBa486a75C80593808A17A909442c49f8; // deployments/base-mainnet-fund-v6.json
	address internal constant UNI_ADAPTER = 0xDd61a210100a6f53CcAB49Ee3324190B77Fd818b; // base-mainnet-v4.json uniAdapter
	address internal constant CLM_ADAPTER = 0x871E24C3e2e64195a2d31554975344227A857952; // base-mainnet-clm-funds.json
	address internal constant STRATEGY_FACTORY = 0x99c49323e589136BD4F9937b6ae226fD25A267aa; // funds-yield base-mainnet-clm.json
	address internal constant VAULT_FACTORY = 0x13a4FD7dD96D01BA22bddF8e3D8B56b81c073C74;

	address internal manager = makeAddr('manager');
	address internal investor = makeAddr('investor');
	address internal keeper = makeAddr('keeper');

	bool internal ready;
	FundFactory internal factory = FundFactory(ClmFundsDeploy.FUND_FACTORY);
	ValueInterpreter internal vi = ValueInterpreter(ClmFundsDeploy.VALUE_INTERPRETER);
	RedemptionQueueV2 internal queue = RedemptionQueueV2(QUEUE);
	ClmVaultPriceFeed internal feed;
	address internal clmVault;
	ClmVaultExitAdapter internal clmExit;
	AerodromeSlipstreamSwapAdapterV2 internal aeroSwap;
	ViaWethSellAdapterV2 internal viaWeth;
	IClmPoolDeployerV2 internal poolDeployer;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0 || !vm.exists(string.concat(OUT, 'ClmPoolDeployerV2.sol/ClmPoolDeployerV2.json'))) return;
		vm.createSelectFork(rpc, FORK_BLOCK);
		ready = true;
		address[] memory mstrHolders = new address[](1);
		mstrHolders[0] = AERO_POOL_MSTRC_USDC;
		_standIn(MSTRC, mstrHolders);
		feed = ClmVaultPriceFeed(vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-clm-funds.json'), '.feed'));

		vm.etch(QUEUE, type(RedemptionQueueV2ShortDeadline).runtimeCode);
		vm.prank(DEPLOYER);
		queue.setKeeper(keeper, true);

		// funds-yield DeployClmV2: v2 on v1's factory, then one Aero pool through ClmPoolDeployerV2
		address implementation = vm.deployCode(string.concat(OUT, 'FrostyClmStrategyV2.sol/FrostyClmStrategyV2.json'));
		poolDeployer = IClmPoolDeployerV2(vm.deployCode(
			string.concat(OUT, 'ClmPoolDeployerV2.sol/ClmPoolDeployerV2.json'), abi.encode(STRATEGY_FACTORY, VAULT_FACTORY, address(this))
		));
		string memory name = poolDeployer.STRATEGY_NAME();
		vm.prank(DEPLOYER);
		IClmStrategyFactoryLike(STRATEGY_FACTORY).addStrategy(name, implementation);
		(, clmVault) = poolDeployer.deployPool(ClmPoolConfigV2({
			compoundToken: USDC, maxTickDeviation: 5, pool: AERO_POOL_WETH_USDC, positionWidth: 20, symbol: 'USDC-WETH', twapInterval: 120
		}));

		// ListClmVaults (CLM_BOOK = the v2 book) and DeployAeroAdapters, as the deployer
		address[] memory vaults = new address[](1);
		vaults[0] = clmVault;
		vm.startPrank(DEPLOYER);
		ClmFundsDeploy.listUnpriced(feed, vaults);
		DeployAeroAdapters.Adapters memory deployed = new DeployAeroAdapters().deployAdapters(DEPLOYER);
		(clmExit, aeroSwap, viaWeth) = (deployed.clmExit, deployed.aeroSwap, deployed.viaWeth);
		factory.registerAdapter(address(clmExit));
		factory.registerAdapter(address(aeroSwap));
		factory.registerAdapter(address(viaWeth));
		vm.stopPrank();
	}

	function test_feed_pricesAV2VaultAsAWithdrawalPays() public {
		vm.skip(!ready);
		assertTrue(vi.isSupportedAsset(clmVault), 'listed like a v1 vault');
		(ComptrollerV6 fund, uint256 shares) = _fundInTheVault();
		(uint256 weth, uint256 usdc) = IClmVaultPreview(clmVault).previewWithdraw(shares);
		uint256 withdrawalUsd = usdc + vi.calcCanonicalAssetValue(WETH, weth, USDC);
		uint256 feedUsd = vi.calcCanonicalAssetValue(clmVault, shares, USDC);
		assertApproxEqRel(feedUsd, withdrawalUsd, 0.005e18, 'the feed values the shares at what they pay out');
		assertGt(fund.calcGav(), 19_500e6, 'the fund is still worth its deposit');
	}

	function test_keeper_exitsAnOverdueFundsV2SharesThroughAero_andTheLeaverIsPaidInUsdc() public {
		vm.skip(!ready);
		(ComptrollerV6 fund, uint256 clmShares) = _fundInTheVault();
		address fundVault = address(fund.vault());

		uint256 leaving = fund.shares().balanceOf(investor) / 2;
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(QUEUE, leaving);
		queue.requestRedeem(address(fund), leaving);
		vm.stopPrank();
		skip(2);
		vm.roll(block.number + 1);
		assertTrue(queue.isOverdue(address(fund)));

		uint256 gavBefore = fund.calcGav();
		ClmVaultExitAdapter.Route[] memory routes = new ClmVaultExitAdapter.Route[](1);
		routes[0] = ClmVaultExitAdapter.Route(clmExit.router1(), abi.encodePacked(WETH, int24(50), USDC)); // Aero's router
		vm.prank(keeper);
		queue.liquidate(address(fund), address(clmExit), abi.encode(uint8(2), clmVault, clmShares, uint256(0), USDC, routes));
		assertEq(IERC20(clmVault).balanceOf(fundVault), 0, 'every vault share exited');
		assertEq(IERC20(WETH).balanceOf(address(clmExit)), 0, 'nothing left in the adapter');
		uint256 gavAfter = fund.calcGav();
		emit log_named_uint('exit cost vs oracle value (USDC, 6 decimals)', gavBefore - gavAfter);
		assertGt(gavAfter, gavBefore * 9_970 / 10_000, 'well inside the 3% cap');

		uint256 supply = fund.shares().totalSupply();
		vm.prank(keeper);
		assertEq(queue.settle(address(fund), 1), 1);
		assertApproxEqAbs(IERC20(USDC).balanceOf(investor), gavAfter * leaving / supply, 2, 'paid in USDC');
	}

	function test_exit_refusesARouterItWasntGiven() public {
		vm.skip(!ready);
		(ComptrollerV6 fund, uint256 clmShares) = _fundInTheVault();
		uint256 leaving = fund.shares().balanceOf(investor) / 2;
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(QUEUE, leaving);
		queue.requestRedeem(address(fund), leaving);
		vm.stopPrank();
		skip(2);
		vm.roll(block.number + 1);
		ClmVaultExitAdapter.Route[] memory routes = new ClmVaultExitAdapter.Route[](1);
		routes[0] = ClmVaultExitAdapter.Route(ClmFundsDeploy.SLIPSTREAM3_ROUTER, abi.encodePacked(WETH, int24(100), USDC));
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(ClmVaultExitAdapter.NotARouter.selector, ClmFundsDeploy.SLIPSTREAM3_ROUTER));
		queue.liquidate(address(fund), address(clmExit), abi.encode(uint8(2), clmVault, clmShares, uint256(0), USDC, routes));
	}

	function test_aeroSwap_aManagerBuysOnAerosPool_andTheKeeperSellsThereForAnOverdueLeaver() public {
		vm.skip(!ready);
		ComptrollerV6 fund = _fundWithUsdc();
		address fundVault = address(fund.vault());
		uint256 treasuryBefore = IERC20(USDC).balanceOf(V4Pricing.TREASURY);
		uint256 gavBefore = fund.calcGav();

		vm.prank(manager);
		fund.callOnIntegration(address(aeroSwap), abi.encode(USDC, WETH, int24(50), uint256(10_000e6), uint256(1)));
		uint256 weth = IERC20(WETH).balanceOf(fundVault);
		assertGt(weth, 0, 'the vault got WETH from Aero\'s pool');
		assertEq(IERC20(USDC).balanceOf(V4Pricing.TREASURY) - treasuryBefore, 5e6, '5 bps of 10,000 USDC to the Treasury');
		uint256 gavAfterBuy = fund.calcGav();
		emit log_named_uint('buy cost vs oracle value (USDC, 6 decimals)', gavBefore - gavAfterBuy);
		assertGt(gavAfterBuy, gavBefore * 9_950 / 10_000, 'a 10k buy costs under 0.5% on Aero');

		uint256 leaving = fund.shares().balanceOf(investor) * 3 / 4; // more than the 10,000 USDC left
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(QUEUE, leaving);
		queue.requestRedeem(address(fund), leaving);
		vm.stopPrank();
		skip(2);
		vm.roll(block.number + 1);
		assertTrue(queue.isOverdue(address(fund)));

		vm.prank(keeper);
		queue.liquidate(address(fund), address(aeroSwap), abi.encode(WETH, USDC, int24(50), weth, uint256(0)));
		assertEq(IERC20(WETH).balanceOf(fundVault), 0, 'the WETH sold on Aero');
		assertGt(fund.calcGav(), gavAfterBuy * 9_970 / 10_000, 'well inside the 3% cap');
		vm.prank(keeper);
		assertEq(queue.settle(address(fund), 1), 1, 'the leaver is paid');
	}

	function test_viaWethV2_theKeeperSellsCbEthThroughWethOnAero_andTheLeaverIsPaid() public {
		vm.skip(!ready);
		ComptrollerV6 fund = _fundWithUsdc();
		address fundVault = address(fund.vault());
		// the manager buys cbETH on Aero: USDC → WETH, then WETH → cbETH
		vm.startPrank(manager);
		fund.callOnIntegration(address(aeroSwap), abi.encode(USDC, WETH, int24(50), uint256(10_000e6), uint256(1)));
		fund.callOnIntegration(address(aeroSwap), abi.encode(WETH, CBETH, int24(1), IERC20(WETH).balanceOf(fundVault), uint256(1)));
		vm.stopPrank();
		uint256 cbeth = IERC20(CBETH).balanceOf(fundVault);
		assertGt(cbeth, 0);
		assertEq(IERC20(WETH).balanceOf(fundVault), 0);

		uint256 leaving = fund.shares().balanceOf(investor) * 3 / 4; // more than the 10,000 USDC left
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(QUEUE, leaving);
		queue.requestRedeem(address(fund), leaving);
		vm.stopPrank();
		skip(2);
		vm.roll(block.number + 1);

		uint256 gavBefore = fund.calcGav();
		uint256 treasuryBefore = IERC20(CBETH).balanceOf(V4Pricing.TREASURY);
		ViaWethSellAdapterV2.Hop memory toWeth = ViaWethSellAdapterV2.Hop(ViaWethSellAdapterV2.Venue.Aero, 1);
		ViaWethSellAdapterV2.Hop memory fromWeth = ViaWethSellAdapterV2.Hop(ViaWethSellAdapterV2.Venue.Aero, 50);
		vm.prank(keeper);
		queue.liquidate(address(fund), address(viaWeth), abi.encode(CBETH, cbeth, uint256(0), USDC, toWeth, fromWeth));
		assertEq(IERC20(CBETH).balanceOf(fundVault), 0, 'every cbETH sold');
		assertEq(IERC20(WETH).balanceOf(address(viaWeth)), 0, 'nothing left in the adapter');
		assertEq(IERC20(CBETH).balanceOf(V4Pricing.TREASURY) - treasuryBefore, cbeth * 5 / 10_000, '5 bps, once');
		uint256 gavAfter = fund.calcGav();
		emit log_named_uint('sale cost vs oracle value (USDC, 6 decimals)', gavBefore - gavAfter);
		assertGt(gavAfter, gavBefore * 9_970 / 10_000, 'well inside the 3% cap');
		vm.prank(keeper);
		assertEq(queue.settle(address(fund), 1), 1, 'the leaver is paid');
	}

	// ─── a stock: MSTRc ─────────────────────────────────────────────────────────────────────────────────────────────

	function test_mstrc_aManagerBuysOnAero_andTheKeeperSellsThereForAnOverdueLeaver() public {
		vm.skip(!ready);
		ComptrollerV6 fund = _fundWithUsdc();
		address fundVault = address(fund.vault());
		_assertTheLiveTokenLets([fundVault, address(aeroSwap), address(aeroSwap.router()), AERO_POOL_MSTRC_USDC]);
		uint256 gavBefore = fund.calcGav();

		vm.prank(manager);
		fund.callOnIntegration(address(aeroSwap), abi.encode(USDC, MSTRC, int24(10), uint256(10_000e6), uint256(1)));
		uint256 mstr = IERC20(MSTRC).balanceOf(fundVault);
		assertGt(mstr, 0, 'the vault got MSTRc from Aero\'s pool');
		uint256 gavAfterBuy = fund.calcGav();
		emit log_named_int('MSTRc buy: GAV change at Friday\'s close (USDC, 6 dp)', int256(gavAfterBuy) - int256(gavBefore));
		assertGt(gavAfterBuy, gavBefore * 9_970 / 10_000, 'the pool trades close enough to the feed to sell it back');

		uint256 leaving = fund.shares().balanceOf(investor) * 3 / 4; // more than the 10,000 USDC left
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(QUEUE, leaving);
		queue.requestRedeem(address(fund), leaving);
		vm.stopPrank();
		skip(2);
		vm.roll(block.number + 1);

		vm.prank(keeper);
		queue.liquidate(address(fund), address(aeroSwap), abi.encode(MSTRC, USDC, int24(10), mstr, uint256(0)));
		assertEq(IERC20(MSTRC).balanceOf(fundVault), 0, 'the MSTRc sold on Aero');
		emit log_named_int('MSTRc sale: GAV change at Friday\'s close (USDC, 6 dp)', int256(fund.calcGav()) - int256(gavAfterBuy));
		vm.prank(keeper);
		assertEq(queue.settle(address(fund), 1), 1, 'the leaver is paid');
	}

	function test_mstrcVault_listedAndPriced_aFundDeposits_andTheKeeperExitsItThroughAero() public {
		vm.skip(!ready);
		(address strategy, address mstrVault) = _listedMstrVault();
		(ComptrollerV6 fund, uint256 shares) = _fundInMstrVault(mstrVault, strategy);
		(uint256 usdc, uint256 mstrOut) = IClmVaultPreview(mstrVault).previewWithdraw(shares);
		uint256 withdrawalUsd = usdc + vi.calcCanonicalAssetValue(MSTRC, mstrOut, USDC);
		assertApproxEqRel(vi.calcCanonicalAssetValue(mstrVault, shares, USDC), withdrawalUsd, 0.005e18, 'priced at what it pays out');

		uint256 leaving = fund.shares().balanceOf(investor) / 2;
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(QUEUE, leaving);
		queue.requestRedeem(address(fund), leaving);
		vm.stopPrank();
		skip(2);
		vm.roll(block.number + 1);

		uint256 gavBefore = fund.calcGav();
		_exitMstrVault(fund, mstrVault, shares);
		uint256 gavAfter = fund.calcGav();
		emit log_named_int('MSTRc vault exit: GAV change at Friday\'s close (USDC, 6 dp)', int256(gavAfter) - int256(gavBefore));
		uint256 supply = fund.shares().totalSupply();
		vm.prank(keeper);
		assertEq(queue.settle(address(fund), 1), 1);
		assertApproxEqAbs(IERC20(USDC).balanceOf(investor), gavAfter * leaving / supply, 2, 'paid in USDC');
	}

	/// @dev The USDC-MSTRc v2 vault, as funds-yield script/config/base-mainnet-pools-v2.json's entry deploys it
	///      (funds-yield's DeployClmV2Fork runs every entry of that file), listed on the live ClmVaultPriceFeed.
	function _listedMstrVault() internal returns (address strategy, address mstrVault) {
		(strategy, mstrVault) = poolDeployer.deployPool(ClmPoolConfigV2({
			compoundToken: USDC, maxTickDeviation: 9, pool: AERO_POOL_MSTRC_USDC, positionWidth: 50, symbol: 'USDC-MSTRc', twapInterval: 120
		}));
		address[] memory vaults = new address[](1);
		vaults[0] = mstrVault;
		vm.startPrank(DEPLOYER);
		ClmFundsDeploy.listUnpriced(feed, vaults); // ClmVaultPriceFeed._oracleFed: MSTRc is on its Chainlink feed
		vm.stopPrank();
		assertTrue(vi.isSupportedAsset(mstrVault), 'listed like the crypto vaults');
	}

	/// @dev A live v6 fund buys MSTRc on Aero with 9,000 USDC and puts it all, with 9,000 USDC, in the vault.
	function _fundInMstrVault(address mstrVault, address strategy) internal returns (ComptrollerV6 fund, uint256 shares) {
		fund = _fundWithUsdc();
		address fundVault = address(fund.vault());
		_assertTheLiveTokenLets([fundVault, CLM_ADAPTER, strategy, AERO_NFT_MANAGER]);
		_assertTheLiveTokenLets([mstrVault, address(clmExit), clmExit.router1(), AERO_POOL_MSTRC_USDC]);
		vm.startPrank(manager);
		fund.callOnIntegration(address(aeroSwap), abi.encode(USDC, MSTRC, int24(10), uint256(9_000e6), uint256(1)));
		uint256 mstr = IERC20(MSTRC).balanceOf(fundVault);
		(uint256 preview,,,,) = IClmVaultPreview(mstrVault).previewDeposit(9_000e6, mstr);
		fund.callOnIntegration(CLM_ADAPTER, abi.encode(uint8(0), mstrVault, uint256(9_000e6), mstr, preview * 99 / 100));
		vm.stopPrank();
		shares = IERC20(mstrVault).balanceOf(fundVault);
		assertGt(shares, 0);
		skip(121); // the vault's TWAP window
		vm.roll(block.number + 1);
	}

	/// @dev The keeper exits all of the fund's vault shares into USDC, selling the MSTRc on Aero's router.
	function _exitMstrVault(ComptrollerV6 fund, address mstrVault, uint256 shares) internal {
		ClmVaultExitAdapter.Route[] memory routes = new ClmVaultExitAdapter.Route[](1);
		routes[0] = ClmVaultExitAdapter.Route(clmExit.router1(), abi.encodePacked(MSTRC, int24(10), USDC)); // Aero's router
		vm.prank(keeper);
		queue.liquidate(address(fund), address(clmExit), abi.encode(uint8(2), mstrVault, shares, uint256(0), USDC, routes));
		address fundVault = address(fund.vault());
		assertEq(IERC20(mstrVault).balanceOf(fundVault), 0, 'every vault share exited');
		assertEq(IERC20(MSTRC).balanceOf(fundVault), 0, 'its MSTRc sold, not left in the vault');
		assertEq(IERC20(MSTRC).balanceOf(address(clmExit)), 0, 'nothing left in the adapter');
	}

	// ─── helpers ────────────────────────────────────────────────────────────────────────────────────────────────────

	/// @dev The real MSTRc, on Base at the fork block, lets each of these send, receive and move it.
	function _assertTheLiveTokenLets(address[4] memory movers) internal {
		for (uint256 i; i < movers.length; ++i) {
			assertTrue(_b20Allows(MSTRC, movers[i]), string.concat('the live MSTRc blocks ', vm.toString(movers[i])));
		}
	}


	/// @dev A live v6 fund with 20,000 USDC: the manager buys WETH on Uniswap with 9,000 and puts it all, with 9,000
	///      USDC, in the v2 vault (its first deposit takes both). Returns the fund's vault shares.
	function _fundInTheVault() internal returns (ComptrollerV6 fund, uint256 clmShares) {
		fund = _fundWithUsdc();
		address fundVault = address(fund.vault());
		vm.prank(manager);
		fund.callOnIntegration(UNI_ADAPTER, abi.encode(USDC, WETH, uint24(500), uint256(9_000e6), uint256(1)));
		uint256 weth = IERC20(WETH).balanceOf(fundVault);
		(uint256 preview,,,,) = IClmVaultPreview(clmVault).previewDeposit(weth, 9_000e6);
		vm.prank(manager);
		fund.callOnIntegration(CLM_ADAPTER, abi.encode(uint8(0), clmVault, weth, uint256(9_000e6), preview * 99 / 100));
		clmShares = IERC20(clmVault).balanceOf(fundVault);
		assertGt(clmShares, 0);
		skip(121); // the vault's TWAP window: calm for the exit
		vm.roll(block.number + 1);
	}

	/// @dev A live v6 fund holding the investor's 20,000 USDC.
	function _fundWithUsdc() internal returns (ComptrollerV6 fund) {
		vm.prank(manager);
		fund = ComptrollerV6(factory.createFund(FundFactory.FundConfig({
			name: 'CLM v2 on Aero',
			symbol: 'frV2A',
			denominationAsset: IERC20(USDC),
			fundOwner: manager,
			mgmtScaledPerSecondRate: 0,
			perfFeeBps: 0,
			sharesActionTimelock: 0,
			minRequestDuration: 1 minutes,
			executionWindow: 1 days,
			allowRiskyAssets: false
		})));
		deal(USDC, investor, 20_000e6);
		vm.startPrank(investor);
		IERC20(USDC).approve(address(fund), 20_000e6);
		fund.requestDeposit(20_000e6, type(uint256).max);
		vm.stopPrank();
		skip(1 minutes);
		vm.roll(block.number + 30);
		fund.executeDepositRequest(investor);
	}
}
