// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {RedemptionQueue} from '../../src/redemption/RedemptionQueue.sol';
import {ClmVaultExitAdapter} from '../../src/adapters/ClmVaultExitAdapter.sol';
import {AerodromeSlipstreamSwapAdapter} from '../../src/adapters/AerodromeSlipstreamSwapAdapter.sol';
import {ViaWethSellAdapter} from '../../src/adapters/ViaWethSellAdapter.sol';
import {IFrostyClmVault} from '../../src/interfaces/external/IFrostyClm.sol';
import {IValueInterpreter} from '../../src/interfaces/IValueInterpreter.sol';
import {BaseMainnet} from '../../script/release/BaseMainnet.sol';
import {B20Mirror, B20StandIn} from '../utils/B20Mirror.sol';
import {ReleaseFork} from './utils/ReleaseFork.sol';

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

/// @notice CLM v2 on Aero (FrostyFi 2026-10-25) with the release, on Base after the Aero upgrade: v2 added to the live
///         strategy factory and a USDC-WETH vault on Aero's pool (funds-yield, from ../funds-yield/out), listed on the
///         release's ClmVaultPriceFeed, which must price it as a withdrawal pays; a fund buys WETH and deposits through the
///         release's ClmVaultAdapter; and once its leaver is overdue the keeper exits the vault shares into USDC through
///         the release's ClmVaultExitAdapter, selling WETH on Aero's router. The release's Aero spot adapter trades on
///         Aero's pool for a manager and sells for the keeper, and its ViaWethSellAdapter sells a WETH-paired
///         token (cbETH) through WETH on Aero's pools. The same flows run on a stock, MSTRc (B20: Base's node runs it, Foundry
///         can't), against a stand-in holding the Aero pool's real reserves (B20Mirror._standIn), with the real token's
///         transfer rules read from Base for every contract that moves it; the fork block is a Sunday, so the stock's
///         Chainlink feed holds Friday's close while the pool trades. MSTRc and cbETH are listed with the feeds the live VI
///         used at the block; a 1-second deadline queue.
///         Run: (cd ../funds-yield && forge build) && BASE_MAINNET_RPC=<archive url> forge test --match-contract ClmV2AeroLiquidationFork -vv
contract ClmV2AeroLiquidationForkTest is ReleaseFork, B20Mirror {
	string internal constant OUT = '../funds-yield/out/';
	address internal constant DEPLOYER = 0xaE51f2EfE70e57b994BE8F7f97C4dC824c51802a; // the live CLM factories' owner
	address internal constant AERO_POOL_WETH_USDC = 0x4A7af46bC8aBc00048c6c7920a1488DAF568366c; // WETH token0, tick spacing 50
	address internal constant CBETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22; // Aero cbETH/WETH: tick spacing 1
	address internal constant MSTRC = 0xb2000000000000000000004884b426556b92883d; // B20, 8 decimals, Chainlink-priced
	address internal constant AERO_POOL_MSTRC_USDC = 0x66DCd42E6314B287110922AE36cB2a8bdEECc153; // USDC token0, tick spacing 10
	address internal constant AERO_NFT_MANAGER = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
	address internal constant STRATEGY_FACTORY = BaseMainnet.CLM_STRATEGY_FACTORY; // funds-yield base-mainnet-clm-v2.json
	address internal constant VAULT_FACTORY = 0x13a4FD7dD96D01BA22bddF8e3D8B56b81c073C74;

	bool internal ready;
	IValueInterpreter internal vi;
	RedemptionQueue internal queue;
	address internal clmVault;
	ClmVaultExitAdapter internal clmExit;
	AerodromeSlipstreamSwapAdapter internal aeroSwap;
	ViaWethSellAdapter internal viaWeth;
	address internal uniAdapter;
	address internal clmAdapter;
	IClmPoolDeployerV2 internal poolDeployer;

	/// @dev 2026-10-25, three days after the Aero upgrade (a Sunday).
	function _forkBlock() internal pure override returns (uint256) {
		return 53_075_000;
	}

	function setUp() public override {
		if (!vm.exists(string.concat(OUT, 'ClmPoolDeployerV2.sol/ClmPoolDeployerV2.json'))) return;
		super.setUp();
		if (!forked) return;
		ready = true;
		address[] memory mstrHolders = new address[](1);
		mstrHolders[0] = AERO_POOL_MSTRC_USDC;
		_standIn(MSTRC, mstrHolders);
		_copyFeed(MSTRC);
		_copyFeed(CBETH);
		vi = r.valueInterpreter;
		queue = _shortDeadlineQueue();
		(clmExit, aeroSwap, viaWeth) = (r.adapters.clmExit, r.adapters.aero, r.adapters.viaWeth);
		uniAdapter = address(r.adapters.uniswapV3);
		clmAdapter = address(r.adapters.clm);

		// funds-yield DeployClmV2: v2 on the live factory, then one Aero pool through ClmPoolDeployerV2
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
		_listDerivative(clmVault, address(r.clmFeed));
	}

	function test_feed_pricesAV2VaultAsAWithdrawalPays() public {
		vm.skip(!ready);
		assertTrue(vi.isSupportedAsset(clmVault), 'listed like a v1 vault');
		(Comptroller fund, uint256 shares) = _fundInTheVault();
		(uint256 weth, uint256 usdc) = IClmVaultPreview(clmVault).previewWithdraw(shares);
		uint256 withdrawalUsd = usdc + vi.calcCanonicalAssetValue(WETH, weth, USDC);
		uint256 feedUsd = vi.calcCanonicalAssetValue(clmVault, shares, USDC);
		assertApproxEqRel(feedUsd, withdrawalUsd, 0.005e18, 'the feed values the shares at what they pay out');
		assertGt(fund.calcGav(), 19_500e6, 'the fund is still worth its deposit');
	}

	function test_keeper_exitsAnOverdueFundsV2SharesThroughAero_andTheLeaverIsPaidInUsdc() public {
		vm.skip(!ready);
		(Comptroller fund, uint256 clmShares) = _fundInTheVault();
		address fundVault = address(fund.vault());

		uint256 leaving = fund.shares().balanceOf(investor) / 2;
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(address(queue), leaving);
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
		(Comptroller fund, uint256 clmShares) = _fundInTheVault();
		uint256 leaving = fund.shares().balanceOf(investor) / 2;
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(address(queue), leaving);
		queue.requestRedeem(address(fund), leaving);
		vm.stopPrank();
		skip(2);
		vm.roll(block.number + 1);
		ClmVaultExitAdapter.Route[] memory routes = new ClmVaultExitAdapter.Route[](1);
		routes[0] = ClmVaultExitAdapter.Route(BaseMainnet.CL3_SWAP_ROUTER, abi.encodePacked(WETH, int24(100), USDC));
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(ClmVaultExitAdapter.NotARouter.selector, BaseMainnet.CL3_SWAP_ROUTER));
		queue.liquidate(address(fund), address(clmExit), abi.encode(uint8(2), clmVault, clmShares, uint256(0), USDC, routes));
	}

	function test_aeroSwap_aManagerBuysOnAerosPool_andTheKeeperSellsThereForAnOverdueLeaver() public {
		vm.skip(!ready);
		Comptroller fund = _fundWithUsdc();
		address fundVault = address(fund.vault());
		uint256 treasuryBefore = IERC20(USDC).balanceOf(BaseMainnet.TREASURY);
		uint256 gavBefore = fund.calcGav();

		vm.prank(manager);
		fund.callOnIntegration(address(aeroSwap), abi.encode(USDC, WETH, int24(50), uint256(10_000e6), uint256(1), uint256(0)));
		uint256 weth = IERC20(WETH).balanceOf(fundVault);
		assertGt(weth, 0, 'the vault got WETH from Aero\'s pool');
		assertEq(IERC20(USDC).balanceOf(BaseMainnet.TREASURY) - treasuryBefore, 5e6, '5 bps of 10,000 USDC to the Treasury');
		uint256 gavAfterBuy = fund.calcGav();
		emit log_named_uint('buy cost vs oracle value (USDC, 6 decimals)', gavBefore - gavAfterBuy);
		assertGt(gavAfterBuy, gavBefore * 9_950 / 10_000, 'a 10k buy costs under 0.5% on Aero');

		uint256 leaving = fund.shares().balanceOf(investor) * 3 / 4; // more than the 10,000 USDC left
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(address(queue), leaving);
		queue.requestRedeem(address(fund), leaving);
		vm.stopPrank();
		skip(2);
		vm.roll(block.number + 1);
		assertTrue(queue.isOverdue(address(fund)));

		vm.prank(keeper);
		queue.liquidate(address(fund), address(aeroSwap), abi.encode(WETH, USDC, int24(50), weth, uint256(0), uint256(0)));
		assertEq(IERC20(WETH).balanceOf(fundVault), 0, 'the WETH sold on Aero');
		assertGt(fund.calcGav(), gavAfterBuy * 9_970 / 10_000, 'well inside the 3% cap');
		vm.prank(keeper);
		assertEq(queue.settle(address(fund), 1), 1, 'the leaver is paid');
	}

	function test_viaWeth_theKeeperSellsCbEthThroughWethOnAero_andTheLeaverIsPaid() public {
		vm.skip(!ready);
		Comptroller fund = _fundWithUsdc();
		address fundVault = address(fund.vault());
		// the manager buys cbETH on Aero: USDC → WETH, then WETH → cbETH
		vm.startPrank(manager);
		fund.callOnIntegration(address(aeroSwap), abi.encode(USDC, WETH, int24(50), uint256(10_000e6), uint256(1), uint256(0)));
		fund.callOnIntegration(address(aeroSwap), abi.encode(WETH, CBETH, int24(1), IERC20(WETH).balanceOf(fundVault), uint256(1), uint256(0)));
		vm.stopPrank();
		uint256 cbeth = IERC20(CBETH).balanceOf(fundVault);
		assertGt(cbeth, 0);
		assertEq(IERC20(WETH).balanceOf(fundVault), 0);

		uint256 leaving = fund.shares().balanceOf(investor) * 3 / 4; // more than the 10,000 USDC left
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(address(queue), leaving);
		queue.requestRedeem(address(fund), leaving);
		vm.stopPrank();
		skip(2);
		vm.roll(block.number + 1);

		uint256 gavBefore = fund.calcGav();
		uint256 treasuryBefore = IERC20(CBETH).balanceOf(BaseMainnet.TREASURY);
		ViaWethSellAdapter.Hop memory toWeth = ViaWethSellAdapter.Hop(ViaWethSellAdapter.Venue.Aero, 1);
		ViaWethSellAdapter.Hop memory fromWeth = ViaWethSellAdapter.Hop(ViaWethSellAdapter.Venue.Aero, 50);
		vm.prank(keeper);
		queue.liquidate(address(fund), address(viaWeth), abi.encode(CBETH, cbeth, uint256(0), USDC, toWeth, fromWeth));
		assertEq(IERC20(CBETH).balanceOf(fundVault), 0, 'every cbETH sold');
		assertEq(IERC20(WETH).balanceOf(address(viaWeth)), 0, 'nothing left in the adapter');
		assertEq(IERC20(CBETH).balanceOf(BaseMainnet.TREASURY) - treasuryBefore, cbeth * 5 / 10_000, '5 bps, once');
		uint256 gavAfter = fund.calcGav();
		emit log_named_uint('sale cost vs oracle value (USDC, 6 decimals)', gavBefore - gavAfter);
		assertGt(gavAfter, gavBefore * 9_970 / 10_000, 'well inside the 3% cap');
		vm.prank(keeper);
		assertEq(queue.settle(address(fund), 1), 1, 'the leaver is paid');
	}

	// ─── a stock: MSTRc ─────────────────────────────────────────────────────────────────────────────────────────────

	function test_mstrc_aManagerBuysOnAero_andTheKeeperSellsThereForAnOverdueLeaver() public {
		vm.skip(!ready);
		Comptroller fund = _fundWithUsdc();
		address fundVault = address(fund.vault());
		_assertTheLiveTokenLets([fundVault, address(aeroSwap), address(aeroSwap.router()), AERO_POOL_MSTRC_USDC]);
		uint256 gavBefore = fund.calcGav();

		vm.prank(manager);
		fund.callOnIntegration(address(aeroSwap), abi.encode(USDC, MSTRC, int24(10), uint256(10_000e6), uint256(1), uint256(0)));
		uint256 mstr = IERC20(MSTRC).balanceOf(fundVault);
		assertGt(mstr, 0, 'the vault got MSTRc from Aero\'s pool');
		uint256 gavAfterBuy = fund.calcGav();
		emit log_named_int('MSTRc buy: GAV change at Friday\'s close (USDC, 6 dp)', int256(gavAfterBuy) - int256(gavBefore));
		assertGt(gavAfterBuy, gavBefore * 9_970 / 10_000, 'the pool trades close enough to the feed to sell it back');

		uint256 leaving = fund.shares().balanceOf(investor) * 3 / 4; // more than the 10,000 USDC left
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(address(queue), leaving);
		queue.requestRedeem(address(fund), leaving);
		vm.stopPrank();
		skip(2);
		vm.roll(block.number + 1);

		vm.prank(keeper);
		queue.liquidate(address(fund), address(aeroSwap), abi.encode(MSTRC, USDC, int24(10), mstr, uint256(0), uint256(0)));
		assertEq(IERC20(MSTRC).balanceOf(fundVault), 0, 'the MSTRc sold on Aero');
		emit log_named_int('MSTRc sale: GAV change at Friday\'s close (USDC, 6 dp)', int256(fund.calcGav()) - int256(gavAfterBuy));
		vm.prank(keeper);
		assertEq(queue.settle(address(fund), 1), 1, 'the leaver is paid');
	}

	function test_mstrcVault_listedAndPriced_aFundDeposits_andTheKeeperExitsItThroughAero() public {
		vm.skip(!ready);
		(address strategy, address mstrVault) = _listedMstrVault();
		(Comptroller fund, uint256 shares) = _fundInMstrVault(mstrVault, strategy);
		(uint256 usdc, uint256 mstrOut) = IClmVaultPreview(mstrVault).previewWithdraw(shares);
		uint256 withdrawalUsd = usdc + vi.calcCanonicalAssetValue(MSTRC, mstrOut, USDC);
		assertApproxEqRel(vi.calcCanonicalAssetValue(mstrVault, shares, USDC), withdrawalUsd, 0.005e18, 'priced at what it pays out');

		uint256 leaving = fund.shares().balanceOf(investor) / 2;
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(address(queue), leaving);
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
	///      (funds-yield's DeployClmV2Fork runs every entry of that file), listed on the release's ClmVaultPriceFeed.
	function _listedMstrVault() internal returns (address strategy, address mstrVault) {
		(strategy, mstrVault) = poolDeployer.deployPool(ClmPoolConfigV2({
			compoundToken: USDC, maxTickDeviation: 9, pool: AERO_POOL_MSTRC_USDC, positionWidth: 50, symbol: 'USDC-MSTRc', twapInterval: 120
		}));
		_listDerivative(mstrVault, address(r.clmFeed)); // ClmVaultPriceFeed._oracleFed: MSTRc is on its Chainlink feed
		assertTrue(vi.isSupportedAsset(mstrVault), 'listed like the crypto vaults');
	}

	/// @dev A fund buys MSTRc on Aero with 9,000 USDC and puts it all, with 9,000 USDC, in the vault.
	function _fundInMstrVault(address mstrVault, address strategy) internal returns (Comptroller fund, uint256 shares) {
		fund = _fundWithUsdc();
		address fundVault = address(fund.vault());
		_assertTheLiveTokenLets([fundVault, clmAdapter, strategy, AERO_NFT_MANAGER]);
		_assertTheLiveTokenLets([mstrVault, address(clmExit), clmExit.router1(), AERO_POOL_MSTRC_USDC]);
		vm.startPrank(manager);
		fund.callOnIntegration(address(aeroSwap), abi.encode(USDC, MSTRC, int24(10), uint256(9_000e6), uint256(1), uint256(0)));
		uint256 mstr = IERC20(MSTRC).balanceOf(fundVault);
		(uint256 preview,,,,) = IClmVaultPreview(mstrVault).previewDeposit(9_000e6, mstr);
		fund.callOnIntegration(clmAdapter, abi.encode(uint8(0), mstrVault, uint256(9_000e6), mstr, preview * 99 / 100));
		vm.stopPrank();
		shares = IERC20(mstrVault).balanceOf(fundVault);
		assertGt(shares, 0);
		skip(121); // the vault's TWAP window
		vm.roll(block.number + 1);
	}

	/// @dev The keeper exits all of the fund's vault shares into USDC, selling the MSTRc on Aero's router.
	function _exitMstrVault(Comptroller fund, address mstrVault, uint256 shares) internal {
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
	function _fundInTheVault() internal returns (Comptroller fund, uint256 clmShares) {
		fund = _fundWithUsdc();
		address fundVault = address(fund.vault());
		vm.prank(manager);
		fund.callOnIntegration(uniAdapter, abi.encode(USDC, WETH, uint24(500), uint256(9_000e6), uint256(1)));
		uint256 weth = IERC20(WETH).balanceOf(fundVault);
		(uint256 preview,,,,) = IClmVaultPreview(clmVault).previewDeposit(weth, 9_000e6);
		vm.prank(manager);
		fund.callOnIntegration(clmAdapter, abi.encode(uint8(0), clmVault, weth, uint256(9_000e6), preview * 99 / 100));
		clmShares = IERC20(clmVault).balanceOf(fundVault);
		assertGt(clmShares, 0);
		skip(121); // the vault's TWAP window: calm for the exit
		vm.roll(block.number + 1);
	}

	/// @dev A fund holding the investor's 20,000 USDC.
	function _fundWithUsdc() internal returns (Comptroller fund) {
		fund = _fundWithDeposit(20_000e6);
	}
}
