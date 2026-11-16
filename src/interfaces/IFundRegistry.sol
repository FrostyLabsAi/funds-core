// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice The fund factory's registry: which comptrollers are canonical funds, and the guardian.
interface IFundRegistry {
	function funds(address comptroller)
		external
		view
		returns (address comptroller_, address vault, address shares, address fundOwner, uint64 createdAt);

	function guardian() external view returns (address);
}
