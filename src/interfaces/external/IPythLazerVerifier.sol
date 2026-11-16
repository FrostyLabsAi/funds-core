// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice Pyth Lazer's on-chain verifier (Base 0xACeA761c27A909d4D3895128EBe6370FDE2dF481):
///         checks the packet's signature against Pyth's trusted signers and returns the payload.
interface IPythLazerVerifier {
	function verifyUpdate(bytes calldata update) external payable returns (bytes memory payload, address signer);

	function verification_fee() external view returns (uint256);
}
