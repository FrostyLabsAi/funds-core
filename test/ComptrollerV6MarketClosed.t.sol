// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ComptrollerV6} from '../src/core/ComptrollerV6.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {IDerivativePriceFeed} from '../src/interfaces/IDerivativePriceFeed.sol';
import {LimitOrderPositionFactory} from '../src/positions/LimitOrderPosition.sol';
import {RedemptionQueueV2} from '../src/redemption/RedemptionQueueV2.sol';
import {PoolPriceRegistrarWindowed} from '../src/pricing/PoolPriceRegistrarWindowed.sol';
import {MockERC20, MockAggregator, MockERC4626Vault} from './utils/Mocks.sol';
import {ScriptedCLPool, MockUniswapV3Factory} from './utils/PoolPriceMocks.sol';
import {stdStorage, StdStorage} from 'forge-std/Test.sol';
import {RedemptionFixtureV6} from './utils/RedemptionFixtureV6.sol';

/// @dev A CLM vault as the fund sees it: a share token that names its strategy, which names its two tokens.
contract StubClmVault is MockERC20 {
	address public strategy;

	constructor(address strategy_) MockERC20('Vault', 'V', 18) {
		strategy = strategy_;
	}
}

contract StubClmStrategy {
	address public lpToken0;
	address public lpToken1;

	constructor(address token0_, address token1_) {
		lpToken0 = token0_;
		lpToken1 = token1_;
	}
}

/// @dev One share = 1 of `underlying`.
contract StubVaultFeed is IDerivativePriceFeed {
	address internal immutable underlying;

	constructor(address underlying_) {
		underlying = underlying_;
	}

	function calcUnderlyingValues(address, uint256 amount) external view returns (address[] memory assets, uint256[] memory amounts) {
		assets = new address[](1);
		amounts = new uint256[](1);
		assets[0] = underlying;
		amounts[0] = amount;
	}

	function isSupportedAsset(address) external pure returns (bool) {
		return true;
	}
}

