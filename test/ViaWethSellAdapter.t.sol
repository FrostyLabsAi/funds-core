// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ViaWethSellAdapter} from '../src/adapters/ViaWethSellAdapter.sol';
import {ProtocolFeeAdapter} from '../src/adapters/ProtocolFeeAdapter.sol';
import {IUniswapV3SwapRouter} from '../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {ISlipstreamSwapRouter} from '../src/interfaces/external/ISlipstreamSwapRouter.sol';
import {IAerodromeRouter} from '../src/interfaces/external/IAerodromeRouter.sol';
import {MockERC20} from './utils/Mocks.sol';

/// @dev What every router stand-in does: takes `fillBps` of the input (a pool out of liquidity fills part) and pays
///      `rate` out per 1e18 in. Each subclass answers only its own router's call shape, so a hop sent with another
///      venue's shape reverts (review 2026-10-14: one mock answering every shape couldn't catch a swapped one).
abstract contract MockRouterBase {
	uint256 public rate = 2e18;
	uint256 public fillBps = 10_000;
	int256 public lastKey; // the fee, the tick spacing, or -1 for an Aerodrome volatile route
	address public lastFactory;

	function setFillBps(uint256 bps) external {
		fillBps = bps;
	}

	function _swap(address tokenIn, address tokenOut, uint256 amountIn, address to) internal returns (uint256 out) {
		uint256 taken = (amountIn * fillBps) / 10_000;
		IERC20(tokenIn).transferFrom(msg.sender, address(this), taken);
		out = (taken * rate) / 1e18;
		MockERC20(tokenOut).mint(to, out);
	}
}

/// @dev SwapRouter02: exactInputSingle without a deadline.
contract MockUniswapV3Router is MockRouterBase {
	function exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams calldata p) external returns (uint256) {
		lastKey = int256(uint256(p.fee));
		return _swap(p.tokenIn, p.tokenOut, p.amountIn, p.recipient);
	}
}

/// @dev The Slipstream SwapRouter: exactInputSingle keyed by tick spacing, with a deadline.
contract MockSlipstreamSingleRouter is MockRouterBase {
	function exactInputSingle(ISlipstreamSwapRouter.ExactInputSingleParams calldata p) external returns (uint256) {
		lastKey = p.tickSpacing;
		return _swap(p.tokenIn, p.tokenOut, p.amountIn, p.recipient);
	}
}

/// @dev The Aerodrome Router's fee-on-transfer exact-in swap over (from, to, stable, factory) routes.
contract MockAerodromeRouter is MockRouterBase {
	function swapExactTokensForTokensSupportingFeeOnTransferTokens(
		uint256 amountIn,
		uint256,
		IAerodromeRouter.Route[] calldata routes,
		address to,
		uint256
	) external {
		require(routes.length == 1 && !routes[0].stable, 'one volatile route');
		lastKey = -1;
		lastFactory = routes[0].factory;
		_swap(routes[0].from, routes[0].to, amountIn, to);
	}
}

