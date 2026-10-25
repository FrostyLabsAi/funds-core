// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {ViaWethSellAdapterV2} from '../src/adapters/ViaWethSellAdapterV2.sol';
import {ProtocolFeeAdapter} from '../src/adapters/ProtocolFeeAdapter.sol';
import {MockERC20} from './utils/Mocks.sol';
import {MockAerodromeRouter, MockSlipstreamSingleRouter, MockUniswapV3Router} from './ViaWethSellAdapter.t.sol';

/// @notice ViaWethSellAdapterV2 (2026-10-25): V1's venues as before, plus Aero on its own router.
contract ViaWethSellAdapterV2Test is Test {
	MockERC20 internal usdc = new MockERC20('USD Coin', 'USDC', 6);
	MockERC20 internal weth = new MockERC20('Wrapped Ether', 'WETH', 18);
	MockERC20 internal cbeth = new MockERC20('Coinbase Wrapped Staked ETH', 'cbETH', 18);
	MockUniswapV3Router internal uni = new MockUniswapV3Router();
	MockSlipstreamSingleRouter internal s1 = new MockSlipstreamSingleRouter();
	MockSlipstreamSingleRouter internal s2 = new MockSlipstreamSingleRouter();
	MockSlipstreamSingleRouter internal s3 = new MockSlipstreamSingleRouter();
	MockSlipstreamSingleRouter internal aeroCl = new MockSlipstreamSingleRouter(); // Aero's SwapRouter: Slipstream's shape
	MockAerodromeRouter internal aerodrome = new MockAerodromeRouter();
	address internal constant AERODROME_FACTORY = address(0xFAC7);
	address internal treasury = makeAddr('treasury');
	address internal owner = makeAddr('owner');
	ViaWethSellAdapterV2 internal adapter;
	address internal fundVault = makeAddr('fundVault');

	function setUp() public {
		adapter = new ViaWethSellAdapterV2(
			address(weth), address(uni), address(s1), address(s2), address(s3), address(aerodrome), AERODROME_FACTORY,
			address(aeroCl), treasury, 5, owner
		);
		cbeth.mint(address(adapter), 4e18); // what the Comptroller sends before executeAction
	}

	function _hop(ViaWethSellAdapterV2.Venue venue, int24 param) internal pure returns (ViaWethSellAdapterV2.Hop memory) {
		return ViaWethSellAdapterV2.Hop(venue, param);
	}

	function _sale(ViaWethSellAdapterV2.Hop memory toWeth, ViaWethSellAdapterV2.Hop memory fromWeth)
		internal
		view
		returns (bytes memory)
	{
		return abi.encode(address(cbeth), uint256(4e18), uint256(7), address(usdc), toWeth, fromWeth);
	}

	function test_aeroThenAero_onAerosRouter_takesTheFeeOnce() public {
		adapter.executeAction(
			fundVault, _sale(_hop(ViaWethSellAdapterV2.Venue.Aero, 1), _hop(ViaWethSellAdapterV2.Venue.Aero, 50))
		);
		assertEq(aeroCl.lastKey(), 50, 'both hops on Aero\'s router, the WETH/USDC ts50 pool last');
		uint256 fee = 4e18 * 5 / 10_000;
		assertEq(cbeth.balanceOf(treasury), fee, '5 bps of the input, once');
		assertEq(usdc.balanceOf(fundVault), (4e18 - fee) * 4, 'the rest, at 2 per unit each hop');
		assertEq(s1.lastKey(), 0, 'no Slipstream router touched');
		assertEq(s2.lastKey(), 0);
		assertEq(s3.lastKey(), 0);
		assertEq(weth.balanceOf(address(adapter)), 0, 'holds nothing after a call');
		assertEq(cbeth.balanceOf(address(adapter)), 0);
	}

	function test_aeroMixesWithV1sVenues() public {
		adapter.executeAction(
			fundVault, _sale(_hop(ViaWethSellAdapterV2.Venue.Aero, 1), _hop(ViaWethSellAdapterV2.Venue.UniswapV3, 500))
		);
		assertEq(aeroCl.lastKey(), 1, 'cbETH to WETH on Aero');
		assertEq(uni.lastKey(), 500, 'WETH to USDC on Uniswap v3');
		cbeth.mint(address(adapter), 4e18);
		adapter.executeAction(
			fundVault, _sale(_hop(ViaWethSellAdapterV2.Venue.AerodromeBasic, 0), _hop(ViaWethSellAdapterV2.Venue.Slipstream3, 100))
		);
		assertEq(aerodrome.lastFactory(), AERODROME_FACTORY, 'V1\'s venues route as before');
		assertEq(s3.lastKey(), 100);
		assertEq(aeroCl.lastKey(), 1, 'Aero untouched by them');
	}

	function test_aPartialFillOnAero_reverts() public {
		aeroCl.setFillBps(9_900);
		vm.expectRevert(abi.encodeWithSelector(ViaWethSellAdapterV2.Unsold.selector, address(cbeth)));
		adapter.executeAction(
			fundVault, _sale(_hop(ViaWethSellAdapterV2.Venue.Aero, 1), _hop(ViaWethSellAdapterV2.Venue.UniswapV3, 500))
		);
	}

	function test_aVenuePastAeroDoesntDecode() public {
		vm.expectRevert();
		adapter.executeAction(
			fundVault, abi.encode(address(cbeth), uint256(4e18), uint256(0), address(usdc), uint8(6), int24(1), uint8(0), int24(500))
		);
		assertEq(cbeth.balanceOf(address(adapter)), 4e18, 'nothing moved');
	}

	function test_parse_refusesWethAtEitherEnd() public {
		ViaWethSellAdapterV2.Hop memory h = _hop(ViaWethSellAdapterV2.Venue.Aero, 50);
		vm.expectRevert(ViaWethSellAdapterV2.BadSale.selector);
		adapter.parseAssetsForAction(abi.encode(address(weth), uint256(1), uint256(0), address(usdc), h, h));
		vm.expectRevert(ViaWethSellAdapterV2.BadSale.selector);
		adapter.parseAssetsForAction(abi.encode(address(cbeth), uint256(1), uint256(0), address(weth), h, h));
	}

	function test_constructor_rejectsAZeroAeroRouter() public {
		vm.expectRevert(ProtocolFeeAdapter.ZeroAddress.selector);
		new ViaWethSellAdapterV2(
			address(weth), address(uni), address(s1), address(s2), address(s3), address(aerodrome), AERODROME_FACTORY,
			address(0), treasury, 5, owner
		);
	}
}