/// @notice A tokenized stock's feed stops from Friday's close to the next open, so nobody may trade the fund at that price
///         while everyone can see where the market will reopen (red-team PF-02, 2026-10-27). Exits go to the queue, the
///         queue and deposits wait for the feed, and the fund stays readable.
contract ComptrollerV6MarketClosedTest is RedemptionFixtureV6 {
	using stdStorage for StdStorage;

	uint256 internal constant LIMIT_TYPE = 95;
	MockERC20 internal stock;
	MockAggregator internal stockFeed;

	function setUp() public override {
		super.setUp();
		stock = new MockERC20('Stock', 'STKc', 18);
		stockFeed = new MockAggregator(8, 100e8);
		// as the live Coinbase-stock primitives: a 5-day heartbeat, so a closed market stays readable
		registrar.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (address(stock), address(stockFeed), uint32(5 days))));
		factory.registerPositionType(LIMIT_TYPE, address(new LimitOrderPositionFactory()));
	}

	/// @dev Alice and Bob in for 10,000 each, half the fund in the stock at $100.
	function _stockFund() internal returns (ComptrollerV6 fund) {
		fund = ComptrollerV6(factory.createFund(_config(0, 0, 0)));
		_deposit(fund, alice, 10_000e6);
		_deposit(fund, bob, 10_000e6);
		_swap(fund, usdc, stock, 10_000e6, 100e18);
	}

	/// @dev The weekend starts: every other feed keeps reporting, the stock's doesn't.
	function _closeTheMarket() internal {
		skip(5 hours);
		_refreshFeeds();
	}

	function _worth(ComptrollerV6 fund, address who) internal returns (uint256) {
		return fund.calcGav() * _sharesOf(fund, who) / fund.shares().totalSupply();
	}

	// ─── instant exit ────────────────────────────────────────────────────────────

	function test_anOpenMarketExitsInstantly() public {
		ComptrollerV6 fund = _stockFund();
		uint256 shares = _sharesOf(fund, bob) / 10;
		vm.prank(bob);
		fund.redeemShares(shares);
		assertApproxEqRel(usdc.balanceOf(bob), 1_000e6, 1e15);
	}

	function test_aClosedMarketSendsTheInstantExitToTheQueue() public {
		ComptrollerV6 fund = _stockFund();
		_closeTheMarket();
		uint256 shares = _sharesOf(fund, bob);
		vm.prank(bob);
		vm.expectRevert(ComptrollerV6.UseRedemptionQueue.selector);
		fund.redeemShares(shares);
	}

	// ─── the queue ───────────────────────────────────────────────────────────────

	/// The red team's weekend: −20% on the stock. Bob asks Sunday; on Friday's price he took 10,000 of a fair 9,000, and
	/// Alice paid for it. The queue waits for the market, so he is paid at Monday's price.
	function test_aQueuedExitWaitsForTheMarket_andPaysMondaysPrice() public {
		ComptrollerV6 fund = _stockFund();
		_closeTheMarket();
		_request(fund, bob, _sharesOf(fund, bob));
		vm.prank(keeper);
		vm.expectRevert(RedemptionQueueV2.PriceUnreadable.selector);
		queue.settle(address(fund), 1);

		stockFeed.setAnswer(80e8); // Monday's first print
		vm.prank(keeper);
		queue.settle(address(fund), 1);
		assertApproxEqRel(usdc.balanceOf(bob), 9_000e6, 1e15, 'half the fund at $80, half in USDC');
		assertApproxEqRel(_worth(fund, alice), 9_000e6, 1e15, 'alice keeps her share');
	}

	// ─── deposits ────────────────────────────────────────────────────────────────

	/// The red team's other side: +20% over the weekend. Carol asks Sunday at Friday's price and would hold a free gain;
	/// her deposit waits, then buys at Monday's.
	function test_aDepositWaitsForTheMarket_andBuysAtMondaysPrice() public {
		ComptrollerV6 fund = _stockFund();
		_closeTheMarket();
		deal(address(usdc), carol, 10_000e6);
		vm.startPrank(carol);
		usdc.approve(address(fund), 10_000e6);
		fund.requestDeposit(10_000e6, type(uint256).max);
		vm.stopPrank();
		skip(1 minutes);
		vm.expectRevert(ComptrollerV6.MarketClosed.selector);
		fund.executeDepositRequest(carol);

		stockFeed.setAnswer(120e8);
		fund.executeDepositRequest(carol);
		assertApproxEqRel(_worth(fund, carol), 10_000e6, 1e15, 'no free gain');
		assertApproxEqRel(_worth(fund, alice), 11_000e6, 1e15, 'the gain stays with who held it');
	}

	/// Cancelling never waits on the market.
	function test_aClosedMarketNeverStopsACancel() public {
		ComptrollerV6 fund = _stockFund();
		_closeTheMarket();
		_request(fund, bob, _sharesOf(fund, bob));
		vm.prank(bob);
		queue.cancel(address(fund));
		assertGt(_sharesOf(fund, bob), 0, 'shares back');
	}

	// ─── what stays as it was ────────────────────────────────────────────────────

	/// A closed market stays readable: GAV and the terminal's figures don't revert.
	function test_aClosedMarketStaysReadable() public {
		ComptrollerV6 fund = _stockFund();
		_closeTheMarket();
		assertApproxEqRel(fund.calcGav(), 20_000e6, 1e15);
		assertApproxEqRel(fund.calcGrossShareValue(), fund.calcGav() * 1e18 / fund.shares().totalSupply(), 1e15);
	}

	/// A fund holding only WETH and USDC is untouched: their feeds aren't session feeds, however old inside their heartbeat.
	function test_aFundWithoutStocksIsUntouched() public {
		ComptrollerV6 fund = ComptrollerV6(factory.createFund(_config(0, 0, 0)));
		_deposit(fund, alice, 10_000e6);
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		skip(20 hours); // both feeds are 20 h old, inside their 25-hour heartbeat
		uint256 shares = _sharesOf(fund, alice) / 10;
		vm.prank(alice);
		fund.redeemShares(shares);
		assertApproxEqRel(usdc.balanceOf(alice), 1_000e6, 1e15);
	}

	/// Just inside the age, a quiet feed trades on; just past it, it waits.
	function test_theAgeLimitIsFourHours() public {
		ComptrollerV6 fund = _stockFund();
		uint256 shares = _sharesOf(fund, bob) / 10;
		stockFeed.setAnswer(100e8);
		skip(4 hours);
		_refreshFeeds();
		vm.prank(bob);
		fund.redeemShares(shares);

		skip(1);
		vm.prank(bob);
		vm.expectRevert(ComptrollerV6.UseRedemptionQueue.selector);
		fund.redeemShares(shares);
	}

	/// A selling stock with no holding left doesn't hold anything up.
	function test_aSoldStockHoldsNothingUp() public {
		ComptrollerV6 fund = _stockFund();
		_swap(fund, stock, usdc, 100e18, 10_000e6);
		_closeTheMarket();
		uint256 shares = _sharesOf(fund, bob) / 10;
		vm.prank(bob);
		fund.redeemShares(shares);
		assertApproxEqRel(usdc.balanceOf(bob), 1_000e6, 1e15);
	}

	// ─── through positions and vaults ────────────────────────────────────────────

	/// A stock in a limit order is the same stock: the queue waits.
	function test_aStockInAPositionHoldsTheQueueToo() public {
		ComptrollerV6 fund = _stockFund();
		vm.prank(manager);
		address order = fund.createExternalPosition(LIMIT_TYPE, '');
		address[] memory assets = new address[](1);
		uint256[] memory amounts = new uint256[](1);
		assets[0] = address(stock);
		amounts[0] = 100e18;
		vm.prank(manager);
		fund.callOnExternalPosition(order, assets, amounts, new address[](0),
			abi.encode(uint8(0), abi.encode(address(stock), address(usdc), uint128(100e18), uint128(10_000e6), uint64(block.timestamp + 30 days))));
		_closeTheMarket();
		_request(fund, bob, _sharesOf(fund, bob));
		vm.prank(keeper);
		vm.expectRevert(RedemptionQueueV2.PriceUnreadable.selector);
		queue.settle(address(fund), 1);
	}

	/// A stock CLM vault's price reads the stock: the instant exit goes to the queue, which waits.
	function test_aClmVaultOnAStockHoldsExitsToo() public {
		ComptrollerV6 fund = _stockFund();
		_swap(fund, stock, usdc, 100e18, 10_000e6);
		StubClmVault vault = new StubClmVault(address(new StubClmStrategy(address(stock), address(usdc))));
		registrar.execute(abi.encodeCall(ValueInterpreter.addDerivative, (address(vault), address(new StubVaultFeed(address(stock))))));
		vm.prank(manager);
		fund.addTrackedAsset(address(vault));
		vault.mint(address(fund.vault()), 10e18);

		uint256 shares = _sharesOf(fund, bob) / 10;
		vm.prank(bob);
		fund.redeemShares(shares); // the market's open

		_closeTheMarket();
		vm.prank(bob);
		vm.expectRevert(ComptrollerV6.UseRedemptionQueue.selector);
		fund.redeemShares(shares);
	}

	/// An ERC4626 vault on a stock (the live IPOR carry vaults on GOOGLc, METAc, AAPLc, NVDAc) reads the stock: the same
	/// (review 2026-11-01, Medium 3).
	function test_anErc4626OnAStockHoldsExitsToo() public {
		ComptrollerV6 fund = _stockFund();
		_swap(fund, stock, usdc, 100e18, 10_000e6);
		MockERC4626Vault vault = new MockERC4626Vault(IERC20(address(stock)));
		registrar.execute(abi.encodeCall(ValueInterpreter.addDerivative, (address(vault), address(new StubVaultFeed(address(stock))))));
		vm.prank(manager);
		fund.addTrackedAsset(address(vault));
		deal(address(vault), address(fund.vault()), 10e18);

		uint256 shares = _sharesOf(fund, bob) / 10;
		vm.prank(bob);
		fund.redeemShares(shares); // the market's open

		_closeTheMarket();
		vm.prank(bob);
		vm.expectRevert(ComptrollerV6.UseRedemptionQueue.selector);
		fund.redeemShares(shares);
	}

	/// A pool-priced token quoted against a stock reads the stock: its queue and deposits wait.
	function test_aTokenQuotedInAStockHoldsTheQueueToo() public {
		MockERC20 token = new MockERC20('Quoted', 'QTD', 18);
		MockUniswapV3Factory uniswap = MockUniswapV3Factory(address(PoolPriceRegistrarWindowed(address(registrar)).uniswapV3Factory()));
		ScriptedCLPool stockPool = new ScriptedCLPool(address(token), address(stock), address(uniswap), 3000, 60);
		stockPool.setHistory(2 days);
		stockPool.setOracle(0, 1e24); // 1M of the stock in range
		deal(address(stock), address(stockPool), 1_000_000e18);
		uniswap.setPool(address(token), address(stock), 3000, address(stockPool));
		// the live chain adds a quote through PoolPriceRegistrarV3.setQuote; this registrar takes its quotes at construction
		stdstore.target(address(registrar)).sig('isQuote(address)').with_key(address(stock)).checked_write(true);
		registrar.register(address(token), address(stockPool));

		ComptrollerV6 fund = ComptrollerV6(factory.createFund(_config(0, 0, 0)));
		_deposit(fund, alice, 10_000e6);
		_deposit(fund, bob, 10_000e6);
		_swap(fund, usdc, token, 10_000e6, 100e18);
		_closeTheMarket();
		_request(fund, bob, _sharesOf(fund, bob));
		vm.prank(keeper);
		vm.expectRevert(RedemptionQueueV2.PriceUnreadable.selector);
		queue.settle(address(fund), 1);
	}

	/// `settleFees` no longer waits on the market: a cancel's fee stop must hold (review 2026-11-01, Low 6).
	function test_settleFeesRunsInAClosedMarket() public {
		ComptrollerV6 fund = _stockFund();
		_closeTheMarket();
		fund.settleFees();
	}
}
