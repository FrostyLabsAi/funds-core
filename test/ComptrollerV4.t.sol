// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {ComptrollerBlueprintDeployer} from '../src/core/FundComponentDeployers.sol';
import {ComptrollerV3} from '../src/core/ComptrollerV3.sol';
import {ComptrollerV4} from '../src/core/ComptrollerV4.sol';
import {MockUnwindPosition} from './utils/MockUnwindPosition.sol';
import {ComptrollerV3Test} from './ComptrollerV3.t.sol';

/// @notice Fund version 4 = version 3 without the in-kind exit that forfeits (founder 2026-10-09: no
///         exit may pay a redeemer less than their shares' value). While a fund holds perps or LPs,
///         in kind is refused and the queue is the exit; a pure-spot fund keeps it, since there a
///         slice of every token is the whole value. The whole V3 suite runs here against V4.
contract ComptrollerV4Test is ComptrollerV3Test {
	function setUp() public override {
		super.setUp();
		factory.setComptrollerDeployer(
			new ComptrollerBlueprintDeployer(type(ComptrollerV4).creationCode, abi.encode(registrar, queue))
		);
	}

	/// V3's escape hatch paid 6,000 of a 10,000 fund's value and kept the position's 4,000 from the
	/// redeemer (TestFund4, 2026-10-09: $1.97 paid for $9.51 of shares). V4 refuses it.
	function test_inKindExit_staysOpenWithPositionsHeld() public override {
		(ComptrollerV3 fund,) = _fundWithUnwindPosition();
		uint256 tenth = _sharesOf(fund, alice) / 10;
		vm.prank(alice);
		vm.expectRevert(ComptrollerV3.UseRedemptionQueue.selector);
		fund.redeemSharesInKind(tenth);
		assertEq(_sharesOf(fund, alice), tenth * 10, 'shares untouched');
		assertEq(_held(fund, usdc), 6_000e6, 'vault untouched');
	}

	function test_v4_inKindWithSkips_refusedWhileTheFundHoldsAPosition() public {
		(ComptrollerV3 fund,) = _fundWithUnwindPosition();
		vm.prank(alice);
		vm.expectRevert(ComptrollerV3.UseRedemptionQueue.selector);
		fund.redeemSharesInKindWithSkips(1e18, new address[](0));
	}

	/// A pure-spot fund: a tenth of every token is a tenth of the fund's value.
	function test_v4_spotOnlyFund_inKindPaysTheFullValue() public {
		ComptrollerV3 fund = _fund(0);
		_swap(fund, usdc, weth, 5_000e6, 2.5e18); // 5,000 USDC + 2.5 WETH ($5,000)
		uint256 tenth = _sharesOf(fund, alice) / 10;
		uint256 supply = fund.shares().totalSupply();
		uint256 valueOfTenth = fund.calcGav() * tenth / supply;
		vm.prank(alice);
		fund.redeemSharesInKind(tenth);
		uint256 received = usdc.balanceOf(alice) + weth.balanceOf(alice) * 2_000e6 / 1e18;
		assertApproxEqAbs(received, valueOfTenth, 2, 'the whole value, nothing forfeited');
		assertEq(weth.balanceOf(alice), 2.5e18 * tenth / supply, 'a tenth of the WETH');
	}

	/// The check is the fund's state at the call: once the manager closes and removes the position,
	/// in kind is open again.
	function test_v4_inKindOpensAgainOnceThePositionIsRemoved() public {
		(ComptrollerV3 fund, MockUnwindPosition position) = _fundWithUnwindPosition();
		vm.startPrank(manager);
		fund.callOnExternalPosition(address(position), new address[](0), new uint256[](0), new address[](0), abi.encode(uint8(1), abi.encode(uint256(4_000e6))));
		(address[] memory back,) = _usdc(0);
		fund.callOnExternalPosition(address(position), new address[](0), new uint256[](0), back, abi.encode(uint8(6), abi.encode(uint256(4_000e6))));
		fund.removeExternalPosition(address(position));
		vm.stopPrank();

		uint256 tenth = _sharesOf(fund, alice) / 10;
		uint256 expected = 10_000e6 * tenth / fund.shares().totalSupply();
		vm.prank(alice);
		fund.redeemSharesInKind(tenth);
		assertEq(usdc.balanceOf(alice), expected, 'a slice of the whole 10,000, the position back in the vault');
	}
}
