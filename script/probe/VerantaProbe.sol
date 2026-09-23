// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IVerantaTradingRouter} from '../../src/interfaces/external/IVeranta.sol';

/// @notice Minimal fork probe: does the REAL Veranta v2 router accept a CONTRACT as
///         trader for setDelegate and openTrade? Deployed only on the local anvil fork.
contract VerantaProbe {
	IVerantaTradingRouter public immutable router;

	constructor(IVerantaTradingRouter router_, IERC20 usdc, address tradingStorage) {
		router = router_;
		usdc.approve(tradingStorage, type(uint256).max);
	}

	function probeSetDelegate(address keeper, uint256 expiry) external {
		router.setDelegate(keeper, expiry);
	}

	function probeOpenShort(uint256 pairIndex, uint256 collateral, uint256 leverage, uint256 refPrice, uint256 slippageP)
		external
	{
		router.openTrade(
			IVerantaTradingRouter.Trade({
				trader: address(this),
				pairIndex: pairIndex,
				index: 0,
				initialPosToken: 0,
				positionSizeUSDC: collateral,
				openPrice: refPrice,
				buy: false,
				leverage: leverage,
				tp: 0,
				sl: 0,
				timestamp: 0
			}),
			0, // market
			slippageP
		);
	}
}
