// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {
	IVerantaTradingRouter,
	IVerantaMulticall,
	IVerantaPairStorage,
	IVerantaReferral
} from './external/IVeranta.sol';

/// @title IVerantaPerpConfig
/// @notice The protocol config every fund perp account reads: Veranta's contracts, the pair → underlying map (managers
///         can't self-map), the autopilot keeper and the referral code.
interface IVerantaPerpConfig {
	function usdc() external view returns (IERC20);
	function router() external view returns (IVerantaTradingRouter);
	function verantaMulticall() external view returns (IVerantaMulticall);
	function tradingStorage() external view returns (address);
	function pairStorage() external view returns (IVerantaPairStorage);
	function autopilotKeeper() external view returns (address);

	/// @notice Veranta pairIndex → the ERC20 whose oracle prices that pair's underlying (0 = new opens disabled).
	function pairAsset(uint256 pairIndex) external view returns (address);

	function referral() external view returns (IVerantaReferral);
	function referralCode() external view returns (bytes32);
}
