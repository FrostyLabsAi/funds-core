// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {console} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {ComptrollerLib} from '../../src/core/ComptrollerLib.sol';
import {IComptroller} from '../../src/interfaces/IComptroller.sol';
import {IIntegrationAdapter} from '../../src/interfaces/IIntegrationAdapter.sol';
import {AggregatorV3Interface} from '../../src/interfaces/AggregatorV3Interface.sol';
import {IV4PoolManager, IV4StateView, PoolKey, PoolKeyId} from '../../src/interfaces/external/IUniswapV4.sol';
import {TickMath} from '../../src/libraries/TickMath.sol';
import {PoolPriceMath} from '../../src/libraries/PoolPriceMath.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {V4PoolPriceAdapter} from '../../src/pricing/V4PoolPriceAdapter.sol';
import {UniswapV4SwapAdapter} from '../../src/adapters/UniswapV4SwapAdapter.sol';
import {RedemptionQueue} from '../../src/redemption/RedemptionQueue.sol';
import {BaseMainnet} from '../../script/release/BaseMainnet.sol';
import {ReleaseListings} from '../../script/release/ReleaseListings.sol';
import {B20LocalStandIns} from '../../script/release/B20LocalStandIn.sol';
import {MockERC20} from '../utils/Mocks.sol';
import {ReleaseFork} from './utils/ReleaseFork.sol';
import {V4TestRouter} from './utils/V4TestRouter.sol';
import {IV4PoolSetup} from './utils/IV4PoolSetup.sol';
import {IDividendVault, IStockifyToken} from './utils/IStockify.sol';
import {IO1FeeEscrow} from './utils/IO1FeeEscrow.sol';
import {ISlipstreamSlot0} from './utils/ISlipstreamSlot0.sol';

