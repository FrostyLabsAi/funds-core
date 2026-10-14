// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IIntegrationAdapter} from '../interfaces/IIntegrationAdapter.sol';
import {IFrostyClmVault} from '../interfaces/external/IFrostyClm.sol';

/// @notice Slipstream SwapRouter multi-hop exact-in (verified source of 0x698C…A92F, SwapRouter.sol, 2026-10-13).
///         Path: token (20 bytes) | tickSpacing int24 (3 bytes) | token | …
interface ISlipstreamMultiHopRouter {
	struct ExactInputParams {
		bytes path;
		address recipient;
		uint256 deadline;
		uint256 amountIn;
		uint256 amountOutMinimum;
	}

	function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @title ClmVaultAdapter
/// @notice Deposits into, withdraws from and exits FrostyFi CLM vaults (funds-yield; plan 2, 2026-10-13), on any of the
///         three Slipstream deployments and any pair.
/// @dev integrationData:
///      - 0 Deposit:  (0, clmVault, amount0, amount1, minShares). What the vault's ratio doesn't take goes back to the
///        fund's Vault.
///      - 1 Withdraw: (1, clmVault, shares, amount0Min, amount1Min).
///      - 2 Exit:     (2, clmVault, shares, minOut, outToken, Route[] routes). Withdraws, then sells each pool token
///        other than `outToken` along its route: a multi-hop path through one of the three Slipstream routers, from
///        that token to `outToken`. One asset comes back, the shape the v6 keeper's liquidation sale needs
///        (ComptrollerV6Lib._checkSale), with its 3% oracle cap on the whole exit. New pairs need a route, not code
///        (founder 2026-10-13).
///      Minimums are the Comptroller's to check (vault balance deltas); this adapter is never trusted for accounting, so
///      its swaps take no minimum of their own. It never holds tokens after a call.
contract ClmVaultAdapter is IIntegrationAdapter {
	using SafeERC20 for IERC20;

	struct Route {
		address router;
		bytes path;
	}

	uint8 public constant ACTION_DEPOSIT = 0;
	uint8 public constant ACTION_WITHDRAW = 1;
	uint8 public constant ACTION_EXIT = 2;
	uint256 private constant ADDR_SIZE = 20;
	uint256 private constant HOP_SIZE = 23; // tickSpacing (3) + token (20)

	/// @notice The Slipstream-1/2/3 SwapRouters (Base: 0xBE6D…18a5, 0x698C…A92F, 0xcbBb…Ce0D).
	address public immutable router1;
	address public immutable router2;
	address public immutable router3;

	error UnknownAction();
	error ZeroAddress();
	error NotARouter(address router);
	error BadRoute(uint256 index);
	error Unsold(address token);

	constructor(address router1_, address router2_, address router3_) {
		if (router1_ == address(0) || router2_ == address(0) || router3_ == address(0)) revert ZeroAddress();
		router1 = router1_;
		router2 = router2_;
		router3 = router3_;
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
		uint8 action = abi.decode(integrationData[:32], (uint8));
		if (action == ACTION_EXIT) {
			(, address clmVault, uint256 shares, uint256 minOut, address outToken,) =
				abi.decode(integrationData, (uint8, address, uint256, uint256, address, Route[]));
			return (_one(clmVault), _amount(shares), _one(outToken), _amount(minOut));
		}
		(, address vault_, uint256 a, uint256 b, uint256 c) =
			abi.decode(integrationData, (uint8, address, uint256, uint256, uint256));
		(address token0, address token1) = IFrostyClmVault(vault_).wants();
		if (action == ACTION_DEPOSIT) return (_pair(token0, token1), _amounts(a, b), _one(vault_), _amount(c));
		if (action == ACTION_WITHDRAW) return (_one(vault_), _amount(a), _pair(token0, token1), _amounts(b, c));
		revert UnknownAction();
	}

	/// @inheritdoc IIntegrationAdapter
	function executeAction(address vault, bytes calldata integrationData) external {
		uint8 action = abi.decode(integrationData[:32], (uint8));
		if (action == ACTION_EXIT) return _exit(vault, integrationData);
		(, address clmVault, uint256 a, uint256 b, uint256 c) =
			abi.decode(integrationData, (uint8, address, uint256, uint256, uint256));
		(address token0, address token1) = IFrostyClmVault(clmVault).wants();
		if (action == ACTION_DEPOSIT) {
			IERC20(token0).forceApprove(clmVault, a);
			IERC20(token1).forceApprove(clmVault, b);
			IFrostyClmVault(clmVault).deposit(a, b, c);
			IERC20(token0).forceApprove(clmVault, 0);
			IERC20(token1).forceApprove(clmVault, 0);
			_sendAll(clmVault, vault);
			_sendAll(token0, vault);
			_sendAll(token1, vault);
		} else if (action == ACTION_WITHDRAW) {
			IFrostyClmVault(clmVault).withdraw(a, b, c);
			_sendAll(token0, vault);
			_sendAll(token1, vault);
		} else {
			revert UnknownAction();
		}
	}

	function _exit(address vault, bytes calldata integrationData) private {
		(, address clmVault, uint256 shares,, address outToken, Route[] memory routes) =
			abi.decode(integrationData, (uint8, address, uint256, uint256, address, Route[]));
		(address token0, address token1) = IFrostyClmVault(clmVault).wants();
		// Every route is checked before anything moves.
		for (uint256 i; i < routes.length; ++i) {
			_checkRoute(routes[i], i, outToken, token0, token1);
		}
		IFrostyClmVault(clmVault).withdraw(shares, 0, 0);
		for (uint256 i; i < routes.length; ++i) {
			_swapAll(routes[i]);
		}
		if (token0 != outToken && IERC20(token0).balanceOf(address(this)) != 0) revert Unsold(token0);
		if (token1 != outToken && IERC20(token1).balanceOf(address(this)) != 0) revert Unsold(token1);
		_sendAll(outToken, vault);
	}

	/// @dev An allowed router and a well-formed path, from a pool token other than `outToken` to `outToken`.
	function _checkRoute(Route memory route, uint256 index, address outToken, address token0, address token1) private view {
		if (route.router != router1 && route.router != router2 && route.router != router3) revert NotARouter(route.router);
		uint256 length = route.path.length;
		if (length < ADDR_SIZE + HOP_SIZE || (length - ADDR_SIZE) % HOP_SIZE != 0) revert BadRoute(index);
		address first = _tokenAt(route.path, 0);
		if ((first != token0 && first != token1) || first == outToken) revert BadRoute(index);
		if (_tokenAt(route.path, length - ADDR_SIZE) != outToken) revert BadRoute(index);
	}

	/// @dev Sells this adapter's whole balance of the route's first token along the route.
	function _swapAll(Route memory route) private {
		address tokenIn = _tokenAt(route.path, 0);
		uint256 amountIn = IERC20(tokenIn).balanceOf(address(this));
		if (amountIn == 0) return;
		IERC20(tokenIn).forceApprove(route.router, amountIn);
		ISlipstreamMultiHopRouter(route.router).exactInput(
			ISlipstreamMultiHopRouter.ExactInputParams({
				path: route.path, recipient: address(this), deadline: block.timestamp, amountIn: amountIn, amountOutMinimum: 0
			})
		);
	}

	function _tokenAt(bytes memory path, uint256 offset) private pure returns (address token) {
		assembly ('memory-safe') {
			token := shr(96, mload(add(add(path, 32), offset)))
		}
	}

	function _sendAll(address token, address to) private {
		uint256 balance = IERC20(token).balanceOf(address(this));
		if (balance > 0) IERC20(token).safeTransfer(to, balance);
	}

	function _one(address asset) private pure returns (address[] memory assets) {
		assets = new address[](1);
		assets[0] = asset;
	}

	function _pair(address asset0, address asset1) private pure returns (address[] memory assets) {
		assets = new address[](2);
		assets[0] = asset0;
		assets[1] = asset1;
	}

	function _amount(uint256 amount) private pure returns (uint256[] memory amounts) {
		amounts = new uint256[](1);
		amounts[0] = amount;
	}

	function _amounts(uint256 amount0, uint256 amount1) private pure returns (uint256[] memory amounts) {
		amounts = new uint256[](2);
		amounts[0] = amount0;
		amounts[1] = amount1;
	}
}
