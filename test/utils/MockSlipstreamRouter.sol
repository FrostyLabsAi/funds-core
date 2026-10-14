// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ISlipstreamMultiHopRouter} from '../../src/adapters/ClmVaultAdapter.sol';
import {MockERC20} from './Mocks.sol';

/// @dev A Slipstream router stand-in for the exit adapters: takes the path's first token and pays the last at `rate` (out
///      per 1e18 in). Two ways a pool out of liquidity fills part: `fillBps` under 10,000 takes only that share of the
///      input (the rest stays with the payer); `midLeftover` leaves that much of the second token in the router, as a
///      later hop that filled part does.
contract MockSlipstreamRouter {
	uint256 public rate = 2e18;
	uint256 public fillBps = 10_000;
	uint256 public midLeftover;

	function setFillBps(uint256 bps) external {
		fillBps = bps;
	}

	function setMidLeftover(uint256 amount) external {
		midLeftover = amount;
	}

	function exactInput(ISlipstreamMultiHopRouter.ExactInputParams calldata p) external payable returns (uint256 out) {
		uint256 taken = (p.amountIn * fillBps) / 10_000;
		IERC20(_tokenAt(p.path, 0)).transferFrom(msg.sender, address(this), taken);
		out = (taken * rate) / 1e18;
		MockERC20(_tokenAt(p.path, p.path.length - 20)).mint(p.recipient, out);
		if (p.path.length > 43 && midLeftover > 0) MockERC20(_tokenAt(p.path, 23)).mint(address(this), midLeftover);
	}

	function _tokenAt(bytes memory path, uint256 offset) private pure returns (address token) {
		assembly ('memory-safe') {
			token := shr(96, mload(add(add(path, 32), offset)))
		}
	}
}
