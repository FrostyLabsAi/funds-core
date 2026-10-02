// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {TickMath} from '../libraries/TickMath.sol';

/// @notice Who may call `compound()`: the CompounderFactory in production, whose `compounders`
///         role goes to the FrostyFi workflow wallet that compounds on a schedule.
interface ICompounderRoles {
	function compounders(address account) external view returns (bool);
}

/// @title FeeCompounderBase
/// @notice One shared full-range LP position per vault. Trading fees are harvested,
///         `perfFeeBps` of the harvest (never principal) goes to the treasury, and the rest is
///         added back so every holder's share value grows. Deposits/withdrawals are dual-token and
///         open to anyone; the stand-alone `compound()` is reserved to the compounder role.
/// @dev Port of FrostyCompounder (Base Sepolia) with the same external interface, so the deployed
///      CompounderAdapter and CompounderPriceFeed serve it unchanged. Venue calls go through the
///      internal hooks below. No oracle and no swaps. A share is an exact pro-rata claim on two
///      things:
///      - the position's liquidity: mint `added × supply / liquidityBefore`, exit
///        `liquidity × shares / supply`, so compounded liquidity accrues to every holder;
///      - the tracked idle tokens (`idle0`/`idle1`): the part of past harvests the reinvest could not
///        pair at the pool ratio. A depositor buys in at `idle × shares / supply` (rounded up) of
///        each token, set aside from its amounts before the rest is added as liquidity, and an exit
///        pays `idle × shares / supply` (rounded down) on top of its liquidity slice. Nobody joins
///        or leaves at another holder's expense, whatever the idle pile holds.
///      Idle is tracked, never read from `balanceOf`: tokens sent to the vault are untracked, never
///      reinvested and never counted in share value; the owner can sweep them (`sweepUntracked`).
///      Tokens are added at the live pool ratio; a manipulated ratio only changes the token mix,
///      which depositors bound with min-amounts. `_compound()` runs before every deposit,
///      withdrawal and fee change, so pending fees stay with the holders who earned them, at the
///      rate in force when they were earned. The position is never staked: it earns trading fees,
///      not emissions.
abstract contract FeeCompounderBase is ERC20, Ownable2Step, ReentrancyGuard {
	using SafeERC20 for IERC20;

	uint16 public constant MIN_PERF_FEE_BPS = 500; // ≥5% of yield
	uint16 public constant MAX_PERF_FEE_BPS = 3000; // ≤30% of yield
	int24 internal constant MAX_TICK = 887272;
	uint256 private constant Q96 = 0x1000000000000000000000000;

	/// @dev Donation-inflation defense: the first deposit seeds this many shares to an unredeemable
	///      sink, and `minShares` lets each depositor bound the shares received (liquidity added to
	///      the vault's NFT through the position manager skews liquidityBefore, which the amount mins
	///      can't catch). 1e6 liquidity units is dust at real scale.
	uint256 public constant MIN_BOOTSTRAP_SHARES = 1e6;
	address public constant BOOTSTRAP_SHARES_SINK = 0x000000000000000000000000000000000000dEaD;

	ICompounderRoles public immutable roles;
	IERC20 public immutable token0;
	IERC20 public immutable token1;
	int24 public immutable tickLower;
	int24 public immutable tickUpper;
	uint160 private immutable sqrtLowerX96;
	uint160 private immutable sqrtUpperX96;

	uint16 public perfFeeBps;
	address public treasury;
	uint256 public tokenId; // 0 until the first deposit mints the shared position
	/// @notice Harvest leftovers the reinvest could not pair, plus deposit buy-ins less exit payouts:
	///         owned by the holders pro-rata. Always ≤ the vault's balance; any surplus is untracked.
	uint256 public idle0;
	uint256 public idle1;

	event Deposited(address indexed account, uint256 shares, uint256 amount0, uint256 amount1);
	event Withdrawn(address indexed account, uint256 shares, uint256 amount0, uint256 amount1);
	event Compounded(uint256 harvested0, uint256 harvested1, uint256 fee0, uint256 fee1, uint128 liquidityAdded);
	event PerfFeeSet(uint16 bps);
	event TreasurySet(address treasury);
	event UntrackedSwept(address indexed token, address indexed to, uint256 amount);

	error ZeroAddress();
	error PerfFeeOutOfBounds(uint16 bps);
	error TokensOutOfOrder();
	error InvalidTickRange();
	error InvalidTickSpacing();
	error PoolNotFound();
	error NothingMinted();
	error BootstrapTooSmall();
	error SharesBelowMin(uint256 shares, uint256 minShares);
	error InsufficientIdleBuyIn(address token, uint256 need, uint256 have);
	error NotCompounder();

	modifier onlyCompounder() {
		if (!roles.compounders(msg.sender)) revert NotCompounder();
		_;
	}

	constructor(
		string memory name_,
		string memory symbol_,
		IERC20 token0_,
		IERC20 token1_,
		int24 tickLower_,
		int24 tickUpper_,
		uint16 perfFeeBps_,
		address treasury_,
		address owner_,
		ICompounderRoles roles_
	) ERC20(name_, symbol_) Ownable(owner_) {
		if (address(token0_) == address(0) || treasury_ == address(0) || address(roles_) == address(0)) {
			revert ZeroAddress();
		}
		if (address(token0_) >= address(token1_)) revert TokensOutOfOrder();
		if (tickLower_ >= tickUpper_) revert InvalidTickRange();
		_checkPerfFee(perfFeeBps_);
		roles = roles_;
		token0 = token0_;
		token1 = token1_;
		tickLower = tickLower_;
		tickUpper = tickUpper_;
		sqrtLowerX96 = TickMath.getSqrtRatioAtTick(tickLower_);
		sqrtUpperX96 = TickMath.getSqrtRatioAtTick(tickUpper_);
		perfFeeBps = perfFeeBps_;
		treasury = treasury_;
	}

	/// @notice Deposit both tokens; unused amounts are refunded. The vault first sets aside the idle
	///         buy-in (see the contract notes) for the shares the amounts can afford, adds the rest at
	///         the live pool ratio, and mints shares pro-rata to the liquidity added.
	///         `amount0Min/amount1Min` bound the amounts the pool takes; `minShares` bounds the shares.
	///         `previewDeposit` shows the split.
	/// @dev The pool's spot price only SIZES the set-aside (the per-share cost of liquidity + idle);
	///      shares come from the liquidity actually added, capped at what the amounts afford, and the
	///      buy-in from those shares — so a skewed spot can only refund more or mint fewer shares to
	///      the depositor (bounded by `minShares`), never move value from existing holders.
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
		BuyInPlan memory plan = _planBuyIn(liquidityBefore, idle0, idle1, amount0Desired, amount1Desired);
		uint128 liquidity;
		uint256 used0;
		uint256 used1;
		if (tokenId == 0) {
			(tokenId, liquidity, used0, used1) = _mintPosition(amount0Desired, amount1Desired, amount0Min, amount1Min);
		} else {
			(liquidity, used0, used1) = _increase(
				tokenId, amount0Desired - plan.reserve0, amount1Desired - plan.reserve1, amount0Min, amount1Min, false
			);
		}
		if (liquidity == 0) revert NothingMinted();

		shares = _settleDeposit(liquidity, liquidityBefore, plan, amount0Desired, amount1Desired, used0, used1, minShares);
	}

	/// @dev A deposit's split: `cap` = the shares the amounts can afford at the per-share cost
	///      (position tokens at spot + idle), `reserveN` = the idle those shares bring (rounded up).
	struct BuyInPlan {
		uint256 supply;
		uint256 cap;
		uint256 reserve0;
		uint256 reserve1;
	}

	function _planBuyIn(uint128 liquidityBefore, uint256 i0, uint256 i1, uint256 amount0, uint256 amount1)
		private
		view
		returns (BuyInPlan memory plan)
	{
		plan.supply = totalSupply();
		if (plan.supply == 0) {
			plan.cap = type(uint256).max; // the first deposit: no idle, no buy-in
			return plan;
		}
		(uint256 cost0, uint256 cost1) = _amountsForLiquidity(_sqrtPriceX96(), liquidityBefore);
		cost0 += i0;
		cost1 += i1;
		plan.cap = type(uint256).max;
		if (cost0 > 0) plan.cap = Math.mulDiv(amount0, plan.supply, cost0);
		if (cost1 > 0) plan.cap = Math.min(plan.cap, Math.mulDiv(amount1, plan.supply, cost1));
		(plan.reserve0, plan.reserve1) = _buyIns(plan.cap, plan.supply, i0, i1);
	}

	/// @dev Shares against the liquidity already backing existing shares (the compounded portion
	///      stays with the holders who earned it), the idle buy-in, refunds, mint.
	function _settleDeposit(
		uint128 liquidity,
		uint128 liquidityBefore,
		BuyInPlan memory plan,
		uint256 amount0Desired,
		uint256 amount1Desired,
		uint256 used0,
		uint256 used1,
		uint256 minShares
	) private returns (uint256 shares) {
		uint256 buyIn0;
		uint256 buyIn1;
		if (plan.supply == 0) {
			if (liquidity <= MIN_BOOTSTRAP_SHARES) revert BootstrapTooSmall();
			_mint(BOOTSTRAP_SHARES_SINK, MIN_BOOTSTRAP_SHARES);
			shares = uint256(liquidity) - MIN_BOOTSTRAP_SHARES;
		} else {
			// rounding in the pool can't buy more shares than the amounts afford
			shares = Math.min((uint256(liquidity) * plan.supply) / liquidityBefore, plan.cap);
			(buyIn0, buyIn1) = _buyIns(shares, plan.supply, idle0, idle1);
		}
		if (shares == 0) revert NothingMinted();
		if (shares < minShares) revert SharesBelowMin(shares, minShares);

		idle0 += _takeBuyIn(token0, amount0Desired, used0, buyIn0);
		idle1 += _takeBuyIn(token1, amount1Desired, used1, buyIn1);
		_mint(msg.sender, shares);
		emit Deposited(msg.sender, shares, used0 + buyIn0, used1 + buyIn1);
	}

	/// @dev Keep `buyIn` out of what the pool left over (the set-aside included); refund the rest.
	///      The cap and the set-aside make a shortfall unreachable; the check stays as a guard.
	function _takeBuyIn(IERC20 token, uint256 desired, uint256 used, uint256 buyIn) private returns (uint256) {
		uint256 left = desired > used ? desired - used : 0;
		if (buyIn > left) revert InsufficientIdleBuyIn(address(token), buyIn, left);
		if (left > buyIn) token.safeTransfer(msg.sender, left - buyIn);
		return buyIn;
	}

	/// @dev The idle a new `shares` must bring: the existing per-share idle, rounded up.
	function _buyIns(uint256 shares, uint256 supply, uint256 i0, uint256 i1)
		private
		pure
		returns (uint256 buyIn0, uint256 buyIn1)
	{
		buyIn0 = Math.mulDiv(i0, shares, supply, Math.Rounding.Ceil);
		buyIn1 = Math.mulDiv(i1, shares, supply, Math.Rounding.Ceil);
	}

	/// @notice Burn shares for the proportional slice of the position plus the same slice of the idle
	///         tokens; pending fees are compounded first. `amount0Min/amount1Min` bound the liquidity
	///         slice (the idle slice is exact); the returned amounts include both.
	function withdraw(uint256 shares, uint256 amount0Min, uint256 amount1Min)
		external
		nonReentrant
		returns (uint256 amount0, uint256 amount1)
	{
		_compound();
		uint256 supply = totalSupply();
		// Slices BEFORE burning (rounding down favors remaining holders)
		uint128 liquidityOut = uint128((uint256(_positionLiquidity()) * shares) / supply);
		uint256 idleOut0 = (idle0 * shares) / supply;
		uint256 idleOut1 = (idle1 * shares) / supply;
		_burn(msg.sender, shares); // reverts on insufficient balance
		idle0 -= idleOut0;
		idle1 -= idleOut1;

		(amount0, amount1) = _decrease(tokenId, liquidityOut, amount0Min, amount1Min);
		// Removed principal parks as owed on the position — sweep exactly that amount out
		_collect(tokenId, msg.sender, uint128(amount0), uint128(amount1));
		if (idleOut0 > 0) token0.safeTransfer(msg.sender, idleOut0);
		if (idleOut1 > 0) token1.safeTransfer(msg.sender, idleOut1);
		amount0 += idleOut0;
		amount1 += idleOut1;
		emit Withdrawn(msg.sender, shares, amount0, amount1);
	}

	/// @notice Harvest fees, take the protocol's cut of the yield, add the rest back to the
	///         position. Compounder role only, so no outsider can time a stand-alone harvest;
	///         deposits and withdrawals still harvest first, so a stalled role only delays fees.
	function compound() external nonReentrant onlyCompounder {
		_compound();
	}

	function _compound() internal {
		uint256 id = tokenId;
		if (id == 0) return;

		(uint256 harvested0, uint256 harvested1) = _collect(id, address(this), type(uint128).max, type(uint128).max);

		uint256 fee0 = (harvested0 * perfFeeBps) / 10_000;
		uint256 fee1 = (harvested1 * perfFeeBps) / 10_000;
		if (fee0 > 0) token0.safeTransfer(treasury, fee0);
		if (fee1 > 0) token1.safeTransfer(treasury, fee1);

		// Reinvest the net harvest plus the tracked leftovers of earlier rounds — never a raw
		// balance, so nothing sent to the vault can pair with the idle pile.
		// No shares are minted → the added liquidity accrues to ALL holders pro-rata.
		uint256 avail0 = idle0 + harvested0 - fee0;
		uint256 avail1 = idle1 + harvested1 - fee1;
		uint128 added;
		uint256 used0;
		uint256 used1;
		if (avail0 > 0 && avail1 > 0) {
			// Dust-tolerant: amounts too small to mint any liquidity would revert in
			// the pool — keep them idle for the next round instead of bricking the path
			(added, used0, used1) = _increase(id, avail0, avail1, 0, 0, true);
		}
		idle0 = avail0 > used0 ? avail0 - used0 : 0;
		idle1 = avail1 > used1 ? avail1 - used1 : 0;
		if (harvested0 > 0 || harvested1 > 0 || added > 0) {
			emit Compounded(harvested0, harvested1, fee0, fee1, added);
		}
	}

	function _positionLiquidity() internal view returns (uint128 liquidity) {
		if (tokenId == 0) return 0;
		(liquidity,,) = _positions(tokenId);
	}

	// ─── Views ───────────────────────────────────────────────────────────────────

	/// @notice The shared position's liquidity and what else backs the shares: `pendingFeesN` is the
	///         position's owed tokens (gross; the perf fee is taken at harvest) plus the tracked idle.
	///         Share value = (liquidity + pending) / totalSupply — the CompounderPriceFeed counts both.
	/// @dev The pool credits fees to `tokensOwed` only when the position is touched (compound,
	///      deposit, withdraw), so between touches NAV leaves the newest fees out and steps up at the
	///      next compound: conservative, and a daily compound bounds the step.
	function positionState()
		external
		view
		returns (uint128 liquidity, uint128 pendingFees0, uint128 pendingFees1)
	{
		if (tokenId == 0) return (0, 0, 0);
		uint128 owed0;
		uint128 owed1;
		(liquidity, owed0, owed1) = _positions(tokenId);
		pendingFees0 = SafeCast.toUint128(owed0 + idle0);
		pendingFees1 = SafeCast.toUint128(owed1 + idle1);
	}

	/// @notice What `deposit(amount0Desired, amount1Desired, …)` would do now: shares, the amounts the
	///         pool would take, and the idle buy-ins; the rest of the amounts is refunded.
	/// @dev Exact while the pool has credited every fee the position earned (right after any
	///      compound, deposit or withdraw, with no swap since): it replays deposit's harvest (owed
	///      fees, the perf fee, the reinvest of what pairs), the set-aside and the pool's own rounding.
	///      Fees not yet credited are harvested by deposit() first: liquidity per share only rises,
	///      so shares can only be lower, and a buy-in can move by at most the new shares' slice of
	///      those fees. For an exact quote in any state, eth_call deposit() from the depositor.
	function previewDeposit(uint256 amount0Desired, uint256 amount1Desired)
		external
		view
		returns (uint256 shares, uint256 used0, uint256 used1, uint256 buyIn0, uint256 buyIn1)
	{
		uint160 sqrtPriceX96 = _sqrtPriceX96();
		(uint128 liquidityBefore, uint256 i0, uint256 i1) = _previewHarvest(sqrtPriceX96);
		BuyInPlan memory plan = _planBuyIn(liquidityBefore, i0, i1, amount0Desired, amount1Desired);
		uint128 liquidity =
			_liquidityForAmounts(sqrtPriceX96, amount0Desired - plan.reserve0, amount1Desired - plan.reserve1);
		(used0, used1) = _amountsForLiquidity(sqrtPriceX96, liquidity);
		if (plan.supply == 0) {
			return (liquidity > MIN_BOOTSTRAP_SHARES ? liquidity - MIN_BOOTSTRAP_SHARES : 0, used0, used1, 0, 0);
		}
		shares = Math.min((uint256(liquidity) * plan.supply) / liquidityBefore, plan.cap);
		(buyIn0, buyIn1) = _buyIns(shares, plan.supply, i0, i1);
	}

	/// @dev `_compound()` replayed on the credited fees: the position's liquidity and the idle after it.
	function _previewHarvest(uint160 sqrtPriceX96) private view returns (uint128 liquidity, uint256 i0, uint256 i1) {
		i0 = idle0;
		i1 = idle1;
		if (tokenId == 0) return (0, i0, i1);
		uint128 owed0;
		uint128 owed1;
		(liquidity, owed0, owed1) = _positions(tokenId);
		i0 += owed0 - (uint256(owed0) * perfFeeBps) / 10_000;
		i1 += owed1 - (uint256(owed1) * perfFeeBps) / 10_000;
		if (i0 == 0 || i1 == 0) return (liquidity, i0, i1);
		uint128 added = _liquidityForAmounts(sqrtPriceX96, i0, i1);
		if (added == 0) return (liquidity, i0, i1); // the pool refuses zero liquidity; all stays idle
		(uint256 u0, uint256 u1) = _amountsForLiquidity(sqrtPriceX96, added);
		return (liquidity + added, i0 > u0 ? i0 - u0 : 0, i1 > u1 ? i1 - u1 : 0);
	}

	// ─── Protocol controls ───────────────────────────────────────────────────────

	/// @notice Pending fees are harvested first, at the rate in force when they were earned.
	function setPerfFee(uint16 bps) external nonReentrant onlyOwner {
		_checkPerfFee(bps);
		_compound();
		perfFeeBps = bps;
		emit PerfFeeSet(bps);
	}

	function setTreasury(address treasury_) external onlyOwner {
		if (treasury_ == address(0)) revert ZeroAddress();
		treasury = treasury_;
		emit TreasurySet(treasury_);
	}

	/// @notice Move tokens the vault holds beyond its tracked idle (donations, mistaken transfers):
	///         they never enter share value or reinvestment. Tracked idle can never be swept; nothing
	///         is in flight outside deposit/withdraw/compound, which this call cannot interleave.
	function sweepUntracked(IERC20 token, address to) external nonReentrant onlyOwner returns (uint256 amount) {
		if (to == address(0)) revert ZeroAddress();
		uint256 tracked = token == token0 ? idle0 : (token == token1 ? idle1 : 0);
		uint256 balance = token.balanceOf(address(this));
		amount = balance > tracked ? balance - tracked : 0;
		if (amount > 0) token.safeTransfer(to, amount);
		emit UntrackedSwept(address(token), to, amount);
	}

	function _checkPerfFee(uint16 bps) private pure {
		if (bps < MIN_PERF_FEE_BPS || bps > MAX_PERF_FEE_BPS) revert PerfFeeOutOfBounds(bps);
	}

	/// @dev The widest range the venue accepts: ±MAX_TICK rounded toward zero to `spacing`.
	function _fullRangeTick(int24 spacing) internal pure returns (int24) {
		if (spacing <= 0) revert InvalidTickSpacing();
		return (MAX_TICK / spacing) * spacing;
	}

	// ─── Pool math (Uniswap v3 LiquidityAmounts / SqrtPriceMath, as the position managers use it) ──

	/// @dev Liquidity the manager would mint for these amounts over [tickLower, tickUpper] (rounded down).
	function _liquidityForAmounts(uint160 sqrtPriceX96, uint256 amount0, uint256 amount1)
		private
		view
		returns (uint128)
	{
		uint160 sqrtA = sqrtLowerX96;
		uint160 sqrtB = sqrtUpperX96;
		if (sqrtPriceX96 <= sqrtA) return _liquidity0(sqrtA, sqrtB, amount0);
		if (sqrtPriceX96 < sqrtB) {
			uint128 l0 = _liquidity0(sqrtPriceX96, sqrtB, amount0);
			uint128 l1 = _liquidity1(sqrtA, sqrtPriceX96, amount1);
			return l0 < l1 ? l0 : l1;
		}
		return _liquidity1(sqrtA, sqrtB, amount1);
	}

	function _liquidity0(uint160 sqrtA, uint160 sqrtB, uint256 amount0) private pure returns (uint128) {
		return SafeCast.toUint128(Math.mulDiv(amount0, Math.mulDiv(sqrtA, sqrtB, Q96), sqrtB - sqrtA));
	}

	function _liquidity1(uint160 sqrtA, uint160 sqrtB, uint256 amount1) private pure returns (uint128) {
		return SafeCast.toUint128(Math.mulDiv(amount1, Q96, sqrtB - sqrtA));
	}

	/// @dev Token amounts the pool takes for `liquidity` (rounded up, as the pool charges a mint).
	function _amountsForLiquidity(uint160 sqrtPriceX96, uint128 liquidity)
		private
		view
		returns (uint256 amount0, uint256 amount1)
	{
		uint160 sqrtA = sqrtLowerX96;
		uint160 sqrtB = sqrtUpperX96;
		if (sqrtPriceX96 <= sqrtA) {
			amount0 = _amount0Up(sqrtA, sqrtB, liquidity);
		} else if (sqrtPriceX96 < sqrtB) {
			amount0 = _amount0Up(sqrtPriceX96, sqrtB, liquidity);
			amount1 = _amount1Up(sqrtA, sqrtPriceX96, liquidity);
		} else {
			amount1 = _amount1Up(sqrtA, sqrtB, liquidity);
		}
	}

	function _amount0Up(uint160 sqrtA, uint160 sqrtB, uint128 liquidity) private pure returns (uint256) {
		return Math.ceilDiv(Math.mulDiv(uint256(liquidity) << 96, sqrtB - sqrtA, sqrtB, Math.Rounding.Ceil), sqrtA);
	}

	function _amount1Up(uint160 sqrtA, uint160 sqrtB, uint128 liquidity) private pure returns (uint256) {
		return Math.mulDiv(liquidity, sqrtB - sqrtA, Q96, Math.Rounding.Ceil);
	}

	// ─── Venue hooks ─────────────────────────────────────────────────────────────

	/// @dev Mint the shared position over [tickLower, tickUpper] to this vault, paid by this vault.
	function _mintPosition(uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min)
		internal
		virtual
		returns (uint256 newTokenId, uint128 liquidity, uint256 used0, uint256 used1);

	/// @dev Add to position `id`. `tolerant`: a revert in the position manager returns zeros
	///      instead of bubbling (the compound path keeps dust idle for the next round).
	function _increase(
		uint256 id,
		uint256 amount0Desired,
		uint256 amount1Desired,
		uint256 amount0Min,
		uint256 amount1Min,
		bool tolerant
	) internal virtual returns (uint128 liquidity, uint256 used0, uint256 used1);

	function _decrease(uint256 id, uint128 liquidity, uint256 amount0Min, uint256 amount1Min)
		internal
		virtual
		returns (uint256 amount0, uint256 amount1);

	function _collect(uint256 id, address recipient, uint128 amount0Max, uint128 amount1Max)
		internal
		virtual
		returns (uint256 amount0, uint256 amount1);

	/// @dev Position `id`'s liquidity and owed tokens (tokensOwed0/1).
	function _positions(uint256 id) internal view virtual returns (uint128 liquidity, uint128 owed0, uint128 owed1);

	/// @dev The pool's current sqrt price (slot0), for previewDeposit.
	function _sqrtPriceX96() internal view virtual returns (uint160);
}
