// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice Aerodrome Router (fee-on-transfer-supporting exactIn swap only), for basic (v2-style) pools.
/// @dev Verified against the Basescan source of 0xcF77…4E43 (defaultFactory 0x420D…40Da): `Route`
///      field order is (from, to, stable, factory), selector 0x88cd821e. Pulls `amountIn` from the
///      caller into the first route's pool, swaps what the pool actually received, and requires the
///      recipient's balance of the last token to rise by ≥ `amountOutMin`. Returns nothing.
interface IAerodromeRouter {
	struct Route {
		address from;
		address to;
		bool stable;
		address factory;
	}

	function swapExactTokensForTokensSupportingFeeOnTransferTokens(
		uint256 amountIn,
		uint256 amountOutMin,
		Route[] calldata routes,
		address to,
		uint256 deadline
	) external;
}
