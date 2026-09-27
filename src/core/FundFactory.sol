// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {Comptroller} from './Comptroller.sol';
import {Shares} from '../fund/Shares.sol';
import {Vault} from '../fund/Vault.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {IPolicy} from '../interfaces/IPolicy.sol';
import {UnrestrictedMandatePolicy} from '../policies/UnrestrictedMandatePolicy.sol';
import {IProtocolFeeReserve} from '../interfaces/IProtocolFeeReserve.sol';
import {SharesVaultDeployer} from './FundComponentDeployers.sol';
import {IComptrollerDeployer} from '../interfaces/IComptrollerDeployer.sol';

/// @title FundFactory
/// @notice Deploys funds (Comptroller + Vault + Shares) and keeps the canonical registry.
/// @dev Successor to melon-v1 FundFactory (melon-v1/src/factory/FundFactory.sol), shaped by
///      Enzyme v4's FundDeployer (spec/architecture/release.md#funddeployer).
///      Fee/timelock/request-duration bounds are enforced against the Comptroller's
///      bytecode caps here, at creation time.
///      Direct deployments, no proxies. Fix path for a Comptroller bug (where nearly all fund
///      logic lives — Vault and Shares only hold and mint): the owner (the FROST timelock after
///      the governance handoff) points `comptrollerDeployer` at a fixed build, and each fund OWNER
///      opts in through reconfiguration, behind the investor exit window. Nothing reaches a live
///      fund without its owner.
///      SCAFFOLD notes:
///      - Marketplace gating (PermaLocker stake-to-deploy) is a later, separate module —
///        creation stays permissionless at the contract layer.
///      Emergency lane (frosty-core discipline): the `guardian` can pause any fund's
///      deposits INSTANTLY; only the factory owner (governance/timelock later) can unpause.
///      Guardians can never touch redemptions, custody, or configuration.
contract FundFactory is Ownable2Step {
	struct FundConfig {
		string name;
		string symbol;
		IERC20 denominationAsset;
		address fundOwner;
		uint128 mgmtScaledPerSecondRate; // 1e27-scaled; pass 1e27 (or 0) for no management fee
		uint16 perfFeeBps;
		uint64 sharesActionTimelock;
		uint64 minRequestDuration;
		uint64 executionWindow; // matured requests stay executable this long, then expire
		bool allowRiskyAssets; // immutable "degen fund" disclosure (side-pocket assets)
	}

	struct FundInfo {
		address comptroller;
		address vault;
		address shares;
		address fundOwner;
		uint64 createdAt;
	}

	uint256 private constant RATE_SCALE = 1e27;
	uint256 private constant SHARES_UNIT = 1e18;

	/// @dev Investor exit window between signaling and executing a reconfiguration —
	///      config changes (e.g., fee raises) can never ambush depositors.
	uint256 public constant RECONFIGURATION_TIMELOCK = 2 days;

	/// @notice Bytecode cap on the protocol AUM fee: governance can never set more than
	///         1%/yr (Enzyme launched at 25 bps — same order of magnitude, hard-bounded).
	uint256 public constant MAX_PROTOCOL_FEE_BPS = 100;

	struct ReconfigurationRequest {
		address newComptroller;
		uint64 executableAt;
	}

	mapping(address oldComptroller => ReconfigurationRequest) public reconfigurationRequests;

	/// @dev Policy fix path. A policy contract is one fund's rule with its settings baked in; a
	///      bug in it would otherwise live in that fund forever (rulesets are set-once and carry
	///      over verbatim). Governance approves `replacement` = the fixed contract deployed with the
	///      SAME settings (it verifies that before approving); a fund OWNER opts in per
	///      reconfiguration, behind the investor exit window. Managers still can't drop or loosen
	///      a rule: only an approved one-for-one replacement is possible.
	struct PolicySwap {
		address from;
		address to;
	}

	mapping(address policy => address replacement) public policyReplacements;
	mapping(address oldComptroller => PolicySwap[]) internal requestedPolicySwaps;

	IValueInterpreter public immutable valueInterpreter;
	/// @dev Creation bytecode outsourced to stay under EIP-170 (see FundComponentDeployers).
	/// @dev Settable (not immutable) so a fixed Comptroller build can ship: it only affects NEW
	///      funds and reconfiguration requests created after the change — a request already in its
	///      exit window keeps the Comptroller its owner reviewed.
	IComptrollerDeployer public comptrollerDeployer;
	SharesVaultDeployer public immutable sharesVaultDeployer;
	/// @notice The protocol-wide "may hold anything" declaration — attached whenever a
	///         fund is created without an explicit mandate (every fund carries one).
	address public immutable unrestrictedMandate;
	address public guardian;

	/// @dev Protocol AUM fee, live-read by every Comptroller at fee settlement. Ships
	///      disabled (0 / zero-recipient). The recipient may be a plain treasury or a
	///      ProtocolFeeReserve (which additionally enables the FROST-burn buyback).
	uint16 public protocolFeeBps;
	address public protocolFeeRecipient;

	/// @dev Protocol-curated adapter allowlist (Enzyme v4 "council list" pattern): funds can
	///      only trade through adapters vetted here. Owner = governance/timelock later.
	mapping(address adapter => bool) public isAdapterRegistered;

	/// @dev Protocol-curated external-position type registry: typeId → per-type deployer
	///      (e.g., 1 = HyperliquidPerpPositionFactory). Same trust model as adapters.
	mapping(uint256 typeId => address) public positionTypeFactories;

	address[] public fundsList;
	mapping(address comptroller => FundInfo) public funds;

	/// @dev Fund-name uniqueness (melon-v1 Registry.reserveFundName): blocks marketplace
	///      impersonation by name collision. Names are reserved forever, even past shutdown.
	mapping(bytes32 nameHash => bool) public isFundNameTaken;

	/// @dev Protocol-level policies EVERY new fund carries on top of its own ruleset (e.g. the
	///      TwapExposurePolicy — the TWAP price tier's caps are not a manager's choice). Changing
	///      the list affects new funds and reconfigurations only; existing rulesets are set-once.
	PolicyReg[] internal mandatoryPolicies;

	event FundCreated(
		address indexed fundOwner,
		address indexed comptroller,
		address vault,
		address shares,
		string name,
		string symbol
	);

	event GuardianSet(address indexed guardian);
	event ComptrollerDeployerSet(address indexed deployer);
	event ProtocolFeeSet(uint16 feeBps, address indexed recipient);
	event ReconfigurationRequested(address indexed oldComptroller, address indexed newComptroller, uint64 executableAt);
	event ReconfigurationCancelled(address indexed oldComptroller);
	event FundReconfigured(address indexed oldComptroller, address indexed newComptroller);
	event AdapterRegistered(address indexed adapter);
	event AdapterDeregistered(address indexed adapter);
	event PositionTypeRegistered(uint256 indexed typeId, address indexed typeFactory);
	event PositionTypeDeregistered(uint256 indexed typeId);
	event FundDepositsPausedByGuardian(address indexed comptroller);
	event FundDepositsUnpausedByOwner(address indexed comptroller);
	event MandatoryPolicySet(uint256 indexed index, IPolicy.PolicyHook hook, address indexed policy);
	event PolicyReplacementSet(address indexed policy, address indexed replacement);
	event PolicySwapRequested(address indexed oldComptroller, address indexed from, address indexed to);

	error ZeroAddress();
	error PerfFeeAboveMax();
	error MgmtFeeAboveMax();
	error TimelockAboveMax();
	error RequestDurationOutOfBounds();
	error OnlyGuardian();
	error UnknownFund(address comptroller);
	error OnlyFundOwner();
	error DenominationAssetMismatch();
	error FundOwnerMismatch();
	error ExternalPositionsStillActive();
	error NoReconfigurationRequest();
	error ReconfigurationTimelocked(uint64 executableAt);
	error ReconfigurationRequestExists();
	error FundSuspended();
	error ExecutionWindowOutOfBounds();
	error FundNameTaken(string name);
	error ProtocolFeeAboveMax();
	error ProtocolFeeRecipientZero();
	error ZeroBuyBack();
	error InvalidPolicyReplacement();
	error ReplacementHookMismatch(address policy, address replacement);
	error PolicyReplacementNotApproved(address policy);
	error PolicyNotAttached(address policy);
	error DuplicatePolicySwap(address policy);
	error PolicyReplacementChanged(address policy);

	constructor(
		IValueInterpreter valueInterpreter_,
		IComptrollerDeployer comptrollerDeployer_,
		SharesVaultDeployer sharesVaultDeployer_
	) Ownable(msg.sender) {
		if (
			address(valueInterpreter_) == address(0) || address(comptrollerDeployer_) == address(0)
				|| address(sharesVaultDeployer_) == address(0)
		) revert ZeroAddress();
		valueInterpreter = valueInterpreter_;
		comptrollerDeployer = comptrollerDeployer_;
		sharesVaultDeployer = sharesVaultDeployer_;
		unrestrictedMandate = address(new UnrestrictedMandatePolicy());
	}

	// ─── Adapter registry ────────────────────────────────────────────────────────

	function registerAdapter(address adapter) external onlyOwner {
		if (adapter == address(0)) revert ZeroAddress();
		isAdapterRegistered[adapter] = true;
		emit AdapterRegistered(adapter);
	}

	/// @dev Deregistration is also a guardian-grade emergency action: a compromised venue
	///      adapter must be removable instantly.
	function deregisterAdapter(address adapter) external {
		if (msg.sender != owner() && msg.sender != guardian) revert OnlyGuardian();
		isAdapterRegistered[adapter] = false;
		emit AdapterDeregistered(adapter);
	}

	// ─── External position type registry ────────────────────────────────────────

	function registerPositionType(uint256 typeId, address typeFactory) external onlyOwner {
		if (typeFactory == address(0)) revert ZeroAddress();
		positionTypeFactories[typeId] = typeFactory;
		emit PositionTypeRegistered(typeId, typeFactory);
	}

	/// @dev Like adapter deregistration, killing a compromised position type is an
	///      emergency action — guardian may do it instantly.
	function deregisterPositionType(uint256 typeId) external {
		if (msg.sender != owner() && msg.sender != guardian) revert OnlyGuardian();
		delete positionTypeFactories[typeId];
		emit PositionTypeDeregistered(typeId);
	}

	// ─── Protocol fee ────────────────────────────────────────────────────────────

	/// @notice Set the protocol AUM fee: bps/yr of every fund's share supply, minted to
	///         `recipient` at each fund's fee settlements. Hard-capped in bytecode so
	///         governance can never rug funds past MAX_PROTOCOL_FEE_BPS. Passing 0 with
	///         a zero recipient disables the fee entirely.
	function setProtocolFee(uint16 feeBps, address recipient) external onlyOwner {
		if (feeBps > MAX_PROTOCOL_FEE_BPS) revert ProtocolFeeAboveMax();
		if (feeBps > 0 && recipient == address(0)) revert ProtocolFeeRecipientZero();
		protocolFeeBps = feeBps;
		protocolFeeRecipient = recipient;
		emit ProtocolFeeSet(feeBps, recipient);
	}

	/// @notice The Comptrollers' single read point (IProtocolFeeConfig).
	function getProtocolFeeConfig() external view returns (uint256 feeBps, address recipient) {
		return (protocolFeeBps, protocolFeeRecipient);
	}

	/// @notice Buy back a fund's protocol-fee shares from the ProtocolFeeReserve at its
	///         discount (50%), paying in the reserve's burn asset (FROST) from the fund's
	///         vault. Fund-owner only: the shares are burned and the FROST destroyed, so
	///         the fund reclaims full value for half its cost — Enzyme v4's MLN buyback.
	/// @dev Lives here (not in the Comptroller) purely for EIP-170 room; the Comptroller's
	///      executeProtocolFeeBuyBack hardcodes the dead-address destination, so this
	///      orchestration can never redirect assets. Reverts unless the current recipient
	///      implements IProtocolFeeReserve (a plain treasury never consents), the burn
	///      asset is priced in the ValueInterpreter, and the vault holds enough of it.
	function buyBackProtocolFeeShares(address comptroller, uint256 sharesAmount) external {
		FundInfo memory info = funds[comptroller];
		if (info.comptroller == address(0)) revert UnknownFund(comptroller);
		if (msg.sender != info.fundOwner) revert OnlyFundOwner();
		if (sharesAmount == 0) revert ZeroBuyBack();

		// Settles ALL fees (incl. protocol) and returns the fully settled gross share price.
		uint256 sharePrice = Comptroller(comptroller).settleFees();
		uint256 shareValue = Math.mulDiv(sharesAmount, sharePrice, SHARES_UNIT);

		address recipient = protocolFeeRecipient;
		address burnAsset = IProtocolFeeReserve(recipient).burnAsset();
		uint256 burnAssetValue = valueInterpreter.calcCanonicalAssetValue(
			address(Comptroller(comptroller).denominationAsset()), shareValue, burnAsset
		);

		uint256 amountToBurn = IProtocolFeeReserve(recipient).buyBackShares(sharesAmount, burnAssetValue);
		// The reserve prices a DISCOUNT: never accept a burn above the shares' market value.
		if (amountToBurn == 0 || amountToBurn > burnAssetValue) revert ZeroBuyBack();

		Comptroller(comptroller).executeProtocolFeeBuyBack(recipient, burnAsset, sharesAmount, amountToBurn);
	}

	// ─── Comptroller fix path ────────────────────────────────────────────────────

	/// @notice Point new funds and new reconfiguration requests at another Comptroller build
	///         (a ComptrollerBlueprintDeployer carrying the fix). Existing funds are untouched
	///         until their owner reconfigures; a request already in its window is unaffected.
	function setComptrollerDeployer(IComptrollerDeployer deployer) external onlyOwner {
		if (address(deployer) == address(0)) revert ZeroAddress();
		comptrollerDeployer = deployer;
		emit ComptrollerDeployerSet(address(deployer));
	}

	// ─── Policy fix path ─────────────────────────────────────────────────────────

	/// @notice Approve `replacement` — the fixed policy, deployed with the SAME settings — for
	///         `policy`. It must implement every hook `policy` does, so a fund's rule can never
	///         silently fall off a hook. Funds adopt it only through an owner's reconfiguration.
	function setPolicyReplacement(address policy, address replacement) external onlyOwner {
		if (policy == address(0) || replacement == address(0) || replacement == policy) revert InvalidPolicyReplacement();
		IPolicy.PolicyHook[] memory needed = IPolicy(policy).implementedHooks();
		IPolicy.PolicyHook[] memory offered = IPolicy(replacement).implementedHooks();
		for (uint256 i; i < needed.length; ++i) {
			bool found;
			for (uint256 j; j < offered.length; ++j) {
				if (offered[j] == needed[i]) {
					found = true;
					break;
				}
			}
			if (!found) revert ReplacementHookMismatch(policy, replacement);
		}
		policyReplacements[policy] = replacement;
		emit PolicyReplacementSet(policy, replacement);
	}

	/// @notice Withdraw an approval. A tightening, so the guardian may do it instantly too; a
	///         request relying on it can then no longer execute.
	function revokePolicyReplacement(address policy) external {
		if (msg.sender != owner() && msg.sender != guardian) revert OnlyGuardian();
		delete policyReplacements[policy];
		emit PolicyReplacementSet(policy, address(0));
	}

	// ─── Guardian lane ───────────────────────────────────────────────────────────

	function setGuardian(address guardian_) external onlyOwner {
		if (guardian_ == address(0)) revert ZeroAddress();
		guardian = guardian_;
		emit GuardianSet(guardian_);
	}

	/// @notice Instant emergency halt of a fund's deposits. Reduction-only power.
	function pauseFundDeposits(address comptroller) external {
		if (msg.sender != guardian) revert OnlyGuardian();
		if (funds[comptroller].comptroller == address(0)) revert UnknownFund(comptroller);
		Comptroller(comptroller).setGuardianDepositsPaused(true);
		emit FundDepositsPausedByGuardian(comptroller);
	}

	/// @notice The loosening path: only the factory owner (governance) re-enables.
	function unpauseFundDeposits(address comptroller) external onlyOwner {
		if (funds[comptroller].comptroller == address(0)) revert UnknownFund(comptroller);
		Comptroller(comptroller).setGuardianDepositsPaused(false);
		emit FundDepositsUnpausedByOwner(comptroller);
	}

	struct PolicyReg {
		IPolicy.PolicyHook hook;
		address policy;
	}

	/// @notice Live name-availability check for setup UIs (melon Registry.canUseFundName
	///         analog). The mapping getter takes the hash; this takes the name.
	function fundNameTaken(string calldata name) external view returns (bool) {
		return isFundNameTaken[keccak256(bytes(name))];
	}

	/// @notice Create a fund that is BORN with its ruleset — SET-ONCE, like melon: the
	///         policies (the fund's on-chain investment mandate — bytecode, not a PPM)
	///         register atomically with creation and can never be changed after. Every
	///         fund MUST carry a mandate-hook policy; declining restriction is itself a
	///         public declaration (the protocol-wide UnrestrictedMandatePolicy attaches
	///         when no PostCallOnIntegration policy is supplied).
	function createFund(FundConfig calldata config, PolicyReg[] calldata policies)
		external
		returns (address comptrollerAddress)
	{
		comptrollerAddress = _createFund(config);
		bool hasMandate;
		for (uint256 i; i < policies.length; ++i) {
			if (policies[i].policy == address(0)) revert ZeroAddress();
			if (policies[i].hook == IPolicy.PolicyHook.PostCallOnIntegration) hasMandate = true;
			Comptroller(comptrollerAddress).addPolicy(policies[i].hook, policies[i].policy);
		}
		if (!hasMandate) {
			Comptroller(comptrollerAddress).addPolicy(
				IPolicy.PolicyHook.PostCallOnIntegration, unrestrictedMandate
			);
		}
		_attachMandatoryPolicies(Comptroller(comptrollerAddress));
	}

	function createFund(FundConfig calldata config) external returns (address comptrollerAddress) {
		comptrollerAddress = _createFund(config);
		// No ruleset supplied → the fund still carries its declaration on-chain
		Comptroller(comptrollerAddress).addPolicy(IPolicy.PolicyHook.PostCallOnIntegration, unrestrictedMandate);
		_attachMandatoryPolicies(Comptroller(comptrollerAddress));
	}

	/// @notice Replace the protocol's mandatory-policy list (new funds + reconfigurations).
	function setMandatoryPolicies(PolicyReg[] calldata policies) external onlyOwner {
		delete mandatoryPolicies;
		for (uint256 i; i < policies.length; ++i) {
			if (policies[i].policy == address(0)) revert ZeroAddress();
			mandatoryPolicies.push(policies[i]);
			emit MandatoryPolicySet(i, policies[i].hook, policies[i].policy);
		}
	}

	function getMandatoryPolicies() external view returns (PolicyReg[] memory) {
		return mandatoryPolicies;
	}

	/// @dev Attach every mandatory policy the fund does not already carry on that hook (a
	///      manager may have included one in their own ruleset; no double runs).
	function _attachMandatoryPolicies(Comptroller comptroller) private {
		for (uint256 i; i < mandatoryPolicies.length; ++i) {
			PolicyReg memory reg = mandatoryPolicies[i];
			// a mandatory policy with an approved fix is satisfied by either, and a fund that
			// has neither gets the fix — the buggy original is never re-attached
			address replacement = policyReplacements[reg.policy];
			address[] memory existing = comptroller.getPolicies(reg.hook);
			bool present;
			for (uint256 j; j < existing.length; ++j) {
				if (existing[j] == reg.policy || (replacement != address(0) && existing[j] == replacement)) {
					present = true;
					break;
				}
			}
			if (!present) comptroller.addPolicy(reg.hook, replacement != address(0) ? replacement : reg.policy);
		}
	}

	function _createFund(FundConfig calldata config) private returns (address comptrollerAddress) {
		if (address(config.denominationAsset) == address(0) || config.fundOwner == address(0)) revert ZeroAddress();

		bytes32 nameHash = keccak256(bytes(config.name));
		if (isFundNameTaken[nameHash]) revert FundNameTaken(config.name);
		isFundNameTaken[nameHash] = true;

		Comptroller comptroller = _deployComptroller(config);
		(Shares shares, Vault vault) = sharesVaultDeployer.deploy(config.name, config.symbol, address(comptroller));
		comptroller.initialize(shares, vault);

		comptrollerAddress = address(comptroller);
		funds[comptrollerAddress] = FundInfo({
			comptroller: comptrollerAddress,
			vault: address(vault),
			shares: address(shares),
			fundOwner: config.fundOwner,
			createdAt: uint64(block.timestamp)
		});
		fundsList.push(comptrollerAddress);

		emit FundCreated(
			config.fundOwner, comptrollerAddress, address(vault), address(shares), config.name, config.symbol
		);
	}

	/// @dev Deploys a Comptroller and enforces its bytecode caps against the config.
	function _deployComptroller(FundConfig calldata config) private returns (Comptroller comptroller) {
		uint256 mgmtRate = config.mgmtScaledPerSecondRate == 0 ? RATE_SCALE : config.mgmtScaledPerSecondRate;

		comptroller = comptrollerDeployer.deploy(
			config.fundOwner,
			config.denominationAsset,
			valueInterpreter,
			Comptroller.FeeConfig({mgmtScaledPerSecondRate: uint128(mgmtRate), perfFeeBps: config.perfFeeBps}),
			config.sharesActionTimelock,
			config.minRequestDuration,
			config.executionWindow,
			config.allowRiskyAssets
		);

		if (config.perfFeeBps > comptroller.MAX_PERF_FEE_BPS()) revert PerfFeeAboveMax();
		if (mgmtRate > comptroller.MAX_MGMT_SCALED_PER_SECOND_RATE()) revert MgmtFeeAboveMax();
		if (config.sharesActionTimelock > comptroller.MAX_SHARES_ACTION_TIMELOCK()) revert TimelockAboveMax();
		if (
			config.minRequestDuration < comptroller.MIN_REQUEST_DURATION_FLOOR()
				|| config.minRequestDuration > comptroller.MAX_REQUEST_DURATION()
		) revert RequestDurationOutOfBounds();
		// expiry = maturity + window, so any bounded window gives a non-empty
		// execution window (supersedes the old TTL check / review M-6)
		if (
			config.executionWindow < comptroller.MIN_EXECUTION_WINDOW()
				|| config.executionWindow > comptroller.MAX_EXECUTION_WINDOW()
		) revert ExecutionWindowOutOfBounds();
	}

	// ─── Reconfiguration (spec/topics/creation-migration-reconfiguration.md) ─────
	// Swap a fund's Comptroller (config/fees/logic) while keeping its Vault, Shares,
	// holders, and HWM. Signal → 2-day investor exit window → execute.

	function createReconfigurationRequest(address oldComptroller, FundConfig calldata config)
		external
		returns (address newComptroller)
	{
		return _createReconfigurationRequest(oldComptroller, config, new address[](0));
	}

	/// @notice Same, opting into governance-approved replacements for `policiesToReplace`. The
	///         pairs are fixed now, so investors see exactly which rules change during the window.
	function createReconfigurationRequest(
		address oldComptroller,
		FundConfig calldata config,
		address[] calldata policiesToReplace
	) external returns (address newComptroller) {
		return _createReconfigurationRequest(oldComptroller, config, policiesToReplace);
	}

	function _createReconfigurationRequest(
		address oldComptroller,
		FundConfig calldata config,
		address[] memory policiesToReplace
	) private returns (address newComptroller) {
		FundInfo memory info = funds[oldComptroller];
		if (info.comptroller == address(0)) revert UnknownFund(oldComptroller);
		if (msg.sender != info.fundOwner) revert OnlyFundOwner();
		if (config.fundOwner != info.fundOwner) revert FundOwnerMismatch();
		if (address(config.denominationAsset) != address(Comptroller(oldComptroller).denominationAsset())) {
			revert DenominationAssetMismatch();
		}
		if (reconfigurationRequests[oldComptroller].newComptroller != address(0)) {
			revert ReconfigurationRequestExists();
		}
		// A shut-down fund cannot reconfigure its way back to life (review M-1). A guardian-
		// paused one CAN — that is the bug-fix path (pause first, then move onto the fixed
		// build) — and the pause carries over to the new Comptroller, so it still can't escape.
		if (Comptroller(oldComptroller).shutDown()) revert FundSuspended();

		newComptroller = address(_deployComptroller(config));
		// The exit window must actually be usable: recent depositors are locked for up
		// to sharesActionTimelock, so the window is at least that long (review M-2)
		uint256 window = RECONFIGURATION_TIMELOCK;
		uint256 holderTimelock = Comptroller(oldComptroller).sharesActionTimelock();
		if (holderTimelock > window) window = holderTimelock;
		uint64 executableAt = uint64(block.timestamp + window);
		reconfigurationRequests[oldComptroller] =
			ReconfigurationRequest({newComptroller: newComptroller, executableAt: executableAt});
		_recordPolicySwaps(Comptroller(oldComptroller), policiesToReplace);

		emit ReconfigurationRequested(oldComptroller, newComptroller, executableAt);
	}

	function _recordPolicySwaps(Comptroller old, address[] memory policiesToReplace) private {
		PolicySwap[] storage swaps = requestedPolicySwaps[address(old)];
		for (uint256 i; i < policiesToReplace.length; ++i) {
			address from = policiesToReplace[i];
			address to = policyReplacements[from];
			if (to == address(0)) revert PolicyReplacementNotApproved(from);
			if (!_hasPolicy(old, from)) revert PolicyNotAttached(from);
			for (uint256 j; j < swaps.length; ++j) {
				if (swaps[j].from == from) revert DuplicatePolicySwap(from);
			}
			swaps.push(PolicySwap({from: from, to: to}));
			emit PolicySwapRequested(address(old), from, to);
		}
	}

	function _hasPolicy(Comptroller comptroller, address policy) private view returns (bool) {
		for (uint8 h; h <= uint8(IPolicy.PolicyHook.RemoveExternalPosition); ++h) {
			address[] memory hookPolicies = comptroller.getPolicies(IPolicy.PolicyHook(h));
			for (uint256 i; i < hookPolicies.length; ++i) {
				if (hookPolicies[i] == policy) return true;
			}
		}
		return false;
	}

	function getRequestedPolicySwaps(address oldComptroller) external view returns (PolicySwap[] memory) {
		return requestedPolicySwaps[oldComptroller];
	}

	function cancelReconfigurationRequest(address oldComptroller) external {
		if (msg.sender != funds[oldComptroller].fundOwner) revert OnlyFundOwner();
		if (reconfigurationRequests[oldComptroller].newComptroller == address(0)) revert NoReconfigurationRequest();
		delete reconfigurationRequests[oldComptroller];
		delete requestedPolicySwaps[oldComptroller];
		emit ReconfigurationCancelled(oldComptroller);
	}

	function executeReconfiguration(address oldComptroller) external {
		FundInfo memory info = funds[oldComptroller];
		if (msg.sender != info.fundOwner) revert OnlyFundOwner();

		ReconfigurationRequest memory request = reconfigurationRequests[oldComptroller];
		if (request.newComptroller == address(0)) revert NoReconfigurationRequest();
		if (block.timestamp < request.executableAt) revert ReconfigurationTimelocked(request.executableAt);

		Comptroller old = Comptroller(oldComptroller);
		// Re-check at execution — a shutdown DURING the window binds (M-1); a guardian pause
		// during it carries over below
		if (old.shutDown()) revert FundSuspended();
		bool guardianPaused = old.guardianDepositsPaused();
		// External positions hold an immutable Comptroller reference — wind them down first.
		if (old.getExternalPositions().length != 0) revert ExternalPositionsStillActive();

		// Settle fees at the handover point (old rates apply up to this moment; requires
		// valid pricing, so reconfigurations execute during market hours — by design).
		old.settleFees();

		Shares shares = old.shares();
		Vault vault = old.vault();
		shares.migrateComptroller(request.newComptroller);
		vault.migrateComptroller(request.newComptroller);
		Comptroller(request.newComptroller).initializeForMigration(shares, vault, old);

		// The ruleset is SET-ONCE for the FUND, not the comptroller: reconfiguration
		// changes terms, never the mandate — every policy carries over verbatim (bar an
		// owner-requested, governance-approved fix), and any protocol-mandatory policy the
		// fund predates is added (a tightening only).
		_carryPolicies(old, Comptroller(request.newComptroller));
		_attachMandatoryPolicies(Comptroller(request.newComptroller));
		// The pause survives the swap: only the owner (governance) re-enables deposits (M-1)
		if (guardianPaused) Comptroller(request.newComptroller).setGuardianDepositsPaused(true);

		// The old Comptroller is dead for deposits forever (escrow cancellation still works).
		old.setGuardianDepositsPaused(true);

		delete funds[oldComptroller];
		delete reconfigurationRequests[oldComptroller];
		funds[request.newComptroller] = FundInfo({
			comptroller: request.newComptroller,
			vault: address(vault),
			shares: address(shares),
			fundOwner: info.fundOwner,
			createdAt: info.createdAt
		});
		fundsList.push(request.newComptroller);

		emit FundReconfigured(oldComptroller, request.newComptroller);
	}

	/// @dev Each requested swap must still be approved for EXACTLY the contract recorded at
	///      request time — a revocation, or a different replacement approved mid-window, blocks
	///      execution (the owner cancels and re-requests, opening a fresh window).
	function _carryPolicies(Comptroller old, Comptroller fresh) private {
		PolicySwap[] memory swaps = requestedPolicySwaps[address(old)];
		for (uint256 s; s < swaps.length; ++s) {
			if (policyReplacements[swaps[s].from] != swaps[s].to) revert PolicyReplacementChanged(swaps[s].from);
		}
		for (uint8 h; h <= uint8(IPolicy.PolicyHook.RemoveExternalPosition); ++h) {
			address[] memory hookPolicies = old.getPolicies(IPolicy.PolicyHook(h));
			for (uint256 i; i < hookPolicies.length; ++i) {
				fresh.addPolicy(IPolicy.PolicyHook(h), _swapped(hookPolicies[i], swaps));
			}
		}
		delete requestedPolicySwaps[address(old)];
	}

	function _swapped(address policy, PolicySwap[] memory swaps) private pure returns (address) {
		for (uint256 s; s < swaps.length; ++s) {
			if (swaps[s].from == policy) return swaps[s].to;
		}
		return policy;
	}

	function fundsCount() external view returns (uint256) {
		return fundsList.length;
	}
}
