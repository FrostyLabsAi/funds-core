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
import {FundValuationV6} from './FundValuationV6.sol';
import {IRedemptionQueue} from '../interfaces/IRedemptionQueue.sol';
import {ComptrollerV3Lib} from './ComptrollerV3Lib.sol';
import {ComptrollerV6Lib} from './ComptrollerV6Lib.sol';
import {IPriorComptroller} from './ComptrollerV3.sol';

/// @notice What a reconfiguration asks the old fund's queue (RedemptionQueue and RedemptionQueueV2 both answer it).
interface IQueueBounds {
	function queueBounds(address comptroller) external view returns (uint256 head, uint256 length);
}

/// @title ComptrollerV6
/// @notice Fund version 6 = version 3 with a USDC-only exit (founder 2026-10-11, PLAN_CASH_ONLY_EXIT_2026-10-11.md): an
///         investor enters with USDC and leaves with USDC. Per-fund logic: deposits, redemptions, GAV/share price,
///         fees, policies, tracked assets and external positions.
/// @dev Deposits are async: request (escrow) → wait ≥ minRequestDuration → anyone executes at
///      the current share price, so deposit→withdraw is never atomic.
///      Redemptions pay the denomination asset only, never tokens in kind:
///      - at once (redeemShares) for a fund holding no position, no long-tail (pool-priced) token and no token whose
///        price can't be read now, so nobody picks the moment a 30-minute pool price is wrong (D1);
///      - otherwise through RedemptionQueueV2: the manager raises the USDC, the manager or the queue's keeper settles
///        at that moment's NAV. Past the 4-day deadline the manager's fees stop, the manager can't spend the vault's
///        USDC, and the keeper may liquidate (sell to USDC, close perps, pull LPs and orders back; ComptrollerV6Lib).
///      A token whose balance can't be read counts as $0 until it reads again (D2, FundValuationV6).
///      Fees settle before every share-supply change: management (compounding) and performance
///      (continuous HWM) to fundOwner; the protocol AUM fee to the factory's recipient.
contract ComptrollerV6 is ReentrancyGuard {
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
	/// @notice The queue (RedemptionQueueV2) every redemption the instant exit refuses goes through.
	IRedemptionQueue public immutable redemptionQueue;
	/// @notice The Veranta perp config every perp account names as positionFactory() (V4 accounts too, as PerpUnwinder
	///         checks): a CloseTrade of 0 on such an account is refused.
	address public immutable perpConfig;
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

	EnumerableSet.AddressSet internal trackedAssets;
	EnumerableSet.AddressSet internal externalPositions;

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
	event RedemptionPaidOut(address indexed to, uint256 sharesBurned);

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
	error PoolPriceUnsettled();
	error ZeroGavWithSupply();
	error HookNotImplemented(IPolicy.PolicyHook hook, address policy);
	error SharePriceAboveMax(uint256 sharePrice, uint256 maxSharePrice);
	error OnlyRedemptionQueue();
	error UseRedemptionQueue();
	error UsdcSpentWhileOverdue();
	error OpenRedemptions();

	modifier onlyFundOwner() {
		if (msg.sender != fundOwner) revert OnlyFundOwner();
		_;
	}

	modifier onlyRedemptionQueue() {
		if (msg.sender != address(redemptionQueue)) revert OnlyRedemptionQueue();
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
		PoolPriceRegistrar registrar_,
		IRedemptionQueue redemptionQueue_,
		address perpConfig_
	) {
		if (
			factory_ == address(0) || fundOwner_ == address(0) || address(denominationAsset_) == address(0)
				|| address(valueInterpreter_) == address(0) || address(redemptionQueue_) == address(0)
				|| perpConfig_ == address(0)
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
		redemptionQueue = redemptionQueue_;
		perpConfig = perpConfig_;
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
		_requireNoOpenRedemptions(address(oldComptroller));

		shares = shares_;
		vault = vault_;
		uint256 priorHwm = oldComptroller.highWaterMark();
		highWaterMark = priorHwm == 0 ? defaultSharePrice : priorHwm;
		lastMgmtFeeSettled = block.timestamp;
		lastProtocolFeeSettled = block.timestamp;

		trackedAssets.add(address(denominationAsset));
		ComptrollerV3Lib.copyTracked(trackedAssets, oldComptroller.getTrackedAssets());

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

		(uint256 sharePrice, uint256 feeGav) = _settleFeesAndGetSharePrice(true);
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

	/// @notice Burn shares for the redeemer's share of the fund, all of it in the denomination asset, from the vault.
	///         Only for a fund holding no position, no long-tail (pool-priced) token and no token whose price can't be
	///         read now (founder 2026-10-11, D1: the redeemer picks this moment, so no 30-minute pool price may set
	///         it); every other redemption goes through the queue. Reverts when the vault's USDC can't cover it.
	function redeemShares(uint256 sharesAmount) external nonReentrant {
		if (externalPositions.length() != 0) revert UseRedemptionQueue();
		_checkTimelockAndBalance(msg.sender, sharesAmount);
		FundValuationV6.Valuation memory v = _settleFeesTolerant();
		for (uint256 i; i < v.inKind.length; ++i) {
			if (v.inKind[i]) revert UseRedemptionQueue();
		}

		uint256 cashOwed = Math.mulDiv(v.gav, sharesAmount, shares.totalSupply());
		_runPolicies(IPolicy.PolicyHook.RedeemSharesForSpecificAssets, abi.encode(msg.sender, sharesAmount, cashOwed));

		shares.burn(msg.sender, sharesAmount);
		if (cashOwed > 0) vault.withdraw(address(denominationAsset), msg.sender, cashOwed);

		emit SharesRedeemed(msg.sender, sharesAmount, cashOwed, new address[](0), new uint256[](0));
	}

	/// @notice The queue pays a settled request: it burns the escrowed shares and pays `amount` of the denomination
	///         asset from the vault (RedemptionQueueV2 computed it at the settlement's NAV).
	function payOutRedemption(address to, uint256 sharesToBurn, uint256 amount) external onlyRedemptionQueue nonReentrant {
		shares.burn(address(redemptionQueue), sharesToBurn);
		if (amount > 0) vault.withdraw(address(denominationAsset), to, amount);
		emit RedemptionPaidOut(to, sharesToBurn);
	}

	/// @notice The queue's settlement values the fund once: fees settle (the performance fee waits while a price can't
	///         be read) and the queue pays from the GAV of the same pass, only when `complete`.
	function settleFeesForRedemption() external onlyRedemptionQueue nonReentrant returns (uint256 gav, bool complete) {
		FundValuationV6.Valuation memory v = _settleFeesTolerant();
		// with a pool unsettled the manager could be settling short on their own LP's pulls, or exiting a rug of their own at the
		// old price, so the queue waits for its deadline, and a real rug's exits go on from there (review 2026-11-01)
		return (v.gav, v.complete && (!v.unsettled || _overdue()));
	}

	/// @notice Liquidation, through the queue's keeper once a redemption is overdue: sell tracked tokens into the
	///         denomination asset, a long-tail token through its pool's quote (ComptrollerV6Lib.liquidateTrade).
	function liquidateTrade(address adapter, bytes calldata integrationData) external onlyRedemptionQueue nonReentrant {
		if (!IAdapterRegistry(factory).isAdapterRegistered(adapter)) revert AdapterNotRegistered(adapter);
		ComptrollerV6Lib.liquidateTrade(trackedAssets, _tracking(), costBasis, _context(), adapter, integrationData);
	}

	/// @notice Liquidation, through the queue's keeper once a redemption is overdue: close or pull back what a position
	///         holds (ComptrollerV6Lib.liquidatePosition).
	function liquidatePosition(address position, address[] calldata assetsToReceive, bytes[] calldata actions)
		external
		onlyRedemptionQueue
		nonReentrant
	{
		if (!externalPositions.contains(position)) revert NotActiveExternalPosition(position);
		ComptrollerV6Lib.liquidatePosition(
			trackedAssets, _tracking(), _context(), perpConfig, IExternalPosition(position), assetsToReceive, actions
		);
	}

	// ─── Valuation ───────────────────────────────────────────────────────────────

	/// @notice GAV in denomination units: tracked vault balances + external positions (managed −
	///         debt, floored at zero each). Deposit escrow is not fund value.
	function calcGav() public returns (uint256) {
		return _value(false).gav;
	}

	/// @dev FundValuationV6.value over this fund's holdings (see there).
	function _value(bool tolerant) private returns (FundValuationV6.Valuation memory) {
		return FundValuationV6.value(trackedAssets, externalPositions, costBasis, _context(), tolerant);
	}

	function _calcExternalPositionValue(IExternalPosition position) private returns (uint256) {
		return FundValuationV6.positionValue(position, _context());
	}

	function _context() private view returns (FundValuationV6.Context memory) {
		return FundValuationV6.Context(valueInterpreter, registrar, address(vault), address(denominationAsset));
	}


	/// @dev A deposit buys in at the full share price, so where unrealized long-tail gains sit
	///      above cost it lifts the fee price without creating wealth; the high-water mark moves by
	///      the same amount so newcomers' money never reads as performance.
	function _followFeePrice(uint256 feeGav, uint256 supplyBefore, uint256 assetsIn) private {
		if (supplyBefore == 0) return;
		uint256 before = Math.mulDiv(feeGav, SHARES_UNIT, supplyBefore);
		uint256 afterDeposit = Math.mulDiv(feeGav + assetsIn, SHARES_UNIT, shares.totalSupply());
		// above the mark, the fee is waiting on a closed market: the mark takes the new money at cost, so the gain to charge
		// stays the holders' alone (founder 2026-11-03)
		if (before > highWaterMark) {
			highWaterMark = Math.mulDiv(Math.mulDiv(highWaterMark, supplyBefore, SHARES_UNIT) + assetsIn, SHARES_UNIT, shares.totalSupply());
		} else if (afterDeposit > before) {
			highWaterMark += afterDeposit - before;
		}
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
		assets = trackedAssets.values();
		balances = ComptrollerV3Lib.vaultBalances(address(vault), assets);
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
	///      Not gated by pause/shutdown: a winding-down fund must still unwind. While a redemption is overdue the
	///      vault's USDC can't drop (founder 2026-10-11): the manager may sell into it, never spend it.
	function callOnIntegration(address adapter, bytes calldata integrationData) external onlyFundOwner nonReentrant {
		if (!IAdapterRegistry(factory).isAdapterRegistered(adapter)) revert AdapterNotRegistered(adapter);
		uint256 usdcFloor = _usdcFloor();

		(
			address[] memory spendAssets,
			uint256[] memory spendAmounts,
			address[] memory incomingAssets,
			uint256[] memory minIncomingAmounts
		) = IIntegrationAdapter(adapter).parseAssetsForAction(integrationData);

		uint256[] memory balancesBefore = ComptrollerV3Lib.vaultBalances(address(vault), incomingAssets);
		uint256[] memory spendBefore = ComptrollerV3Lib.vaultBalances(address(vault), spendAssets);

		ComptrollerV3Lib.withdrawAll(vault, adapter, spendAssets, spendAmounts);

		IIntegrationAdapter(adapter).executeAction(address(vault), integrationData);

		uint256[] memory incomingAmounts = ComptrollerV3Lib.receivedAmounts(
			trackedAssets, _tracking(), address(vault), incomingAssets, balancesBefore, minIncomingAmounts
		);
		// from here spendAmounts is what left the vault: a deposit's refund is no loss to the policies (review 2026-11-01, Medium 4)
		spendAmounts = FundValuationV6.followTrade(costBasis, _context(), spendAssets, spendBefore, incomingAssets, incomingAmounts);
		_keepUsdc(usdcFloor);

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
		(grossSharePrice,) = _settleFeesAndGetSharePrice(false);
		emit FeesSettled(msg.sender, grossSharePrice);
	}

	/// @dev Fees as a redemption settles them: the performance fee waits while a price can't be read
	///      (the valuation marks that holding in kind and incomplete instead of reverting).
	function _settleFeesTolerant() private returns (FundValuationV6.Valuation memory v) {
		_settleManagementFee();
		v = _value(true);
		if (v.complete) _performanceFee(v.feeGav, v.gav, shares.totalSupply(), true);
		_settleProtocolFee();
	}

	/// @dev Settles management, performance, then protocol fee; returns the gross share price.
	///      Zero GAV with supply outstanding reverts (pricing at the default would expropriate
	///      holders).
	function _settleFeesAndGetSharePrice(bool deposit) private returns (uint256 sharePrice, uint256 feeGav) {
		_settleManagementFee();

		uint256 totalSupply = shares.totalSupply();
		if (totalSupply == 0) {
			_settleProtocolFee(); // advances the clock; mints nothing at zero supply
			return (defaultSharePrice, 0);
		}

		FundValuationV6.Valuation memory v = _value(false);
		if (v.gav == 0) revert ZeroGavWithSupply();
		// a closed market never stops a deposit: it buys at the last price (founder 2026-11-03). Accepted: someone who saw the
		// weekend's move keeps it, from the holders (red-team PF-02's deposit side); a manager can pause deposits for that.
		// an LP's own pulls would sell the depositor the token's share for nothing (review 2026-11-01)
		if (deposit && v.unsettled) revert PoolPriceUnsettled();

		// the performance fee waits for a real price; settling the rest must not, or a cancel loses its fee stop (Low 6).
		// A deposit buys at the price after a waiting fee, so new money pays none of it. Charging it here instead let a dust
		// deposit take a fee on a live gain over a stock that had really fallen (review 2026-11-03)
		uint256 feeWaiting = v.complete || deposit ? _performanceFee(v.feeGav, v.gav, totalSupply, v.complete) : 0;
		// After the manager's fees, before pricing the action.
		_settleProtocolFee();
		return (Math.mulDiv(v.gav - feeWaiting, SHARES_UNIT, shares.totalSupply()), v.feeGav);
	}

	/// @dev sharesDue = (rpow(scaledPerSecondRate, dt, 1e27) - 1e27) * totalSupply / 1e27
	function _settleManagementFee() internal {
		uint256 rate = feeConfig.mgmtScaledPerSecondRate;
		uint256 elapsed = block.timestamp - lastMgmtFeeSettled;
		lastMgmtFeeSettled = block.timestamp;
		if (rate <= RATE_SCALE || elapsed == 0) return;
		// fee stop: while a redemption is overdue the time is forfeited (founder 2026-10-06)
		if (_overdue()) return;

		uint256 totalSupply = shares.totalSupply();
		if (totalSupply == 0) return;

		uint256 sharesDue = Math.mulDiv(MathHelpers.rpow(rate, elapsed, RATE_SCALE) - RATE_SCALE, totalSupply, RATE_SCALE);
		if (sharesDue == 0) return;

		shares.mint(fundOwner, sharesDue);
		emit ManagementFeeSettled(sharesDue);
	}

	/// @dev Continuous accrual, no crystallization, on the FEE GAV (long-tail tokens at the lower
	///      of value and cost): g = feeGAV/TS; W = max(g - hwm, 0)*TS; F = W*rate; hwm' = feeGAV/TS' when paid.
	///      feeShares = F*TS/(fullGAV - F): a share claims the full GAV, so shares sized on the fee GAV paid the manager
	///      F*gav/feeGav, past the rate and the bytecode cap (red-team V6FEES-02, 2026-10-27).
	/// @dev With `charge`, settles the performance fee. Without it, changes nothing and returns what the fee would take: none
	///      under the fee stop, which charges nothing.
	function _performanceFee(uint256 feeGav, uint256 gav, uint256 totalSupply, bool charge) private returns (uint256 feeValue) {
		uint256 rate = feeConfig.perfFeeBps;
		if (rate == 0) return 0;

		uint256 grossSharePrice = Math.mulDiv(feeGav, SHARES_UNIT, totalSupply);
		uint256 hwm = highWaterMark;
		if (grossSharePrice <= hwm) return 0;
		// fee stop: gains made while a redemption is overdue are never charged (founder 2026-10-06)
		if (_overdue()) {
			if (charge) highWaterMark = grossSharePrice;
			return 0;
		}

		uint256 wealthCreated = Math.mulDiv(grossSharePrice - hwm, totalSupply, SHARES_UNIT);
		feeValue = (wealthCreated * rate) / BPS;
		if (!charge) return feeValue;
		if (feeValue == 0 || feeValue >= gav) return 0;

		uint256 feeShares = Math.mulDiv(feeValue, totalSupply, gav - feeValue);
		if (feeShares == 0) return 0;

		shares.mint(fundOwner, feeShares);
		uint256 newHwm = Math.mulDiv(feeGav, SHARES_UNIT, shares.totalSupply());
		highWaterMark = newHwm;

		emit PerformanceFeeSettled(feeShares, newHwm);
		return 0;
	}

	/// @dev Protocol AUM fee: factory-set bps/yr of share supply, minted to the factory's
	///      recipient (rate read live, capped at 1%/yr by the factory). The clock advances only
	///      when this fund settles, so a fee turned on later charges since the last settlement.
	function _settleProtocolFee() internal {
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
		ComptrollerV3Lib.trackAsset(trackedAssets, _tracking(), asset);
	}

	function _tracking() private view returns (ComptrollerV3Lib.Tracking memory) {
		return ComptrollerV3Lib.Tracking(valueInterpreter, allowRiskyAssets, MAX_TRACKED_ASSETS);
	}

	/// @notice Write off a token whose pool reads 1 wei: it leaves the vault for good, so deposits and the queue stop waiting on it
	///         (review 2026-11-01). Selling it is refused at that price (MinPoolLiquidityPolicy), so this is the manager's way
	///         out of a dead token. It is burned rather than sent anywhere: faking the floor to write off a live one pays nobody.
	function writeOffAsset(address asset) external onlyFundOwner nonReentrant {
		ComptrollerV6Lib.writeOff(trackedAssets, costBasis, _context(), asset);
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
	///      never the stated arrays. Venue-side losses between calls are outside this check. A perp CloseTrade of 0
	///      is refused (ComptrollerV6Lib.closesNothing); while a redemption is overdue the vault's USDC can't drop.
	function callOnExternalPosition(
		address position,
		address[] calldata assetsToTransfer,
		uint256[] calldata amountsToTransfer,
		address[] calldata assetsToReceive,
		bytes calldata actionData
	) external onlyFundOwner nonReentrant {
		if (!externalPositions.contains(position)) revert NotActiveExternalPosition(position);
		if (assetsToTransfer.length != amountsToTransfer.length) revert ArrayLengthMismatch();
		if (ComptrollerV6Lib.closesNothing(perpConfig, position, actionData)) revert ComptrollerV6Lib.CloseOfNothing();
		uint256 usdcFloor = _usdcFloor();

		// A risk-reducing action (e.g. closing a perp) with nothing leaving the vault skips
		// pricing, so a stale oracle never stops a manager from cutting risk.
		bool unpriced = assetsToTransfer.length == 0 && IExternalPosition(position).isRiskReducing(actionData);
		uint256 beforeValue = unpriced
			? 0
			: _calcExternalPositionValue(IExternalPosition(position)) + FundValuationV6.assetsValue(assetsToTransfer, amountsToTransfer, _context());
		uint256[] memory receiveBalancesBefore = ComptrollerV3Lib.vaultBalances(address(vault), assetsToReceive);

		ComptrollerV3Lib.withdrawAll(vault, position, assetsToTransfer, amountsToTransfer);
		_trackHeld(position);

		IExternalPosition(position).receiveCallFromFund(actionData);

		uint256 lossValue = _lossValue(position, unpriced, beforeValue, assetsToReceive, receiveBalancesBefore);
		_keepUsdc(usdcFloor);

		_runPolicies(IPolicy.PolicyHook.PostCallOnExternalPosition, abi.encode(position, lossValue));

		emit CallOnExternalPositionExecuted(position, assetsToTransfer, amountsToTransfer, assetsToReceive);
	}

	/// @dev Whatever the position holds counts once it reaches the vault, listed or not (review 2026-10-11;
	///      ComptrollerV6Lib.trackHeld). A helper for stack depth.
	function _trackHeld(address position) private {
		ComptrollerV6Lib.trackHeld(trackedAssets, _tracking(), IExternalPosition(position));
	}

	/// @dev callOnExternalPosition's measured loss: the position's value plus what reached the vault, before vs after
	///      (a stack-depth split, 2026-10-11).
	function _lossValue(
		address position,
		bool unpriced,
		uint256 beforeValue,
		address[] calldata assetsToReceive,
		uint256[] memory receiveBalancesBefore
	) private returns (uint256) {
		uint256 afterValue = (unpriced ? 0 : _calcExternalPositionValue(IExternalPosition(position)))
			+ ComptrollerV3Lib.receivedValue(
				trackedAssets, _tracking(), address(vault), address(denominationAsset), assetsToReceive, receiveBalancesBefore, !unpriced
			);
		return beforeValue > afterValue ? beforeValue - afterValue : 0;
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
		if (!ComptrollerV3Lib.implementsHook(policy, hook)) revert HookNotImplemented(hook, policy);
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
		// a request or a cancel moves shares to or from the queue: an exit, not a transfer to a third party
		if (from != address(redemptionQueue) && to != address(redemptionQueue)) {
			_runPolicies(IPolicy.PolicyHook.PreTransferShares, abi.encode(from, to, amount));
		}
	}

	function _runPolicies(IPolicy.PolicyHook hook, bytes memory validationData) private {
		address[] memory hookPolicies = policies[hook];
		for (uint256 i; i < hookPolicies.length; ++i) {
			IPolicy(hookPolicies[i]).validate(hook, validationData);
		}
	}

	/// @dev A reconfiguration never orphans queued redemptions (final review 2026-10-11, C1): the old fund's queue book
	///      stays with the old comptroller, which the factory unregisters, so its requests could no longer be settled,
	///      liquidated for or made overdue. The move waits until none is open. A fund before the queue (v1, v2) has none.
	function _requireNoOpenRedemptions(address oldComptroller) private view {
		(bool ok, bytes memory ret) = oldComptroller.staticcall(abi.encodeWithSignature('redemptionQueue()'));
		if (!ok || ret.length != 32) return;
		(uint256 head, uint256 length) = IQueueBounds(abi.decode(ret, (address))).queueBounds(oldComptroller);
		if (head < length) revert OpenRedemptions();
	}

	/// @dev The vault's USDC a manager's trade must leave: all of it while a redemption is overdue, else none.
	function _overdue() private view returns (bool) {
		return redemptionQueue.isOverdue(address(this));
	}

	function _usdcFloor() private view returns (uint256) {
		if (!_overdue()) return 0;
		return denominationAsset.balanceOf(address(vault));
	}

	function _keepUsdc(uint256 usdcFloor) private view {
		if (denominationAsset.balanceOf(address(vault)) < usdcFloor) revert UsdcSpentWhileOverdue();
	}

	function _checkTimelockAndBalance(address holder, uint256 sharesAmount) internal view {
		if (sharesAmount == 0) revert ZeroAmount();
		if (shares.balanceOf(holder) < sharesAmount) revert InsufficientSharesBalance();
		if (block.timestamp < lastDepositTimestamp[holder] + sharesActionTimelock) {
			revert SharesActionTimelocked(holder);
		}
	}
}
