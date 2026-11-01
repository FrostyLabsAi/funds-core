// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {ComptrollerV6} from '../src/core/ComptrollerV6.sol';
import {RedemptionFixtureV6} from './utils/RedemptionFixtureV6.sol';

/// @notice The v6 performance fee charges real gains at its rate and nothing else (red-team V6FEES-01 and V6FEES-02,
///         2026-10-27): the real ComptrollerV6, RedemptionQueueV2 and registrar, on a pool whose 30-minute price is scripted.
contract ComptrollerV6FeesTest is RedemptionFixtureV6 {
	int24 internal constant TICK_HALF = -6932; // ≈ $0.50
	int24 internal constant TICK_FIVE = 16095; // ≈ $5

	function _setTknTwapTick(int24 assetIsToken0Tick) internal {
		pool.setOracle(pool.token0() == address(tkn) ? assetIsToken0Tick : -assetIsToken0Tick, PLENTY);
	}

	function _perfFund(uint16 perfBps) internal returns (ComptrollerV6 fund) {
		fund = ComptrollerV6(factory.createFund(_config(0, perfBps, 0)));
		_deposit(fund, alice, 10_000e6);
	}

	/// @dev What `who`'s shares are worth at the fund's full GAV.
	function _worth(ComptrollerV6 fund, address who) internal returns (uint256) {
		return fund.calcGav() * _sharesOf(fund, who) / fund.shares().totalSupply();
	}

	// ─── V6FEES-01: the basis is what was spent ──────────────────────────────────

	/// A buy under the lagging 30-minute price is no gain: 2,000 TKN "worth" 2,000 for 1,000 USDC books 1,000 and mints no fee.
	function test_aBuyUnderTheLaggingPriceBooksWhatWasSpent_andChargesNoFee() public {
		ComptrollerV6 fund = _perfFund(2_000);
		_swap(fund, usdc, tkn, 1_000e6, 2_000e6);
		assertEq(fund.costBasis(address(tkn)), 1_000e6, 'the 1,000 USDC spent');
		fund.settleFees();
		assertEq(_sharesOf(fund, manager), 0, 'no fee on the paper gain');

		_setTknTwapTick(TICK_HALF); // the price catches up with the fill
		fund.settleFees();
		assertEq(_sharesOf(fund, manager), 0, 'still none');
		assertApproxEqRel(_worth(fund, alice), 10_000e6, 2e15, 'alice keeps what she put in');
	}

	/// A buy over the price is a loss at once: the basis is the value, not the overpayment.
	function test_aBuyOverThePriceBooksItsValue() public {
		ComptrollerV6 fund = _perfFund(2_000);
		_swap(fund, usdc, tkn, 2_000e6, 1_000e6);
		assertEq(fund.costBasis(address(tkn)), 1_000e6);
	}

	function test_aFairBuyBooksItsPrice_andChargesNoFee() public {
		ComptrollerV6 fund = _perfFund(2_000);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		assertEq(fund.costBasis(address(tkn)), 2_000e6);
		fund.settleFees();
		assertEq(_sharesOf(fund, manager), 0);
	}

	/// A real gain, once realized, is charged on what the buy really cost.
	function test_theGainFromABargainIsChargedWhenSold() public {
		ComptrollerV6 fund = _perfFund(2_000);
		_swap(fund, usdc, tkn, 1_000e6, 2_000e6); // 2,000 TKN at $1 for 1,000 USDC
		fund.settleFees();
		_swap(fund, tkn, usdc, 2_000e6, 2_000e6); // sold at $1: 1,000 of real gain
		assertEq(fund.costBasis(address(tkn)), 0, 'the basis left with the units');
		fund.settleFees();
		assertApproxEqRel(_worth(fund, manager), 200e6, 1e16, '20% of the 1,000 gain');
	}

	// ─── V6FEES-02: fee shares are sized on the full GAV ─────────────────────────

	/// With unrealized long-tail gains held, a real +1,000 pays 20% of it, not gav/feeGav times that.
	function test_feeSharesAreWorthTheRate_withUnrealizedLongTailGainsHeld() public {
		ComptrollerV6 fund = _perfFund(2_000);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		_setTknTwapTick(TICK_FIVE); // TKN to $5: unrealized, so no fee
		fund.settleFees();
		assertEq(_sharesOf(fund, manager), 0);

		wethFeed.setAnswer(3_000e8); // a real +1,000 on WETH
		fund.settleFees();
		assertApproxEqRel(_worth(fund, manager), 200e6, 1e15, '20% of the 1,000, at the full GAV');
	}

	/// The whole life of the trade pays the rate once on the real gain: TKN's 8,000 realized and WETH's 1,000.
	function test_realizingTheGainLaterPaysTheRateOnce() public {
		ComptrollerV6 fund = _perfFund(2_000);
		_swap(fund, usdc, tkn, 2_000e6, 2_000e6);
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		_setTknTwapTick(TICK_FIVE);
		wethFeed.setAnswer(3_000e8);
		fund.settleFees();

		_swap(fund, tkn, usdc, 2_000e6, 10_000e6); // sold at $5: 8,000 realized
		fund.settleFees();
		// 200 on the WETH, then 1,600 on the TKN, which dilutes the manager's own first 200 to 183: never past the rate
		// (fee shares sized on the fee GAV paid about 1,945 here)
		uint256 take = _worth(fund, manager);
		assertLe(take, 1_800e6, 'never past 20% of the 9,000 gain');
		assertGt(take, 1_780e6, 'the gain is charged');
	}

	/// Holding only cash and feed-priced tokens, fee GAV is full GAV: the fee is what it always was.
	function test_withoutLongTailTheFeeIsUnchanged() public {
		ComptrollerV6 fund = _perfFund(2_000);
		_swap(fund, usdc, weth, 2_000e6, 1e18);
		wethFeed.setAnswer(3_000e8);
		fund.settleFees();
		assertApproxEqRel(_worth(fund, manager), 200e6, 1e15);
		assertEq(fund.highWaterMark(), fund.calcGrossShareValue(), 'the mark follows the price');
	}
}
