// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {IPolicy} from '../src/interfaces/IPolicy.sol';
import {IUniswapV3SwapRouter} from '../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {UniswapV3SwapAdapter} from '../src/adapters/UniswapV3SwapAdapter.sol';
import {CumulativeSlippageTolerancePolicy} from '../src/policies/CumulativeSlippageTolerancePolicy.sol';
import {RedemptionFixture} from './utils/RedemptionFixture.sol';

/// @notice A venue that pays a set amount out of the manager's own inventory, so the fund's loss is the manager's gain.
contract ManagerPoolRouter {
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

/// @title The slippage policy accrues every loss, however small (red-team ADAPTERS-01, 2026-10-27)
/// @dev Whole-bps accrual rounded each loss under 1 bp of GAV to 0, so 250 such trades took 246 bps against a 100 bps
///      tolerance with nothing accrued. Losses now accrue at 1e18 precision, rounded up.
contract SlippagePrecisionTest is RedemptionFixture {
	uint256 internal constant TOLERANCE_BPS = 100;
	CumulativeSlippageTolerancePolicy internal slippage;
	ManagerPoolRouter internal managerPool;
	UniswapV3SwapAdapter internal adapter;

	function setUp() public override {
		super.setUp();
		slippage = new CumulativeSlippageTolerancePolicy(TOLERANCE_BPS);
		managerPool = new ManagerPoolRouter(manager);
		adapter = new UniswapV3SwapAdapter(IUniswapV3SwapRouter(address(managerPool)), address(0xFEE), 0, address(this));
		factory.registerAdapter(address(adapter));
		deal(address(weth), manager, 1_000e18);
		vm.prank(manager);
		weth.approve(address(managerPool), type(uint256).max);
	}

	function _slippageFund() internal returns (Comptroller fund) {
		FundFactory.PolicyReg[] memory regs = new FundFactory.PolicyReg[](2);
		regs[0] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnIntegration, policy: address(slippage)});
		regs[1] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnExternalPosition, policy: address(slippage)});
		fund = Comptroller(factory.createFund(_config(0, 0, 0), regs));
		_deposit(fund, alice, 10_000e6);
	}

	/// @dev Buys WETH with `usdcIn` USDC, receiving WETH worth `usdcIn - lossUsdc` at the oracle ($2,000/WETH).
	function lossyBuy(Comptroller fund, uint256 usdcIn, uint256 lossUsdc) external {
		managerPool.setNextAmountOut((usdcIn - lossUsdc) * 5e8); // 1 USDC unit = 5e8 wei at $2,000
		vm.prank(manager);
		fund.callOnIntegration(address(adapter), abi.encode(address(usdc), address(weth), uint24(10_000), usdcIn, uint256(0)));
	}

	function _accruedBps(Comptroller fund) internal view returns (uint256 accrued) {
		(accrued,) = slippage.slippageStates(address(fund));
	}

	function test_oneTradeOverTheToleranceReverts() public {
		Comptroller fund = _slippageFund();
		vm.expectRevert(
			abi.encodeWithSelector(CumulativeSlippageTolerancePolicy.CumulativeSlippageExceeded.selector, 200, TOLERANCE_BPS)
		);
		this.lossyBuy(fund, 1_000e6, 200e6);
	}

	/// The red-team loop: each trade loses just under 1 bp of GAV. It now stops at the tolerance.
	function test_subBpsLossesAccrueAndStopAtTheTolerance() public {
		Comptroller fund = _slippageFund();
		uint256 gavStart = fund.calcGav();
		uint256 trades;
		bytes memory refusal;
		for (; trades < 250; ++trades) {
			uint256 loss = fund.calcGav() / 10_000 - 2;
			try this.lossyBuy(fund, 20e6, loss) {} catch (bytes memory reason) {
				refusal = reason;
				break;
			}
		}
		uint256 lostBps = (gavStart - fund.calcGav()) * 10_000 / gavStart;

		assertEq(bytes4(refusal), CumulativeSlippageTolerancePolicy.CumulativeSlippageExceeded.selector, 'the loop is refused');
		assertLt(trades, 250, 'refused before the loop ends');
		assertLe(lostBps, TOLERANCE_BPS, 'the fund lost no more than the tolerance');
		assertGe(_accruedBps(fund), TOLERANCE_BPS - 1, 'what was lost is what accrued');
	}

	function test_aLossUnderOneBpIsAccruedRoundedUp() public {
		Comptroller fund = _slippageFund();
		this.lossyBuy(fund, 20e6, 1); // 1e-6 USDC of a 10,000 USDC fund: 1e-6 bps
		assertEq(_accruedBps(fund), 1, 'shown as 1 bp, rounded up');
	}

	function test_aLosslessTradeAccruesNothing() public {
		Comptroller fund = _slippageFund();
		this.lossyBuy(fund, 20e6, 0);
		assertEq(_accruedBps(fund), 0);
	}

	/// The budget still replenishes linearly over 7 days, now at full precision.
	function test_theBudgetReplenishesOverSevenDays() public {
		Comptroller fund = _slippageFund();
		this.lossyBuy(fund, 1_000e6, 90e6); // 90 bps
		assertEq(_accruedBps(fund), 90);

		vm.warp(block.timestamp + 7 days);
		wethFeed.setAnswer(2000e8); // keep the feed inside its heartbeat
		usdcFeed.setAnswer(1e8);
		this.lossyBuy(fund, 1_000e6, 90e6); // allowed again: the first 90 bps were replenished
		assertEq(_accruedBps(fund), 91, 'only the new loss (90.8 bps of a smaller fund), rounded up');
	}
}
