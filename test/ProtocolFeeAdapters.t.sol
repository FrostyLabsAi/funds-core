// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {ProtocolFeeAdapter} from '../src/adapters/ProtocolFeeAdapter.sol';
import {UniswapV3SwapAdapterV2} from '../src/adapters/UniswapV3SwapAdapterV2.sol';
import {AerodromeSlipstreamSwapAdapterV2} from '../src/adapters/AerodromeSlipstreamSwapAdapterV2.sol';
import {AerodromeBasicSwapAdapterV2} from '../src/adapters/AerodromeBasicSwapAdapterV2.sol';
import {IUniswapV3SwapRouter} from '../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {ISlipstreamSwapRouter} from '../src/interfaces/external/ISlipstreamSwapRouter.sol';
import {IAerodromeRouter} from '../src/interfaces/external/IAerodromeRouter.sol';
import {MockERC20, MockSwapRouter} from './utils/Mocks.sol';

/// @dev Aerodrome basic router stand-in: takes `amountIn` of the first hop's token, mints `nextAmountOut`.
contract MockAerodromeRouter {
	uint256 public nextAmountOut;

	function setNextAmountOut(uint256 amountOut) external {
		nextAmountOut = amountOut;
	}

	function swapExactTokensForTokensSupportingFeeOnTransferTokens(
		uint256 amountIn,
		uint256,
		IAerodromeRouter.Route[] calldata routes,
		address to,
		uint256
	) external {
		MockERC20(routes[0].from).transferFrom(msg.sender, address(this), amountIn);
		MockERC20(routes[0].to).mint(to, nextAmountOut);
	}
}

/// @notice The protocol fee on spot swaps (spec 2026-10-08 §5; founder 2026-10-08: 0–10 bps, 5 at deployment, to the
///         Treasury) and the three V2 spot adapters that take it.
contract ProtocolFeeAdaptersTest is Test {
	MockERC20 internal usdc;
	MockERC20 internal tkn;
	MockSwapRouter internal router;
	MockAerodromeRouter internal aero;
	UniswapV3SwapAdapterV2 internal v3;
	AerodromeSlipstreamSwapAdapterV2 internal slip;
	AerodromeBasicSwapAdapterV2 internal basic;
	address internal treasury = makeAddr('treasury');
	address internal owner = makeAddr('owner');
	address internal vault = makeAddr('vault');

	function setUp() public {
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		tkn = new MockERC20('Token', 'TKN', 18);
		router = new MockSwapRouter();
		aero = new MockAerodromeRouter();
		v3 = new UniswapV3SwapAdapterV2(IUniswapV3SwapRouter(address(router)), treasury, 5, owner);
		slip = new AerodromeSlipstreamSwapAdapterV2(ISlipstreamSwapRouter(address(router)), treasury, 5, owner);
		basic = new AerodromeBasicSwapAdapterV2(IAerodromeRouter(address(aero)), makeAddr('factory'), treasury, 5, owner);
		router.setNextAmountOut(7e18);
		aero.setNextAmountOut(7e18);
	}

	/// @dev The Comptroller's order: spend assets to the adapter, then executeAction.
	function _send(address adapter, uint256 amount) internal {
		usdc.mint(adapter, amount);
	}

	function test_v3_takesFiveBpsForTheTreasury_andSwapsTheRest() public {
		_send(address(v3), 10_000e6);
		v3.executeAction(vault, abi.encode(address(usdc), address(tkn), uint24(3000), uint256(10_000e6), uint256(1)));
		assertEq(usdc.balanceOf(treasury), 5e6, '5 bps');
		assertEq(usdc.balanceOf(address(router)), 9_995e6, 'the rest is swapped');
		assertEq(tkn.balanceOf(vault), 7e18);
		assertEq(usdc.balanceOf(address(v3)), 0, 'nothing left behind');
		assertEq(router.lastFee(), 3000);
	}

	function test_slipstream_takesFiveBps() public {
		_send(address(slip), 10_000e6);
		slip.executeAction(vault, abi.encode(address(usdc), address(tkn), int24(100), uint256(10_000e6), uint256(1)));
		assertEq(usdc.balanceOf(treasury), 5e6);
		assertEq(usdc.balanceOf(address(router)), 9_995e6);
		assertEq(router.lastTickSpacing(), 100);
	}

	/// Aerodrome basic swaps what arrived (a taxed transfer in), so the fee is on what arrived too.
	function test_basic_takesFiveBpsOfWhatArrived() public {
		_send(address(basic), 9_000e6); // 10,000 stated, 9,000 arrived
		basic.executeAction(vault, abi.encode(address(usdc), address(tkn), uint256(10_000e6), uint256(1)));
		assertEq(usdc.balanceOf(treasury), 4.5e6);
		assertEq(usdc.balanceOf(address(aero)), 8_995.5e6);
	}

	/// The fund spends the full stated amount (the fee is part of the trade's cost).
	function test_parse_spendsTheFullAmount() public view {
		(address[] memory spend, uint256[] memory amounts, address[] memory incoming, uint256[] memory mins) =
			v3.parseAssetsForAction(abi.encode(address(usdc), address(tkn), uint24(3000), uint256(10_000e6), uint256(42)));
		assertEq(spend[0], address(usdc));
		assertEq(amounts[0], 10_000e6);
		assertEq(incoming[0], address(tkn));
		assertEq(mins[0], 42);
	}

	function test_fee_cappedAtTenBps() public {
		vm.prank(owner);
		vm.expectRevert(abi.encodeWithSelector(ProtocolFeeAdapter.FeeAboveCap.selector, uint16(11)));
		v3.setFeeBps(11);
		vm.prank(owner);
		v3.setFeeBps(10);
		assertEq(v3.feeBps(), 10);
		vm.expectRevert(abi.encodeWithSelector(ProtocolFeeAdapter.FeeAboveCap.selector, uint16(11)));
		new UniswapV3SwapAdapterV2(IUniswapV3SwapRouter(address(router)), treasury, 11, owner);
	}

	function test_fee_zeroSendsNothing() public {
		vm.prank(owner);
		v3.setFeeBps(0);
		_send(address(v3), 10_000e6);
		v3.executeAction(vault, abi.encode(address(usdc), address(tkn), uint24(3000), uint256(10_000e6), uint256(1)));
		assertEq(usdc.balanceOf(treasury), 0);
		assertEq(usdc.balanceOf(address(router)), 10_000e6);
	}

	function test_fee_ownerOnly() public {
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
		v3.setFeeBps(1);
	}

	function test_treasury_cannotBeZero() public {
		vm.expectRevert(ProtocolFeeAdapter.ZeroAddress.selector);
		new UniswapV3SwapAdapterV2(IUniswapV3SwapRouter(address(router)), address(0), 5, owner);
	}
}
