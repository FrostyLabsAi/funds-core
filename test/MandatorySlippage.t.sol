// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ComptrollerV6} from '../src/core/ComptrollerV6.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {IPolicy} from '../src/interfaces/IPolicy.sol';
import {IUniswapV3SwapRouter} from '../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {UniswapV3SwapAdapter} from '../src/adapters/UniswapV3SwapAdapter.sol';
import {CumulativeSlippageTolerancePolicy} from '../src/policies/CumulativeSlippageTolerancePolicy.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';
import {RedemptionFixtureV6} from './utils/RedemptionFixtureV6.sol';

/// @notice A venue that pays a set amount out of the manager's own inventory, so the fund's loss is the manager's gain.
contract ManagerRouter {
	address public immutable manager;
	uint256 public nextAmountOut;

	constructor(address manager_) {
		manager = manager_;
	}

	function setNextAmountOut(uint256 amountOut) external {
		nextAmountOut = amountOut;
	}

	function exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams calldata p) external returns (uint256) {
		IERC20(p.tokenIn).transferFrom(msg.sender, manager, p.amountIn);
		IERC20(p.tokenOut).transferFrom(manager, p.recipient, nextAmountOut);
		return nextAmountOut;
	}
}

/// @notice Takes `stated` of a token, refunds part to the vault as a CLM deposit refunds what the ratio doesn't take, and pays
///         `out` of another. What it was stated to spend isn't what it spent.
contract RefundingAdapter {
	function parseAssetsForAction(bytes calldata data)
		external
		pure
		returns (address[] memory spend, uint256[] memory amounts, address[] memory incoming, uint256[] memory minIncoming)
	{
		(address tokenIn, address tokenOut, uint256 stated,,) = abi.decode(data, (address, address, uint256, uint256, uint256));
		spend = new address[](1);
		amounts = new uint256[](1);
		incoming = new address[](1);
		minIncoming = new uint256[](1);
		spend[0] = tokenIn;
		amounts[0] = stated;
		incoming[0] = tokenOut;
	}

	function executeAction(address vault, bytes calldata data) external {
		(address tokenIn, address tokenOut,, uint256 refund, uint256 out) = abi.decode(data, (address, address, uint256, uint256, uint256));
		IERC20(tokenIn).transfer(vault, refund);
		MockERC20(tokenOut).mint(vault, out);
	}
}

