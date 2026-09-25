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

/// @title Comptroller
/// @notice Per-fund logic + config hub: deposits, redemptions, GAV/share price, fees, policies,
///         tracked assets, and external positions.
/// @dev Absorbs melon-v1's Participation (request/execute), Accounting (GAV/tracked assets),
///      and FeeManager (share-dilution fees) spokes into Enzyme v4's per-fund-Comptroller shape
///      (spec/architecture/release.md). References inline.
///
///      Deposit flow (melon-v1 Participation.sol:117-262 → ERC-7540 style):
///        requestDeposit(escrow) → wait ≥ minRequestDuration → executeDepositRequest
///        (anyone; keeper in practice) → shares minted at CURRENT share price.
///      Async by construction — no atomic deposit→withdraw (Gamma lesson #2). Equity feed
///      heartbeats gate execution to market hours (see ValueInterpreter).
///
///      Redemptions (spec/topics/fund-holdings.md#redemptions):
///        - redeemSharesForDenominationAsset: canonical, value-inclusive of external positions.
///        - redeemSharesInKind: guaranteed 24/7 exit, prorata tracked assets, FORFEITS
///          external-position value, settles management fee only (no pricing dependency).
///
///      Fees (settled before every share-supply change):
///        - Management: continuous compounding via scaledPerSecondRate, to fundOwner
///          (spec/fee-formulas/managementfee.md).
///        - Performance: continuous HWM accrual, no crystallization, to fundOwner
///          (spec/fee-formulas/performance-fee.md).
///        - Protocol: factory-set bps/yr AUM fee to the protocol recipient, with an
///          optional FROST-burn buyback at 50% (Enzyme v4 protocol-fee port).
contract Comptroller is ReentrancyGuard {
	using SafeERC20 for IERC20;
	using EnumerableSet for EnumerableSet.AddressSet;

	struct DepositRequest {
		uint256 assets; // denomination-asset amount escrowed
		uint64 requestedAt;
	}

	struct FeeConfig {
		uint128 mgmtScaledPerSecondRate; // 1e27-scaled per-second rate; 1e27 = 0%
		uint16 perfFeeBps; // % of wealth created above HWM
	}

	uint256 public constant SHARES_UNIT = 1e18;
	uint256 public constant BPS = 10_000;
	uint256 private constant RATE_SCALE = 1e27;
	uint256 private constant SECONDS_IN_YEAR = 31_557_600; // 365.25 days, per Enzyme v4

	// Bytecode-capped risk params (Gamma lesson #3: config is attack surface).
	uint256 public constant MAX_PERF_FEE_BPS = 3_000; // 30%
	/// @dev ≈10% annual management fee, expressed as a per-second compounding rate.
	uint256 public constant MAX_MGMT_SCALED_PER_SECOND_RATE = 1_000_000_003_400_000_000_000_000_000;
	uint256 public constant MAX_SHARES_ACTION_TIMELOCK = 30 days;
	// 1 minute floor: enough to guarantee request→execute is never atomic (the Gamma
	// lesson) while letting managers offer near-instant deposits; conservative funds
	// simply configure longer.
	uint256 public constant MIN_REQUEST_DURATION_FLOOR = 1 minutes;
	uint256 public constant MAX_REQUEST_DURATION = 7 days;
	// Execution-window bounds (M-5, founder decision 2026-09-22): a matured request is
	// executable only for the fund's configured window, then expires (cancel reclaims).
	// Short windows structurally kill the "sit on the matured request and pick your
	// moment" free option with NO keeper dependency; equity funds configure longer
	// windows to span closed markets.
	uint256 public constant MIN_EXECUTION_WINDOW = 15 minutes;
	uint256 public constant MAX_EXECUTION_WINDOW = 7 days;
	uint256 public constant MAX_TRACKED_ASSETS = 20; // melon-v1 Accounting MAX_OWNED_ASSETS
	uint256 public constant MAX_EXTERNAL_POSITIONS = 10;
	/// @dev Donation-inflation defense (security review 2026-09-22, C-1): the bootstrap
	///      deposit seeds this many shares to an unredeemable sink, so total supply can
	///      never be dusted back below it and share-price inflation against later
	///      depositors stops paying. 1e18 = exactly one whole denomination token at the
	///      bootstrap price, whatever the denomination's decimals.
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
	/// @notice Creation-time disclosure, enforced: only true-flagged ("degen") funds can
	///         acquire zero-priced side-pocket assets. Immutable for this Comptroller —
	///         changing it requires reconfiguration and its 2-day investor exit window.
	bool public immutable allowRiskyAssets;
	uint256 public immutable defaultSharePrice; // 10^denominationAsset.decimals()
	FeeConfig public feeConfig;

	Shares public shares;
	Vault public vault;

	mapping(address depositor => DepositRequest) public depositRequests;
	mapping(address holder => uint256) public lastDepositTimestamp;
	mapping(IPolicy.PolicyHook hook => address[]) private policies;

	/// @dev Deposit gates (melon-v1 Hub.shutDownFund successor + frosty-core guardian lane).
	///      Redemptions and request cancellation are NEVER gated — exiting is an investor
	///      guarantee under every state below.
	bool public shutDown; // one-way, fundOwner: fund is winding down
	bool public ownerDepositsPaused; // toggle, fundOwner: subscriptions closed
	bool public guardianDepositsPaused; // set via factory: guardian pauses instantly, only factory owner unpauses

	EnumerableSet.AddressSet private trackedAssets;
	EnumerableSet.AddressSet private externalPositions;

	uint256 public highWaterMark; // gross share price (denomination units per SHARES_UNIT)
	uint256 public lastMgmtFeeSettled;
	uint256 public lastProtocolFeeSettled;

	event FundInitialized(address shares, address vault);
	event DepositRequested(address indexed depositor, uint256 assets);
	event DepositRequestCancelled(address indexed depositor, uint256 assetsReturned);
	event DepositExecuted(address indexed depositor, address indexed executor, uint256 assets, uint256 sharesMinted);
	event SharesRedeemedForDenominationAsset(address indexed redeemer, uint256 sharesAmount, uint256 assetsPaid);
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
		bool allowRiskyAssets_
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

	/// @dev Reconfiguration variant: adopt an existing fund's Shares + Vault, carrying over
	///      (1) the HWM — a manager can NEVER reset it (and re-earn old performance) by
	///      reconfiguring — and (2) the tracked-asset set, so vault holdings never become
	///      silent residue across a migration (Gamma lesson #4). Policies do NOT carry
	///      (investor-restricting hooks stay frozen: shares supply is already nonzero).
	///      External positions must be wound down before reconfiguring — their comptroller
	///      reference is immutable (enforced by the factory).
	function initializeForMigration(Shares shares_, Vault vault_, Comptroller oldComptroller) external {
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

	function requestDeposit(uint256 assets) external nonReentrant whenDepositsAllowed {
		if (assets == 0) revert ZeroAmount();
		if (depositRequests[msg.sender].requestedAt != 0) revert RequestExists();

		depositRequests[msg.sender] = DepositRequest({assets: assets, requestedAt: uint64(block.timestamp)});
		denominationAsset.safeTransferFrom(msg.sender, address(this), assets);

		_runPolicies(IPolicy.PolicyHook.PostDepositRequest, abi.encode(msg.sender, assets));

		emit DepositRequested(msg.sender, assets);
	}

	/// @notice Always available: reclaim escrow for an open (or expired) request.
	function cancelDepositRequest() external nonReentrant {
		DepositRequest memory request = depositRequests[msg.sender];
		if (request.requestedAt == 0) revert NoRequest();

		delete depositRequests[msg.sender];
		denominationAsset.safeTransfer(msg.sender, request.assets);

		emit DepositRequestCancelled(msg.sender, request.assets);
	}

	/// @notice Execute a matured request at current share price. Callable by anyone (keeper).
	/// @dev Reverts outside market hours for funds holding equity assets (stale feeds), which
	///      is the intended weekend NAV-gaming defense.
	function executeDepositRequest(address depositor) external nonReentrant whenDepositsAllowed {
		DepositRequest memory request = depositRequests[depositor];
		if (request.requestedAt == 0) revert NoRequest();
		if (block.timestamp < request.requestedAt + minRequestDuration) revert RequestTooYoung();
		if (block.timestamp > request.requestedAt + minRequestDuration + executionWindow) revert RequestExpired();

		delete depositRequests[depositor];

		uint256 sharePrice = _settleFeesAndGetSharePrice();
		uint256 sharesToMint = Math.mulDiv(request.assets, SHARES_UNIT, sharePrice);
		if (sharesToMint == 0) revert ZeroAmount();

		// Bootstrap seeds MIN_BOOTSTRAP_SHARES to the sink — nobody can ever redeem them,
		// so supply stays above the floor for the fund's whole life and dusting the supply
		// to re-run donation inflation is impossible. The first depositor pays the seed
		// (one denomination token) and must cover more than it.
		if (shares.totalSupply() == 0) {
			if (sharesToMint <= MIN_BOOTSTRAP_SHARES) revert BootstrapDepositTooSmall();
			shares.mint(BOOTSTRAP_SHARES_SINK, MIN_BOOTSTRAP_SHARES);
			sharesToMint -= MIN_BOOTSTRAP_SHARES;
		}

		denominationAsset.safeTransfer(address(vault), request.assets);
		shares.mint(depositor, sharesToMint);
		lastDepositTimestamp[depositor] = block.timestamp;

		_runPolicies(IPolicy.PolicyHook.PostBuyShares, abi.encode(depositor, request.assets, sharesToMint));

		emit DepositExecuted(depositor, msg.sender, request.assets, sharesToMint);
	}

	// ─── Redemptions ─────────────────────────────────────────────────────────────

	/// @notice Canonical redemption: burns shares, pays denomination asset at current share
	///         price — value-INCLUSIVE of external positions. Requires the vault to hold
	///         sufficient denomination asset (keeper maintains epoch liquidity).
	function redeemSharesForDenominationAsset(uint256 sharesAmount) external nonReentrant {
		_checkTimelockAndBalance(msg.sender, sharesAmount);

		uint256 sharePrice = _settleFeesAndGetSharePrice();
		uint256 assetsOwed = Math.mulDiv(sharesAmount, sharePrice, SHARES_UNIT);
		if (assetsOwed == 0) revert ZeroAmount();

		_runPolicies(IPolicy.PolicyHook.RedeemSharesForSpecificAssets, abi.encode(msg.sender, sharesAmount, assetsOwed));

		shares.burn(msg.sender, sharesAmount);
		vault.withdraw(address(denominationAsset), msg.sender, assetsOwed);

		emit SharesRedeemedForDenominationAsset(msg.sender, sharesAmount, assetsOwed);
	}

	/// @notice Guaranteed exit: prorata slice of every tracked asset. Runs with NO pricing
	///         dependency (works when markets are closed / feeds stale) and NO policies
	///         (always-available, per spec/topics/fund-holdings.md). Settles management fee
	///         only; performance fee is skipped (needs GAV). FORFEITS external-position value.
	function redeemSharesInKind(uint256 sharesAmount) external nonReentrant {
		_redeemSharesInKind(sharesAmount, new address[](0));
	}

	/// @notice In-kind exit that SKIPS (forfeits) selected assets — the escape hatch when a
	///         tracked asset's transfers are broken (paused token, frozen wrapper). The
	///         guaranteed exit must never be blockable by one bad asset.
	/// @dev Port of melon-v1 Participation.redeemWithConstraints
	///      (melon-v1/src/fund/participation/Participation.sol:296). Skipped value stays in
	///      the vault for remaining holders.
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
			amounts[i] = skip ? 0 : Math.mulDiv(IERC20(asset).balanceOf(address(vault)), sharesAmount, totalSupply);
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

	/// @notice GAV in denomination-asset units: tracked assets (vault balances) + external
	///         positions (managed − debt, floored at zero per position), priced ONLY via
	///         the ValueInterpreter. Deposit escrow held by this contract is NOT fund value.
	function calcGav() public returns (uint256 gav) {
		uint256 assetCount = trackedAssets.length();
		for (uint256 i; i < assetCount; ++i) {
			address asset = trackedAssets.at(i);
			uint256 balance = IERC20(asset).balanceOf(address(vault));
			if (balance == 0) continue;
			gav += valueInterpreter.calcCanonicalAssetValue(asset, balance, address(denominationAsset));
		}

		uint256 positionCount = externalPositions.length();
		for (uint256 i; i < positionCount; ++i) {
			gav += _calcExternalPositionValue(IExternalPosition(externalPositions.at(i)));
		}
	}

	/// @notice Value of the vault's holding of a single asset, in denomination units.
	/// @dev Port of melon-v1 Accounting.calcAssetGAV. Untracked assets are valued too, but
	///      only TRACKED assets count in calcGav.
	function calcAssetGav(address asset) external returns (uint256) {
		uint256 balance = IERC20(asset).balanceOf(address(vault));
		if (balance == 0) return 0;
		return valueInterpreter.calcCanonicalAssetValue(asset, balance, address(denominationAsset));
	}

	/// @notice All tracked assets with their current vault balances.
	/// @dev Port of melon-v1 Accounting.getFundHoldings.
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

	function _calcExternalPositionValue(IExternalPosition position) private returns (uint256) {
		(address[] memory managedAssets, uint256[] memory managedAmounts) = position.getManagedAssets();
		(address[] memory debtAssets, uint256[] memory debtAmounts) = position.getDebtAssets();

		uint256 managed;
		for (uint256 i; i < managedAssets.length; ++i) {
			if (managedAmounts[i] == 0) continue;
			managed +=
				valueInterpreter.calcCanonicalAssetValue(managedAssets[i], managedAmounts[i], address(denominationAsset));
		}

		uint256 debt;
		for (uint256 i; i < debtAssets.length; ++i) {
			if (debtAmounts[i] == 0) continue;
			debt += valueInterpreter.calcCanonicalAssetValue(debtAssets[i], debtAmounts[i], address(denominationAsset));
		}

		// Liability of a position is limited to the position itself.
		return managed > debt ? managed - debt : 0;
	}

	// ─── Trading: callOnIntegration ──────────────────────────────────────────────

	/// @notice Trade fund assets through a protocol-registered adapter.
	/// @dev Successor to melon-v1 Trading.sol via Enzyme v4's IntegrationManager
	///      (spec/architecture/release.md#integrationmanager). Safety model:
	///      - adapter must be on the factory's curated registry (the protocol-level
	///        AllowedAdapters list; per-fund policies can restrict further)
	///      - incoming amounts are measured as VAULT BALANCE DELTAS, never adapter claims
	///      - incoming assets are auto-tracked (no silent residue, Gamma lesson #4)
	///      - PostCallOnIntegration policies (MaxConcentration, CumulativeSlippageTolerance)
	///        run on the measured result
	///      Deliberately NOT gated by pause/shutdown: a winding-down fund must still trade
	///      to unwind into the denomination asset for redemptions.
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

		_runPolicies(
			IPolicy.PolicyHook.PostCallOnIntegration,
			abi.encode(adapter, spendAssets, spendAmounts, incomingAssets, incomingAmounts)
		);

		emit CallOnIntegrationExecuted(adapter, spendAssets, spendAmounts, incomingAssets, incomingAmounts);
	}

	// ─── Shutdown / pause lane ───────────────────────────────────────────────────

	/// @notice Permanently shut the fund down (wind-down): blocks new deposits and new
	///         positions forever. Redemptions stay open. One-way, per melon-v1 Hub.shutDownFund.
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

	/// @notice Emergency lane, callable only through the factory: the guardian pauses
	///         instantly; ONLY the factory owner (governance) can unpause (frosty-core
	///         one-way discipline — halting is instant, loosening is privileged).
	function setGuardianDepositsPaused(bool paused) external {
		if (msg.sender != factory) revert OnlyFactory();
		guardianDepositsPaused = paused;
		emit GuardianDepositsPauseSet(paused);
	}

	// ─── Fees ────────────────────────────────────────────────────────────────────

	/// @notice Settle accrued fees without a deposit/redeem action. Callable by anyone
	///         (melon-v1 Accounting.triggerRewardAllFees successor). Requires valid pricing
	///         for the performance fee, so it reverts while equity feeds are stale — keepers
	///         call it during market hours.
	function settleFees() external nonReentrant returns (uint256 grossSharePrice) {
		grossSharePrice = _settleFeesAndGetSharePrice();
		emit FeesSettled(msg.sender, grossSharePrice);
	}

	/// @dev Settles management then performance fee (order per spec/fee-formulas), then
	///      returns the resulting gross share price used for the current action. Only the
	///      empty-fund bootstrap may price at defaultSharePrice: zero priced GAV with
	///      supply outstanding (fully side-pocketed / wiped fund) REVERTS instead —
	///      minting or value-redeeming at the default price there expropriates existing
	///      holders (security review 2026-09-22, C-2). The in-kind exit stays open.
	function _settleFeesAndGetSharePrice() private returns (uint256 sharePrice) {
		_settleManagementFee();

		uint256 totalSupply = shares.totalSupply();
		if (totalSupply == 0) {
			_settleProtocolFee(); // advances the clock; mints nothing at zero supply
			return defaultSharePrice;
		}

		uint256 gav = calcGav();
		if (gav == 0) revert ZeroGavWithSupply();

		_settlePerformanceFee(gav, totalSupply);
		// After the manager's fees (Enzyme v4 ordering), before pricing the action.
		_settleProtocolFee();
		return Math.mulDiv(gav, SHARES_UNIT, shares.totalSupply());
	}

	/// @dev spec/fee-formulas/managementfee.md:
	///      sharesDue = (rpow(scaledPerSecondRate, dt, 1e27) - 1e27) * totalSupply / 1e27
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

	/// @dev spec/fee-formulas/performance-fee.md (continuous accrual, no crystallization):
	///      g = GAV/TS; W = max(g - hwm, 0)*TS; F = W*rate; feeShares = F*TS/(GAV - F);
	///      hwm' = GAV/TS' when fee paid.
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

	/// @dev Protocol AUM fee (founder decision 2026-09-22, Enzyme v4 ProtocolFeeTracker
	///      port): factory-set bps/yr of share supply, minted to the factory's recipient.
	///      Straight-dilution mint, same convention as the management fee. The rate is
	///      live-read but bounded by the factory's bytecode cap (1%/yr); the clock always
	///      advances, so enabling the fee later never back-charges dormant history.
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

	/// @notice Execution half of the protocol-fee buyback (orchestrated + guarded by the
	///         factory's buyBackProtocolFeeShares, which lives there for EIP-170 room):
	///         burns the reserve's fee shares and destroys the burn asset (FROST) from
	///         the vault. The dead-address destination is hardcoded HERE so the factory
	///         can direct value to nobody — bought-back value accrues pro-rata to ALL
	///         holders via the supply reduction. Enzyme v4 MLN-buyback port.
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

	/// @dev No silent residue (Gamma lesson #4): an asset with a non-zero vault balance is
	///      fund value and cannot be untracked.
	function removeTrackedAsset(address asset) external onlyFundOwner {
		if (asset == address(denominationAsset)) revert CannotRemoveDenominationAsset();
		if (IERC20(asset).balanceOf(address(vault)) != 0) revert NonZeroBalanceRemoval(asset);
		if (trackedAssets.remove(asset)) emit TrackedAssetRemoved(asset);
	}

	/// @notice Deploy and activate an external position of a protocol-registered type
	///         (spec/topics/external-positions.md lifecycle: CreateExternalPosition).
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

	/// @notice Interact with an active external position: optionally move vault assets to it,
	///         then forward the action (spec lifecycle: CallOnExternalPosition).
	/// @param assetsToReceive Assets expected to arrive at the vault from this action —
	///        auto-tracked so returned value is never silent residue.
	/// @dev Policies receive the MEASURED value this call lost — position value plus
	///      vault flows, before vs after — never the stated arrays, which can lie by
	///      omission (security review 2026-09-22, H-1). This makes the call require
	///      pricing (stale feeds block EP management, same market-hours discipline as
	///      deposits). Venue-side losses BETWEEN calls remain the documented
	///      manager-trust boundary of external positions until a GAV-fraction outflow
	///      cap exists.
	function callOnExternalPosition(
		address position,
		address[] calldata assetsToTransfer,
		uint256[] calldata amountsToTransfer,
		address[] calldata assetsToReceive,
		bytes calldata actionData
	) external onlyFundOwner nonReentrant {
		if (!externalPositions.contains(position)) revert NotActiveExternalPosition(position);
		if (assetsToTransfer.length != amountsToTransfer.length) revert ArrayLengthMismatch();

		// A RISK-REDUCING action (the position type vouches it can only move value back toward
		// the fund — e.g. closing a perp) with nothing leaving the vault is not priced: a
		// down or stale oracle must never stop a manager from cutting risk (security review
		// 2026-09-24, H-1). Everything else: value going in (position + transfers) vs value
		// coming out (position + vault receipts).
		bool unpriced = assetsToTransfer.length == 0 && IExternalPosition(position).isRiskReducing(actionData);
		uint256 beforeValue = unpriced
			? 0
			: _calcExternalPositionValue(IExternalPosition(position)) + _assetsValue(assetsToTransfer, amountsToTransfer);
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

	function _assetsValue(address[] calldata assets, uint256[] calldata amounts) private returns (uint256 value) {
		for (uint256 i; i < assets.length; ++i) {
			if (amounts[i] > 0) {
				value += valueInterpreter.calcCanonicalAssetValue(assets[i], amounts[i], address(denominationAsset));
			}
		}
	}

	function _vaultBalances(address[] calldata assets) private view returns (uint256[] memory balances) {
		balances = new uint256[](assets.length);
		for (uint256 i; i < assets.length; ++i) {
			balances[i] = IERC20(assets[i]).balanceOf(address(vault));
		}
	}

	/// @dev Values what the vault actually received (balance deltas) and auto-tracks it;
	///      duplicate entries are skipped — counting one delta twice would hide losses.
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

	/// @notice Deactivate an external position. Only allowed once its value is dust
	///         (≤ 1 denomination unit) — a manager can never hide significant value by
	///         untracking a position (v4 OnlyRemoveDustExternalPositionPolicy, enforced
	///         in-protocol; spec/topics/policies.md).
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

	/// @notice Add a policy. Investor-restricting hooks (share transfers, value redemptions)
	///         can only be configured before the fund has depositors — an immutable guarantee
	///         to investors (spec/architecture/release.md#policymanager).
	/// @dev SET-ONCE like melon: only the factory registers policies — atomically at
	///      creation (createFund-with-ruleset) and when carrying the ruleset across a
	///      reconfiguration. Managers can never add, change, or remove rules after
	///      launch; the ruleset is the fund's permanent public commitment. (Policies
	///      with internal member lists, e.g. the depositor whitelist, still maintain
	///      their own membership — the POLICY SET itself is frozen.)
	function addPolicy(IPolicy.PolicyHook hook, address policy) external {
		if (msg.sender != factory) revert OnlyFactory();
		// A policy may only attach to hooks it implements: stock policies on foreign
		// hooks either brick the action on decode (a set-once redemption rug kit) or
		// silently no-op (security review 2026-09-22, M-3)
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
