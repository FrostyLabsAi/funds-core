// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice Circle CCTP TokenMessenger (subset): native USDC burn-and-mint bridging.
interface ICCTPTokenMessenger {
	/// @param mintRecipient recipient address on the destination chain, as bytes32
	///        (Solana pubkeys are full 32 bytes).
	function depositForBurn(uint256 amount, uint32 destinationDomain, bytes32 mintRecipient, address burnToken)
		external
		returns (uint64 nonce);
}
