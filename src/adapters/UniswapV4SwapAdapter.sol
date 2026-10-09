// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IIntegrationAdapter} from '../interfaces/IIntegrationAdapter.sol';
import {IV4PoolManager, IV4UnlockCallback, PoolKey, PoolKeyId, V4Delta} from '../interfaces/external/IUniswapV4.sol';
import {TickMath} from '../libraries/TickMath.sol';
import {PoolPriceRegistrarV2} from '../pricing/PoolPriceRegistrarV2.sol';
import {ProtocolFeeAdapter} from './ProtocolFeeAdapter.sol';

/// @notice WETH9's wrap/unwrap.
interface IWETH9 {
	function deposit() external payable;
	function withdraw(uint256 amount) external;
}

/// @title UniswapV4SwapAdapter
/// @notice Single-pool exactIn swaps on Uniswap v4 for funds built on PoolPriceRegistrarV2 (spec 2026-10-08 §5):
///         memestocks such as STFY (StockifyFeeHook) and o1 launches (LaunchHook), against USDC/WETH/native ETH or
///         a stock token. The protocol fee (ProtocolFeeAdapter) comes off the input first.
/// @dev - integrationData = abi.encode(PoolKey key, bool zeroForOne, uint256 amountIn, uint256 minAmountOut).
///        A native-ETH side is WETH in the vault: unwrapped going in, wrapped coming out.
///      - New funds only: the calling fund's `registrar()` must be PoolPriceRegistrarV2, the registrar that makes
///        v4 tokens long-tail (in-kind redemption, realized-only fees, $25k buys). Funds on today's registrar would
///        hold them as ordinary tokens, so they're refused (founder 2026-10-08).
///      - The pool must be one the registrar approved (its owner or a pool approver): a token priced from an approved
///        pool can't be bought through a manager's own side pool at a price he set (final review 2026-10-08, H1).
///      - The pool's hook must be none or one the registrar approved; the bytes passed to it are the approval's
///        (o1: the Treasury as referrer), never the manager's. A hook's own fee (STFY 3%, o1 1% + anti-snipe)
///        reduces the output; the fund's minAmountOut and slippage policy cover it, and the terminal quotes it
///        with Uniswap's v4 Quoter, which runs the hook.
///      - Swaps what arrived (a taxed transfer in is spent as received); unspent input (a partial fill at the
///        price limit) goes back to the vault. Holds nothing between calls.
contract UniswapV4SwapAdapter is IIntegrationAdapter, IV4UnlockCallback, ProtocolFeeAdapter {
	using SafeERC20 for IERC20;

	IV4PoolManager public immutable poolManager;
	PoolPriceRegistrarV2 public immutable registrar;
	address public immutable weth;

	error NotANewFund(address caller);
	error HookNotApproved(address hook);
	error PoolNotApproved(bytes32 poolId);
	error NotPoolManager(address caller);
	error UnexpectedDelta(int128 deltaIn, int128 deltaOut);
	error EthRefused(address sender);

	constructor(
		IV4PoolManager poolManager_,
		PoolPriceRegistrarV2 registrar_,
		address weth_,
		address treasury_,
		uint16 feeBps_,
		address owner_
	) ProtocolFeeAdapter(treasury_, feeBps_, owner_) {
		if (address(poolManager_) == address(0) || address(registrar_) == address(0) || weth_ == address(0)) {
			revert ZeroAddress();
		}
		poolManager = poolManager_;
		registrar = registrar_;
		weth = weth_;
	}

	/// @notice ETH only arrives from WETH (unwrap) or the PoolManager (take).
	receive() external payable {
		if (msg.sender != weth && msg.sender != address(poolManager)) revert EthRefused(msg.sender);
	}

	/// @inheritdoc IIntegrationAdapter
	function parseAssetsForAction(bytes calldata integrationData)
		external
		view
		returns (
			address[] memory spendAssets,
			uint256[] memory spendAmounts,
			address[] memory incomingAssets,
			uint256[] memory minIncomingAmounts
		)
	{
		(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint256 minAmountOut) =
			abi.decode(integrationData, (PoolKey, bool, uint256, uint256));
		(address currencyIn, address currencyOut) = _currencies(key, zeroForOne);

		spendAssets = new address[](1);
		spendAssets[0] = _asset(currencyIn);
		spendAmounts = new uint256[](1);
		spendAmounts[0] = amountIn;
		incomingAssets = new address[](1);
		incomingAssets[0] = _asset(currencyOut);
		minIncomingAmounts = new uint256[](1);
		minIncomingAmounts[0] = minAmountOut;
	}

	/// @inheritdoc IIntegrationAdapter
	function executeAction(address vault, bytes calldata integrationData) external {
		_requireNewFund(msg.sender);
		(PoolKey memory key, bool zeroForOne,,) = abi.decode(integrationData, (PoolKey, bool, uint256, uint256));
		bytes32 id = PoolKeyId.toId(key);
		if (!registrar.isPoolApproved(id)) revert PoolNotApproved(id);
		if (!registrar.isHookAllowed(key.hooks)) revert HookNotApproved(key.hooks);
		(, bytes memory hookData) = registrar.hookOf(key.hooks);

		(address currencyIn,) = _currencies(key, zeroForOne);
		address assetIn = _asset(currencyIn);
		uint256 amountIn = _takeFee(assetIn, IERC20(assetIn).balanceOf(address(this)));
		if (currencyIn == address(0)) IWETH9(weth).withdraw(amountIn);
		poolManager.unlock(abi.encode(key, zeroForOne, amountIn, hookData, vault));
	}

	/// @inheritdoc IV4UnlockCallback
	function unlockCallback(bytes calldata data) external returns (bytes memory) {
		if (msg.sender != address(poolManager)) revert NotPoolManager(msg.sender);
		(PoolKey memory key, bool zeroForOne, uint256 amountIn, bytes memory hookData, address vault) =
			abi.decode(data, (PoolKey, bool, uint256, bytes, address));

		int256 delta = poolManager.swap(
			key,
			IV4PoolManager.SwapParams({
				zeroForOne: zeroForOne,
				amountSpecified: -int256(amountIn),
				sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
			}),
			hookData
		);
		(int128 deltaIn, int128 deltaOut) =
			zeroForOne ? (V4Delta.amount0(delta), V4Delta.amount1(delta)) : (V4Delta.amount1(delta), V4Delta.amount0(delta));
		if (deltaIn > 0 || deltaOut < 0 || uint256(uint128(-deltaIn)) > amountIn) revert UnexpectedDelta(deltaIn, deltaOut);
		uint256 owed = uint256(uint128(-deltaIn));
		uint256 out = uint256(uint128(deltaOut));

		(address currencyIn, address currencyOut) = _currencies(key, zeroForOne);
		_pay(currencyIn, owed);
		_takeTo(currencyOut, out, vault);
		if (amountIn > owed) _send(currencyIn, amountIn - owed, vault);
		return '';
	}

	// ─── Internals ───────────────────────────────────────────────────────────────

	/// @dev The fund calling must be built on this adapter's registrar.
	function _requireNewFund(address caller) internal view {
		(bool ok, bytes memory ret) = caller.staticcall(abi.encodeWithSignature('registrar()'));
		if (!ok || ret.length != 32 || abi.decode(ret, (address)) != address(registrar)) revert NotANewFund(caller);
	}

	function _currencies(PoolKey memory key, bool zeroForOne) internal pure returns (address currencyIn, address currencyOut) {
		(currencyIn, currencyOut) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
	}

	/// @dev The vault-side asset of a pool currency: native ETH is WETH.
	function _asset(address currency) internal view returns (address) {
		return currency == address(0) ? weth : currency;
	}

	/// @dev Settle what the swap owes the PoolManager: native ETH as msg.value, an ERC-20 by sync → transfer → settle.
	function _pay(address currency, uint256 amount) internal {
		if (currency == address(0)) {
			poolManager.settle{value: amount}();
		} else {
			poolManager.sync(currency);
			IERC20(currency).safeTransfer(address(poolManager), amount);
			poolManager.settle();
		}
	}

	/// @dev Take the output: an ERC-20 straight to the vault; native ETH here, wrapped, then to the vault.
	function _takeTo(address currency, uint256 amount, address vault) internal {
		if (currency == address(0)) {
			poolManager.take(address(0), address(this), amount);
			_send(address(0), amount, vault);
		} else {
			poolManager.take(currency, vault, amount);
		}
	}

	/// @dev Send `amount` of a pool currency held here to the vault (native ETH as WETH).
	function _send(address currency, uint256 amount, address vault) internal {
		if (currency == address(0)) {
			IWETH9(weth).deposit{value: amount}();
			IERC20(weth).safeTransfer(vault, amount);
		} else {
			IERC20(currency).safeTransfer(vault, amount);
		}
	}
}
