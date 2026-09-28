// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

/// @title PriceMarker
/// @notice A supply-less ERC-20 standing for an underlying with no token on Base (an equity, oil,
///         an index), so a perp leg on it can be valued: register it as a VI primitive with the
///         underlying's feed, then `setPairAsset(pair, marker)`.
/// @dev No mint and no owner: supply is zero forever.
contract PriceMarker is ERC20 {
	constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}
}
