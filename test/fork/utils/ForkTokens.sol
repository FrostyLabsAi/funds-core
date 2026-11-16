// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {BaseMainnet} from '../../../script/release/BaseMainnet.sol';

/// @dev The two tokens every fork suite names, declared once for the fixtures that combine (ReleaseFork, ClmFixture).
abstract contract ForkTokens {
	address internal constant USDC = BaseMainnet.USDC;
	address internal constant WETH = BaseMainnet.WETH;
}
