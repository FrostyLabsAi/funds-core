// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

/// @title PriceMarker
/// @notice A supply-less ERC-20 that stands for an underlying with no token on Base (an
///         off-chain equity, oil, an index, an L1 coin) so a perp leg can be valued:
///         VerantaPerpPositionV2 reports `coinExposure × price(pairAsset)`, and `pairAsset`
///         must be an ERC-20 the ValueInterpreter prices (it reads `decimals()`). Register the
///         marker as a VI primitive with the underlying's feed, then `setPairAsset(pair, marker)`.
/// @dev No mint, no owner: total supply is zero forever, so no one can ever hold, deposit or
///      trade a marker — it only carries a name, a symbol and 18 decimals.
contract PriceMarker is ERC20 {
	constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}
}
