// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice o1's FeeEscrows (verified sources): per-recipient fee credits, paid out by anyone to the recipient —
///         `claim` on the first hook's escrow, `claimFor` on the second hook's (a later version).
interface IO1FeeEscrow {
	function owed(address recipient, address currency) external view returns (uint256);
	function claim(address recipient, address currency) external;
	function claimFor(address recipient, address currency) external;
}
