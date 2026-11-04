// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ComptrollerV6} from '../src/core/ComptrollerV6.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {IDerivativePriceFeed} from '../src/interfaces/IDerivativePriceFeed.sol';
import {IExternalPosition} from '../src/interfaces/IExternalPosition.sol';
import {IExternalPositionTypeFactory} from '../src/interfaces/IExternalPositionTypeFactory.sol';
import {LimitOrderPositionFactory} from '../src/positions/LimitOrderPosition.sol';
import {VerantaPriceAdapterV2} from '../src/pricing/VerantaPriceAdapterV2.sol';
import {VerantaPriceStoreV2} from '../src/pricing/VerantaPriceStoreV2.sol';
import {MockStoreV2} from './B20VerantaPriceAdapter.t.sol';
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

/// @dev A perp account as the fund sees it: what it holds and what it owes, set by the test.
contract StubPerpAccount is IExternalPosition {
	address internal managedAsset;
	uint256 internal managedAmount;
	address internal debtAsset;
	uint256 internal debtAmount;

	function set(address managedAsset_, uint256 managedAmount_, address debtAsset_, uint256 debtAmount_) external {
		(managedAsset, managedAmount, debtAsset, debtAmount) = (managedAsset_, managedAmount_, debtAsset_, debtAmount_);
	}

	function _leg(address asset, uint256 amount) private pure returns (address[] memory assets, uint256[] memory amounts) {
		if (asset == address(0)) return (new address[](0), new uint256[](0));
		assets = new address[](1);
		amounts = new uint256[](1);
		assets[0] = asset;
		amounts[0] = amount;
	}

	function getManagedAssets() external view returns (address[] memory, uint256[] memory) {
		return _leg(managedAsset, managedAmount);
	}

	function getDebtAssets() external view returns (address[] memory, uint256[] memory) {
		return _leg(debtAsset, debtAmount);
	}

	function receiveCallFromFund(bytes calldata) external {}

	function isRiskReducing(bytes calldata) external pure returns (bool) {
		return false;
	}
}

contract StubPerpAccountFactory is IExternalPositionTypeFactory {
	function deployPosition(address, bytes calldata) external returns (address) {
		return address(new StubPerpAccount());
	}
}

