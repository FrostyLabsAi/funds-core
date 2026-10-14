// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ISlipstreamMultiHopRouter} from './ClmVaultAdapter.sol';

/// @title SlipstreamSell
/// @notice The keeper exit adapters' Slipstream sale (review 2026-10-14): a path's shape, and a sale of the seller's whole
///         balance that reverts when any of it stays unsold. A pool out of liquidity fills only part of its hop: on the
///         first hop the rest stays with the seller; on a later hop it stays in the router, whose public sweepToken
///         (in all three Slipstream routers' bytecode) hands it to anyone. ClmVaultAdapter (live) has neither check.
library SlipstreamSell {
	using SafeERC20 for IERC20;

	uint256 internal constant ADDR_SIZE = 20;
	uint256 internal constant HOP_SIZE = 23; // tickSpacing (3) + token (20)

	error Unsold(address token);

	/// @dev At least one hop, and whole hops: token (20) | tickSpacing (3) | token | …
	function wellFormed(bytes memory path) internal pure returns (bool) {
		uint256 length = path.length;
		return length >= ADDR_SIZE + HOP_SIZE && (length - ADDR_SIZE) % HOP_SIZE == 0;
	}

	function firstToken(bytes memory path) internal pure returns (address) {
		return _tokenAt(path, 0);
	}

	function lastToken(bytes memory path) internal pure returns (address) {
		return _tokenAt(path, path.length - ADDR_SIZE);
	}

	/// @dev Sells this contract's whole balance of the path's first token along a well-formed path, paying `recipient`;
	///      reverts Unsold when any of it stays here or any hop's input stays in the router.
	function sellAll(address router, bytes memory path, address recipient) internal {
		address tokenIn = _tokenAt(path, 0);
		uint256 amountIn = IERC20(tokenIn).balanceOf(address(this));
		if (amountIn == 0) return;
		uint256 hops = (path.length - ADDR_SIZE) / HOP_SIZE;
		uint256[] memory routerHeld = new uint256[](hops);
		for (uint256 i = 1; i < hops; ++i) {
			routerHeld[i] = IERC20(_tokenAt(path, i * HOP_SIZE)).balanceOf(router);
		}
		IERC20(tokenIn).forceApprove(router, amountIn);
		ISlipstreamMultiHopRouter(router).exactInput(
			ISlipstreamMultiHopRouter.ExactInputParams({
				path: path, recipient: recipient, deadline: block.timestamp, amountIn: amountIn, amountOutMinimum: 0
			})
		);
		if (IERC20(tokenIn).balanceOf(address(this)) != 0) revert Unsold(tokenIn);
		for (uint256 i = 1; i < hops; ++i) {
			address mid = _tokenAt(path, i * HOP_SIZE);
			if (IERC20(mid).balanceOf(router) > routerHeld[i]) revert Unsold(mid);
		}
	}

	function _tokenAt(bytes memory path, uint256 offset) private pure returns (address token) {
		assembly ('memory-safe') {
			token := shr(96, mload(add(add(path, 32), offset)))
		}
	}
}
