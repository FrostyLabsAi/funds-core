// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IIntegrationAdapter} from '../interfaces/IIntegrationAdapter.sol';
import {SlipstreamSell} from './SlipstreamSell.sol';

/// @title ERC4626ExitAdapter
/// @notice The v6 keeper's exit from any ERC-4626 vault share (founder 2026-10-14): redeems, then sells the underlying
///         into `outToken` along one Slipstream route. One asset comes back, the shape a v6 liquidation sale needs
///         (ComptrollerV6Lib._checkSale), with its 3% oracle cap on the whole exit. ERC4626Adapter's plain redeem returns
///         the underlying, which isn't a sale unless the underlying is the denomination.
/// @dev integrationData = abi.encode(vault4626, shares, minOut, outToken, Route[] routes):
///      - underlying == outToken: no route; the redeem pays the fund's Vault directly.
///      - otherwise exactly one route: a multi-hop path through one of the three Slipstream routers, from the underlying
///        to `outToken`, checked as ClmVaultAdapter's, and sold by SlipstreamSell (nothing left unsold here or in the
///        router).
///      Minimums are the Comptroller's to check (vault balance deltas); this adapter is never trusted for accounting, so
///      its swap takes no minimum of its own. It never holds tokens after a call.
contract ERC4626ExitAdapter is IIntegrationAdapter {
	struct Route {
		address router;
		bytes path;
	}

	/// @notice The Slipstream-1/2/3 SwapRouters (Base: 0xBE6D…18a5, 0x698C…A92F, 0xcbBb…Ce0D).
	address public immutable router1;
	address public immutable router2;
	address public immutable router3;

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
		(address vault4626, uint256 shares, uint256 minOut, address outToken,) =
			abi.decode(integrationData, (address, uint256, uint256, address, Route[]));
		return (_one(vault4626), _amount(shares), _one(outToken), _amount(minOut));
	}

	/// @inheritdoc IIntegrationAdapter
	function executeAction(address vault, bytes calldata integrationData) external {
		(address vault4626, uint256 shares,, address outToken, Route[] memory routes) =
			abi.decode(integrationData, (address, uint256, uint256, address, Route[]));
		address underlying = IERC4626(vault4626).asset();
		if (underlying == outToken) {
			if (routes.length != 0) revert BadRoute(0);
			IERC4626(vault4626).redeem(shares, vault, address(this));
			return;
		}
		// The route is checked before anything moves.
		if (routes.length != 1) revert BadRoute(routes.length);
		_checkRoute(routes[0], underlying, outToken);
		IERC4626(vault4626).redeem(shares, address(this), address(this));
		SlipstreamSell.sellAll(routes[0].router, routes[0].path, vault);
	}

	/// @dev An allowed router and a well-formed path, from `underlying` to `outToken`.
	function _checkRoute(Route memory route, address underlying, address outToken) private view {
		if (route.router != router1 && route.router != router2 && route.router != router3) revert NotARouter(route.router);
		if (!SlipstreamSell.wellFormed(route.path)) revert BadRoute(0);
		if (SlipstreamSell.firstToken(route.path) != underlying) revert BadRoute(0);
		if (SlipstreamSell.lastToken(route.path) != outToken) revert BadRoute(0);
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
