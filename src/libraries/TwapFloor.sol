// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title TwapFloor
/// @notice The TWAP tier's band-depth floor, in one place (Ruling 23). The liquidity floor is
///         two-part: the pool's QUOTE reserve ≥ the reserve floor AND its band depth (quote bids
///         within −10% of the price) ≥ the band floor derived here from that reserve floor.
///         A full-range x·y=k pool holding exactly the reserve floor of quote has
///         (1 − √0.9) = 5.1316% of it within −10%, so Uniswap v2 and Aerodrome basic pools meet the
///         band floor whenever they meet the reserve floor; a concentrated pool also needs real
///         liquidity near the price — a balance of uncollected fees, removed-but-uncollected
///         liquidity (tokensOwed) or donations holds the reserve but no bids.
/// @dev Every TWAP adapter derives its `minBandDepthUsd` from its `minLiquidityUsd` with
///      `minBandDepthUsd`; TwapListingRegistryV2.MIN_BAND_DEPTH_USD is the same expression on its
///      MIN_QUOTE_RESERVE_USD (25_000 → 1_282).
library TwapFloor {
	/// @notice floor((1 − √0.9) · 1e6): the share of an x·y=k pool's quote reserve within −10% of
	///         the price — what a −10% sell pays out.
	uint256 internal constant BAND_QUOTE_PPM = 51_316;

	/// @notice The band floor (whole USD) that goes with a quote-reserve floor (whole USD): what a
	///         full-range x·y=k pool holding exactly that much quote has within −10%, rounded down.
	function minBandDepthUsd(uint256 minQuoteReserveUsd) internal pure returns (uint256) {
		return minQuoteReserveUsd * BAND_QUOTE_PPM / 1e6;
	}
}
