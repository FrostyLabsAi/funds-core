// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {RedemptionQueueV2} from '../../src/redemption/RedemptionQueueV2.sol';

/// @dev Test only: RedemptionQueueV2 with a 1-second deadline, so a fork test can liquidate within the seconds a real
///      signed Veranta price (or a Chainlink round) stays usable. Production keeps 4 days.
contract RedemptionQueueV2ShortDeadline is RedemptionQueueV2 {
	constructor(address owner_) RedemptionQueueV2(owner_) {}

	function deadline() public pure override returns (uint256) {
		return 1;
	}
}
