// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import {IPolicy} from '../interfaces/IPolicy.sol';

/// @title AllowedSharesTransferRecipientsPolicy
/// @notice Restricts share transfers to a recipient whitelist, so a deposit whitelist can't be
///         bypassed by transferring shares.
/// @dev One instance per fund, roster owned by its manager. Mint and burn never hit it, so
///      redemptions can't be blocked.
contract AllowedSharesTransferRecipientsPolicy is IPolicy, Ownable2Step {
	using EnumerableSet for EnumerableSet.AddressSet;

	EnumerableSet.AddressSet private recipients;

	event RecipientAdded(address indexed recipient);
	event RecipientRemoved(address indexed recipient);

	error TransferRecipientNotAllowed(address recipient);

	constructor(address fundManager, address[] memory initialRecipients) Ownable(fundManager) {
		for (uint256 i; i < initialRecipients.length; ++i) {
			if (recipients.add(initialRecipients[i])) emit RecipientAdded(initialRecipients[i]);
		}
	}

	function addRecipients(address[] calldata accounts) external onlyOwner {
		for (uint256 i; i < accounts.length; ++i) {
			if (recipients.add(accounts[i])) emit RecipientAdded(accounts[i]);
		}
	}

	function removeRecipients(address[] calldata accounts) external onlyOwner {
		for (uint256 i; i < accounts.length; ++i) {
			if (recipients.remove(accounts[i])) emit RecipientRemoved(accounts[i]);
		}
	}

	function isAllowed(address recipient) public view returns (bool) {
		return recipients.contains(recipient);
	}

	/// @inheritdoc IPolicy
	function validate(PolicyHook, bytes calldata validationData) external view {
		// (from, to, amount): the recipient is the second word
		(, address to) = abi.decode(validationData[:64], (address, address));
		if (!isAllowed(to)) revert TransferRecipientNotAllowed(to);
	}

	/// @inheritdoc IPolicy
	function implementedHooks() external pure returns (PolicyHook[] memory hooks) {
		hooks = new PolicyHook[](1);
		hooks[0] = PolicyHook.PreTransferShares;
	}
}
