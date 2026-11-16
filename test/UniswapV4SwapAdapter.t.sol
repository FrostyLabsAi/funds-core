// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {UniswapV4SwapAdapter} from '../src/adapters/UniswapV4SwapAdapter.sol';
import {IPoolPriceRegistrar} from '../src/interfaces/IPoolPriceRegistrar.sol';
import {IV4PoolManager, PoolKey, PoolKeyId} from '../src/interfaces/external/IUniswapV4.sol';
import {MockERC20} from './utils/Mocks.sol';
import {MockV4PoolManager, MockHookRegistrar, MockWETH} from './utils/V4Mocks.sol';

/// @dev A fund stand-in: answers `registrar()` and calls the adapter the way Comptroller.callOnIntegration does.
contract FakeFund {
	address public registrar;

	constructor(address registrar_) {
		registrar = registrar_;
	}

	function trade(UniswapV4SwapAdapter adapter, address vault, bytes calldata data) external {
		adapter.executeAction(vault, data);
	}
}

/// @notice UniswapV4SwapAdapter units (spec 2026-10-08 §5): new funds only, approved hooks only, hookData from the
///         registrar, the protocol fee, native ETH ↔ WETH. Swap mechanics against the real PoolManager are in the
///         fork test.
contract UniswapV4SwapAdapterTest is Test {
	MockV4PoolManager internal manager;
	MockHookRegistrar internal registrar;
	MockWETH internal weth;
	MockERC20 internal usdc;
	MockERC20 internal meme;
	UniswapV4SwapAdapter internal adapter;
	FakeFund internal fund;
	address internal treasury = makeAddr('treasury');
	address internal owner = makeAddr('owner');
	address internal vault = makeAddr('vault');
	address internal constant HOOK = address(0x47Ec48C74f3069e9Ae69406197821996d80200cC);

	function setUp() public {
		manager = new MockV4PoolManager();
		registrar = new MockHookRegistrar();
		weth = new MockWETH();
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		meme = new MockERC20('Memestock', 'MEME', 18);
		adapter = new UniswapV4SwapAdapter(
			IV4PoolManager(address(manager)), IPoolPriceRegistrar(address(registrar)), address(weth), treasury, 5, owner
		);
		fund = new FakeFund(address(registrar));
		manager.setNextAmountOut(1_000e18);
	}

	/// @dev The MEME/USDC pool, approved in the registrar (the v4 adapter trades approved pools only).
	function _key(address hooks) internal returns (PoolKey memory key) {
		(address c0, address c1) = address(usdc) < address(meme) ? (address(usdc), address(meme)) : (address(meme), address(usdc));
		key = PoolKey({currency0: c0, currency1: c1, fee: 10_000, tickSpacing: 200, hooks: hooks});
		registrar.setPoolApproved(PoolKeyId.toId(key), true);
	}

	function _buyMeme(PoolKey memory key, uint256 amountIn) internal returns (bytes memory data) {
		bool zeroForOne = key.currency0 == address(usdc);
		data = abi.encode(key, zeroForOne, amountIn, uint256(1));
		usdc.mint(address(adapter), amountIn); // the Comptroller sends the spend asset first
		fund.trade(adapter, vault, data);
	}

	function test_buy_takesTheFeeThenSwapsTheRestToTheVault() public {
		_buyMeme(_key(address(0)), 10_000e6);
		assertEq(usdc.balanceOf(treasury), 5e6, '5 bps');
		assertEq(manager.lastAmountSpecified(), -int256(9_995e6), 'exact input of the rest');
		assertEq(usdc.balanceOf(address(manager)), 9_995e6, 'paid in');
		assertEq(meme.balanceOf(vault), 1_000e18, 'output to the vault');
		assertEq(usdc.balanceOf(address(adapter)), 0, 'nothing left behind');
	}

	/// A partial fill (the price limit reached before all the input is spent): the unspent input goes back to the vault
	/// and the adapter keeps nothing. The protocol fee was taken on the whole input (final review 2026-10-08, L3: at
	/// most 5 bps of the returned part, only on a fill that hits the price limit).
	function test_partialFill_returnsTheUnspentInput() public {
		manager.setNextConsumed(4_000e6);
		_buyMeme(_key(address(0)), 10_000e6);
		assertEq(usdc.balanceOf(address(manager)), 4_000e6, 'only what the pool took');
		assertEq(usdc.balanceOf(vault), 5_995e6, 'the rest of the 9,995 back');
		assertEq(meme.balanceOf(vault), 1_000e18);
		assertEq(usdc.balanceOf(treasury), 5e6);
		assertEq(usdc.balanceOf(address(adapter)), 0, 'nothing left behind');
	}

	/// The swap's deltas are checked before anything is paid: input credited to the caller, output owed by the caller,
	/// or more input owed than was offered all revert (a misbehaving hook's return deltas included).
	function test_unexpectedDeltas_revert() public {
		PoolKey memory key = _key(address(0));
		bool zeroForOne = key.currency0 == address(usdc);
		bytes memory data = abi.encode(key, zeroForOne, uint256(10_000e6), uint256(1));
		int128[3] memory ins = [int128(1), int128(-1), -int128(int256(9_995e6 + 1))];
		int128[3] memory outs = [int128(1), int128(-1), int128(1)];
		for (uint256 i; i < 3; ++i) {
			manager.setNextDeltas(ins[i], outs[i]);
			usdc.mint(address(adapter), 10_000e6);
			vm.expectRevert(abi.encodeWithSelector(UniswapV4SwapAdapter.UnexpectedDelta.selector, ins[i], outs[i]));
			fund.trade(adapter, vault, data);
			deal(address(usdc), address(adapter), 0);
		}
	}

	/// Only approved pools are traded: a token priced from an approved pool can't be bought through a manager's own
	/// side pool at a price he set (final review 2026-10-08, H1).
	function test_refusesAnUnapprovedPool() public {
		PoolKey memory key = _key(address(0));
		bytes32 id = PoolKeyId.toId(key);
		registrar.setPoolApproved(id, false);
		bytes memory data = abi.encode(key, true, uint256(1e6), uint256(1));
		vm.expectRevert(abi.encodeWithSelector(UniswapV4SwapAdapter.PoolNotApproved.selector, id));
		fund.trade(adapter, vault, data);
	}

	/// The adapter reports the tax recorded for the pool a sale goes through, and nothing for any other pool, even one
	/// trading the same token: the keeper's raised cap follows the taxed pool, never the token.
	function test_saleTaxBps_isThePoolsOwn() public {
		PoolKey memory taxed = _key(address(0));
		PoolKey memory other = PoolKey({currency0: address(0), currency1: taxed.currency1, fee: 500, tickSpacing: 10, hooks: address(0)});
		registrar.setPoolSaleTax(PoolKeyId.toId(taxed), 290);
		assertEq(adapter.saleTaxBps(abi.encode(taxed, false, uint256(1e18), uint256(0))), 290);
		assertEq(adapter.saleTaxBps(abi.encode(other, false, uint256(1e18), uint256(0))), 0, 'the same token elsewhere: no tax');
	}

	/// Old funds (built on today's registrar) are refused: v4 tokens aren't long-tail for them (founder 2026-10-08).
	function test_refusesAnOldFund() public {
		FakeFund oldFund = new FakeFund(makeAddr('todaysRegistrar'));
		bytes memory data = abi.encode(_key(address(0)), true, uint256(1e6), uint256(1));
		vm.expectRevert(abi.encodeWithSelector(UniswapV4SwapAdapter.NotANewFund.selector, address(oldFund)));
		oldFund.trade(adapter, vault, data);
		vm.expectRevert(abi.encodeWithSelector(UniswapV4SwapAdapter.NotANewFund.selector, address(this)));
		adapter.executeAction(vault, data); // a caller with no registrar() at all
	}

	function test_refusesAnUnapprovedHook() public {
		bytes memory data = abi.encode(_key(HOOK), true, uint256(1e6), uint256(1));
		vm.expectRevert(abi.encodeWithSelector(UniswapV4SwapAdapter.HookNotApproved.selector, HOOK));
		fund.trade(adapter, vault, data);
	}

	/// Review Focus 4: the hook gets the registrar's bytes (o1: the Treasury as referrer), never the manager's.
	function test_hookDataComesFromTheRegistrar() public {
		registrar.setHook(HOOK, true, abi.encode(treasury));
		_buyMeme(_key(HOOK), 1_000e6);
		assertEq(manager.lastHookData(), abi.encode(treasury));
	}

	/// A native-ETH pool: the vault's WETH is unwrapped in, ETH out is wrapped back; the adapter keeps neither.
	function test_nativeEth_inAndOut() public {
		PoolKey memory key = PoolKey({currency0: address(0), currency1: address(meme), fee: 10_000, tickSpacing: 200, hooks: address(0)});
		registrar.setPoolApproved(PoolKeyId.toId(key), true);
		// buy: ETH in
		vm.deal(address(this), 10 ether);
		weth.deposit{value: 10 ether}();
		weth.transfer(address(adapter), 10 ether);
		fund.trade(adapter, vault, abi.encode(key, true, uint256(10 ether), uint256(1)));
		assertEq(weth.balanceOf(treasury), 0.005 ether, 'fee in WETH');
		assertEq(address(manager).balance, 9.995 ether, 'ETH paid in');
		assertEq(meme.balanceOf(vault), 1_000e18);
		// sell: ETH out
		manager.setNextAmountOut(2 ether);
		vm.deal(address(manager), 12 ether);
		meme.mint(address(adapter), 500e18);
		fund.trade(adapter, vault, abi.encode(key, false, uint256(500e18), uint256(1)));
		assertEq(weth.balanceOf(vault), 2 ether, 'ETH out arrives as WETH');
		assertEq(address(adapter).balance, 0);
		assertEq(weth.balanceOf(address(adapter)), 0);
	}

	function test_parse_mapsNativeEthToWeth() public view {
		PoolKey memory key = PoolKey({currency0: address(0), currency1: address(meme), fee: 10_000, tickSpacing: 200, hooks: address(0)});
		(address[] memory spend, uint256[] memory amounts, address[] memory incoming, uint256[] memory mins) =
			adapter.parseAssetsForAction(abi.encode(key, true, uint256(3 ether), uint256(7)));
		assertEq(spend[0], address(weth));
		assertEq(amounts[0], 3 ether);
		assertEq(incoming[0], address(meme));
		assertEq(mins[0], 7);
		(spend,, incoming,) = adapter.parseAssetsForAction(abi.encode(key, false, uint256(3e18), uint256(7)));
		assertEq(spend[0], address(meme));
		assertEq(incoming[0], address(weth));
	}

	function test_unlockCallback_onlyPoolManager() public {
		vm.expectRevert(abi.encodeWithSelector(UniswapV4SwapAdapter.NotPoolManager.selector, address(this)));
		adapter.unlockCallback('');
	}

	function test_receive_onlyWethOrPoolManager() public {
		vm.deal(address(this), 1 ether);
		(bool ok,) = address(adapter).call{value: 1}('');
		assertFalse(ok);
	}
}
