// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice BaseStonk's AdvancedLaunchTokenV7 (verified source): an OpenZeppelin ERC-20 with a per-wallet cap.
interface IBaseStonkToken {
	error MaxWalletExceeded(address to, uint256 balance, uint256 cap);

	function maxWalletBps() external view returns (uint16);
	function exemptFromMaxWallet(address who) external view returns (bool);
	function totalSupply() external view returns (uint256);
}

/// @notice BaseStonk's AdvancedLauncherV7: its platform admin exempts a wallet from a token's cap.
interface IBaseStonkLauncher {
	function setTokenExempt(address token, address who, bool on) external;
}
