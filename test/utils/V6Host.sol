// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {ComptrollerV6} from '../../src/core/ComptrollerV6.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {MockRedemptionQueueV6, MockPerpAccountFactory} from './MockRedemptionQueueV6.sol';

/// @dev A registrar with no pool-priced tokens: what a feature suite that isn't about long-tail tokens needs of one.
contract NoPoolPricedRegistrar {
	uint256 public constant MIN_LIQUIDITY_USD = 25_000;

	function poolPricedAdapter(address) external pure returns (address) {
		return address(0);
	}
}

/// @notice Builds the fund every new fund is: ComptrollerV6, on a stub registrar and a mock queue, for the feature suites
///         (policies, positions, adapters, fees). A suite that needs the real registrar or queue builds them itself.
library V6Host {
	function deployer() internal returns (ComptrollerBlueprintDeployer) {
		return new ComptrollerBlueprintDeployer(
			type(ComptrollerV6).creationCode,
			abi.encode(new NoPoolPricedRegistrar(), new MockRedemptionQueueV6(), new MockPerpAccountFactory(IERC20(address(1))))
		);
	}
}
