// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {RedemptionQueue} from '../../src/redemption/RedemptionQueue.sol';

/// @dev Test only: RedemptionQueue with a 1-second deadline, so a fork test can liquidate within the seconds a real
///      signed Veranta price (or a Chainlink round) stays usable. Production keeps 4 days.
contract RedemptionQueueShortDeadline is RedemptionQueue {
	constructor(address owner_) RedemptionQueue(owner_) {}

	function deadline() public pure override returns (uint256) {
		return 1;
	}
}
