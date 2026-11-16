// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice WETH9's wrap/unwrap.
interface IWETH9 {
	function deposit() external payable;
	function withdraw(uint256 amount) external;
}
