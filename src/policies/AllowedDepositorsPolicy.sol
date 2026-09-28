// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import {IPolicy} from '../interfaces/IPolicy.sol';

/// @title AllowedDepositorsPolicy
/// @notice Restricts deposits to a whitelist.
/// @dev One instance per fund, owned by its manager. Checked at request (fail fast) and at execution.
contract AllowedDepositorsPolicy is IPolicy, Ownable2Step {
	using EnumerableSet for EnumerableSet.AddressSet;

	EnumerableSet.AddressSet private depositors;

	event DepositorAdded(address indexed depositor);
	event DepositorRemoved(address indexed depositor);

	error DepositorNotAllowed(address depositor);

	constructor(address fundManager, address[] memory initialDepositors) Ownable(fundManager) {
		for (uint256 i; i < initialDepositors.length; ++i) {
			if (depositors.add(initialDepositors[i])) emit DepositorAdded(initialDepositors[i]);
		}
	}

	function addDepositors(address[] calldata accounts) external onlyOwner {
		for (uint256 i; i < accounts.length; ++i) {
			if (depositors.add(accounts[i])) emit DepositorAdded(accounts[i]);
		}
	}

	function removeDepositors(address[] calldata accounts) external onlyOwner {
		for (uint256 i; i < accounts.length; ++i) {
			if (depositors.remove(accounts[i])) emit DepositorRemoved(accounts[i]);
		}
	}

	function isAllowed(address depositor) public view returns (bool) {
		return depositors.contains(depositor);
	}

	/// @inheritdoc IPolicy
	function validate(PolicyHook, bytes calldata validationData) external view {
		// the depositor is the first word of both hooks' data
		address depositor = abi.decode(validationData[:32], (address));
		if (!isAllowed(depositor)) revert DepositorNotAllowed(depositor);
	}

	/// @inheritdoc IPolicy
	function implementedHooks() external pure returns (PolicyHook[] memory hooks) {
		hooks = new PolicyHook[](2);
		hooks[0] = PolicyHook.PostDepositRequest;
		hooks[1] = PolicyHook.PostBuyShares;
	}
}
