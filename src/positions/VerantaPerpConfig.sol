// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {
	IVerantaTradingRouter,
	IVerantaMulticall,
	IVerantaPairStorage,
	IVerantaReferral
} from '../interfaces/external/IVeranta.sol';
import {IVerantaPerpConfig} from '../interfaces/IVerantaPerpConfig.sol';

/// @title VerantaPerpConfig
/// @notice The shared protocol config of every fund perp account: Veranta's contracts, the pair → underlying map
///         (managers can't self-map), the autopilot keeper and the referral code. Owned by governance; accounts read it
///         live, so a change reaches every account at once.
contract VerantaPerpConfig is IVerantaPerpConfig, Ownable2Step {
	IERC20 public immutable usdc;
	IVerantaTradingRouter public immutable router;
	IVerantaMulticall public immutable verantaMulticall;
	address public immutable tradingStorage;
	IVerantaPairStorage public immutable pairStorage;

	address public autopilotKeeper;
	/// @notice Veranta pairIndex → the ERC20 whose oracle prices that pair's underlying.
	mapping(uint256 => address) public pairAsset;
	/// @notice Veranta Referral contract and the protocol code positions link to (a fee discount
	///         for the fund). Unset = LinkReferral reverts.
	IVerantaReferral public referral;
	bytes32 public referralCode;

	event AutopilotKeeperSet(address indexed keeper);
	event PairAssetSet(uint256 indexed pairIndex, address indexed asset);
	event ReferralSet(address indexed referral, bytes32 indexed code);

	error ZeroAddress();

	constructor(
		IERC20 usdc_,
		IVerantaTradingRouter router_,
		IVerantaMulticall multicall_,
		address tradingStorage_,
		IVerantaPairStorage pairStorage_,
		address autopilotKeeper_
	) Ownable(msg.sender) {
		if (
			address(usdc_) == address(0) || address(router_) == address(0) || address(multicall_) == address(0)
				|| tradingStorage_ == address(0) || address(pairStorage_) == address(0) || autopilotKeeper_ == address(0)
		) {
			revert ZeroAddress();
		}
		usdc = usdc_;
		router = router_;
		verantaMulticall = multicall_;
		tradingStorage = tradingStorage_;
		pairStorage = pairStorage_;
		autopilotKeeper = autopilotKeeper_;
		emit AutopilotKeeperSet(autopilotKeeper_);
	}

	/// @notice Rotate the protocol keeper key. Applies to NEW SetAutopilot opt-ins; funds
	///         with an existing delegation keep it until they re-opt-in (or it expires).
	function setAutopilotKeeper(address keeper) external onlyOwner {
		if (keeper == address(0)) revert ZeroAddress();
		autopilotKeeper = keeper;
		emit AutopilotKeeperSet(keeper);
	}

	/// @notice Map a Veranta pair to its VI-priceable underlying (0 disables new opens).
	function setPairAsset(uint256 pairIndex, address asset) external onlyOwner {
		pairAsset[pairIndex] = asset;
		emit PairAssetSet(pairIndex, asset);
	}

	/// @notice Set the referral contract + protocol code for NEW LinkReferral calls; already
	///         linked positions keep their link until the manager links again.
	function setReferral(IVerantaReferral referral_, bytes32 code) external onlyOwner {
		referral = referral_;
		referralCode = code;
		emit ReferralSet(address(referral_), code);
	}
}
