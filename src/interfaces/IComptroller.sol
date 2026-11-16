// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IPolicy} from './IPolicy.sol';
import {IShares} from './IShares.sol';
import {IVault} from './IVault.sol';
import {IValueInterpreter} from './IValueInterpreter.sol';
import {IPoolPriceRegistrar} from './IPoolPriceRegistrar.sol';
import {IRedemptionQueue} from './IRedemptionQueue.sol';
import {IPriorComptroller} from './IPriorComptroller.sol';

/// @title IComptroller
/// @notice A fund's logic: deposits, redemptions, valuation, fees, policies, tracked assets and external positions.
///         Everything the factory, policies, positions, the redemption queue and the registries call on a fund.
interface IComptroller is IPriorComptroller {
	struct FeeConfig {
		uint128 mgmtScaledPerSecondRate; // 1e27-scaled per-second rate; 1e27 = 0%
		uint16 perfFeeBps; // % of wealth created above the high-water mark
	}

	// ─── Limits (bytecode caps the factory checks a new fund's config against) ───
	function MAX_PERF_FEE_BPS() external view returns (uint256);
	function MAX_MGMT_SCALED_PER_SECOND_RATE() external view returns (uint256);
	function MAX_SHARES_ACTION_TIMELOCK() external view returns (uint256);
	function MIN_REQUEST_DURATION_FLOOR() external view returns (uint256);
	function MAX_REQUEST_DURATION() external view returns (uint256);
	function MIN_EXECUTION_WINDOW() external view returns (uint256);
	function MAX_EXECUTION_WINDOW() external view returns (uint256);
	function MAX_TRACKED_ASSETS() external view returns (uint256);
	function MAX_EXTERNAL_POSITIONS() external view returns (uint256);

	// ─── Wiring and config ───
	function factory() external view returns (address);
	function fundOwner() external view returns (address);
	function denominationAsset() external view returns (IERC20);
	function valueInterpreter() external view returns (IValueInterpreter);
	function registrar() external view returns (IPoolPriceRegistrar);
	function redemptionQueue() external view returns (IRedemptionQueue);
	function perpConfig() external view returns (address);
	function shares() external view returns (IShares);
	function vault() external view returns (IVault);
	function sharesActionTimelock() external view returns (uint256);
	function minRequestDuration() external view returns (uint256);
	function executionWindow() external view returns (uint256);
	function allowRiskyAssets() external view returns (bool);
	function feeConfig() external view returns (uint128 mgmtScaledPerSecondRate, uint16 perfFeeBps);

	// ─── State ───
	function shutDown() external view returns (bool);
	function ownerDepositsPaused() external view returns (bool);
	function guardianDepositsPaused() external view returns (bool);
	function lastMgmtFeeSettled() external view returns (uint256);
	function lastProtocolFeeSettled() external view returns (uint256);
	function depositRequests(address depositor)
		external
		view
		returns (uint256 assets, uint64 requestedAt, uint256 maxSharePrice);
	function lastDepositTimestamp(address holder) external view returns (uint256);
	function costBasis(address asset) external view returns (uint256);
	function getExternalPositions() external view returns (address[] memory);
	function getPolicies(IPolicy.PolicyHook hook) external view returns (address[] memory);
	function getFundHoldings() external view returns (address[] memory assets, uint256[] memory balances);

	// ─── Setup (factory) ───
	function initialize(IShares shares_, IVault vault_) external;
	function initializeForMigration(IShares shares_, IVault vault_, IPriorComptroller oldComptroller) external;
	function addPolicy(IPolicy.PolicyHook hook, address policy) external;
	function setGuardianDepositsPaused(bool paused) external;

	// ─── Investors ───
	function requestDeposit(uint256 assets, uint256 maxSharePrice) external;
	function cancelDepositRequest() external;
	function executeDepositRequest(address depositor) external;
	function redeemShares(uint256 sharesAmount) external;

	// ─── Redemption queue ───
	function payOutRedemption(address to, uint256 sharesToBurn, uint256 amount) external;
	function settleFeesForRedemption() external returns (uint256 gav, bool complete);
	function liquidateTrade(address adapter, bytes calldata integrationData) external;
	function liquidatePosition(address position, address[] calldata assetsToReceive, bytes[] calldata actions) external;

	// ─── Valuation and fees ───
	function calcGav() external returns (uint256);
	function calcAssetGav(address asset) external returns (uint256);
	function calcGrossShareValue() external returns (uint256);
	function settleFees() external returns (uint256 grossSharePrice);
	function executeProtocolFeeBuyBack(address recipient, address burnAsset, uint256 sharesAmount, uint256 amountToBurn)
		external;

	// ─── Manager ───
	function callOnIntegration(address adapter, bytes calldata integrationData) external;
	function shutDownFund() external;
	function setOwnerDepositsPaused(bool paused) external;
	function addTrackedAsset(address asset) external;
	function writeOffAsset(address asset) external;
	function removeTrackedAsset(address asset) external;
	function createExternalPosition(uint256 typeId, bytes calldata initArgs) external returns (address position);
	function callOnExternalPosition(
		address position,
		address[] calldata assetsToTransfer,
		uint256[] calldata amountsToTransfer,
		address[] calldata assetsToReceive,
		bytes calldata actionData
	) external;
	function removeExternalPosition(address position) external;

	// ─── Shares ───
	function validateSharesTransfer(address from, address to, uint256 amount) external;
}