/// @notice Uniswap v4 and memestocks (spec docs/superpowers/specs/2026-10-08-uniswap-v4-memestocks-design.md) on the
///         release, on a Base fork: setUp lists what these proofs price (the stock feeds today's VI used at the block,
///         the five stock quotes, the three hooks with the Treasury as o1's referrer, STFY's launch pool), then funds
///         trade STFY (StockifyFeeHook), o1 launches and stock-quoted tokens through the real PoolManager, pools and
///         hooks. Coinbase's B20 tokens (the stock tokens and every o1 launch token) are Base precompiles Foundry's EVM
///         can't run: where a proof moves one, the token's address gets a plain ERC-20's code and the balances it needs.
///         Everything else is live code. That a real B20 stock reaches a fund vault was checked on Base itself
///         (eth_call 2026-10-08: NVDAc, AAPLc, GOOGLc, METAC and SPCXc `transfer` from the DividendVault to
///         TestFund4's vault all return true).
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/UniswapV4Fork.t.sol -vv
contract UniswapV4ForkTest is ReleaseFork {
	/// @dev STFY's next hourly payout is 33 minutes after this block (cast 2026-10-08).
	uint256 internal constant V4_FORK_BLOCK = 52_345_288;

	address internal constant TREASURY = BaseMainnet.TREASURY;
	address internal constant POOL_MANAGER = BaseMainnet.UNI_V4_POOL_MANAGER;
	address internal constant STATE_VIEW = BaseMainnet.UNI_V4_STATE_VIEW;
	/// @dev The release's v4 pool approver (Release.Config.guardian).
	address internal constant SAFE = BaseMainnet.ADMIN_SAFE;
	address internal constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;

	/// @dev STFY / native ETH, fee 1%, tick spacing 200, StockifyFeeHook (3% of the ETH side to the DividendVault).
	address internal constant STFY = 0xC6405D7a226e1C18E559Be2F335F74C01Ad07bF5;
	bytes32 internal constant STFY_POOL_ID = 0xa6979745954ea4976d4c94a5957c225801de74b4ef6ab22d122854fb09405e06;
	address internal constant DIVIDEND_VAULT = 0x4Ee35c658b8032a7577096B60bd51Ae9909E4f98;
	/// @dev The DividendVault's index (stockAt 0–4, 20% each), all B20; each is a quote on the registrar.
	address internal constant AAPLC = 0xb200000000000000000000C2e324d24d7eEcd1fb;
	address internal constant GOOGLC = 0xb2000000000000000000002D0BA3164cc74f58B7;
	address internal constant METAC = 0xb2000000000000000000008bC8786B856E61707C;
	address internal constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C;
	address internal constant SPCXC = 0xb2000000000000000000007b9fcbd005511aCBd5;

	/// @dev o1 on its first LaunchHook: BLUECHIP / NVDAc (NVDAc is currency0), fee 0, tick spacing 200; base
	///      fee 1% split creator 50% / platform 30% / referrer 20%; launched 2026-08-21, anti-snipe long over.
	address internal constant BLUECHIP = 0xB200000000000000000000cFbdF64a8706a94a01;
	bytes32 internal constant BLUECHIP_POOL_ID = 0x41084f2d35b54dc0d070fbf76aa52c46f5d9c7e36c163252064b6b184d9429d9;
	address internal constant O1_ESCROW_1 = 0x1D8c991A9019df7D72ADCd8deA6f12D600C9d02f;
	/// @dev o1 on its second LaunchHook: "Jez" / native ETH, its busiest pool (2,152 trades in 60k blocks);
	///      base fee 1%, fee components creator 50 / platform 30 / referrer 20 (poolFeeComponents). Its escrow pays
	///      out with `claimFor`.
	address internal constant JEZ = 0xb2000000000000000000002927f6d5EeEfBbDA01;
	bytes32 internal constant JEZ_POOL_ID = 0xca21386ab9129812ad3c0971db5b3578c8cfe5060a956c53a8ca2eb8be2b1b04;
	address internal constant O1_ESCROW_2 = 0xB3F11a3fb06A88059b7F7F423Ec0Dda506356866;
	/// @dev NVDAc / USDC on Slipstream (the CL2 factory), tick spacing 10: step one of a stock-paired buy.
	address internal constant NVDAC_USDC_CL2 = 0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9;
	/// @dev ElonRWA / SPCXc on Slipstream (CL2), tick spacing 200: ≈ 334 SPCXc of full-range-equivalent depth but
	///      101.16 SPCXc actually in the pool (cast balanceOf at the fork block), ≈ $16.4k — under the $25k floor.
	address internal constant ELON_RWA = 0xAa6Cccdce193698D33deb9ffd4be74eAa74c4898;
	address internal constant ELON_SPCXC_CL2 = 0xfd616e10311Ac827FA953cA04f62Fb2B054d8Da6;
	uint256 internal constant ELON_POOL_SPCXC = 10_115_582_440;
	/// @dev A genesis fund at the block (ComptrollerV3, on the registrar of the time).
	address internal constant TEST_FUND_4 = 0xd989D464E8bD518AF14151cb0F95a4f970F365DA;

	UniswapV4SwapAdapter internal v4Adapter;

	/// @dev The v4 adapter asks its caller for `registrar()`: this test answers the release's, so it passes the
	///      adapter's new-funds gate as a release fund would when it calls the adapter directly.
	function registrar() external view returns (address) {
		return address(r.registrar);
	}

	function _forkBlock() internal pure override returns (uint256) {
		return V4_FORK_BLOCK;
	}

	function setUp() public override {
		super.setUp();
		if (!forked) return;
		v4Adapter = r.adapters.uniswapV4;
		address[5] memory stocks = [NVDAC, AAPLC, GOOGLC, METAC, SPCXC];
		address[] memory b20s = new address[](stocks.length);
		for (uint256 i; i < stocks.length; ++i) {
			b20s[i] = stocks[i];
		}
		B20LocalStandIns.standIn(b20s); // listing a stock reads its decimals
		_copyFeed(AERO);
		for (uint256 i; i < stocks.length; ++i) {
			_copyFeed(stocks[i]);
			r.registrar.setQuote(stocks[i], true);
		}
		r.registrar.setHook(ReleaseListings.STOCKIFY_HOOK, true, '');
		r.registrar.setHook(ReleaseListings.O1_HOOK_1, true, abi.encode(TREASURY));
		r.registrar.setHook(ReleaseListings.O1_HOOK_2, true, abi.encode(TREASURY));
		r.registrar.setPoolApproved(STFY_POOL_ID, true); // a launch pool
		r.registrar.setPoolSaleTax(STFY_POOL_ID, ReleaseListings.STFY_SALE_TAX_BPS); // as ReleaseListings records it
		_freshenFeeds();
	}

	// ─── STFY ────────────────────────────────────────────────────────────────────

	/// Anyone registers STFY; three samples aren't enough to buy, the fourth is; the buy pays 5 bps to the Treasury
	/// and STFY's 3% to its DividendVault; GAV counts STFY at its median.
	/// The exit (USDC only): the keeper pays the vault's USDC, sells the WETH, then sells STFY. Its sale pays the hook's
	/// 3%, the pool's 1% and our 5 bps — over the keeper's 3% cap at any size — so the registrar records the pool's tax
	/// (2.9% of what is sold) and a sale through it may lose 5.9% (founder 2026-11-15). One sale of all of it still loses
	/// more (price impact on a thin pool), so the
	/// keeper sells it in quarters, an hour of samples apart, and the leaver is paid the whole fund in USDC, less the
	/// sales. Before the fix neither the keeper nor the manager (5% budget, measured on what remained) could sell it.
	function test_fork_stfy_registerWarmupBuyValue_andTheKeeperSellsItInPieces() public {
		vm.skip(!forked);
		PoolKey memory key = _stfyKey();
		assertEq(PoolKeyId.toId(key), STFY_POOL_ID, 'the live pool');
		vm.prank(investor);
		r.registrar.registerV4(STFY, key);
		RedemptionQueue queue = _shortDeadlineQueue();
		Comptroller fund = _fundWithDeposit(10_000e6);
		_buyWeth(fund, 9_000e6);
		address vault = address(fund.vault());
		bytes memory buy = abi.encode(key, true, uint256(1 ether), uint256(1));

		_sampleRounds(STFY_POOL_ID, 3);
		vm.prank(manager);
		vm.expectRevert(V4PoolPriceAdapter.NoPriceHistory.selector);
		fund.callOnIntegration(address(v4Adapter), buy);

		_sampleRounds(STFY_POOL_ID, 1);
		uint256 dividendEth = DIVIDEND_VAULT.balance;
		uint256 treasuryWeth = IERC20(WETH).balanceOf(TREASURY);
		vm.prank(manager);
		fund.callOnIntegration(address(v4Adapter), buy);

		uint256 fee = 1 ether * BaseMainnet.SWAP_FEE_BPS / 10_000;
		assertEq(IERC20(WETH).balanceOf(TREASURY) - treasuryWeth, fee, '5 bps to the Treasury');
		assertEq(DIVIDEND_VAULT.balance - dividendEth, (1 ether - fee) * 300 / 10_000, "STFY's 3% to its DividendVault");
		uint256 stfy = IERC20(STFY).balanceOf(vault);
		uint256 stfyValue = r.valueInterpreter.calcCanonicalAssetValue(STFY, stfy, WETH);
		// 1 ETH less 5 bps, the hook's 3%, the pool's 1% and the price impact, valued at the pre-trade median
		assertGt(stfyValue, 0.85 ether);
		assertLt(stfyValue, 0.96 ether);
		uint256 parts = IERC20(USDC).balanceOf(vault)
			+ r.valueInterpreter.calcCanonicalAssetValue(WETH, IERC20(WETH).balanceOf(vault), USDC)
			+ r.valueInterpreter.calcCanonicalAssetValue(STFY, stfy, USDC);
		assertApproxEqAbs(fund.calcGav(), parts, 2, 'GAV counts STFY');
		_assertHoldsNothing(address(v4Adapter), STFY);

		_leaveInUsdc(fund, queue, key, stfy);
	}

	/// A whale lifts STFY's pool over 25% for two of six samples and sells back each time: the median, and so
	/// the price, stays within 1% of the unpumped pool.
	function test_fork_stfy_pumpAtFewerThanHalfTheSamplesLeavesTheMedian() public {
		vm.skip(!forked);
		PoolKey memory key = _stfyKey();
		r.registrar.registerV4(STFY, key);
		uint256 unpumped = _spotUsd(STFY_POOL_ID);
		V4TestRouter whale = new V4TestRouter(IV4PoolManager(POOL_MANAGER));
		vm.deal(address(whale), 10 ether);

		uint256 pumped;
		for (uint256 i; i < 6; ++i) {
			bool pump = i == 1 || i == 4;
			_advance(10 minutes);
			if (pump) {
				whale.swap(key, true, 3 ether, address(whale));
				pumped = _spotUsd(STFY_POOL_ID);
			}
			_sample(STFY_POOL_ID);
			if (pump) whale.swap(key, false, IERC20(STFY).balanceOf(address(whale)), address(whale));
		}
		console.log('unpumped', unpumped, 'pumped', pumped);
		assertGt(pumped, unpumped * 125 / 100, 'each pump lifted the pool over 25%');
		assertApproxEqRel(r.valueInterpreter.calcUsdRate(STFY), unpumped, 0.01e18, 'the median ignores two pumped samples of six');
	}

	/// A fund holding 100k+ STFY joins STFY's holder registry; the DividendVault's hourly cycle pushes it its
	/// slice of each stock, which counts in GAV once the manager tracks it.
	function test_fork_stfy_dividendCyclePushesStocksIntoTheVault() public {
		vm.skip(!forked);
		IDividendVault dividends = IDividendVault(DIVIDEND_VAULT);
		if (block.timestamp < dividends.nextDistribution()) vm.warp(dividends.nextDistribution());
		_freshenFeeds();
		address[5] memory stocks = [NVDAC, AAPLC, GOOGLC, METAC, SPCXC];
		uint256[5] memory pots;
		for (uint256 i; i < stocks.length; ++i) {
			_etchToken(stocks[i], 8);
			MockERC20(stocks[i]).mint(DIVIDEND_VAULT, 100e8); // what buyStocks would have bought
			pots[i] = IERC20(stocks[i]).balanceOf(DIVIDEND_VAULT) - dividends.unpaidTotal(stocks[i]);
		}

		PoolKey memory key = _stfyKey();
		r.registrar.registerV4(STFY, key);
		Comptroller fund = _fundWithDeposit(2_000e6);
		_buyWeth(fund, 1_000e6);
		address vault = address(fund.vault());
		_sampleRounds(STFY_POOL_ID, 4);
		vm.prank(manager);
		fund.callOnIntegration(address(v4Adapter), abi.encode(key, true, uint256(0.1 ether), uint256(1)));
		uint256 held = IERC20(STFY).balanceOf(vault);
		IStockifyToken stfy = IStockifyToken(STFY);
		assertGe(held, stfy.minShareBalance(), 'over the 100k STFY payout floor');
		assertEq(stfy.holderAt(stfy.holderCount() - 1), vault, 'the vault joined the holder registry');

		vm.prank(dividends.owner());
		dividends.setKeeper(address(this), true);
		dividends.startCycle();
		uint256 eligible = dividends.eligibleSupply();
		while (dividends.cycleActive()) {
			dividends.distributeBatch(100);
		}

		uint256 gavBefore = fund.calcGav();
		uint256 added;
		for (uint256 i; i < stocks.length; ++i) {
			uint256 got = IERC20(stocks[i]).balanceOf(vault);
			assertGt(got, 0);
			assertEq(got, pots[i] * held / eligible, "the vault's pro-rata slice");
			vm.prank(manager);
			fund.addTrackedAsset(stocks[i]);
			added += r.valueInterpreter.calcCanonicalAssetValue(stocks[i], got, USDC);
		}
		assertApproxEqAbs(fund.calcGav(), gavBefore + added, 5, 'tracked, the stocks count in GAV');
	}

	// ─── o1 ──────────────────────────────────────────────────────────────────────

	/// The two-step buy: NVDAc for USDC on Slipstream, then BLUECHIP for NVDAc through o1's first hook,
	/// which credits the Treasury 20% of its 1% base fee; anyone's claim pays the Treasury.
	function test_fork_o1_stockPairedTwoStepBuy_creditsTheTreasury_claimPays() public {
		vm.skip(!forked);
		_etchToken(NVDAC, 8);
		_etchToken(BLUECHIP, 18);
		MockERC20(NVDAC).mint(NVDAC_USDC_CL2, 1_000_000e8); // the pools' reserves of each B20
		MockERC20(BLUECHIP).mint(POOL_MANAGER, 1e36);
		PoolKey memory key = _bluechipKey();
		assertEq(PoolKeyId.toId(key), BLUECHIP_POOL_ID, 'the live pool');
		vm.prank(SAFE); // a pool approver: no timelock
		r.registrar.setPoolApproved(BLUECHIP_POOL_ID, true);
		r.registrar.registerV4(BLUECHIP, key);
		Comptroller fund = _fundWithDeposit(10_000e6);
		address vault = address(fund.vault());
		_sampleRounds(BLUECHIP_POOL_ID, 4);

		uint256 nvdacMin = r.valueInterpreter.calcCanonicalAssetValue(USDC, 2_000e6, NVDAC) * 97 / 100;
		vm.prank(manager);
		fund.callOnIntegration(
			address(r.adapters.slipstream2), abi.encode(USDC, NVDAC, int24(10), uint256(2_000e6), nvdacMin, uint256(0))
		);
		uint256 nvdac = IERC20(NVDAC).balanceOf(vault);
		assertGe(nvdac, nvdacMin, 'step one: NVDAc');

		IO1FeeEscrow escrow = IO1FeeEscrow(O1_ESCROW_1);
		uint256 owedBefore = escrow.owed(TREASURY, NVDAC);
		vm.prank(manager);
		fund.callOnIntegration(address(v4Adapter), abi.encode(key, true, nvdac, uint256(1)));
		uint256 baseFee = (nvdac - nvdac * BaseMainnet.SWAP_FEE_BPS / 10_000) * 100 / 10_000;
		assertEq(escrow.owed(TREASURY, NVDAC) - owedBefore, baseFee * 2_000 / 10_000, 'referrer: 20% of the 1% base fee');
		assertGt(IERC20(BLUECHIP).balanceOf(vault), 0, 'step two: BLUECHIP');
		assertEq(IERC20(NVDAC).balanceOf(vault), 0);
		assertApproxEqRel(fund.calcGav(), 10_000e6, 0.03e18, 'BLUECHIP valued at its median');
		_assertHoldsNothing(address(v4Adapter), NVDAC);

		uint256 owed = escrow.owed(TREASURY, NVDAC);
		uint256 treasuryBefore = IERC20(NVDAC).balanceOf(TREASURY);
		vm.prank(makeAddr('sweeper'));
		escrow.claim(TREASURY, NVDAC);
		assertEq(IERC20(NVDAC).balanceOf(TREASURY) - treasuryBefore, owed, 'the claim pays the Treasury');
		assertEq(escrow.owed(TREASURY, NVDAC), 0);
	}

	/// o1's second hook (its own escrow), on an ETH-paired launch, credits the Treasury the same 20% of a 1% base fee, in ETH.
	function test_fork_o1_ethPairedBuy_creditsTheTreasury_claimPays() public {
		vm.skip(!forked);
		_etchToken(JEZ, 18);
		MockERC20(JEZ).mint(POOL_MANAGER, 1e36);
		PoolKey memory key = _jezKey();
		assertEq(PoolKeyId.toId(key), JEZ_POOL_ID, 'the live pool');
		vm.prank(SAFE);
		r.registrar.setPoolApproved(JEZ_POOL_ID, true);
		IO1FeeEscrow escrow = IO1FeeEscrow(O1_ESCROW_2);
		uint256 owedBefore = escrow.owed(TREASURY, address(0));
		address vault = makeAddr('vault');

		deal(WETH, address(v4Adapter), 0.1 ether); // what a fund's callOnIntegration sends first
		v4Adapter.executeAction(vault, abi.encode(key, true, uint256(0.1 ether), uint256(1)));
		uint256 baseFee = (0.1 ether - 0.1 ether * uint256(BaseMainnet.SWAP_FEE_BPS) / 10_000) * 100 / 10_000;
		assertEq(escrow.owed(TREASURY, address(0)) - owedBefore, baseFee * 20 / 100, 'referrer: 20% of the 1% base fee');
		assertGt(IERC20(JEZ).balanceOf(vault), 0);
		_assertHoldsNothing(address(v4Adapter), JEZ);

		uint256 owed = escrow.owed(TREASURY, address(0));
		uint256 treasuryBefore = TREASURY.balance;
		escrow.claimFor(TREASURY, address(0));
		assertEq(TREASURY.balance - treasuryBefore, owed, 'the claim pays the Treasury in ETH');
	}

	// ─── Pool approval (final review 2026-10-08, H1) ────────────────────────────

	/// A manager's own token on his own hookless pool, with a one-tick position at the price holding no USDC (the
	/// review's proof met the $25k check that way): it can't be registered unapproved. And an approved token can't be
	/// bought through a side pool he set up at his own price.
	function test_fork_unapprovedV4PoolsRefused() public {
		vm.skip(!forked);
		MockERC20 junk = new MockERC20('Junk', 'JUNK', 18);
		bool junkIs0 = address(junk) < USDC;
		PoolKey memory junkKey = PoolKey({
			currency0: junkIs0 ? address(junk) : USDC, currency1: junkIs0 ? USDC : address(junk), fee: 100, tickSpacing: 1, hooks: address(0)
		});
		IV4PoolSetup(POOL_MANAGER).initialize(junkKey, uint160(1 << 96));
		V4TestRouter lp = new V4TestRouter(IV4PoolManager(POOL_MANAGER));
		junk.mint(address(lp), 1e30);
		deal(USDC, address(lp), 1e12);
		// one tick right at the price on the JUNK side, holding only JUNK (no USDC at all)
		(int24 lower, int24 upper) = junkIs0 ? (int24(0), int24(1)) : (int24(-1), int24(0));
		lp.addLiquidity(junkKey, lower, upper, 1e24);
		bytes32 junkId = PoolKeyId.toId(junkKey);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.PoolNotApproved.selector, junkId));
		r.registrar.registerV4(address(junk), junkKey);

		PoolKey memory side = PoolKey(address(0), STFY, 3_000, 60, address(0)); // STFY / ETH at another fee: not approved
		IV4PoolSetup(POOL_MANAGER).initialize(side, uint160(1 << 96));
		deal(WETH, address(v4Adapter), 0.1 ether);
		vm.expectRevert(abi.encodeWithSelector(UniswapV4SwapAdapter.PoolNotApproved.selector, PoolKeyId.toId(side)));
		v4Adapter.executeAction(makeAddr('vault'), abi.encode(side, true, uint256(0.1 ether), uint256(1)));
	}

	// ─── Stock-quoted pools on today's venues ────────────────────────────────────

	/// ElonRWA trades only against SPCXc (Slipstream): refused while SPCXc isn't an approved quote; with SPCXc
	/// approved, refused only because its pool holds ≈ $16.4k of SPCXc; the owner's correction path prices it
	/// from that pool.
	function test_fork_slipstream_stockQuotedRegistration() public {
		vm.skip(!forked);
		_etchToken(SPCXC, 8); // the adapter reads its decimals() and the pool's balance of it
		MockERC20(SPCXC).mint(ELON_SPCXC_CL2, ELON_POOL_SPCXC);
		r.registrar.setQuote(SPCXC, false);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.QuoteNotAllowed.selector, SPCXC));
		r.registrar.register(ELON_RWA, ELON_SPCXC_CL2);

		r.registrar.setQuote(SPCXC, true);
		uint256 liquidity = Math.mulDiv(ELON_POOL_SPCXC, r.valueInterpreter.calcUsdRate(SPCXC), 1e8);
		vm.expectRevert(abi.encodeWithSelector(PoolPriceRegistrar.NotEnoughLiquidity.selector, liquidity));
		r.registrar.register(ELON_RWA, ELON_SPCXC_CL2);

		r.registrar.setPool(ELON_RWA, ELON_SPCXC_CL2);
		assertTrue(r.registrar.poolPricedAdapter(ELON_RWA) != address(0));
		(uint160 sqrtPriceX96,,,,,) = ISlipstreamSlot0(ELON_SPCXC_CL2).slot0();
		uint256 spot = PoolPriceMath.usdPerAssetAtSqrtP(sqrtPriceX96, true, 18, 8, r.valueInterpreter.calcUsdRate(SPCXC));
		assertApproxEqRel(r.valueInterpreter.calcUsdRate(ELON_RWA), spot, 0.1e18, "SPCXc per ElonRWA times SPCXc's feed");
	}

	// ─── Adapters ────────────────────────────────────────────────────────────────

	/// A fund on another registrar can't use the v4 adapter (founder 2026-10-08: new funds only): a genesis fund's call
	/// is refused by the adapter itself.
	function test_fork_oldFundRefused() public {
		vm.skip(!forked);
		address vault = address(IComptroller(TEST_FUND_4).vault());
		deal(WETH, address(v4Adapter), 0.01 ether);
		vm.prank(TEST_FUND_4);
		vm.expectRevert(abi.encodeWithSelector(UniswapV4SwapAdapter.NotANewFund.selector, TEST_FUND_4));
		v4Adapter.executeAction(vault, abi.encode(_stfyKey(), true, uint256(0.01 ether), uint256(1)));
	}

	/// Each fee-taking spot adapter swaps 100 USDC on a real pool: 5 bps to the Treasury, at least the minimum out.
	function test_fork_feeAdaptersOnRealPools() public {
		vm.skip(!forked);
		uint256 amount = 100e6;
		_swapThrough(address(r.adapters.uniswapV3), abi.encode(USDC, WETH, uint24(500), amount, _minOut(amount, WETH)));
		_swapThrough(address(r.adapters.slipstream1), abi.encode(USDC, WETH, int24(100), amount, _minOut(amount, WETH), uint256(0)));
		_swapThrough(address(r.adapters.slipstream2), abi.encode(USDC, WETH, int24(50), amount, _minOut(amount, WETH), uint256(0)));
		_swapThrough(address(r.adapters.slipstream3), abi.encode(USDC, WETH, int24(50), amount, _minOut(amount, WETH), uint256(0)));
		_swapThrough(address(r.adapters.aerodromeBasic), abi.encode(USDC, AERO, amount, _minOut(amount, AERO)));
	}

	/// More WETH than a thin hookless pool can absorb before the price limit: the pool fills what its range holds
	/// and the rest comes back to the vault.
	function test_fork_partialFill_returnsLeftover() public {
		vm.skip(!forked);
		MockERC20 thin = new MockERC20('Thin', 'THIN', 18);
		bool wethIs0 = WETH < address(thin);
		PoolKey memory key = PoolKey({
			currency0: wethIs0 ? WETH : address(thin),
			currency1: wethIs0 ? address(thin) : WETH,
			fee: 3000,
			tickSpacing: 60,
			hooks: address(0)
		});
		IV4PoolSetup(POOL_MANAGER).initialize(key, uint160(1 << 96));
		vm.prank(SAFE);
		r.registrar.setPoolApproved(PoolKeyId.toId(key), true);
		V4TestRouter lp = new V4TestRouter(IV4PoolManager(POOL_MANAGER));
		thin.mint(address(lp), 1_000e18);
		deal(WETH, address(lp), 1_000e18);
		lp.addLiquidity(key, -600, 600, 1e21);

		address vault = makeAddr('vault');
		deal(WETH, address(v4Adapter), 100 ether);
		v4Adapter.executeAction(vault, abi.encode(key, wethIs0, uint256(100 ether), uint256(1)));

		// 1e21 of liquidity over 600 ticks takes 30.453 WETH (30.545 with the 0.3% pool fee) and pays 29.553 THIN;
		// past it the ticks are empty, the price runs to the limit and the rest of the 99.95 WETH comes back
		assertApproxEqRel(IERC20(WETH).balanceOf(vault), 69.405 ether, 0.0005e18, 'unspent WETH back in the vault');
		assertApproxEqRel(thin.balanceOf(vault), 29.553 ether, 0.0005e18);
		(uint160 sqrtPriceX96,,,) = IV4StateView(STATE_VIEW).getSlot0(PoolKeyId.toId(key));
		assertEq(sqrtPriceX96, wethIs0 ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1, 'at the limit');
		_assertHoldsNothing(address(v4Adapter), address(thin));
	}

	// ─── Sampler ─────────────────────────────────────────────────────────────────

	/// `sample` gas on live pools: one pool and ten, first readings and once each pool's twelve slots are full.
	function test_fork_samplerGas() public {
		vm.skip(!forked);
		bytes32[] memory one = new bytes32[](1);
		one[0] = JEZ_POOL_ID;
		bytes32[] memory ten = _tenPools();
		(uint256 firstOne, uint256 firstTen) = _sampleGas(one, ten);
		for (uint256 i = 1; i < r.sampler.SLOTS(); ++i) {
			_advance(10 minutes);
			_sampleGas(one, ten);
		}
		_advance(10 minutes);
		(uint256 steadyOne, uint256 steadyTen) = _sampleGas(one, ten);
		console.log('sample gas, first reading: 1 pool', firstOne, '10 pools', firstTen);
		console.log('sample gas, slots full:    1 pool', steadyOne, '10 pools', steadyTen);
		assertEq(r.sampler.sampleCount(JEZ_POOL_ID), r.sampler.SLOTS() + 1);
		assertLt(steadyTen, firstTen, 'overwriting a full ring costs less than the first writes');
	}

	// ─── Helpers ─────────────────────────────────────────────────────────────────

	function _stfyKey() internal pure returns (PoolKey memory) {
		return PoolKey(address(0), STFY, 10_000, 200, ReleaseListings.STOCKIFY_HOOK);
	}

	function _bluechipKey() internal pure returns (PoolKey memory) {
		return PoolKey(NVDAC, BLUECHIP, 0, 200, ReleaseListings.O1_HOOK_1);
	}

	function _jezKey() internal pure returns (PoolKey memory) {
		return PoolKey(address(0), JEZ, 0, 200, ReleaseListings.O1_HOOK_2);
	}

	/// @dev STFY, BLUECHIP and eight of the busiest ETH-paired o1 pools (hook logs, 60k blocks to the fork block).
	function _tenPools() internal pure returns (bytes32[] memory ids) {
		ids = new bytes32[](10);
		ids[0] = STFY_POOL_ID;
		ids[1] = BLUECHIP_POOL_ID;
		ids[2] = 0xd4940676850741715c57e713cc586511ba6481ad9343082cd05c152a24a9b1ed;
		ids[3] = 0x186341ed6597e6b946c2bf9c71a283af0b5cbb8114bb05190b31740dd89ee3a5;
		ids[4] = 0xa759ab96dfae2721728d8faf4372bc4f9b05fe971e7ecfd3dbd658e627e0e18c;
		ids[5] = 0x83f003b393c97cd110fbf90c6d4a10f96aa8b59e560c99051a7a980f3c9c5729;
		ids[6] = 0x67427b746773fbfb5084752261a583d7ca077325802e1f1bab4dba0cd91f13bc;
		ids[7] = 0x8914fada2eeb6fae31c6bbc36fa0abe347a13d94436c35365e914604d3ca0995;
		ids[8] = 0x88c12ceab05cd65d96873b4ed19a891b2c5cd0b1233ed7b69e885f9aca6d9300;
		ids[9] = 0x4a9efef7d3430756f9aabe1465e7c13fdd4a665cca375dd2889ea42e991533cb;
	}

	/// @dev The investor asks for every share; the keeper pays the vault's USDC and sells the WETH, is refused one sale
	///      of all the STFY (over 5.9%), then sells it in quarters with the median catching up between them.
	function _leaveInUsdc(Comptroller fund, RedemptionQueue queue, PoolKey memory key, uint256 stfy) internal {
		address vault = address(fund.vault());
		uint256 shares = fund.shares().balanceOf(investor);
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(address(queue), shares);
		uint256 id = queue.requestRedeem(address(fund), shares);
		vm.stopPrank();
		// an hour of the keeper's samples: the deadline passes and STFY's median catches up with the pool the fund's own
		// buy moved (sold straight back, the sale would gain on a median still at the pre-buy price)
		_sampleRounds(STFY_POOL_ID, 6);
		uint256 gav = fund.calcGav();
		uint256 stfyUsd = r.valueInterpreter.calcCanonicalAssetValue(STFY, stfy, USDC);

		vm.startPrank(keeper);
		queue.settle(address(fund), 1);
		queue.liquidate(address(fund), address(r.adapters.uniswapV3), _sellWeth(IERC20(WETH).balanceOf(vault)));
		queue.settle(address(fund), 1);
		vm.expectPartialRevert(ComptrollerLib.LiquidationLoss.selector);
		queue.liquidate(address(fund), address(v4Adapter), abi.encode(key, false, stfy, uint256(1)));
		vm.stopPrank();

		uint256 left = stfy;
		for (uint256 i; i < 4; ++i) {
			uint256 piece = i == 3 ? left : stfy / 4;
			left -= piece;
			_keeperSellsStfy(fund, queue, key, piece);
			vm.startPrank(keeper);
			queue.liquidate(address(fund), address(r.adapters.uniswapV3), _sellWeth(IERC20(WETH).balanceOf(vault)));
			if (queue.requestAt(address(fund), id).open) queue.settle(address(fund), 1);
			vm.stopPrank();
			if (i < 3) _sampleRounds(STFY_POOL_ID, 6);
		}
		assertEq(IERC20(STFY).balanceOf(vault), 0, 'all STFY sold by the keeper');
		assertFalse(queue.requestAt(address(fund), id).open, 'paid');
		uint256 paid = IERC20(USDC).balanceOf(investor);
		console.log('GAV at the request', gav, 'paid in USDC', paid);
		console.log('STFY at the request (USDC)', stfyUsd, 'lost to its sales', gav - paid);
		// the 3% hook, 1% pool and 5 bps on every piece, plus each piece moving STFY's thin pool: measured ≈ 8.7% of
		// the STFY at this block (the WETH sales cost ≈ 0.1%)
		assertGt(gav - paid, stfyUsd * 4 / 100, "STFY's fees were really paid");
		assertLt(gav - paid, stfyUsd * 10 / 100, 'and the rest of the fund reached the leaver');
	}

	/// @dev The keeper's sale (funds-keeper sell): simulated with no minimum, then sent with what arrived less 0.5% as its
	///      minimum; on the same state it gets exactly what the simulation did.
	function _keeperSellsStfy(Comptroller fund, RedemptionQueue queue, PoolKey memory key, uint256 amount) internal {
		uint256 simulated = _simulatedSale(fund, queue, address(v4Adapter), abi.encode(key, false, amount, uint256(0)));
		uint256 minOut = simulated * 9_950 / 10_000;
		vm.prank(keeper);
		uint256 received = queue.liquidate(address(fund), address(v4Adapter), abi.encode(key, false, amount, minOut));
		assertEq(received, simulated, 'the sale gets what its simulation did');
		assertGe(received, minOut);
	}

	/// @dev What the keeper's simulation of a sale reads (RedemptionQueue.liquidate's return), the state then put back.
	function _simulatedSale(Comptroller fund, RedemptionQueue queue, address adapter, bytes memory data) internal returns (uint256 received) {
		uint256 snap = vm.snapshotState();
		vm.prank(keeper);
		received = queue.liquidate(address(fund), adapter, data);
		vm.revertToState(snap);
	}

	/// @dev The manager turns `usdc` of the fund's USDC into WETH (the STFY pool's quote) on Uniswap v3.
	function _buyWeth(Comptroller fund, uint256 usdc) internal {
		bytes memory buy = abi.encode(USDC, WETH, uint24(500), usdc, _minOut(usdc, WETH)); // before the prank: it reads the VI
		vm.prank(manager);
		fund.callOnIntegration(address(r.adapters.uniswapV3), buy);
	}

	/// @dev A keeper sale of `weth` into USDC on Uniswap v3, at most 3% under the oracle.
	function _sellWeth(uint256 weth) internal view returns (bytes memory) {
		uint256 minOut = r.valueInterpreter.calcCanonicalAssetValue(WETH, weth, USDC) * 97 / 100;
		return abi.encode(WETH, USDC, uint24(500), weth, minOut);
	}

	/// @dev The keeper's cadence: ten minutes, then one reading of the pool.
	function _sampleRounds(bytes32 poolId, uint256 rounds) internal {
		for (uint256 i; i < rounds; ++i) {
			_advance(10 minutes);
			_sample(poolId);
		}
	}

	function _sample(bytes32 poolId) internal {
		bytes32[] memory ids = new bytes32[](1);
		ids[0] = poolId;
		vm.prank(keeper);
		r.sampler.sample(ids);
	}

	/// @dev Each call measured as its own transaction would see it: sampler, StateView and PoolManager cold.
	function _sampleGas(bytes32[] memory one, bytes32[] memory ten) internal returns (uint256 gasOne, uint256 gasTen) {
		vm.startPrank(keeper);
		_coolSampling();
		uint256 before = gasleft();
		r.sampler.sample(one);
		gasOne = before - gasleft();
		_coolSampling();
		before = gasleft();
		r.sampler.sample(ten);
		gasTen = before - gasleft();
		vm.stopPrank();
	}

	function _coolSampling() internal {
		vm.cool(address(r.sampler));
		vm.cool(STATE_VIEW);
		vm.cool(POOL_MANAGER);
	}

	/// @dev Time passes; the Chainlink-priced assets keep their answers with a fresh timestamp (the feeds would
	///      have updated on Base).
	function _advance(uint256 secs) internal {
		vm.warp(block.timestamp + secs);
		vm.roll(block.number + secs / 2);
		_freshenFeeds();
	}

	function _freshenFeeds() internal {
		address[8] memory assets = [WETH, USDC, AERO, NVDAC, AAPLC, GOOGLC, METAC, SPCXC];
		for (uint256 i; i < assets.length; ++i) {
			(address aggregator,,,) = r.valueInterpreter.getAssetInfo(assets[i]);
			(uint80 roundId, int256 answer, uint256 startedAt,, uint80 answeredInRound) =
				AggregatorV3Interface(aggregator).latestRoundData();
			vm.mockCall(
				aggregator,
				abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
				abi.encode(roundId, answer, startedAt, block.timestamp, answeredInRound)
			);
		}
	}

	/// @dev A B20 address gets a plain ERC-20's code (its `decimals` is immutable, so it carries over).
	function _etchToken(address at, uint8 decimals) internal {
		MockERC20 template = new MockERC20('', '', decimals);
		vm.etch(at, address(template).code);
	}

	/// @dev The USD value of `token` per whole unit, at the v4 pool's current price against native ETH.
	function _spotUsd(bytes32 poolId) internal view returns (uint256) {
		(uint160 sqrtPriceX96,,,) = IV4StateView(STATE_VIEW).getSlot0(poolId);
		return PoolPriceMath.usdPerAssetAtSqrtP(sqrtPriceX96, false, 18, 18, r.valueInterpreter.calcUsdRate(WETH));
	}

	/// @dev 97% of what `usdc` is worth in `tokenOut` at the VI's prices.
	function _minOut(uint256 usdc, address tokenOut) internal view returns (uint256) {
		return r.valueInterpreter.calcCanonicalAssetValue(USDC, usdc, tokenOut) * 97 / 100;
	}

	/// @dev The Comptroller's order — the spend asset to the adapter, then executeAction — against `vault`.
	function _swapThrough(address adapter, bytes memory integrationData) internal {
		(,, address[] memory incoming, uint256[] memory minimums) =
			IIntegrationAdapter(adapter).parseAssetsForAction(integrationData);
		address vault = makeAddr('vault');
		uint256 outBefore = IERC20(incoming[0]).balanceOf(vault);
		uint256 treasuryBefore = IERC20(USDC).balanceOf(TREASURY);
		deal(USDC, adapter, 100e6);
		IIntegrationAdapter(adapter).executeAction(vault, integrationData);
		assertEq(IERC20(USDC).balanceOf(TREASURY) - treasuryBefore, 100e6 * uint256(BaseMainnet.SWAP_FEE_BPS) / 10_000, '5 bps');
		assertGe(IERC20(incoming[0]).balanceOf(vault) - outBefore, minimums[0], 'at least the minimum out');
		assertEq(IERC20(USDC).balanceOf(adapter), 0, 'nothing left in the adapter');
	}

	function _assertHoldsNothing(address adapter, address token) internal view {
		assertEq(adapter.balance, 0, 'no ETH');
		assertEq(IERC20(WETH).balanceOf(adapter), 0, 'no WETH');
		assertEq(IERC20(token).balanceOf(adapter), 0, 'no tokens');
	}
}
