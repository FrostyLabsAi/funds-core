// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {IUniswapV3NonfungiblePositionManager} from '../interfaces/external/IUniswapV3NonfungiblePositionManager.sol';

/// @title FrostyCompounder
/// @notice The protocol's revenue engine on LP yields (Beefy model): one shared
///         full-range concentrated-liquidity position per vault; anyone can
///         `compound()` — trading fees are harvested, the protocol takes
///         `perfFeeBps` OF THE HARVEST ONLY (never principal), and the rest is
///         folded back into the position so every holder's share value grows.
///         Deposits/withdrawals are dual-token and proportional.
///
/// @dev SAFETY MODEL — no oracle, no swaps, no price surface:
///      · shares track POOL LIQUIDITY UNITS pro-rata: deposits mint
///        `added × supply / liquidityBefore`, exits remove
///        `positionLiquidity × shares / supply` — compounded liquidity therefore
///        accrues to every holder (fork-proven: the 1:1 shortcut orphaned yield),
///        and fairness rides the pool's own liquidity math, unmanipulable;
///      · the vault never swaps: deposits and compounds add both tokens at the
///        live pool ratio (a manipulated ratio changes the token MIX pulled, which
///        depositors bound with min-amounts, never the share count);
///      · `_compound()` runs before every deposit and withdrawal, so pending fees
///        always belong to the holders who earned them;
///      · works unchanged against Uniswap v3 (Sepolia demo, this deploy) and, with
///        a gauge adapter for AERO emissions, Aerodrome Slipstream on mainnet
///        (same NPM ABI shape) — that variant is the mainnet follow-up.
contract FrostyCompounder is ERC20, Ownable2Step, ReentrancyGuard {
	using SafeERC20 for IERC20;

	uint16 public constant MAX_PERF_FEE_BPS = 3000; // hard protocol promise: ≤30% of yield

	IUniswapV3NonfungiblePositionManager public immutable positionManager;
	IERC20 public immutable token0;
	IERC20 public immutable token1;
	uint24 public immutable poolFee;
	int24 public immutable tickLower;
	int24 public immutable tickUpper;

	uint16 public perfFeeBps;
	address public treasury;
	uint256 public tokenId; // 0 until the first deposit mints the shared position

	event Deposited(address indexed account, uint256 shares, uint256 amount0, uint256 amount1);
	event Withdrawn(address indexed account, uint256 shares, uint256 amount0, uint256 amount1);
	event Compounded(uint256 harvested0, uint256 harvested1, uint256 fee0, uint256 fee1, uint128 liquidityAdded);
	event PerfFeeSet(uint16 bps);
	event TreasurySet(address treasury);

	error ZeroAddress();
	error FeeTooHigh();
	error TokensOutOfOrder();
	error NothingMinted();
	error BootstrapTooSmall();
	error SharesBelowMin(uint256 shares, uint256 minShares);

	constructor(
		string memory name_,
		string memory symbol_,
		IUniswapV3NonfungiblePositionManager positionManager_,
		IERC20 token0_,
		IERC20 token1_,
		uint24 poolFee_,
		int24 fullRangeTick_,
		uint16 perfFeeBps_,
		address treasury_
	) ERC20(name_, symbol_) Ownable(msg.sender) {
		if (address(positionManager_) == address(0) || treasury_ == address(0)) revert ZeroAddress();
		if (address(token0_) >= address(token1_)) revert TokensOutOfOrder();
		if (perfFeeBps_ > MAX_PERF_FEE_BPS) revert FeeTooHigh();
		positionManager = positionManager_;
		token0 = token0_;
		token1 = token1_;
		poolFee = poolFee_;
		tickLower = -fullRangeTick_;
		tickUpper = fullRangeTick_;
		perfFeeBps = perfFeeBps_;
		treasury = treasury_;
		token0_.forceApprove(address(positionManager_), type(uint256).max);
		token1_.forceApprove(address(positionManager_), type(uint256).max);
	}

	/// @dev Donation-inflation defense (security review 2026-09-22, H-4): the first
	///      deposit seeds this many liquidity-unit shares to an unredeemable sink so a
	///      1-share supply can never exist, and `minShares` lets every depositor bound
	///      the shares they accept (the ratio-based amount mins can't — a donation
	///      skews liquidityBefore, not the used amounts). 1e6 liquidity units is dust at
	///      real full-range scale (~1e15 for a 10k/10k position) but a 1e6× granularity
	///      floor against rounding theft.
	uint256 public constant MIN_BOOTSTRAP_SHARES = 1e6;
	address public constant BOOTSTRAP_SHARES_SINK = 0x000000000000000000000000000000000000dEaD;

	/// @notice Add both tokens at the live pool ratio. Shares minted = liquidity units
	///         added. Unused amounts (the pool takes the ratio it needs) are refunded.
	///         `amount0Min/amount1Min` bound the USED amounts against ratio movement;
	///         `minShares` bounds the SHARES received (donation/ratio-skew defense).
	function deposit(
		uint256 amount0Desired,
		uint256 amount1Desired,
		uint256 amount0Min,
		uint256 amount1Min,
		uint256 minShares
	) external nonReentrant returns (uint256 shares) {
		_compound();

		token0.safeTransferFrom(msg.sender, address(this), amount0Desired);
		token1.safeTransferFrom(msg.sender, address(this), amount1Desired);

		uint128 liquidityBefore = _positionLiquidity();
		uint128 liquidity;
		uint256 used0;
		uint256 used1;
		if (tokenId == 0) {
			(tokenId, liquidity, used0, used1) = positionManager.mint(
				IUniswapV3NonfungiblePositionManager.MintParams({
					token0: address(token0),
					token1: address(token1),
					fee: poolFee,
					tickLower: tickLower,
					tickUpper: tickUpper,
					amount0Desired: amount0Desired,
					amount1Desired: amount1Desired,
					amount0Min: amount0Min,
					amount1Min: amount1Min,
					recipient: address(this),
					deadline: block.timestamp
				})
			);
		} else {
			(liquidity, used0, used1) = positionManager.increaseLiquidity(
				IUniswapV3NonfungiblePositionManager.IncreaseLiquidityParams({
					tokenId: tokenId,
					amount0Desired: amount0Desired,
					amount1Desired: amount1Desired,
					amount0Min: amount0Min,
					amount1Min: amount1Min,
					deadline: block.timestamp
				})
			);
		}
		if (liquidity == 0) revert NothingMinted();

		// Refund what the pool ratio didn't take
		if (amount0Desired > used0) token0.safeTransfer(msg.sender, amount0Desired - used0);
		if (amount1Desired > used1) token1.safeTransfer(msg.sender, amount1Desired - used1);

		// Pro-rata against the liquidity that already backs existing shares — the
		// compounded portion stays with the holders who earned it
		uint256 supply = totalSupply();
		if (supply == 0) {
			if (liquidity <= MIN_BOOTSTRAP_SHARES) revert BootstrapTooSmall();
			_mint(BOOTSTRAP_SHARES_SINK, MIN_BOOTSTRAP_SHARES);
			shares = uint256(liquidity) - MIN_BOOTSTRAP_SHARES;
		} else {
			shares = (uint256(liquidity) * supply) / liquidityBefore;
		}
		if (shares == 0) revert NothingMinted();
		if (shares < minShares) revert SharesBelowMin(shares, minShares);
		_mint(msg.sender, shares);
		emit Deposited(msg.sender, shares, used0, used1);
	}

	/// @notice Burn shares for the proportional slice of the position — pending fees
	///         are compounded first, so exits always include the yield earned so far.
	function withdraw(uint256 shares, uint256 amount0Min, uint256 amount1Min)
		external
		nonReentrant
		returns (uint256 amount0, uint256 amount1)
	{
		_compound();
		// Liquidity slice BEFORE burning (rounding down favors remaining holders)
		uint128 liquidityOut = uint128((uint256(_positionLiquidity()) * shares) / totalSupply());
		_burn(msg.sender, shares); // reverts on insufficient balance

		(amount0, amount1) = positionManager.decreaseLiquidity(
			IUniswapV3NonfungiblePositionManager.DecreaseLiquidityParams({
				tokenId: tokenId,
				liquidity: liquidityOut,
				amount0Min: amount0Min,
				amount1Min: amount1Min,
				deadline: block.timestamp
			})
		);
		// Removed principal parks as owed on the position — sweep exactly that amount out
		positionManager.collect(
			IUniswapV3NonfungiblePositionManager.CollectParams({
				tokenId: tokenId,
				recipient: msg.sender,
				amount0Max: uint128(amount0),
				amount1Max: uint128(amount1)
			})
		);
		emit Withdrawn(msg.sender, shares, amount0, amount1);
	}

	/// @notice Harvest trading fees, take the protocol's cut OF THE YIELD, fold the
	///         rest back into the shared position. Public — compounding is a favor to
	///         every holder, and more callers just means fresher share value.
	function compound() external nonReentrant {
		_compound();
	}

	function _compound() internal {
		if (tokenId == 0) return;

		(uint256 harvested0, uint256 harvested1) = positionManager.collect(
			IUniswapV3NonfungiblePositionManager.CollectParams({
				tokenId: tokenId,
				recipient: address(this),
				amount0Max: type(uint128).max,
				amount1Max: type(uint128).max
			})
		);

		uint256 fee0 = (harvested0 * perfFeeBps) / 10_000;
		uint256 fee1 = (harvested1 * perfFeeBps) / 10_000;
		if (fee0 > 0) token0.safeTransfer(treasury, fee0);
		if (fee1 > 0) token1.safeTransfer(treasury, fee1);

		// Reinvest everything the vault holds (incl. leftovers from earlier rounds).
		// No shares are minted → the added liquidity accrues to ALL holders pro-rata.
		uint256 bal0 = token0.balanceOf(address(this));
		uint256 bal1 = token1.balanceOf(address(this));
		uint128 added;
		if (bal0 > 0 && bal1 > 0) {
			// Dust-tolerant: amounts too small to mint any liquidity would revert in
			// the pool — park them for the next round instead of bricking the path
			try positionManager.increaseLiquidity(
				IUniswapV3NonfungiblePositionManager.IncreaseLiquidityParams({
					tokenId: tokenId,
					amount0Desired: bal0,
					amount1Desired: bal1,
					amount0Min: 0,
					amount1Min: 0,
					deadline: block.timestamp
				})
			) returns (uint128 liquidityAdded, uint256, uint256) {
				added = liquidityAdded;
			} catch {}
		}
		if (harvested0 > 0 || harvested1 > 0 || added > 0) {
			emit Compounded(harvested0, harvested1, fee0, fee1, added);
		}
	}

	function _positionLiquidity() internal view returns (uint128 liquidity) {
		if (tokenId == 0) return 0;
		(,,,,,,, liquidity,,,,) = positionManager.positions(tokenId);
	}

	// ─── Views ───────────────────────────────────────────────────────────────────

	/// @notice The shared position's current liquidity + uncompounded fees — share
	///         value = liquidity / totalSupply (1 share = 1 liquidity unit forever).
	function positionState()
		external
		view
		returns (uint128 liquidity, uint128 pendingFees0, uint128 pendingFees1)
	{
		if (tokenId == 0) return (0, 0, 0);
		(,,,,,,, liquidity,,, pendingFees0, pendingFees1) = positionManager.positions(tokenId);
	}

	// ─── Protocol controls (fee switch — capped, yield-only by construction) ─────

	function setPerfFee(uint16 bps) external onlyOwner {
		if (bps > MAX_PERF_FEE_BPS) revert FeeTooHigh();
		perfFeeBps = bps;
		emit PerfFeeSet(bps);
	}

	function setTreasury(address treasury_) external onlyOwner {
		if (treasury_ == address(0)) revert ZeroAddress();
		treasury = treasury_;
		emit TreasurySet(treasury_);
	}
}
