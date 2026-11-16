// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @dev A StateView stand-in with settable per-pool slot0 and in-range liquidity.
contract MockStateView {
	struct State {
		uint160 sqrtPriceX96;
		int24 tick;
		uint128 liquidity;
	}

	mapping(bytes32 => State) public states;

	function setPool(bytes32 poolId, uint160 sqrtPriceX96, int24 tick, uint128 liquidity) external {
		states[poolId] = State(sqrtPriceX96, tick, liquidity);
	}

	function getSlot0(bytes32 poolId) external view returns (uint160, int24, uint24, uint24) {
		State memory s = states[poolId];
		return (s.sqrtPriceX96, s.tick, 0, 0);
	}

	function getLiquidity(bytes32 poolId) external view returns (uint128) {
		return states[poolId].liquidity;
	}
}

import {PoolKey, IV4PoolManager, IV4UnlockCallback} from '../../src/interfaces/external/IUniswapV4.sol';
import {MockERC20} from './Mocks.sol';

/// @dev A PoolManager stand-in for the v4 swap adapter's unit tests: unlock calls back the caller; swap records
///      what it was given and returns a delta paying `nextAmountOut` for the whole input; sync/settle/take settle
///      ERC-20s by balance (and native ETH by msg.value) and check every delta is cleared, as the real one does.
contract MockV4PoolManager is IV4PoolManager {
	uint256 public nextAmountOut;
	bytes public lastHookData;
	int256 public lastAmountSpecified;
	address internal synced;
	uint256 internal syncedBalance;
	int256 internal owedIn; // what the caller must pay (positive)
	int256 internal dueOut; // what the caller may take (positive)
	/// @dev A partial fill: the swap consumes only this much input (0 = all of it)
	uint256 public nextConsumed;
	/// @dev Scripted (deltaIn, deltaOut) the swap returns as-is, for the adapter's delta checks
	bool internal scripted;
	int128 internal scriptedIn;
	int128 internal scriptedOut;

	function setNextAmountOut(uint256 amountOut) external {
		nextAmountOut = amountOut;
	}

	function setNextConsumed(uint256 consumed) external {
		nextConsumed = consumed;
	}

	function setNextDeltas(int128 deltaIn, int128 deltaOut) external {
		(scripted, scriptedIn, scriptedOut) = (true, deltaIn, deltaOut);
	}

	function unlock(bytes calldata data) external returns (bytes memory result) {
		result = IV4UnlockCallback(msg.sender).unlockCallback(data);
		require(owedIn == 0 && dueOut == 0, 'CurrencyNotSettled');
	}

	function swap(PoolKey memory, SwapParams memory params, bytes calldata hookData) external returns (int256) {
		lastHookData = hookData;
		lastAmountSpecified = params.amountSpecified;
		int256 amountIn = nextConsumed != 0 ? int256(nextConsumed) : -params.amountSpecified;
		owedIn = amountIn;
		dueOut = int256(nextAmountOut);
		int128 inDelta = int128(-amountIn);
		int128 outDelta = int128(int256(nextAmountOut));
		if (scripted) (inDelta, outDelta) = (scriptedIn, scriptedOut);
		(int128 d0, int128 d1) = params.zeroForOne ? (inDelta, outDelta) : (outDelta, inDelta);
		return (int256(d0) << 128) | int256(uint256(uint128(d1)));
	}

	function sync(address currency) external {
		synced = currency;
		syncedBalance = MockERC20(currency).balanceOf(address(this));
	}

	function settle() external payable returns (uint256 paid) {
		if (synced == address(0)) {
			paid = msg.value;
		} else {
			paid = MockERC20(synced).balanceOf(address(this)) - syncedBalance;
			synced = address(0);
		}
		owedIn -= int256(paid);
	}

	/// @dev Native ETH must be funded into this mock by the test (vm.deal); ERC-20 output is minted.
	function take(address currency, address to, uint256 amount) external {
		dueOut -= int256(amount);
		if (currency == address(0)) {
			(bool ok,) = to.call{value: amount}('');
			require(ok, 'eth');
		} else {
			MockERC20(currency).mint(to, amount);
		}
	}

	receive() external payable {}
}

/// @dev The registrar surface the v4 swap adapter reads.
contract MockHookRegistrar {
	mapping(address => bool) public approved;
	mapping(address => bytes) internal data;
	mapping(bytes32 => bool) public isPoolApproved;
	mapping(bytes32 => uint16) public poolSaleTaxBps;

	function setPoolApproved(bytes32 poolId, bool ok) external {
		isPoolApproved[poolId] = ok;
	}

	function setPoolSaleTax(bytes32 poolId, uint16 taxBps) external {
		poolSaleTaxBps[poolId] = taxBps;
	}

	function setHook(address hook, bool ok, bytes calldata hookData) external {
		approved[hook] = ok;
		data[hook] = hookData;
	}

	function isHookAllowed(address hook) external view returns (bool) {
		return hook == address(0) || approved[hook];
	}

	function hookOf(address hook) external view returns (bool, bytes memory) {
		return (approved[hook], data[hook]);
	}
}

/// @dev WETH9's deposit/withdraw on a mintable test token.
contract MockWETH is MockERC20 {
	constructor() MockERC20('Wrapped Ether', 'WETH', 18) {}

	function deposit() external payable {
		_mint(msg.sender, msg.value);
	}

	function withdraw(uint256 amount) external {
		_burn(msg.sender, amount);
		(bool ok,) = msg.sender.call{value: amount}('');
		require(ok, 'eth');
	}

	receive() external payable {}
}
