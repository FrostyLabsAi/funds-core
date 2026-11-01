// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {console2} from 'forge-std/console2.sol';
import {ComptrollerV6} from '../src/core/ComptrollerV6.sol';
import {LimitOrderPositionFactory} from '../src/positions/LimitOrderPosition.sol';
import {RedemptionFixtureV6} from './utils/RedemptionFixtureV6.sol';

/// @notice The exit keeper cancels at most 100 orders in one transaction (funds-keeper usdc-exit MAX_CANCELS_PER_BATCH), and
///         Base refuses a transaction over 16,777,216 gas (EIP-7825, since its Azul upgrade). Every slot is cooled first, so
///         the batch pays what it would in a transaction of its own.
contract LimitOrderCancelBatchTest is RedemptionFixtureV6 {
	uint256 internal constant BASE_TX_GAS_CAP = 16_777_216;
	uint256 internal constant BATCH = 100;

	function test_aHundredCancelsAndTheReturnFitOneBaseTransaction() public {
		ComptrollerV6 fund = ComptrollerV6(factory.createFund(_config(0, 0, 0)));
		_deposit(fund, alice, 10_000e6);
		_deposit(fund, bob, 10_000e6);
		_swap(fund, usdc, weth, 4_000e6, 2e18);
		factory.registerPositionType(95, address(new LimitOrderPositionFactory()));
		vm.prank(manager);
		address order = fund.createExternalPosition(95, '');

		address[] memory assets = new address[](1);
		uint256[] memory amounts = new uint256[](1);
		assets[0] = address(weth);
		amounts[0] = 0.01e18;
		bytes memory place = abi.encode(
			uint8(0), abi.encode(address(weth), address(usdc), uint128(0.01e18), uint128(20e6), uint64(block.timestamp + 30 days))
		);
		for (uint256 i; i < BATCH; ++i) {
			vm.prank(manager);
			fund.callOnExternalPosition(order, assets, amounts, new address[](0), place);
		}

		_request(fund, bob, _sharesOf(fund, bob));
		skip(queue.deadline() + 1);
		_refreshFeeds();

		bytes[] memory actions = new bytes[](BATCH + 1);
		for (uint256 i; i < BATCH; ++i) actions[i] = abi.encode(uint8(1), abi.encode(i + 1));
		actions[BATCH] = abi.encode(uint8(2), abi.encode(address(weth), uint256(BATCH) * 0.01e18));

		vm.cool(order);
		vm.cool(address(fund));
		vm.cool(address(fund.vault()));
		vm.cool(address(weth));
		vm.cool(address(queue));
		vm.prank(keeper);
		uint256 before = gasleft();
		queue.liquidatePosition(address(fund), order, assets, actions);
		uint256 used = before - gasleft();
		console2.log('gas for 100 cancels and the return', used);
		assertLt(used, BASE_TX_GAS_CAP);
		assertEq(weth.balanceOf(order), 0, 'all back in the vault');
	}
}
