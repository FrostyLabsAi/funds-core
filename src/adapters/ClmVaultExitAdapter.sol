// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IIntegrationAdapter} from '../interfaces/IIntegrationAdapter.sol';
import {IFrostyClmVault} from '../interfaces/external/IFrostyClm.sol';
import {SlipstreamSell} from './SlipstreamSell.sol';

/// @title ClmVaultExitAdapter
/// @notice The v6 keeper's exit from a FrostyFi CLM vault share (review 2026-10-14): ClmVaultAdapter's action 2, same
///         integrationData, with SlipstreamSell's sale, so no route leaves a token unsold in the router. ClmVaultAdapter
///         (live 0x871E…7952) stays for the terminal's deposits and withdrawals; the keeper's CLM_ADAPTER is this one.
/// @dev integrationData = abi.encode(uint8 2, clmVault, shares, minOut, outToken, Route[] routes): withdraws, then sells
///      each pool token other than `outToken` along its route, a multi-hop path through one of the three Slipstream
///      routers, from that token to `outToken`. One asset comes back, the shape the v6 keeper's liquidation sale needs
///      (ComptrollerV6Lib._checkSale), with its 3% oracle cap on the whole exit. Minimums are the Comptroller's to check;
///      the swaps take none of their own. It never holds tokens after a call.
contract ClmVaultExitAdapter is IIntegrationAdapter {
	using SafeERC20 for IERC20;

	struct Route {
		address router;
		bytes path;
	}

	uint8 public constant ACTION_EXIT = 2;

	/// @notice The Slipstream-1/2/3 SwapRouters (Base: 0xBE6D…18a5, 0x698C…A92F, 0xcbBb…Ce0D).
	address public immutable router1;
	address public immutable router2;
	address public immutable router3;

	error UnknownAction();
	error ZeroAddress();
	error NotARouter(address router);
	error BadRoute(uint256 index);

	constructor(address router1_, address router2_, address router3_) {
		if (router1_ == address(0) || router2_ == address(0) || router3_ == address(0)) revert ZeroAddress();
		router1 = router1_;
		router2 = router2_;
		router3 = router3_;
	}

	/// @inheritdoc IIntegrationAdapter
	function parseAssetsForAction(bytes calldata integrationData)
		external
		pure
		returns (
			address[] memory spendAssets,
			uint256[] memory spendAmounts,
			address[] memory incomingAssets,
			uint256[] memory minIncomingAmounts
		)
	{
		(uint8 action, address clmVault, uint256 shares, uint256 minOut, address outToken,) =
			abi.decode(integrationData, (uint8, address, uint256, uint256, address, Route[]));
		if (action != ACTION_EXIT) revert UnknownAction();
		return (_one(clmVault), _amount(shares), _one(outToken), _amount(minOut));
	}

	/// @inheritdoc IIntegrationAdapter
	function executeAction(address vault, bytes calldata integrationData) external {
		(uint8 action, address clmVault, uint256 shares,, address outToken, Route[] memory routes) =
			abi.decode(integrationData, (uint8, address, uint256, uint256, address, Route[]));
		if (action != ACTION_EXIT) revert UnknownAction();
		(address token0, address token1) = IFrostyClmVault(clmVault).wants();
		// Every route is checked before anything moves.
		for (uint256 i; i < routes.length; ++i) {
			_checkRoute(routes[i], i, outToken, token0, token1);
		}
		IFrostyClmVault(clmVault).withdraw(shares, 0, 0);
		for (uint256 i; i < routes.length; ++i) {
			SlipstreamSell.sellAll(routes[i].router, routes[i].path, address(this));
		}
		// a pool token with no route
		if (token0 != outToken && IERC20(token0).balanceOf(address(this)) != 0) revert SlipstreamSell.Unsold(token0);
		if (token1 != outToken && IERC20(token1).balanceOf(address(this)) != 0) revert SlipstreamSell.Unsold(token1);
		uint256 balance = IERC20(outToken).balanceOf(address(this));
		if (balance > 0) IERC20(outToken).safeTransfer(vault, balance);
	}

	/// @dev An allowed router and a well-formed path, from a pool token other than `outToken` to `outToken`.
	function _checkRoute(Route memory route, uint256 index, address outToken, address token0, address token1) private view {
		if (route.router != router1 && route.router != router2 && route.router != router3) revert NotARouter(route.router);
		if (!SlipstreamSell.wellFormed(route.path)) revert BadRoute(index);
		address first = SlipstreamSell.firstToken(route.path);
		if ((first != token0 && first != token1) || first == outToken) revert BadRoute(index);
		if (SlipstreamSell.lastToken(route.path) != outToken) revert BadRoute(index);
	}

	function _one(address asset) private pure returns (address[] memory assets) {
		assets = new address[](1);
		assets[0] = asset;
	}

	function _amount(uint256 amount) private pure returns (uint256[] memory amounts) {
		amounts = new uint256[](1);
		amounts[0] = amount;
	}
}
