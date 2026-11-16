// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IUniswapV3SwapRouter} from '../../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {ISaleTaxAdapter} from '../../src/interfaces/ISaleTaxAdapter.sol';
import {UniswapV3SwapAdapter} from '../../src/adapters/UniswapV3SwapAdapter.sol';

/// @dev A Uniswap v3 adapter (fee 0) on a test router that also reports a sale tax for every route it trades, as the
///      v4 adapter reports a taxed pool's: lets the library's use of ISaleTaxAdapter be tested on the mock venue.
contract MockSaleTaxAdapter is UniswapV3SwapAdapter, ISaleTaxAdapter {
	uint256 public tax;

	constructor(IUniswapV3SwapRouter router_) UniswapV3SwapAdapter(router_, address(0xFEE), 0, msg.sender) {}

	function setTax(uint256 tax_) external {
		tax = tax_;
	}

	function saleTaxBps(bytes calldata) external view returns (uint256) {
		return tax;
	}
}
