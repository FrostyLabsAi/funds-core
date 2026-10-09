// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {ComptrollerBlueprintDeployer} from '../src/core/FundComponentDeployers.sol';
import {ComptrollerV3} from '../src/core/ComptrollerV3.sol';
import {ComptrollerV5} from '../src/core/ComptrollerV5.sol';
import {InKindRedemption} from '../src/core/InKindRedemption.sol';
import {MockUnwindPosition} from './utils/MockUnwindPosition.sol';
import {ComptrollerV3Test} from './ComptrollerV3.t.sol';

/// @notice Fund version 5 = version 3 with an in-kind exit that pays the whole value (founder 2026-10-09: no exit may
///         pay a redeemer less than their shares' value). While the fund holds perps or LPs, in kind pays the slice of
///         every vault token and the share of the positions, in USDC first, then in the vault's readable,
///         non-pool-priced tokens; when the vault can't cover it all, it reverts and the redeemer keeps the shares.
///         A pure-spot fund keeps V3's in kind. The whole V3 suite runs here against V5.
contract ComptrollerV5Test is ComptrollerV3Test {
	function setUp() public override {
		super.setUp();
		factory.setComptrollerDeployer(
			new ComptrollerBlueprintDeployer(type(ComptrollerV5).creationCode, abi.encode(registrar, queue))
		);
	}

	/// V3 paid a tenth of the vault's 6,000 and forfeited the position's 4,000 (TestFund4, 2026-10-09: $1.97 paid
	/// for $9.51 of shares). V5 pays the whole tenth: the vault's USDC covers the position's share.
	function test_inKindExit_staysOpenWithPositionsHeld() public override {
		(ComptrollerV3 fund,) = _fundWithUnwindPosition(); // vault 6,000 USDC, position 4,000
		uint256 tenth = _sharesOf(fund, alice) / 10;
		uint256 supply = fund.shares().totalSupply();
		vm.prank(alice);
		fund.redeemSharesInKind(tenth);
		assertEq(usdc.balanceOf(alice), 10_000e6 * tenth / supply, 'a tenth of the whole 10,000, nothing forfeited');
		assertEq(_sharesOf(fund, alice), tenth * 9);
	}

	/// No USDC in the vault: the position's share is paid in extra WETH (readable, not pool-priced), at its price.
	function test_v5_thePositionsShareIsCoveredByAFeedPricedToken() public {
		ComptrollerV3 fund = _fund(0);
		_swap(fund, usdc, weth, 6_000e6, 3e18); // 3 WETH ($6,000) + 4,000 USDC
		_moveToPosition(fund, 4_000e6); // vault: 3 WETH, 0 USDC; position 4,000
		uint256 tenth = _sharesOf(fund, alice) / 10;
		uint256 supply = fund.shares().totalSupply();
		vm.prank(alice);
		fund.redeemSharesInKind(tenth);
		assertEq(usdc.balanceOf(alice), 0);
		// slice 0.3 WETH + the position's 400 as 0.2 WETH = 0.5 WETH = $1,000 (a tenth of 10,000)
		assertApproxEqAbs(weth.balanceOf(alice) * 2_000e6 / 1e18, 10_000e6 * tenth / supply, 2, 'the whole tenth, in WETH');
		assertApproxEqAbs(weth.balanceOf(alice), 0.5e18, 0.001e18);
	}

	/// A pool-priced token never covers (a pumped long-tail price must not pull value out): it's paid as its slice, and
	/// with nothing else in the vault the position's share can't be paid, so the exit reverts and the shares stay.
	function test_v5_aPoolPricedTokenNeverCovers_theExitRevertsAndTheSharesStay() public {
		ComptrollerV3 fund = _fund(0);
		_swap(fund, usdc, tkn, 6_000e6, 6_000e6); // 6,000 TKN ($1, pool-priced) + 4,000 USDC
		_moveToPosition(fund, 4_000e6);
		uint256 tenth = _sharesOf(fund, alice) / 10;
		vm.prank(alice);
		vm.expectRevert(InKindRedemption.InKindNotCovered.selector);
		fund.redeemSharesInKind(tenth);
		assertEq(_sharesOf(fund, alice), tenth * 10, 'shares untouched');
		assertEq(_held(fund, tkn), 6_000e6, 'vault untouched');
	}

	/// Never a partial payment: when the vault can't cover the whole request, nothing is paid.
	function test_v5_moreThanTheVaultCanCover_reverts() public {
		ComptrollerV3 fund = _fund(0);
		_swap(fund, usdc, weth, 6_000e6, 3e18);
		_moveToPosition(fund, 4_000e6); // vault 3 WETH ($6,000); the position's 4,000 can only be paid from it
		uint256 most = _sharesOf(fund, alice) * 9 / 10; // owed 9,000: 5,400 of WETH slice + 3,600, only 600 of WETH left
		vm.prank(alice);
		vm.expectRevert(InKindRedemption.InKindNotCovered.selector);
		fund.redeemSharesInKind(most);
	}

	/// Skipping a token forfeits its slice: not allowed while the fund holds a position (the whole value or nothing).
	function test_v5_skipsAreRefusedWithAPositionHeld() public {
		(ComptrollerV3 fund,) = _fundWithUnwindPosition();
		address[] memory skip = new address[](1);
		skip[0] = address(weth);
		vm.prank(alice);
		vm.expectRevert(InKindRedemption.InKindNotCovered.selector);
		fund.redeemSharesInKindWithSkips(1e18, skip);
	}

	/// A token whose price can't be read is paid as its slice and never covers; the USDC pays the position's share.
	function test_v5_aStalePriceDoesntBlockIt_thatTokenIsPaidAsItsSlice() public {
		ComptrollerV3 fund = _fund(0);
		_swap(fund, usdc, weth, 5_000e6, 2.5e18); // 2.5 WETH + 5,000 USDC
		_moveToPosition(fund, 4_000e6); // vault: 2.5 WETH + 1,000 USDC; position 4,000
		skip(2 hours); // WETH's feed (1 h heartbeat) is stale; USDC's (25 h) still reads
		uint256 tenth = _sharesOf(fund, alice) / 10;
		uint256 supply = fund.shares().totalSupply();
		vm.prank(alice);
		fund.redeemSharesInKind(tenth);
		assertEq(weth.balanceOf(alice), 2.5e18 * tenth / supply, 'WETH: its slice');
		assertEq(usdc.balanceOf(alice), 5_000e6 * tenth / supply, 'USDC: its slice + the position share');
	}

	/// A pure-spot fund keeps V3's in kind: a slice of every token, no prices needed.
	function test_v5_aPureSpotFund_paysTheSliceOfEveryToken() public {
		ComptrollerV3 fund = _fund(0);
		_swap(fund, usdc, weth, 5_000e6, 2.5e18);
		uint256 tenth = _sharesOf(fund, alice) / 10;
		uint256 supply = fund.shares().totalSupply();
		vm.prank(alice);
		fund.redeemSharesInKind(tenth);
		assertEq(weth.balanceOf(alice), 2.5e18 * tenth / supply);
		assertEq(usdc.balanceOf(alice), 5_000e6 * tenth / supply);
	}

	/// The terminal tells a V5 fund apart (it offers in kind on a fund holding positions only there).
	function test_v5_saysItsInKindPaysTheFullValue() public {
		ComptrollerV3 fund = _fund(0);
		assertTrue(ComptrollerV5(address(fund)).inKindPaysFullValue());
	}

	/// V3's in-kind event, so the subgraph records V5's exit as before (assets and amounts).
	function test_v5_emitsV3sInKindEvent() public {
		(ComptrollerV3 fund,) = _fundWithUnwindPosition();
		uint256 tenth = _sharesOf(fund, alice) / 10;
		address[] memory assets = new address[](1);
		assets[0] = address(usdc);
		uint256[] memory amounts = new uint256[](1);
		amounts[0] = 10_000e6 * tenth / fund.shares().totalSupply();
		vm.expectEmit(true, false, false, true, address(fund));
		emit ComptrollerV3.SharesRedeemedInKind(alice, tenth, assets, amounts);
		vm.prank(alice);
		fund.redeemSharesInKind(tenth);
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	/// A position (the test's perp account) holding `amount` USDC from the vault.
	function _moveToPosition(ComptrollerV3 fund, uint256 amount) internal returns (MockUnwindPosition position) {
		vm.startPrank(manager);
		position = MockUnwindPosition(fund.createExternalPosition(UNWIND_TYPE, ''));
		(address[] memory assets, uint256[] memory amounts) = _usdc(amount);
		fund.callOnExternalPosition(address(position), assets, amounts, new address[](0), abi.encode(uint8(0), abi.encode(amount)));
		vm.stopPrank();
	}
}
