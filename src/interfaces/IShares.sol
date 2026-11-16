// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';

/// @title IShares
/// @notice A fund's share token. Only its comptroller mints and burns.
interface IShares is IERC20Metadata {
	function factory() external view returns (address);
	function comptroller() external view returns (address);

	/// @notice Reconfiguration: the new comptroller takes over mint and burn. Factory only.
	function migrateComptroller(address newComptroller) external;

	function mint(address to, uint256 amount) external;

	function burn(address from, uint256 amount) external;
}
