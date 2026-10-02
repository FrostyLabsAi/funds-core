// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Strings} from '@openzeppelin/contracts/utils/Strings.sol';
import {IUniswapV3PoolFactory, ISlipstreamPoolFactory} from '../pricing/TwapListingRegistry.sol';
import {FeeCompounderBase, ICompounderRoles} from './FeeCompounderBase.sol';
import {
	CompounderDeployerBase,
	UniswapV3CompounderDeployer,
	SlipstreamCompounderDeployer
} from './CompounderDeployers.sol';

/// @dev A position manager's pool factory (Uniswap v3 and Slipstream alike).
interface IPositionManagerFactory {
	function factory() external view returns (address);
}

/// @title CompounderFactory
/// @notice Creates one fee-compounding vault per canonical pool on Uniswap v3 and Aerodrome's three
///         Slipstream deployments, owns every vault, and holds the two roles the vaults rely on:
///         - `creators` (the funds-keeper wallet) may `create`, so every vault branded "Frosty
///           Compounding …" is one we chose; listing it in the ValueInterpreter (keeper-only, in
///           the PriceListingModule) remains the gate for funds;
///         - `compounders` (the FrostyFi workflow wallet) may call each vault's `compound()`: the
///           factory is every vault's ICompounderRoles.
///         Each wallet gets only its own job. The owner (governance) sets both roles, the default
///         perf fee for new vaults (5–30%, starting at 10%), each vault's fee, and the treasury
///         (the FrostyDAO Treasury Safe at deploy), and sweeps untracked tokens to the treasury.
/// @dev The vaults' creation code lives in two deployers this constructor creates, each answering
///      only this factory. Every position manager is checked at construction to mint into the
///      pool factory listed beside it, so the pool resolved here is the one the vault resolves.
///      Venue indices match TwapListingRegistryV2.Venue's first four.
contract CompounderFactory is ICompounderRoles, Ownable2Step {
	/// @dev Append-only: the indices are emitted.
	enum Venue {
		UniswapV3,
		Slipstream,
		Slipstream2,
		Slipstream3
	}

	/// @notice Each venue's pool factory and position manager. All are required except Slipstream-3's
	///         position manager: zero leaves that venue unsupported (its pool factory is then unused).
	struct Venues {
		address uniswapV3Factory;
		address uniswapV3Npm;
		address slipstreamFactory;
		address slipstreamNpm;
		address slipstream2Factory;
		address slipstream2Npm;
		address slipstream3Factory;
		address slipstream3Npm;
	}

	/// @notice The FrostyDAO Treasury Safe (Base): the treasury every vault starts with.
	address public constant DAO_TREASURY = 0x47b7702a4789912d0dfFDadC07c50395c293fF0A;
	uint16 public constant INITIAL_PERF_FEE_BPS = 1000;
	/// @notice The vaults' own fee bounds (FeeCompounderBase.MIN/MAX_PERF_FEE_BPS), for the default.
	uint16 public constant MIN_PERF_FEE_BPS = 500;
	uint16 public constant MAX_PERF_FEE_BPS = 3000;

	address public immutable uniswapV3Factory;
	address public immutable uniswapV3Npm;
	address public immutable slipstreamFactory;
	address public immutable slipstreamNpm;
	address public immutable slipstream2Factory;
	address public immutable slipstream2Npm;
	address public immutable slipstream3Factory;
	address public immutable slipstream3Npm;
	UniswapV3CompounderDeployer public immutable uniswapV3Deployer;
	SlipstreamCompounderDeployer public immutable slipstreamDeployer;

	/// @notice The perf fee new vaults start with.
	uint16 public defaultPerfFeeBps;
	/// @notice Where every vault's perf fee and every sweep go; pushed to existing vaults by `syncTreasury`.
	address public treasury;
	/// @notice Who may `create` vaults.
	mapping(address => bool) public creators;
	/// @notice Who may call any vault's `compound()` (ICompounderRoles).
	mapping(address => bool) public compounders;
	/// @notice The vault of a canonical pool; 0 if none.
	mapping(address => address) public compounderOf;
	/// @notice True for every vault this factory created.
	mapping(address => bool) public isCompounder;
	address[] internal vaults;

	event CreatorSet(address indexed account, bool allowed);
	event CompounderSet(address indexed account, bool allowed);
	event DefaultPerfFeeSet(uint16 bps);
	event TreasurySet(address treasury);
	event CompounderCreated(address indexed pool, address indexed vault, Venue venue);

	error ZeroAddress();
	error NotCreator();
	error VenueNotSupported(Venue venue);
	error PoolNotFound();
	error AlreadyExists(address pool, address vault);
	error UnknownVault(address vault);
	error PerfFeeOutOfBounds(uint16 bps);
	error NpmFactoryMismatch(address npm);

	constructor(Venues memory v) Ownable(msg.sender) {
		_checkVenue(v.uniswapV3Factory, v.uniswapV3Npm, true);
		_checkVenue(v.slipstreamFactory, v.slipstreamNpm, true);
		_checkVenue(v.slipstream2Factory, v.slipstream2Npm, true);
		_checkVenue(v.slipstream3Factory, v.slipstream3Npm, false);
		uniswapV3Factory = v.uniswapV3Factory;
		uniswapV3Npm = v.uniswapV3Npm;
		slipstreamFactory = v.slipstreamFactory;
		slipstreamNpm = v.slipstreamNpm;
		slipstream2Factory = v.slipstream2Factory;
		slipstream2Npm = v.slipstream2Npm;
		slipstream3Factory = v.slipstream3Factory;
		slipstream3Npm = v.slipstream3Npm;
		uniswapV3Deployer = new UniswapV3CompounderDeployer();
		slipstreamDeployer = new SlipstreamCompounderDeployer();
		defaultPerfFeeBps = INITIAL_PERF_FEE_BPS;
		treasury = DAO_TREASURY;
	}

	// ─── roles (owner) ──────────────────────────────────────────────────────────

	function setCreator(address account, bool allowed) external onlyOwner {
		if (account == address(0)) revert ZeroAddress();
		creators[account] = allowed;
		emit CreatorSet(account, allowed);
	}

	function setCompounder(address account, bool allowed) external onlyOwner {
		if (account == address(0)) revert ZeroAddress();
		compounders[account] = allowed;
		emit CompounderSet(account, allowed);
	}

	// ─── create (creators) ──────────────────────────────────────────────────────

	/// @notice Create the vault of the canonical pool of `tokenA`/`tokenB` (either order) on `venue`:
	///         `feeOrTickSpacing` is the Uniswap v3 fee tier or the Slipstream tick spacing.
	///         Named "Frosty Compounding <SYM0>-<SYM1>" / "fc<SYM0><SYM1>", owned by this factory,
	///         at the default perf fee and the current treasury.
	function create(Venue venue, address tokenA, address tokenB, int24 feeOrTickSpacing)
		external
		returns (address vault)
	{
		if (!creators[msg.sender]) revert NotCreator();
		(address poolFactory, address npm) = _venue(venue);
		if (npm == address(0)) revert VenueNotSupported(venue);
		(address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
		address pool = _getPool(venue, poolFactory, token0, token1, feeOrTickSpacing);
		if (pool == address(0)) revert PoolNotFound();
		if (compounderOf[pool] != address(0)) revert AlreadyExists(pool, compounderOf[pool]);

		string memory symbol0 = _symbolOf(token0);
		string memory symbol1 = _symbolOf(token1);
		CompounderDeployerBase.VaultParams memory p = CompounderDeployerBase.VaultParams({
			name: string.concat('Frosty Compounding ', symbol0, '-', symbol1),
			symbol: string.concat('fc', symbol0, symbol1),
			positionManager: npm,
			token0: token0,
			token1: token1,
			feeOrTickSpacing: feeOrTickSpacing,
			perfFeeBps: defaultPerfFeeBps,
			treasury: treasury
		});
		// The vault's constructor calls only the position manager, its pool factory and the two
		// tokens' approve. A token calling back finds every state change here role-gated except
		// syncTreasury, which only writes the owner's treasury to vaults already recorded.
		vault = venue == Venue.UniswapV3 ? uniswapV3Deployer.deploy(p) : slipstreamDeployer.deploy(p);

		compounderOf[pool] = vault;
		isCompounder[vault] = true;
		vaults.push(vault);
		emit CompounderCreated(pool, vault, venue);
	}

	// ─── vault controls (owner) ─────────────────────────────────────────────────

	/// @notice The perf fee vaults created from now on start with, within the vaults' 5–30% bounds.
	function setDefaultPerfFee(uint16 bps) external onlyOwner {
		if (bps < MIN_PERF_FEE_BPS || bps > MAX_PERF_FEE_BPS) revert PerfFeeOutOfBounds(bps);
		defaultPerfFeeBps = bps;
		emit DefaultPerfFeeSet(bps);
	}

	/// @notice Set one vault's perf fee; the vault enforces 5–30% and harvests at the old rate first.
	function setPerfFee(address vault, uint16 bps) external onlyOwner {
		_requireCompounder(vault);
		FeeCompounderBase(vault).setPerfFee(bps);
	}

	/// @notice Set the treasury for new vaults and sweeps. Existing vaults follow through
	///         `syncTreasury`, in pages so no vault count can exceed a block's gas.
	function setTreasury(address newTreasury) external onlyOwner {
		if (newTreasury == address(0)) revert ZeroAddress();
		treasury = newTreasury;
		emit TreasurySet(newTreasury);
	}

	/// @notice Push the treasury to vaults [offset, offset + limit), clipped to the vault count;
	///         vaults already on it are skipped. Anyone may call: it can only write the treasury the
	///         owner set, so a keeper can page through without a governance round per page.
	/// @return next the offset of the next page (the vault count once done)
	function syncTreasury(uint256 offset, uint256 limit) external returns (uint256 next) {
		next = _pageEnd(offset, limit);
		address current = treasury;
		for (uint256 i = offset; i < next; ++i) {
			FeeCompounderBase vault = FeeCompounderBase(vaults[i]);
			if (vault.treasury() != current) vault.setTreasury(current);
		}
	}

	/// @notice Sweep a vault's untracked balance of `token` (donations, mistaken transfers; never
	///         its tracked idle) to the CURRENT treasury, synced to that vault or not.
	function sweepUntracked(address vault, IERC20 token) external onlyOwner returns (uint256) {
		_requireCompounder(vault);
		return FeeCompounderBase(vault).sweepUntracked(token, treasury);
	}

	// ─── views ──────────────────────────────────────────────────────────────────

	function allCompounders() external view returns (address[] memory) {
		return vaults;
	}

	function compounderCount() external view returns (uint256) {
		return vaults.length;
	}

	/// @notice `limit` vaults from `offset`, in creation order; empty past the end.
	function compoundersPage(uint256 offset, uint256 limit) external view returns (address[] memory page) {
		uint256 end = _pageEnd(offset, limit);
		if (end <= offset) return new address[](0);
		page = new address[](end - offset);
		for (uint256 i = offset; i < end; ++i) {
			page[i - offset] = vaults[i];
		}
	}

	// ─── internals ──────────────────────────────────────────────────────────────

	/// @dev A required venue needs both addresses; an optional one may leave its manager zero. A set
	///      manager must mint into the pool factory listed beside it.
	function _checkVenue(address poolFactory, address npm, bool required) private view {
		if (npm == address(0)) {
			if (required) revert ZeroAddress();
			return;
		}
		if (poolFactory == address(0)) revert ZeroAddress();
		if (IPositionManagerFactory(npm).factory() != poolFactory) revert NpmFactoryMismatch(npm);
	}

	function _venue(Venue venue) private view returns (address poolFactory, address npm) {
		if (venue == Venue.UniswapV3) return (uniswapV3Factory, uniswapV3Npm);
		if (venue == Venue.Slipstream) return (slipstreamFactory, slipstreamNpm);
		if (venue == Venue.Slipstream2) return (slipstream2Factory, slipstream2Npm);
		return (slipstream3Factory, slipstream3Npm);
	}

	/// @dev The venue's canonical pool, 0 if none. A non-positive tier names none (and a negative
	///      fee must never wrap into a uint24).
	function _getPool(Venue venue, address poolFactory, address token0, address token1, int24 feeOrTickSpacing)
		private
		view
		returns (address)
	{
		if (feeOrTickSpacing <= 0) return address(0);
		if (venue == Venue.UniswapV3) {
			return IUniswapV3PoolFactory(poolFactory).getPool(token0, token1, uint24(feeOrTickSpacing));
		}
		return ISlipstreamPoolFactory(poolFactory).getPool(token0, token1, feeOrTickSpacing);
	}

	/// @dev The token's symbol() if it returns a canonically encoded, non-empty string; otherwise
	///      "0x" + its address's first three bytes. A raw staticcall, not try/catch: try/catch can't
	///      catch a return-data decode failure (a bytes32 symbol), which would revert create.
	function _symbolOf(address token) private view returns (string memory) {
		(bool ok, bytes memory data) = token.staticcall(abi.encodeCall(IERC20Metadata.symbol, ()));
		if (ok && data.length >= 64) {
			(uint256 offset, uint256 length) = abi.decode(data, (uint256, uint256));
			if (offset == 32 && length > 0 && length <= data.length - 64) return abi.decode(data, (string));
		}
		return Strings.toHexString(uint160(token) >> 136, 3);
	}

	function _requireCompounder(address vault) private view {
		if (!isCompounder[vault]) revert UnknownVault(vault);
	}

	/// @dev min(offset + limit, count) without overflow; `offset` past the end gives the count.
	function _pageEnd(uint256 offset, uint256 limit) private view returns (uint256) {
		uint256 n = vaults.length;
		if (offset >= n) return n;
		return limit > n - offset ? n : offset + limit;
	}
}
