// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {Shares} from '../fund/Shares.sol';
import {Vault} from '../fund/Vault.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {IExternalPosition} from '../interfaces/IExternalPosition.sol';
import {IPolicy} from '../interfaces/IPolicy.sol';
import {IIntegrationAdapter} from '../interfaces/IIntegrationAdapter.sol';
import {IAdapterRegistry, IProtocolFeeConfig} from '../interfaces/IAdapterRegistry.sol';
import {IPositionTypeRegistry} from '../interfaces/IPositionTypeRegistry.sol';
import {IExternalPositionTypeFactory} from '../interfaces/IExternalPositionTypeFactory.sol';
import {MathHelpers} from '../libraries/MathHelpers.sol';
import {PoolPriceRegistrar} from '../pricing/PoolPriceRegistrar.sol';
import {FundValuation} from './FundValuation.sol';

/// @notice What a reconfiguration reads from the fund it replaces (v1 or v2).
interface IPriorComptroller {
	function highWaterMark() external view returns (uint256);
	function getTrackedAssets() external view returns (address[] memory);
}

/// @title Comptroller
/// @notice Per-fund logic: deposits, redemptions, GAV/share price, fees, policies, tracked
///         assets and external positions.
/// @dev Deposits are async: request (escrow) → wait ≥ minRequestDuration → anyone executes at
///      the current share price, so deposit→withdraw is never atomic.
///      Redemptions: for the denomination asset (includes external positions), or in kind
///      (tracked assets pro rata, forfeits external positions, needs no prices).
///      Fees settle before every share-supply change: management (compounding) and performance
///      (continuous HWM) to fundOwner; the protocol AUM fee to the factory's recipient.
contract ComptrollerV2 is ReentrancyGuard {
	using SafeERC20 for IERC20;
	using EnumerableSet for EnumerableSet.AddressSet;

	struct DepositRequest {
		uint256 assets; // denomination-asset amount escrowed
		uint64 requestedAt;
		uint256 maxSharePrice; // the depositor's limit, denomination units per SHARES_UNIT
	}

	struct FeeConfig {
		uint128 mgmtScaledPerSecondRate; // 1e27-scaled per-second rate; 1e27 = 0%
		uint16 perfFeeBps; // % of wealth created above HWM
	}

	uint256 public constant SHARES_UNIT = 1e18;
	uint256 public constant BPS = 10_000;
	uint256 private constant RATE_SCALE = 1e27;
	uint256 private constant SECONDS_IN_YEAR = 31_557_600; // 365.25 days

	// Bytecode-capped risk params.
	uint256 public constant MAX_PERF_FEE_BPS = 3_000; // 30%
	/// @dev ≈10% annual management fee, expressed as a per-second compounding rate.
	uint256 public constant MAX_MGMT_SCALED_PER_SECOND_RATE = 1_000_000_003_400_000_000_000_000_000;
	uint256 public constant MAX_SHARES_ACTION_TIMELOCK = 30 days;
	// 1-minute floor keeps request→execute non-atomic.
	uint256 public constant MIN_REQUEST_DURATION_FLOOR = 1 minutes;
	uint256 public constant MAX_REQUEST_DURATION = 7 days;
	// A matured request is executable only within the fund's window, then expires (cancel
	// reclaims). Short windows remove the "wait and pick your moment" free option.
	uint256 public constant MIN_EXECUTION_WINDOW = 15 minutes;
	uint256 public constant MAX_EXECUTION_WINDOW = 7 days;
	uint256 public constant MAX_TRACKED_ASSETS = 20;
	uint256 public constant MAX_EXTERNAL_POSITIONS = 10;
	/// @dev Donation-inflation defense: the bootstrap deposit mints this many shares to an
	///      unredeemable sink, so supply can never be dusted below it. 1e18 = one whole
	///      denomination token at the bootstrap price.
	uint256 public constant MIN_BOOTSTRAP_SHARES = 1e18;
	address public constant BOOTSTRAP_SHARES_SINK = 0x000000000000000000000000000000000000dEaD;

	address public immutable factory;
	address public immutable fundOwner;
	IERC20 public immutable denominationAsset;
	IValueInterpreter public immutable valueInterpreter;
	uint256 public immutable sharesActionTimelock;
	uint256 public immutable minRequestDuration;
	/// @notice How long a MATURED deposit request stays executable before it expires.
	uint256 public immutable executionWindow;
	/// @notice Only true-flagged ("degen") funds may hold zero-priced side-pocket assets.
	///         Changing it requires a reconfiguration.
	bool public immutable allowRiskyAssets;
	uint256 public immutable defaultSharePrice; // 10^denominationAsset.decimals()
	PoolPriceRegistrar public immutable registrar;
	FeeConfig public feeConfig;

	Shares public shares;
	Vault public vault;

	mapping(address depositor => DepositRequest) public depositRequests;
	mapping(address holder => uint256) public lastDepositTimestamp;
	mapping(IPolicy.PolicyHook hook => address[]) private policies;

	/// @dev Deposit gates. Redemptions and request cancellation are never gated.
	bool public shutDown; // one-way, fundOwner: fund is winding down
	bool public ownerDepositsPaused; // toggle, fundOwner: subscriptions closed
	bool public guardianDepositsPaused; // set via factory: guardian pauses instantly, only factory owner unpauses

	EnumerableSet.AddressSet private trackedAssets;
	EnumerableSet.AddressSet private externalPositions;

	uint256 public highWaterMark; // gross share price (denomination units per SHARES_UNIT)
	uint256 public lastMgmtFeeSettled;
	uint256 public lastProtocolFeeSettled;
	mapping(address asset => uint256) public costBasis;

	event FundInitialized(address shares, address vault);
	event DepositRequested(address indexed depositor, uint256 assets, uint256 maxSharePrice);
	event DepositRequestCancelled(address indexed depositor, uint256 assetsReturned);
	event DepositExecuted(address indexed depositor, address indexed executor, uint256 assets, uint256 sharesMinted);
	event SharesRedeemed(
		address indexed redeemer, uint256 sharesAmount, uint256 cashPaid, address[] inKindAssets, uint256[] inKindAmounts
	);
	event SharesRedeemedInKind(address indexed redeemer, uint256 sharesAmount, address[] assets, uint256[] amounts);
	event ManagementFeeSettled(uint256 sharesMinted);
	event PerformanceFeeSettled(uint256 sharesMinted, uint256 newHighWaterMark);
	event ProtocolFeeSettled(address indexed recipient, uint256 sharesMinted);
	event ProtocolFeeSharesBoughtBack(uint256 sharesAmount, uint256 amountBurned);
	event FeesSettled(address indexed caller, uint256 grossSharePrice);
	event CallOnIntegrationExecuted(
		address indexed adapter,
		address[] spendAssets,
		uint256[] spendAmounts,
		address[] incomingAssets,
		uint256[] incomingAmounts
	);
	event FundShutDown();
	event OwnerDepositsPauseSet(bool paused);
	event GuardianDepositsPauseSet(bool paused);
	event TrackedAssetAdded(address indexed asset);
	event TrackedAssetRemoved(address indexed asset);
	event ExternalPositionCreated(uint256 indexed typeId, address indexed externalPosition);
	event ExternalPositionRemoved(address indexed externalPosition);
	event CallOnExternalPositionExecuted(
		address indexed externalPosition,
		address[] assetsTransferred,
		uint256[] amountsTransferred,
		address[] assetsToReceive
	);
	event PolicyAdded(IPolicy.PolicyHook indexed hook, address indexed policy);

	error OnlyFactory();
	error OnlyFundOwner();
	error AlreadyInitialized();
	error ZeroAmount();
	error RequestExists();
	error NoRequest();
	error RequestTooYoung();
	error RequestExpired();
	error SharesActionTimelocked(address holder);
	error TrackedAssetsLimitReached();
	error ExternalPositionsLimitReached();
	error AssetNotSupported(address asset);
	error CannotRemoveDenominationAsset();
	error NonZeroBalanceRemoval(address asset);
	error InsufficientSharesBalance();
	error DepositsSuspended();
	error AlreadyShutDown();
	error AdapterNotRegistered(address adapter);
	error MinIncomingAmountNotMet(address asset, uint256 received, uint256 minAmount);
	error UnknownPositionType(uint256 typeId);
	error NotActiveExternalPosition(address position);
	error PositionValueAboveDust(address position, uint256 value);
	error ArrayLengthMismatch();
	error ZeroAddressConfig();
	error RiskyAssetsNotAllowed(address asset);
	error BootstrapDepositTooSmall();
	error ZeroGavWithSupply();
	error HookNotImplemented(IPolicy.PolicyHook hook, address policy);
	error SharePriceAboveMax(uint256 sharePrice, uint256 maxSharePrice);

	modifier onlyFundOwner() {
		if (msg.sender != fundOwner) revert OnlyFundOwner();
		_;
	}

	modifier whenDepositsAllowed() {
		if (shutDown || ownerDepositsPaused || guardianDepositsPaused) revert DepositsSuspended();
		_;
	}

	constructor(
		address factory_,
		address fundOwner_,
		IERC20 denominationAsset_,
		IValueInterpreter valueInterpreter_,
		FeeConfig memory feeConfig_,
		uint256 sharesActionTimelock_,
		uint256 minRequestDuration_,
		uint256 executionWindow_,
		bool allowRiskyAssets_,
		PoolPriceRegistrar registrar_
	) {
		if (
			factory_ == address(0) || fundOwner_ == address(0) || address(denominationAsset_) == address(0)
				|| address(valueInterpreter_) == address(0)
		) {
			revert ZeroAddressConfig();
		}
		factory = factory_;
		fundOwner = fundOwner_;
		denominationAsset = denominationAsset_;
		valueInterpreter = valueInterpreter_;
		feeConfig = feeConfig_;
		sharesActionTimelock = sharesActionTimelock_;
		minRequestDuration = minRequestDuration_;
		executionWindow = executionWindow_;
		allowRiskyAssets = allowRiskyAssets_;
		defaultSharePrice = 10 ** IERC20Metadata(address(denominationAsset_)).decimals();
		registrar = registrar_;
	}

	/// @dev Called once by the FundFactory, atomically with fund creation.
	function initialize(Shares shares_, Vault vault_) external {
		if (msg.sender != factory) revert OnlyFactory();
		if (address(shares) != address(0)) revert AlreadyInitialized();

		shares = shares_;
		vault = vault_;
		highWaterMark = defaultSharePrice;
		lastMgmtFeeSettled = block.timestamp;
		lastProtocolFeeSettled = block.timestamp;
		trackedAssets.add(address(denominationAsset));

		emit FundInitialized(address(shares_), address(vault_));
	}

	/// @dev Reconfiguration: adopt an existing fund's Shares + Vault, carrying over the HWM (a
	///      manager can never reset it) and the tracked assets. The factory re-attaches policies;
	///      external positions must be wound down first (their comptroller is immutable).
	function initializeForMigration(Shares shares_, Vault vault_, IPriorComptroller oldComptroller) external {
		if (msg.sender != factory) revert OnlyFactory();
		if (address(shares) != address(0)) revert AlreadyInitialized();

		shares = shares_;
		vault = vault_;
		uint256 priorHwm = oldComptroller.highWaterMark();
		highWaterMark = priorHwm == 0 ? defaultSharePrice : priorHwm;
		lastMgmtFeeSettled = block.timestamp;
		lastProtocolFeeSettled = block.timestamp;

		trackedAssets.add(address(denominationAsset));
		address[] memory priorTracked = oldComptroller.getTrackedAssets();
		for (uint256 i; i < priorTracked.length; ++i) {
			trackedAssets.add(priorTracked[i]);
		}

		emit FundInitialized(address(shares_), address(vault_));
	}

	// ─── Deposits: request / cancel / execute ───────────────────────────────────

	function requestDeposit(uint256 assets, uint256 maxSharePrice) external nonReentrant whenDepositsAllowed {
		if (assets == 0) revert ZeroAmount();
		if (depositRequests[msg.sender].requestedAt != 0) revert RequestExists();

		depositRequests[msg.sender] =
			DepositRequest({assets: assets, requestedAt: uint64(block.timestamp), maxSharePrice: maxSharePrice});
		denominationAsset.safeTransferFrom(msg.sender, address(this), assets);

		_runPolicies(IPolicy.PolicyHook.PostDepositRequest, abi.encode(msg.sender, assets));

		emit DepositRequested(msg.sender, assets, maxSharePrice);
	}

	/// @notice Always available: reclaim escrow for an open (or expired) request.
	function cancelDepositRequest() external nonReentrant {
		DepositRequest memory request = depositRequests[msg.sender];
		if (request.requestedAt == 0) revert NoRequest();

		delete depositRequests[msg.sender];
		denominationAsset.safeTransfer(msg.sender, request.assets);

		emit DepositRequestCancelled(msg.sender, request.assets);
	}

	/// @notice Execute a matured request at the current share price. Callable by anyone (keeper).
	/// @dev Reverts if any held asset's price is stale.
	function executeDepositRequest(address depositor) external nonReentrant whenDepositsAllowed {
		DepositRequest memory request = depositRequests[depositor];
		if (request.requestedAt == 0) revert NoRequest();
		if (block.timestamp < request.requestedAt + minRequestDuration) revert RequestTooYoung();
		if (block.timestamp > request.requestedAt + minRequestDuration + executionWindow) revert RequestExpired();

		delete depositRequests[depositor];

		(uint256 sharePrice, uint256 feeGav) = _settleFeesAndGetSharePrice();
		if (sharePrice > request.maxSharePrice) revert SharePriceAboveMax(sharePrice, request.maxSharePrice);
		uint256 sharesToMint = Math.mulDiv(request.assets, SHARES_UNIT, sharePrice);
		if (sharesToMint == 0) revert ZeroAmount();
		uint256 supplyBefore = shares.totalSupply();

		// First deposit seeds MIN_BOOTSTRAP_SHARES to the unredeemable sink (paid by the depositor).
		if (shares.totalSupply() == 0) {
			if (sharesToMint <= MIN_BOOTSTRAP_SHARES) revert BootstrapDepositTooSmall();
			shares.mint(BOOTSTRAP_SHARES_SINK, MIN_BOOTSTRAP_SHARES);
			sharesToMint -= MIN_BOOTSTRAP_SHARES;
		}

		denominationAsset.safeTransfer(address(vault), request.assets);
		shares.mint(depositor, sharesToMint);
		lastDepositTimestamp[depositor] = block.timestamp;
		_followFeePrice(feeGav, supplyBefore, request.assets);

		_runPolicies(IPolicy.PolicyHook.PostBuyShares, abi.encode(depositor, request.assets, sharesToMint));

		emit DepositExecuted(depositor, msg.sender, request.assets, sharesToMint);
	}

	// ─── Redemptions ─────────────────────────────────────────────────────────────

	/// @notice Burn shares for the redeemer's slice of the fund: cash (the denomination asset, from
	///         the vault) for every holding with a readable price that is not pool-priced, plus
	///         positions; the long-tail (pool-priced) tokens and any token whose price can't be read
	///         now, in kind. A pumped long-tail price therefore can't pull cash out, and a stale feed
	///         never stops the exit. The performance fee settles first only when every price reads.
	/// @dev A position whose value can't be read can't be paid in kind: the redemption waits for
	///      it (redeemSharesInKind stays open).
	function redeemShares(uint256 sharesAmount) external nonReentrant {
		_checkTimelockAndBalance(msg.sender, sharesAmount);
		_settleManagementFee();
		FundValuation.Valuation memory v = _value(true);
		if (v.complete) _settlePerformanceFee(v.feeGav, shares.totalSupply());
		_settleProtocolFee();

		uint256 totalSupply = shares.totalSupply();
		uint256 cashOwed = Math.mulDiv(v.cashValue, sharesAmount, totalSupply);
		_runPolicies(IPolicy.PolicyHook.RedeemSharesForSpecificAssets, abi.encode(msg.sender, sharesAmount, cashOwed));

		uint256[] memory amounts = new uint256[](v.assets.length);
		for (uint256 i; i < v.assets.length; ++i) {
			if (v.inKind[i]) amounts[i] = _payOutShare(v.assets[i], sharesAmount, totalSupply);
		}

		shares.burn(msg.sender, sharesAmount);
		if (cashOwed > 0) vault.withdraw(address(denominationAsset), msg.sender, cashOwed);
		for (uint256 i; i < v.assets.length; ++i) {
			if (amounts[i] > 0) vault.withdraw(v.assets[i], msg.sender, amounts[i]);
		}

		emit SharesRedeemed(msg.sender, sharesAmount, cashOwed, v.assets, amounts);
	}

	/// @notice Guaranteed exit: a pro-rata slice of every tracked asset. Needs no prices and runs
	///         no policies; skips the performance fee and forfeits external-position value.
	function redeemSharesInKind(uint256 sharesAmount) external nonReentrant {
		_redeemSharesInKind(sharesAmount, new address[](0));
	}

	/// @notice In-kind exit that forfeits `assetsToSkip` (e.g. a paused token), so one broken
	///         asset can't block the exit. Skipped value stays with the remaining holders.
	function redeemSharesInKindWithSkips(uint256 sharesAmount, address[] calldata assetsToSkip)
		external
		nonReentrant
	{
		_redeemSharesInKind(sharesAmount, assetsToSkip);
	}

	function _redeemSharesInKind(uint256 sharesAmount, address[] memory assetsToSkip) private {
		_checkTimelockAndBalance(msg.sender, sharesAmount);

		_settleManagementFee();
		_settleProtocolFee(); // no pricing dependency; redeemers must not escape the dilution

		uint256 totalSupply = shares.totalSupply();
		uint256 assetCount = trackedAssets.length();
		address[] memory assets = new address[](assetCount);
		uint256[] memory amounts = new uint256[](assetCount);

		for (uint256 i; i < assetCount; ++i) {
			address asset = trackedAssets.at(i);
			assets[i] = asset;
			bool skip;
			for (uint256 j; j < assetsToSkip.length; ++j) {
				if (assetsToSkip[j] == asset) {
					skip = true;
					break;
				}
			}
			amounts[i] = skip ? 0 : _payOutShare(asset, sharesAmount, totalSupply);
		}

		shares.burn(msg.sender, sharesAmount);

		for (uint256 i; i < assetCount; ++i) {
			if (amounts[i] > 0) {
				vault.withdraw(assets[i], msg.sender, amounts[i]);
			}
		}

		emit SharesRedeemedInKind(msg.sender, sharesAmount, assets, amounts);
	}

	// ─── Valuation ───────────────────────────────────────────────────────────────

	/// @notice GAV in denomination units: tracked vault balances + external positions (managed −
	///         debt, floored at zero each). Deposit escrow is not fund value.
	function calcGav() public returns (uint256) {
		return _value(false).gav;
	}

	/// @dev FundValuation.value over this fund's holdings (see there).
	function _value(bool tolerant) private returns (FundValuation.Valuation memory) {
		return FundValuation.value(trackedAssets, externalPositions, costBasis, _context(), tolerant);
	}

	function _calcExternalPositionValue(IExternalPosition position) private returns (uint256) {
		return FundValuation.positionValue(position, _context());
	}

	function _context() private view returns (FundValuation.Context memory) {
		return FundValuation.Context(valueInterpreter, registrar, address(vault), address(denominationAsset));
	}


	/// @dev The redeemer's pro-rata units of `asset`; a pool-priced token's cost basis leaves with them.
	function _payOutShare(address asset, uint256 sharesAmount, uint256 totalSupply) private returns (uint256 amount) {
		uint256 balance = IERC20(asset).balanceOf(address(vault));
		amount = Math.mulDiv(balance, sharesAmount, totalSupply);
		FundValuation.reduceCostBasis(costBasis, asset, amount, balance);
	}

	/// @dev A deposit buys in at the full share price, so where unrealized long-tail gains sit
	///      above cost it lifts the fee price without creating wealth; the high-water mark moves by
	///      the same amount so newcomers' money never reads as performance.
	function _followFeePrice(uint256 feeGav, uint256 supplyBefore, uint256 assetsIn) private {
		if (supplyBefore == 0) return;
		uint256 before = Math.mulDiv(feeGav, SHARES_UNIT, supplyBefore);
		uint256 afterDeposit = Math.mulDiv(feeGav + assetsIn, SHARES_UNIT, shares.totalSupply());
		if (afterDeposit > before) highWaterMark += afterDeposit - before;
	}

	/// @notice Value of the vault's holding of one asset, in denomination units.
	/// @dev Values untracked assets too; only tracked ones count in calcGav.
	function calcAssetGav(address asset) external returns (uint256) {
		uint256 balance = IERC20(asset).balanceOf(address(vault));
		if (balance == 0) return 0;
		return valueInterpreter.calcCanonicalAssetValue(asset, balance, address(denominationAsset));
	}

	/// @notice All tracked assets with their current vault balances.
	function getFundHoldings() external view returns (address[] memory assets, uint256[] memory balances) {
		uint256 assetCount = trackedAssets.length();
		assets = new address[](assetCount);
		balances = new uint256[](assetCount);
		for (uint256 i; i < assetCount; ++i) {
			assets[i] = trackedAssets.at(i);
			balances[i] = IERC20(assets[i]).balanceOf(address(vault));
		}
	}

	/// @notice Gross share price in denomination units per SHARES_UNIT of shares.
	function calcGrossShareValue() public returns (uint256) {
		uint256 totalSupply = shares.totalSupply();
		if (totalSupply == 0) return defaultSharePrice;
		return Math.mulDiv(calcGav(), SHARES_UNIT, totalSupply);
	}

	// ─── Trading: callOnIntegration ──────────────────────────────────────────────

	/// @notice Trade fund assets through a factory-registered adapter.
	/// @dev Incoming amounts are measured as vault balance deltas (never adapter claims), incoming
	///      assets are auto-tracked, and PostCallOnIntegration policies run on the result.
	///      Not gated by pause/shutdown: a winding-down fund must still unwind.
	function callOnIntegration(address adapter, bytes calldata integrationData) external onlyFundOwner nonReentrant {
		if (!IAdapterRegistry(factory).isAdapterRegistered(adapter)) revert AdapterNotRegistered(adapter);

		(
			address[] memory spendAssets,
			uint256[] memory spendAmounts,
			address[] memory incomingAssets,
			uint256[] memory minIncomingAmounts
		) = IIntegrationAdapter(adapter).parseAssetsForAction(integrationData);

		uint256[] memory balancesBefore = new uint256[](incomingAssets.length);
		for (uint256 i; i < incomingAssets.length; ++i) {
			balancesBefore[i] = IERC20(incomingAssets[i]).balanceOf(address(vault));
		}
		uint256[] memory spendBefore = new uint256[](spendAssets.length);
		for (uint256 i; i < spendAssets.length; ++i) {
			spendBefore[i] = IERC20(spendAssets[i]).balanceOf(address(vault));
		}

		for (uint256 i; i < spendAssets.length; ++i) {
			vault.withdraw(spendAssets[i], adapter, spendAmounts[i]);
		}

		IIntegrationAdapter(adapter).executeAction(address(vault), integrationData);

		uint256[] memory incomingAmounts = new uint256[](incomingAssets.length);
		for (uint256 i; i < incomingAssets.length; ++i) {
			uint256 received = IERC20(incomingAssets[i]).balanceOf(address(vault)) - balancesBefore[i];
			if (received < minIncomingAmounts[i]) {
				revert MinIncomingAmountNotMet(incomingAssets[i], received, minIncomingAmounts[i]);
			}
			incomingAmounts[i] = received;
			_trackAsset(incomingAssets[i]);
		}
		FundValuation.followTrade(costBasis, _context(), spendAssets, spendBefore, incomingAssets, incomingAmounts);

		_runPolicies(
			IPolicy.PolicyHook.PostCallOnIntegration,
			abi.encode(adapter, spendAssets, spendAmounts, incomingAssets, incomingAmounts)
		);

		emit CallOnIntegrationExecuted(adapter, spendAssets, spendAmounts, incomingAssets, incomingAmounts);
	}

	// ─── Shutdown / pause lane ───────────────────────────────────────────────────

	/// @notice Permanently shut the fund down: no new deposits or positions; redemptions stay open.
	function shutDownFund() external onlyFundOwner {
		if (shutDown) revert AlreadyShutDown();
		shutDown = true;
		emit FundShutDown();
	}

	/// @notice Manager's subscription switch: close/reopen deposits at will.
	function setOwnerDepositsPaused(bool paused) external onlyFundOwner {
		ownerDepositsPaused = paused;
		emit OwnerDepositsPauseSet(paused);
	}

	/// @notice Emergency lane via the factory: the guardian pauses instantly; only the factory
	///         owner (governance) unpauses.
	function setGuardianDepositsPaused(bool paused) external {
		if (msg.sender != factory) revert OnlyFactory();
		guardianDepositsPaused = paused;
		emit GuardianDepositsPauseSet(paused);
	}

	// ─── Fees ────────────────────────────────────────────────────────────────────

	/// @notice Settle accrued fees without a deposit/redeem. Callable by anyone; needs valid prices.
	function settleFees() external nonReentrant returns (uint256 grossSharePrice) {
		(grossSharePrice,) = _settleFeesAndGetSharePrice();
		emit FeesSettled(msg.sender, grossSharePrice);
	}

	/// @dev Settles management, performance, then protocol fee; returns the gross share price.
	///      Zero GAV with supply outstanding reverts (pricing at the default would expropriate
	///      holders); the in-kind exit stays open.
	function _settleFeesAndGetSharePrice() private returns (uint256 sharePrice, uint256 feeGav) {
		_settleManagementFee();

		uint256 totalSupply = shares.totalSupply();
		if (totalSupply == 0) {
			_settleProtocolFee(); // advances the clock; mints nothing at zero supply
			return (defaultSharePrice, 0);
		}

		FundValuation.Valuation memory v = _value(false);
		if (v.gav == 0) revert ZeroGavWithSupply();

		_settlePerformanceFee(v.feeGav, totalSupply);
		// After the manager's fees, before pricing the action.
		_settleProtocolFee();
		return (Math.mulDiv(v.gav, SHARES_UNIT, shares.totalSupply()), v.feeGav);
	}

	/// @dev sharesDue = (rpow(scaledPerSecondRate, dt, 1e27) - 1e27) * totalSupply / 1e27
	function _settleManagementFee() private {
		uint256 rate = feeConfig.mgmtScaledPerSecondRate;
		uint256 elapsed = block.timestamp - lastMgmtFeeSettled;
		lastMgmtFeeSettled = block.timestamp;
		if (rate <= RATE_SCALE || elapsed == 0) return;

		uint256 totalSupply = shares.totalSupply();
		if (totalSupply == 0) return;

		uint256 sharesDue = Math.mulDiv(MathHelpers.rpow(rate, elapsed, RATE_SCALE) - RATE_SCALE, totalSupply, RATE_SCALE);
		if (sharesDue == 0) return;

		shares.mint(fundOwner, sharesDue);
		emit ManagementFeeSettled(sharesDue);
	}

	/// @dev Continuous accrual, no crystallization, on the FEE GAV (long-tail tokens at the lower
	///      of value and cost): g = GAV/TS; W = max(g - hwm, 0)*TS; F = W*rate;
	///      feeShares = F*TS/(GAV - F); hwm' = GAV/TS' when paid.
	function _settlePerformanceFee(uint256 gav, uint256 totalSupply) private {
		uint256 rate = feeConfig.perfFeeBps;
		if (rate == 0) return;

		uint256 grossSharePrice = Math.mulDiv(gav, SHARES_UNIT, totalSupply);
		uint256 hwm = highWaterMark;
		if (grossSharePrice <= hwm) return;

		uint256 wealthCreated = Math.mulDiv(grossSharePrice - hwm, totalSupply, SHARES_UNIT);
		uint256 feeValue = (wealthCreated * rate) / BPS;
		if (feeValue == 0 || feeValue >= gav) return;

		uint256 feeShares = Math.mulDiv(feeValue, totalSupply, gav - feeValue);
		if (feeShares == 0) return;

		shares.mint(fundOwner, feeShares);
		uint256 newHwm = Math.mulDiv(gav, SHARES_UNIT, shares.totalSupply());
		highWaterMark = newHwm;

		emit PerformanceFeeSettled(feeShares, newHwm);
	}

	/// @dev Protocol AUM fee: factory-set bps/yr of share supply, minted to the factory's
	///      recipient (rate read live, capped at 1%/yr by the factory). The clock advances only
	///      when this fund settles, so a fee turned on later charges since the last settlement.
	function _settleProtocolFee() private {
		uint256 elapsed = block.timestamp - lastProtocolFeeSettled;
		if (elapsed == 0) return;
		lastProtocolFeeSettled = block.timestamp;

		(uint256 feeBps, address recipient) = IProtocolFeeConfig(factory).getProtocolFeeConfig();
		if (feeBps == 0 || recipient == address(0)) return;

		uint256 totalSupply = shares.totalSupply();
		if (totalSupply == 0) return;

		uint256 sharesDue = (totalSupply * feeBps * elapsed) / (SECONDS_IN_YEAR * BPS);
		if (sharesDue == 0) return;

		shares.mint(recipient, sharesDue);
		emit ProtocolFeeSettled(recipient, sharesDue);
	}

	/// @notice Protocol-fee buyback, called by the factory: burns the reserve's fee shares and
	///         sends the burn asset (FROST) from the vault to the dead address (hardcoded here).
	function executeProtocolFeeBuyBack(
		address recipient,
		address burnAsset,
		uint256 sharesAmount,
		uint256 amountToBurn
	) external nonReentrant {
		if (msg.sender != factory) revert OnlyFactory();
		shares.burn(recipient, sharesAmount);
		vault.withdraw(burnAsset, 0x000000000000000000000000000000000000dEaD, amountToBurn);
		emit ProtocolFeeSharesBoughtBack(sharesAmount, amountToBurn);
	}

	// ─── Tracked assets & external positions (fundOwner ops) ────────────────────

	function addTrackedAsset(address asset) external onlyFundOwner {
		if (shutDown) revert AlreadyShutDown();
		_trackAsset(asset);
	}

	/// @dev Shared by explicit tracking and callOnIntegration auto-tracking. Idempotent.
	function _trackAsset(address asset) private {
		if (trackedAssets.contains(asset)) return;
		if (!valueInterpreter.isSupportedAsset(asset)) revert AssetNotSupported(asset);
		if (valueInterpreter.isZeroPricedAsset(asset) && !allowRiskyAssets) revert RiskyAssetsNotAllowed(asset);
		if (trackedAssets.length() >= MAX_TRACKED_ASSETS) revert TrackedAssetsLimitReached();
		trackedAssets.add(asset);
		emit TrackedAssetAdded(asset);
	}

	/// @dev An asset with a non-zero vault balance is fund value and cannot be untracked.
	function removeTrackedAsset(address asset) external onlyFundOwner {
		if (asset == address(denominationAsset)) revert CannotRemoveDenominationAsset();
		if (IERC20(asset).balanceOf(address(vault)) != 0) revert NonZeroBalanceRemoval(asset);
		if (trackedAssets.remove(asset)) emit TrackedAssetRemoved(asset);
	}

	/// @notice Deploy and activate an external position of a factory-registered type.
	function createExternalPosition(uint256 typeId, bytes calldata initArgs)
		external
		onlyFundOwner
		nonReentrant
		returns (address position)
	{
		if (shutDown) revert AlreadyShutDown();
		address typeFactory = IPositionTypeRegistry(factory).positionTypeFactories(typeId);
		if (typeFactory == address(0)) revert UnknownPositionType(typeId);
		if (externalPositions.length() >= MAX_EXTERNAL_POSITIONS) revert ExternalPositionsLimitReached();

		position = IExternalPositionTypeFactory(typeFactory).deployPosition(address(this), initArgs);
		externalPositions.add(position);

		_runPolicies(IPolicy.PolicyHook.CreateExternalPosition, abi.encode(typeId, position));

		emit ExternalPositionCreated(typeId, position);
	}

	/// @notice Act on an active external position, optionally moving vault assets to it first.
	/// @param assetsToReceive Assets expected back in the vault; auto-tracked.
	/// @dev Policies get the measured value lost (position value + vault flows, before vs after),
	///      never the stated arrays. Venue-side losses between calls are outside this check.
	function callOnExternalPosition(
		address position,
		address[] calldata assetsToTransfer,
		uint256[] calldata amountsToTransfer,
		address[] calldata assetsToReceive,
		bytes calldata actionData
	) external onlyFundOwner nonReentrant {
		if (!externalPositions.contains(position)) revert NotActiveExternalPosition(position);
		if (assetsToTransfer.length != amountsToTransfer.length) revert ArrayLengthMismatch();

		// A risk-reducing action (e.g. closing a perp) with nothing leaving the vault skips
		// pricing, so a stale oracle never stops a manager from cutting risk.
		bool unpriced = assetsToTransfer.length == 0 && IExternalPosition(position).isRiskReducing(actionData);
		uint256 beforeValue = unpriced
			? 0
			: _calcExternalPositionValue(IExternalPosition(position)) + FundValuation.assetsValue(assetsToTransfer, amountsToTransfer, _context());
		uint256[] memory receiveBalancesBefore = _vaultBalances(assetsToReceive);

		for (uint256 i; i < assetsToTransfer.length; ++i) {
			vault.withdraw(assetsToTransfer[i], position, amountsToTransfer[i]);
		}

		IExternalPosition(position).receiveCallFromFund(actionData);

		uint256 afterValue = (unpriced ? 0 : _calcExternalPositionValue(IExternalPosition(position)))
			+ _receivedValue(assetsToReceive, receiveBalancesBefore, !unpriced);
		uint256 lossValue = beforeValue > afterValue ? beforeValue - afterValue : 0;

		_runPolicies(IPolicy.PolicyHook.PostCallOnExternalPosition, abi.encode(position, lossValue));

		emit CallOnExternalPositionExecuted(position, assetsToTransfer, amountsToTransfer, assetsToReceive);
	}

	function _vaultBalances(address[] calldata assets) private view returns (uint256[] memory balances) {
		balances = new uint256[](assets.length);
		for (uint256 i; i < assets.length; ++i) {
			balances[i] = IERC20(assets[i]).balanceOf(address(vault));
		}
	}

	/// @dev Values what the vault actually received and auto-tracks it; duplicates are skipped
	///      (counting a delta twice would hide losses).
	function _receivedValue(address[] calldata assets, uint256[] memory balancesBefore, bool priced)
		private
		returns (uint256 value)
	{
		for (uint256 i; i < assets.length; ++i) {
			_trackAsset(assets[i]);
			if (!priced) continue;
			bool duplicate;
			for (uint256 j; j < i; ++j) {
				if (assets[j] == assets[i]) {
					duplicate = true;
					break;
				}
			}
			if (duplicate) continue;
			uint256 received = IERC20(assets[i]).balanceOf(address(vault)) - balancesBefore[i];
			if (received > 0) {
				value += valueInterpreter.calcCanonicalAssetValue(assets[i], received, address(denominationAsset));
			}
		}
	}

	/// @notice Deactivate an external position once its value is dust (≤ 1 denomination unit),
	///         so value can never be hidden by untracking it.
	function removeExternalPosition(address position) external onlyFundOwner nonReentrant {
		if (!externalPositions.contains(position)) revert NotActiveExternalPosition(position);

		uint256 value = _calcExternalPositionValue(IExternalPosition(position));
		if (value > defaultSharePrice) revert PositionValueAboveDust(position, value);

		externalPositions.remove(position);
		_runPolicies(IPolicy.PolicyHook.RemoveExternalPosition, abi.encode(position, value));

		emit ExternalPositionRemoved(position);
	}

	function getTrackedAssets() external view returns (address[] memory) {
		return trackedAssets.values();
	}

	function getExternalPositions() external view returns (address[] memory) {
		return externalPositions.values();
	}

	// ─── Policies ────────────────────────────────────────────────────────────────

	/// @notice Add a policy. Only the factory can, at creation and when carrying the ruleset
	///         across a reconfiguration; managers never change the rule set.
	function addPolicy(IPolicy.PolicyHook hook, address policy) external {
		if (msg.sender != factory) revert OnlyFactory();
		// A policy may only attach to hooks it implements (else it bricks or silently no-ops).
		IPolicy.PolicyHook[] memory implemented = IPolicy(policy).implementedHooks();
		bool matched;
		for (uint256 i; i < implemented.length; ++i) {
			if (implemented[i] == hook) {
				matched = true;
				break;
			}
		}
		if (!matched) revert HookNotImplemented(hook, policy);
		policies[hook].push(policy);
		emit PolicyAdded(hook, policy);
	}

	function getPolicies(IPolicy.PolicyHook hook) external view returns (address[] memory) {
		return policies[hook];
	}

	/// @notice Called by the Shares token on every transfer (not mint/burn).
	function validateSharesTransfer(address from, address to, uint256 amount) external {
		if (msg.sender != address(shares)) revert OnlyFundOwner();
		if (block.timestamp < lastDepositTimestamp[from] + sharesActionTimelock) revert SharesActionTimelocked(from);
		_runPolicies(IPolicy.PolicyHook.PreTransferShares, abi.encode(from, to, amount));
	}

	function _runPolicies(IPolicy.PolicyHook hook, bytes memory validationData) private {
		address[] memory hookPolicies = policies[hook];
		for (uint256 i; i < hookPolicies.length; ++i) {
			IPolicy(hookPolicies[i]).validate(hook, validationData);
		}
	}

	function _checkTimelockAndBalance(address holder, uint256 sharesAmount) private view {
		if (sharesAmount == 0) revert ZeroAmount();
		if (shares.balanceOf(holder) < sharesAmount) revert InsufficientSharesBalance();
		if (block.timestamp < lastDepositTimestamp[holder] + sharesActionTimelock) {
			revert SharesActionTimelocked(holder);
		}
	}
}