contract ViaWethSellAdapterTest is Test {
	MockERC20 internal usdc = new MockERC20('USD Coin', 'USDC', 6);
	MockERC20 internal weth = new MockERC20('Wrapped Ether', 'WETH', 18);
	MockERC20 internal cbeth = new MockERC20('Coinbase Wrapped Staked ETH', 'cbETH', 18);
	MockUniswapV3Router internal uni = new MockUniswapV3Router();
	MockSlipstreamSingleRouter internal s1 = new MockSlipstreamSingleRouter();
	MockSlipstreamSingleRouter internal s2 = new MockSlipstreamSingleRouter();
	MockSlipstreamSingleRouter internal s3 = new MockSlipstreamSingleRouter();
	MockSlipstreamSingleRouter internal aeroCl = new MockSlipstreamSingleRouter(); // Aero's SwapRouter: Slipstream's shape
	MockAerodromeRouter internal aero = new MockAerodromeRouter();
	address internal constant AERO_FACTORY = address(0xFAC7);
	address internal treasury = makeAddr('treasury');
	address internal owner = makeAddr('owner');
	ViaWethSellAdapter internal adapter;
	address internal fundVault = makeAddr('fundVault');

	function setUp() public {
		adapter = _adapter(address(uni), address(s1), address(aero), 5);
		cbeth.mint(address(adapter), 4e18); // what the Comptroller sends before executeAction
	}

	function _adapter(address uni_, address s1_, address aero_, uint16 feeBps) internal returns (ViaWethSellAdapter) {
		return new ViaWethSellAdapter(
			address(weth), uni_, s1_, address(s2), address(s3), aero_, AERO_FACTORY, address(aeroCl), treasury, feeBps, owner
		);
	}

	function _hop(ViaWethSellAdapter.Venue venue, int24 param) internal pure returns (ViaWethSellAdapter.Hop memory) {
		return ViaWethSellAdapter.Hop(venue, param);
	}

	function _sale(ViaWethSellAdapter.Hop memory toWeth, ViaWethSellAdapter.Hop memory fromWeth)
		internal
		view
		returns (bytes memory)
	{
		return abi.encode(address(cbeth), uint256(4e18), uint256(7), address(usdc), toWeth, fromWeth);
	}

	function test_parse_oneTokenInOneAssetOut() public view {
		(address[] memory spend, uint256[] memory amounts, address[] memory incoming, uint256[] memory mins) = adapter
			.parseAssetsForAction(
			_sale(_hop(ViaWethSellAdapter.Venue.Slipstream1, 1), _hop(ViaWethSellAdapter.Venue.UniswapV3, 500))
		);
		assertEq(spend.length, 1);
		assertEq(spend[0], address(cbeth));
		assertEq(amounts[0], 4e18);
		assertEq(incoming.length, 1, 'one asset back: the shape a v6 liquidation sale needs');
		assertEq(incoming[0], address(usdc));
		assertEq(mins[0], 7);
	}

	function test_parse_refusesWethAtEitherEndOrNoSale() public {
		ViaWethSellAdapter.Hop memory h = _hop(ViaWethSellAdapter.Venue.UniswapV3, 500);
		vm.expectRevert(ViaWethSellAdapter.BadSale.selector);
		adapter.parseAssetsForAction(abi.encode(address(weth), uint256(1), uint256(0), address(usdc), h, h));
		vm.expectRevert(ViaWethSellAdapter.BadSale.selector);
		adapter.parseAssetsForAction(abi.encode(address(cbeth), uint256(1), uint256(0), address(weth), h, h));
		vm.expectRevert(ViaWethSellAdapter.BadSale.selector);
		adapter.parseAssetsForAction(abi.encode(address(usdc), uint256(1), uint256(0), address(usdc), h, h));
	}

	function test_slipstreamThenUniswap_takesTheFeeOnce_andPaysTheFundTheRest() public {
		adapter.executeAction(
			fundVault, _sale(_hop(ViaWethSellAdapter.Venue.Slipstream1, 1), _hop(ViaWethSellAdapter.Venue.UniswapV3, 500))
		);
		assertEq(s1.lastKey(), 1, 'cbETH to WETH on the Slipstream-1 ts1 pool');
		assertEq(uni.lastKey(), 500, 'WETH to USDC on the Uniswap v3 0.05% pool');
		uint256 fee = 4e18 * 5 / 10_000;
		assertEq(cbeth.balanceOf(treasury), fee, '5 bps of the input, once');
		assertEq(weth.balanceOf(treasury), 0, 'no second fee on the WETH hop');
		assertEq(usdc.balanceOf(fundVault), (4e18 - fee) * 4, 'the rest, at 2 per unit each hop');
		assertEq(weth.balanceOf(fundVault), 0);
		assertEq(cbeth.balanceOf(address(adapter)), 0);
		assertEq(weth.balanceOf(address(adapter)), 0);
		assertEq(usdc.balanceOf(address(adapter)), 0, 'holds nothing after a call');
	}

	function test_aerodromeThenSlipstream_usesTheVolatilePoolOfTheDefaultFactory() public {
		adapter.executeAction(
			fundVault,
			_sale(_hop(ViaWethSellAdapter.Venue.AerodromeBasic, 0), _hop(ViaWethSellAdapter.Venue.Slipstream3, 100))
		);
		assertEq(aero.lastKey(), -1);
		assertEq(aero.lastFactory(), AERO_FACTORY);
		assertEq(s3.lastKey(), 100);
		assertEq(usdc.balanceOf(fundVault), (4e18 - 4e18 * 5 / 10_000) * 4);
		assertEq(s1.lastKey(), 0, 'no other venue touched');
		assertEq(s2.lastKey(), 0);
	}

	/// The mocks answer only their own router's shape: a venue wired to another router's shape reverts.
	function test_aHopSentInAnotherVenuesShapeReverts() public {
		ViaWethSellAdapter swapped = _adapter(address(s1), address(uni), address(aero), 5); // Uniswap and Slipstream-1 crossed
		cbeth.mint(address(swapped), 1e18);
		vm.expectRevert();
		swapped.executeAction(
			fundVault, _sale(_hop(ViaWethSellAdapter.Venue.UniswapV3, 500), _hop(ViaWethSellAdapter.Venue.Slipstream2, 100))
		);
		vm.expectRevert();
		swapped.executeAction(
			fundVault, _sale(_hop(ViaWethSellAdapter.Venue.Slipstream1, 1), _hop(ViaWethSellAdapter.Venue.Slipstream2, 100))
		);
	}

	function test_aPartialFill_onEitherHop_reverts() public {
		ViaWethSellAdapter.Hop memory toWeth = _hop(ViaWethSellAdapter.Venue.Slipstream2, 1);
		ViaWethSellAdapter.Hop memory fromWeth = _hop(ViaWethSellAdapter.Venue.UniswapV3, 500);
		s2.setFillBps(9_900);
		vm.expectRevert(abi.encodeWithSelector(ViaWethSellAdapter.Unsold.selector, address(cbeth)));
		adapter.executeAction(fundVault, _sale(toWeth, fromWeth));
		s2.setFillBps(10_000);
		uni.setFillBps(9_900);
		vm.expectRevert(abi.encodeWithSelector(ViaWethSellAdapter.Unsold.selector, address(weth)));
		adapter.executeAction(fundVault, _sale(toWeth, fromWeth));
	}

	function test_aBadPoolKeyReverts() public {
		vm.expectRevert(ViaWethSellAdapter.BadHop.selector); // Aerodrome: volatile only, 0
		adapter.executeAction(
			fundVault, _sale(_hop(ViaWethSellAdapter.Venue.AerodromeBasic, 1), _hop(ViaWethSellAdapter.Venue.UniswapV3, 500))
		);
		vm.expectRevert(ViaWethSellAdapter.BadHop.selector); // Uniswap v3: a fee is positive
		adapter.executeAction(
			fundVault, _sale(_hop(ViaWethSellAdapter.Venue.Slipstream1, 1), _hop(ViaWethSellAdapter.Venue.UniswapV3, -500))
		);
		// a venue past the enum: ViaWethSellAdapterAeroTest.test_aVenuePastAeroDoesntDecode
		assertEq(cbeth.balanceOf(address(adapter)), 4e18, 'nothing moved');
	}

	function test_fee_ownerSetsItUpToTheBytecodeCap() public {
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
		adapter.setFeeBps(0);
		vm.prank(owner);
		vm.expectRevert(abi.encodeWithSelector(ProtocolFeeAdapter.FeeAboveCap.selector, uint16(11)));
		adapter.setFeeBps(11);
		vm.prank(owner);
		adapter.setFeeBps(0);
		adapter.executeAction(
			fundVault, _sale(_hop(ViaWethSellAdapter.Venue.Slipstream1, 1), _hop(ViaWethSellAdapter.Venue.UniswapV3, 500))
		);
		assertEq(cbeth.balanceOf(treasury), 0, 'a 0 fee sends nothing');
		assertEq(usdc.balanceOf(fundVault), 16e18);
	}

	function test_constructor_rejectsZero() public {
		vm.expectRevert(ProtocolFeeAdapter.ZeroAddress.selector);
		new ViaWethSellAdapter(
			address(weth), address(uni), address(s1), address(s2), address(s3), address(aero), address(0), address(aeroCl), treasury, 5, owner
		);
		vm.expectRevert(ProtocolFeeAdapter.ZeroAddress.selector);
		new ViaWethSellAdapter(
			address(weth), address(uni), address(s1), address(s2), address(s3), address(aero), AERO_FACTORY, address(aeroCl), address(0), 5, owner
		);
		vm.expectRevert(abi.encodeWithSelector(ProtocolFeeAdapter.FeeAboveCap.selector, uint16(11)));
		new ViaWethSellAdapter(
			address(weth), address(uni), address(s1), address(s2), address(s3), address(aero), AERO_FACTORY, address(aeroCl), treasury, 11, owner
		);
	}
}