/// @title Every new fund carries the slippage policy (red-team ADAPTERS-02, 2026-10-27)
/// @dev Before this a manager could trade a fund's value away to themselves in one transaction: no mandatory policy bound a
///      trade's price, and `minIncomingAmounts` is the manager's own. The factory attaches the policy to every new fund,
///      as WindowedPricing.switchNewFunds lists it.
contract MandatorySlippageTest is RedemptionFixtureV6 {
	uint256 internal constant TOLERANCE_BPS = 500;
	CumulativeSlippageTolerancePolicy internal slippage;
	ManagerRouter internal managerVenue;
	UniswapV3SwapAdapter internal adapter;

	function setUp() public override {
		super.setUp();
		slippage = new CumulativeSlippageTolerancePolicy(TOLERANCE_BPS);
		FundFactory.PolicyReg[] memory regs = new FundFactory.PolicyReg[](2);
		regs[0] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnIntegration, policy: address(slippage)});
		regs[1] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnExternalPosition, policy: address(slippage)});
		factory.setMandatoryPolicies(regs);
		managerVenue = new ManagerRouter(manager);
		adapter = new UniswapV3SwapAdapter(IUniswapV3SwapRouter(address(managerVenue)));
		factory.registerAdapter(address(adapter));
		deal(address(weth), manager, 1_000e18);
		vm.prank(manager);
		weth.approve(address(managerVenue), type(uint256).max);
	}

	function _plainFund() internal returns (ComptrollerV6 fund) {
		// no ruleset of its own: the manager opted into nothing
		fund = ComptrollerV6(factory.createFund(_config(0, 0, 0)));
		_deposit(fund, alice, 10_000e6);
	}

	/// @dev Buys WETH ($2,000) with `usdcIn` USDC, getting `lossUsdc` less than it's worth.
	function _lossyBuy(ComptrollerV6 fund, uint256 usdcIn, uint256 lossUsdc) internal {
		managerVenue.setNextAmountOut((usdcIn - lossUsdc) * 5e8);
		vm.prank(manager);
		fund.callOnIntegration(address(adapter), abi.encode(address(usdc), address(weth), uint24(10_000), usdcIn, uint256(0)));
	}

	function test_aNewFundCarriesThePolicyWithoutOptingIn() public {
		ComptrollerV6 fund = _plainFund();
		address[] memory onTrades = fund.getPolicies(IPolicy.PolicyHook.PostCallOnIntegration);
		bool found;
		for (uint256 i; i < onTrades.length; ++i) {
			if (onTrades[i] == address(slippage)) found = true;
		}
		assertTrue(found);
	}

	/// The drain: the whole fund for almost nothing, in one transaction.
	function test_tradingTheFundAwayInOneTransactionIsRefused() public {
		ComptrollerV6 fund = _plainFund();
		managerVenue.setNextAmountOut(1);
		vm.prank(manager);
		vm.expectRevert();
		fund.callOnIntegration(address(adapter), abi.encode(address(usdc), address(weth), uint24(10_000), uint256(10_000e6), uint256(0)));
		assertEq(usdc.balanceOf(address(fund.vault())), 10_000e6, 'nothing left the vault');
	}

	/// Just over the budget in one trade is refused; a normal fill's cost passes.
	function test_theBudgetIsFivePercentOfTheFund() public {
		ComptrollerV6 fund = _plainFund();
		managerVenue.setNextAmountOut((1_000e6 - 510e6) * 5e8);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(CumulativeSlippageTolerancePolicy.CumulativeSlippageExceeded.selector, 510, TOLERANCE_BPS));
		fund.callOnIntegration(address(adapter), abi.encode(address(usdc), address(weth), uint24(10_000), uint256(1_000e6), uint256(0)));

		_lossyBuy(fund, 1_000e6, 3e6); // 0.3% on a tenth of the fund: 3 bps of the budget
		(uint128 accrued,) = slippage.slippageStates(address(fund));
		assertEq(accrued, 3);
	}

	/// Many small losses share the budget, and it refills over the week.
	function test_smallLossesShareTheBudget_andItRefills() public {
		ComptrollerV6 fund = _plainFund();
		for (uint256 i; i < 4; ++i) {
			_lossyBuy(fund, 500e6, 100e6); // about 1% each
		}
		managerVenue.setNextAmountOut((500e6 - 200e6) * 5e8);
		vm.prank(manager);
		vm.expectRevert();
		fund.callOnIntegration(address(adapter), abi.encode(address(usdc), address(weth), uint24(10_000), uint256(500e6), uint256(0)));

		skip(7 days);
		_refreshFeeds();
		_lossyBuy(fund, 500e6, 200e6); // refilled
	}

	/// The policy never holds the keeper: a liquidation has its own 3% cap.
	function test_theKeepersLiquidationIsNotHeldByThePolicy() public {
		ComptrollerV6 fund = _plainFund();
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		_request(fund, alice, _sharesOf(fund, alice));
		skip(5 days);
		_refreshFeeds();
		router.setNextAmountOut(1_940e6);
		vm.prank(keeper);
		queue.liquidate(address(fund), address(uniAdapter), abi.encode(address(weth), address(usdc), uint24(3000), uint256(1e18), uint256(0)));
		assertEq(weth.balanceOf(address(fund.vault())), 0, 'sold');
	}

	/// A deposit's refund is no loss: the policy reads what left the vault, not what was stated (review 2026-11-01, Medium 4).
	function test_aRefundIsNoLoss() public {
		ComptrollerV6 fund = _plainFund();
		RefundingAdapter refunding = new RefundingAdapter();
		factory.registerAdapter(address(refunding));
		// stated 3,000, refunded 2,000: 1,000 spent, for 1,000 of WETH
		vm.prank(manager);
		fund.callOnIntegration(address(refunding), abi.encode(address(usdc), address(weth), uint256(3_000e6), uint256(2_000e6), uint256(0.5e18)));
		(uint256 accrued,) = slippage.slippageStates(address(fund));
		assertEq(accrued, 0);
	}

	/// A price elsewhere in the fund going stale (a Veranta stock's 2-minute store) doesn't stop a plain swap: without GAV the
	/// loss is charged against the trade itself, which can only overstate it (review 2026-11-01, Medium 5).
	function test_aStaleHoldingElsewhereDoesNotStopASwap_andChargesAgainstTheTrade() public {
		ComptrollerV6 fund = _plainFund();
		MockERC20 stock = new MockERC20('Stock', 'STK', 18);
		registrar.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (address(stock), address(new MockAggregator(8, 100e8)), uint32(2 minutes))));
		_swap(fund, usdc, stock, 1_000e6, 10e18);
		skip(5 minutes);
		_refreshFeeds();
		vm.expectRevert();
		fund.calcGav();

		_swap(fund, usdc, weth, 1_000e6, 0.495e18); // 990 of WETH for 1,000: a 10 loss, 1% of the trade
		(uint256 accrued,) = slippage.slippageStates(address(fund));
		assertEq(accrued, 100);
	}

	/// Where GAV reads, the loss is charged against the fund, as before.
	function test_aFreshFundChargesAgainstItsValue() public {
		ComptrollerV6 fund = _plainFund();
		_swap(fund, usdc, weth, 1_000e6, 0.495e18); // a 10 loss of a 10,000 fund: 10 bps
		(uint256 accrued,) = slippage.slippageStates(address(fund));
		assertEq(accrued, 10);
	}
}