/// @notice A tokenized stock's feed stops from Friday's close to the next open, while everyone can see where the market
///         will reopen (red-team PF-02, 2026-10-27). Exits go to the queue, the queue waits for the feed, and the fund stays
///         readable. Deposits never wait (founder 2026-11-03): they buy at the last price.
contract ComptrollerV6MarketClosedTest is RedemptionFixtureV6 {
	using stdStorage for StdStorage;

	uint256 internal constant LIMIT_TYPE = 95;
	uint256 internal constant PERP_TYPE = 94;
	MockERC20 internal stock;
	MockAggregator internal stockFeed;

	function setUp() public override {
		super.setUp();
		stock = new MockERC20('Stock', 'STKc', 18);
		stockFeed = new MockAggregator(8, 100e8);
		// as the live Coinbase-stock primitives: a 5-day heartbeat, so a closed market stays readable
		registrar.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (address(stock), address(stockFeed), uint32(5 days))));
		factory.registerPositionType(LIMIT_TYPE, address(new LimitOrderPositionFactory()));
		factory.registerPositionType(PERP_TYPE, address(new StubPerpAccountFactory()));
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

	function _requestDeposit(ComptrollerV6 fund, address who, uint256 amount) internal {
		deal(address(usdc), who, amount);
		vm.startPrank(who);
		usdc.approve(address(fund), amount);
		fund.requestDeposit(amount, type(uint256).max);
		vm.stopPrank();
		skip(1 minutes);
	}

	/// @dev Half the fund in the stock, up 20% before the close: 22,000 against a mark of 20,000, a 20% fee of 400.
	function _stockFundAboveItsMark() internal returns (ComptrollerV6 fund) {
		fund = ComptrollerV6(factory.createFund(_config(0, 2_000, 0)));
		_deposit(fund, alice, 10_000e6);
		_deposit(fund, bob, 10_000e6);
		_swap(fund, usdc, stock, 10_000e6, 100e18);
		stockFeed.setAnswer(120e8);
	}

	/// Founder 2026-11-03: a closed market never stops a deposit, it buys at the last price. The cost he accepted is the red
	/// team's other side, recorded here: +20% over the weekend, and Carol's 10,000 takes a third of the gain from the holders.
	function test_aClosedMarketNeverStopsADeposit_itBuysAtTheLastPrice() public {
		ComptrollerV6 fund = _stockFund();
		_closeTheMarket();
		_requestDeposit(fund, carol, 10_000e6);
		fund.executeDepositRequest(carol);
		assertApproxEqRel(_worth(fund, carol), 10_000e6, 1e15, 'she buys at the last price');
		assertApproxEqRel(_worth(fund, alice), 10_000e6, 1e15, 'the holders are unchanged');

		stockFeed.setAnswer(120e8);
		assertApproxEqRel(_worth(fund, carol), 10_667e6, 1e15, 'the accepted cost: a share of the weekend');
		assertApproxEqRel(_worth(fund, alice), 10_667e6, 1e15, 'alice would have held 11,000');
	}

	/// New money pays no fee on gains made before it arrived: the fee waits for a real price, and the deposit buys at the
	/// price after it. Nothing is charged at the closed price.
	function test_aClosedMarketDepositPaysNoneOfTheFeeWaiting() public {
		ComptrollerV6 fund = _stockFundAboveItsMark();
		_closeTheMarket();
		_requestDeposit(fund, carol, 10_000e6);
		fund.executeDepositRequest(carol);
		assertEq(_sharesOf(fund, manager), 0, 'no fee at a closed price');

		stockFeed.setAnswer(120e8); // the market reopens where it closed
		fund.settleFees();
		assertApproxEqRel(_worth(fund, manager), 400e6, 1e15, 'the fee is 20% of the holders 2,000 gain, none on her money');
		assertApproxEqRel(_worth(fund, carol), 10_000e6, 1e15, 'she still holds what she paid');
		assertApproxEqRel(_worth(fund, alice), 10_800e6, 1e15, 'alice pays her half of the fee');
		assertApproxEqRel(fund.highWaterMark(), fund.calcGav() * 1e18 / fund.shares().totalSupply(), 1e15, 'the mark sits at the price after the fee');
	}

	/// Two deposits over one weekend each buy clean.
	function test_twoClosedMarketDepositsEachPayNoneOfTheFeeWaiting() public {
		ComptrollerV6 fund = _stockFundAboveItsMark();
		_closeTheMarket();
		address dave = makeAddr('dave');
		_requestDeposit(fund, carol, 10_000e6);
		fund.executeDepositRequest(carol);
		_requestDeposit(fund, dave, 5_000e6);
		fund.executeDepositRequest(dave);

		stockFeed.setAnswer(120e8);
		fund.settleFees();
		assertApproxEqRel(_worth(fund, manager), 400e6, 1e15, 'the same 400');
		assertApproxEqRel(_worth(fund, carol), 10_000e6, 1e15);
		assertApproxEqRel(_worth(fund, dave), 5_000e6, 1e15);
		assertApproxEqRel(_worth(fund, alice), 10_800e6, 1e15);
	}

	/// The review's attack (2026-11-03): WETH up 2,000 over the weekend, the stock really down 2,000 behind its frozen feed. A
	/// dust deposit could take a fee on a gain that never existed. It charges nothing, and Monday's flat NAV owes nothing.
	function test_aDustDepositCantChargeAFeeOnAStalePrice() public {
		ComptrollerV6 fund = ComptrollerV6(factory.createFund(_config(0, 2_000, 0)));
		_deposit(fund, alice, 10_000e6);
		_deposit(fund, bob, 10_000e6);
		_swap(fund, usdc, stock, 10_000e6, 100e18);
		_swap(fund, usdc, weth, 5_000e6, 2.5e18);
		skip(5 hours);
		_refreshFeeds();
		wethFeed.setAnswer(2_800e8);

		_requestDeposit(fund, manager, 1e6);
		fund.executeDepositRequest(manager);
		assertLt(_sharesOf(fund, manager), 1e18, 'only what the dust bought');

		stockFeed.setAnswer(80e8);
		_refreshFeeds();
		wethFeed.setAnswer(2_800e8);
		fund.settleFees();
		assertLt(_sharesOf(fund, manager), 1e18, 'no gain, no fee');
		assertApproxEqRel(_worth(fund, alice), 10_000e6, 1e15, 'alice keeps her half');
	}

	/// A loss on Monday means no fee was owed after all: the deposit's cheaper price is the same kind of edge as the last
	/// price, and the mark stays where the holders left it.
	function test_aDropBelowTheMarkOwesNoFee() public {
		ComptrollerV6 fund = _stockFundAboveItsMark();
		_closeTheMarket();
		_requestDeposit(fund, carol, 10_000e6);
		fund.executeDepositRequest(carol);
		stockFeed.setAnswer(90e8); // 19,000 of the 20,000 mark
		fund.settleFees();
		assertEq(_sharesOf(fund, manager), 0, 'below the mark');
	}

	/// The fee stop: a gain while a redemption is overdue is never charged, so nothing comes off the deposit's price.
	function test_anOverdueFundsDepositPaysTheFullPrice() public {
		ComptrollerV6 fund = _stockFundAboveItsMark();
		vm.mockCall(address(queue), abi.encodeCall(queue.isOverdue, (address(fund))), abi.encode(true));
		_closeTheMarket();
		_requestDeposit(fund, carol, 11_000e6);
		fund.executeDepositRequest(carol);
		assertApproxEqRel(_worth(fund, carol), 11_000e6, 1e15, 'the full price, with no fee to come');
		assertApproxEqRel(fund.highWaterMark(), 31_000e6 * 1e18 / fund.shares().totalSupply(), 1e15, 'a closed price never resets the mark');

		stockFeed.setAnswer(120e8);
		fund.settleFees();
		assertEq(_sharesOf(fund, manager), 0, 'the fee stop charges nothing');
		assertApproxEqRel(_worth(fund, alice), 11_000e6, 1e15, 'alice keeps the whole gain');
	}

	/// A stock in a limit order is the same stock: the deposit still buys.
	function test_aStockInAPositionDoesntStopADeposit() public {
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
		_requestDeposit(fund, carol, 10_000e6);
		fund.executeDepositRequest(carol);
		assertApproxEqRel(_worth(fund, carol), 10_000e6, 1e15);
	}

	/// settleFees still leaves the performance fee to a real price.
	function test_settleFeesStillLeavesThePerformanceFeeToARealPrice() public {
		ComptrollerV6 fund = _stockFundAboveItsMark();
		_closeTheMarket();
		uint256 grossBeforeTheFee = fund.calcGrossShareValue();
		assertEq(fund.settleFees(), grossBeforeTheFee, 'only a deposit prices after the waiting fee');
		assertEq(_sharesOf(fund, manager), 0, 'no fee at a closed price');

		stockFeed.setAnswer(120e8);
		fund.settleFees();
		assertApproxEqRel(_worth(fund, manager), 400e6, 1e15, 'charged once the price is real');
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

	/// A pool-priced token quoted against a stock reads the stock: its queue waits.
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

	// ─── perps on markets that close (red-team PF-01; founder 2026-11-03) ──────────

	/// @dev As live after MoveClosingMarketsToStoreV2: a perp's marker priced from the V2 store with a 5-day heartbeat.
	///      Alice and Bob in for 10,000 each, with `manage`d or owed units at $100 in a perp account.
	function _perpFund() internal returns (ComptrollerV6 fund, StubPerpAccount account, MockERC20 marker, MockStoreV2 prices) {
		prices = new MockStoreV2();
		marker = new MockERC20('Veranta MU', 'vmMU', 18);
		VerantaPriceAdapterV2 adapter = new VerantaPriceAdapterV2(VerantaPriceStoreV2(address(prices)), 105, 10 minutes, 5 days, 'MU/USD (Veranta)');
		registrar.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (address(marker), address(adapter), uint32(5 days))));
		_confirm(prices, block.timestamp);
		fund = ComptrollerV6(factory.createFund(_config(0, 0, 0)));
		vm.prank(manager);
		account = StubPerpAccount(fund.createExternalPosition(PERP_TYPE, ''));
		_deposit(fund, alice, 10_000e6);
		_deposit(fund, bob, 10_000e6);
	}

	/// @dev The keeper's push: Pyth signs $100 as current now, and the pair last traded at `lastTrade`.
	function _confirm(MockStoreV2 prices, uint256 lastTrade) internal {
		prices.set(10_000_000, -5, uint64(block.timestamp) * 1e6, uint64(lastTrade) * 1e6);
	}

	function test_aPerpOnAClosedMarketIsPriced_takesADeposit_andHoldsTheQueue() public {
		(ComptrollerV6 fund, StubPerpAccount account, MockERC20 marker, MockStoreV2 prices) = _perpFund();
		account.set(address(marker), 10e18, address(0), 0); // long: 10 units, $1,000
		uint256 close = block.timestamp;
		skip(5 hours);
		_refreshFeeds();
		_confirm(prices, close);
		assertApproxEqRel(fund.calcGav(), 21_000e6, 1e15, 'the fund stays priced');

		_requestDeposit(fund, carol, 10_500e6);
		_confirm(prices, close);
		fund.executeDepositRequest(carol);
		assertApproxEqRel(_worth(fund, carol), 10_500e6, 1e15, 'the deposit goes through at the last price');

		_request(fund, bob, _sharesOf(fund, bob));
		vm.prank(keeper);
		vm.expectRevert(RedemptionQueueV2.PriceUnreadable.selector);
		queue.settle(address(fund), 1);

		_confirm(prices, block.timestamp); // the market reopens
		vm.prank(keeper);
		queue.settle(address(fund), 1);
		assertApproxEqRel(usdc.balanceOf(bob), 10_500e6, 1e15, 'paid once the price is real');
	}

	/// A short's coin leg is owed, not held: the queue waits for it just the same.
	function test_aShortPerpOnAClosedMarketHoldsTheQueueToo() public {
		(ComptrollerV6 fund, StubPerpAccount account, MockERC20 marker, MockStoreV2 prices) = _perpFund();
		deal(address(usdc), address(account), 2_000e6);
		account.set(address(usdc), 2_000e6, address(marker), 10e18); // short: $2,000 of collateral, owes 10 units, $1,000
		uint256 close = block.timestamp;
		skip(5 hours);
		_refreshFeeds();
		_confirm(prices, close);
		assertApproxEqRel(fund.calcGav(), 21_000e6, 1e15, 'the fund stays priced');
		_requestDeposit(fund, carol, 10_500e6);
		_confirm(prices, close);
		fund.executeDepositRequest(carol);

		_request(fund, bob, _sharesOf(fund, bob));
		vm.prank(keeper);
		vm.expectRevert(RedemptionQueueV2.PriceUnreadable.selector);
		queue.settle(address(fund), 1);
	}

	/// An open market isn't held up: a recent trade pays the queue as before.
	function test_aPerpOnAnOpenMarketPaysTheQueue() public {
		(ComptrollerV6 fund, StubPerpAccount account, MockERC20 marker, MockStoreV2 prices) = _perpFund();
		account.set(address(marker), 10e18, address(0), 0);
		skip(1 hours);
		_refreshFeeds();
		_confirm(prices, block.timestamp - 1 hours); // an hour since its last trade is well inside the 4
		_request(fund, bob, _sharesOf(fund, bob) / 2);
		vm.prank(keeper);
		queue.settle(address(fund), 1);
		assertApproxEqRel(usdc.balanceOf(bob), 5_250e6, 1e15);
	}

	/// The price still has to be stored recently, as every store-priced read does: the keeper stores it before a deposit.
	function test_aPerpPriceNobodyStoredWaitsForTheKeeper() public {
		(ComptrollerV6 fund, StubPerpAccount account, MockERC20 marker, MockStoreV2 prices) = _perpFund();
		account.set(address(marker), 10e18, address(0), 0);
		uint256 stored = block.timestamp;
		_confirm(prices, stored);
		skip(5 hours);
		_refreshFeeds();
		_requestDeposit(fund, carol, 10_500e6);
		vm.expectRevert(abi.encodeWithSelector(VerantaPriceAdapterV2.StalePush.selector, stored));
		fund.executeDepositRequest(carol);

		_confirm(prices, stored);
		fund.executeDepositRequest(carol);
		assertGt(_sharesOf(fund, carol), 0);
	}

	/// `settleFees` no longer waits on the market: a cancel's fee stop must hold (review 2026-11-01, Low 6).
	function test_settleFeesRunsInAClosedMarket() public {
		ComptrollerV6 fund = _stockFund();
		_closeTheMarket();
		fund.settleFees();
	}
}
