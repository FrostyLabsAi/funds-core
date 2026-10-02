// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IERC721Receiver} from '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {IExternalPosition} from '../interfaces/IExternalPosition.sol';
import {IExternalPositionTypeFactory} from '../interfaces/IExternalPositionTypeFactory.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {ISlipstreamNonfungiblePositionManager, ISlipstreamPoolLookup, ISlipstreamPoolGauge} from
	'../interfaces/external/ISlipstreamNonfungiblePositionManager.sol';
import {ICLGauge} from '../interfaces/external/ICLGauge.sol';
import {Comptroller} from '../core/Comptroller.sol';
import {TickMath} from '../libraries/TickMath.sol';
import {LiquidityAmounts} from '../libraries/LiquidityAmounts.sol';

/// @notice What a V2 position reads from its factory at every claim.
interface ISlipstreamAeroFeeConfig {
	function aeroFeeBps() external view returns (uint16);

	function treasury() external view returns (address);
}

/// @title SlipstreamLPPositionV2
/// @notice External position holding one Aerodrome Slipstream CL position NFT, either
///         unstaked (earns pool fees minus the `unstakedFee` skim) or staked in the pool's
///         gauge (earns AERO instead; fees go to veAERO voters).
///         V2 = SlipstreamLPPosition plus a protocol cut of gauge rewards: on ClaimRewards and on
///         Unstake (the gauge's withdraw pays accrued rewards too), `aeroFeeBps` of the reward tokens
///         that action brought in goes to the treasury, both read from the factory that deployed
///         this position at that time.
/// @dev Liquidity is valued at the oracle-fair sqrt price, never the pool's spot price, so a
///      flash loan that skews the pool can't move it. Uncollected fees and idle balances count;
///      unclaimed AERO doesn't until it's claimed to the vault.
contract SlipstreamLPPositionV2 is IExternalPosition, IERC721Receiver {
	using SafeERC20 for IERC20;

	enum Action {
		Mint,
		IncreaseLiquidity,
		DecreaseLiquidity,
		Collect,
		Burn,
		Stake,
		Unstake,
		ClaimRewards,
		SweepToVault
	}

	uint256 private constant Q96 = 0x1000000000000000000000000;
	uint256 private constant BPS = 10_000;

	address public immutable comptroller;
	ISlipstreamNonfungiblePositionManager public immutable positionManager;
	ICLGauge public immutable gauge; // address(0) = staking disabled for this position
	IERC20 public immutable token0;
	IERC20 public immutable token1;
	int24 public immutable tickSpacing;
	uint256 private immutable scale0;
	uint256 private immutable scale1;
	/// @notice The factory that deployed this position: the source of the claim fee and treasury.
	ISlipstreamAeroFeeConfig public immutable factory;

	uint256 public tokenId; // 0 = no active NFT
	bool public staked;

	event PositionMinted(uint256 indexed tokenId, uint128 liquidity);
	event LiquidityIncreased(uint128 liquidity);
	event LiquidityDecreased(uint128 liquidity);
	event FeesCollected(uint256 amount0, uint256 amount1);
	event PositionBurned(uint256 indexed tokenId);
	event PositionStaked(uint256 indexed tokenId);
	event PositionUnstaked(uint256 indexed tokenId);
	event RewardsClaimed(address indexed rewardToken, uint256 amount);
	event RewardFeePaid(address indexed rewardToken, address indexed treasury, uint256 claimed, uint256 fee);
	event SweptToVault(address indexed asset, uint256 amount);

	error OnlyComptroller();
	error UnknownAction();
	error NoActivePosition();
	error PositionAlreadyExists();
	error StakingDisabled();
	error PositionIsStaked();
	error UnexpectedNft(address nft, uint256 tokenId);
	error PositionNotStaked();
	error ZeroAddress();

	modifier onlyComptroller() {
		if (msg.sender != comptroller) revert OnlyComptroller();
		_;
	}

	constructor(
		address comptroller_,
		ISlipstreamNonfungiblePositionManager positionManager_,
		ICLGauge gauge_,
		IERC20 token0_,
		IERC20 token1_,
		int24 tickSpacing_
	) {
		if (
			comptroller_ == address(0) || address(positionManager_) == address(0) || address(token0_) == address(0)
				|| address(token1_) == address(0)
		) revert ZeroAddress();
		comptroller = comptroller_;
		positionManager = positionManager_;
		gauge = gauge_;
		token0 = token0_;
		token1 = token1_;
		tickSpacing = tickSpacing_;
		scale0 = 10 ** IERC20Metadata(address(token0_)).decimals();
		scale1 = 10 ** IERC20Metadata(address(token1_)).decimals();
		factory = ISlipstreamAeroFeeConfig(msg.sender);
	}

	// ─── IExternalPosition ───────────────────────────────────────────────────────

	/// @inheritdoc IExternalPosition
	/// @dev Reverts (via calcUsdRate) while a token's feed is stale.
	function getManagedAssets() external view returns (address[] memory assets, uint256[] memory amounts) {
		assets = new address[](2);
		assets[0] = address(token0);
		assets[1] = address(token1);
		amounts = new uint256[](2);
		amounts[0] = token0.balanceOf(address(this));
		amounts[1] = token1.balanceOf(address(this));

		if (tokenId != 0) {
			(,,,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,, uint128 tokensOwed0, uint128 tokensOwed1) =
				positionManager.positions(tokenId);

			if (liquidity != 0) {
				IValueInterpreter interpreter = Comptroller(comptroller).valueInterpreter();
				(uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
					_fairSqrtPriceX96(
						interpreter.calcUsdRate(address(token0)), interpreter.calcUsdRate(address(token1))
					),
					TickMath.getSqrtRatioAtTick(tickLower),
					TickMath.getSqrtRatioAtTick(tickUpper),
					liquidity
				);
				amounts[0] += amount0;
				amounts[1] += amount1;
			}

			amounts[0] += tokensOwed0;
			amounts[1] += tokensOwed1;
		}
	}

	/// @inheritdoc IExternalPosition
	function getDebtAssets() external pure returns (address[] memory assets, uint256[] memory amounts) {
		assets = new address[](0);
		amounts = new uint256[](0);
	}

	/// @notice The gauge returns a staked NFT with `safeTransferFrom`, so Unstake needs this hook.
	///         Only this position's own NFT from its own position manager is accepted.
	function onERC721Received(address, address, uint256 tokenId_, bytes calldata) external view returns (bytes4) {
		if (msg.sender != address(positionManager) || tokenId_ != tokenId) revert UnexpectedNft(msg.sender, tokenId_);
		return IERC721Receiver.onERC721Received.selector;
	}

	/// @inheritdoc IExternalPosition
	/// @dev Never: removing liquidity pays at the pool's live (sandwichable) price, so every LP action stays priced.
	function isRiskReducing(bytes calldata) external pure returns (bool) {
		return false;
	}

	/// @inheritdoc IExternalPosition
	function receiveCallFromFund(bytes calldata actionData) external onlyComptroller {
		(uint8 rawAction, bytes memory args) = abi.decode(actionData, (uint8, bytes));

		if (rawAction == uint8(Action.Mint)) {
			_mint(args);
		} else if (rawAction == uint8(Action.IncreaseLiquidity)) {
			_increaseLiquidity(args);
		} else if (rawAction == uint8(Action.DecreaseLiquidity)) {
			_decreaseLiquidity(args);
		} else if (rawAction == uint8(Action.Collect)) {
			_collect();
		} else if (rawAction == uint8(Action.Burn)) {
			_burn();
		} else if (rawAction == uint8(Action.Stake)) {
			_stake();
		} else if (rawAction == uint8(Action.Unstake)) {
			_unstake();
		} else if (rawAction == uint8(Action.ClaimRewards)) {
			_claimRewards();
		} else if (rawAction == uint8(Action.SweepToVault)) {
			_sweepToVault(abi.decode(args, (address)));
		} else {
			revert UnknownAction();
		}
	}

	// ─── Actions ─────────────────────────────────────────────────────────────────

	function _mint(bytes memory args) private {
		if (tokenId != 0) revert PositionAlreadyExists();
		(int24 tickLower, int24 tickUpper, uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min)
		= abi.decode(args, (int24, int24, uint256, uint256, uint256, uint256));

		token0.forceApprove(address(positionManager), amount0Desired);
		token1.forceApprove(address(positionManager), amount1Desired);

		(uint256 newTokenId, uint128 liquidity,,) = positionManager.mint(
			ISlipstreamNonfungiblePositionManager.MintParams({
				token0: address(token0),
				token1: address(token1),
				tickSpacing: tickSpacing,
				tickLower: tickLower,
				tickUpper: tickUpper,
				amount0Desired: amount0Desired,
				amount1Desired: amount1Desired,
				amount0Min: amount0Min,
				amount1Min: amount1Min,
				recipient: address(this),
				deadline: block.timestamp,
				sqrtPriceX96: 0
			})
		);

		tokenId = newTokenId;
		emit PositionMinted(newTokenId, liquidity);
	}

	function _increaseLiquidity(bytes memory args) private {
		uint256 activeTokenId = _requireActive();
		(uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min) =
			abi.decode(args, (uint256, uint256, uint256, uint256));

		token0.forceApprove(address(positionManager), amount0Desired);
		token1.forceApprove(address(positionManager), amount1Desired);

		(uint128 liquidity,,) = positionManager.increaseLiquidity(
			ISlipstreamNonfungiblePositionManager.IncreaseLiquidityParams({
				tokenId: activeTokenId,
				amount0Desired: amount0Desired,
				amount1Desired: amount1Desired,
				amount0Min: amount0Min,
				amount1Min: amount1Min,
				deadline: block.timestamp
			})
		);
		emit LiquidityIncreased(liquidity);
	}

	function _decreaseLiquidity(bytes memory args) private {
		uint256 activeTokenId = _requireActive();
		if (staked) revert PositionIsStaked();
		(uint128 liquidity, uint256 amount0Min, uint256 amount1Min) = abi.decode(args, (uint128, uint256, uint256));

		positionManager.decreaseLiquidity(
			ISlipstreamNonfungiblePositionManager.DecreaseLiquidityParams({
				tokenId: activeTokenId,
				liquidity: liquidity,
				amount0Min: amount0Min,
				amount1Min: amount1Min,
				deadline: block.timestamp
			})
		);
		emit LiquidityDecreased(liquidity);
	}

	/// @dev Collects fees and decreased principal straight to the vault.
	function _collect() private {
		uint256 activeTokenId = _requireActive();
		if (staked) revert PositionIsStaked();

		(uint256 amount0, uint256 amount1) = positionManager.collect(
			ISlipstreamNonfungiblePositionManager.CollectParams({
				tokenId: activeTokenId,
				recipient: address(Comptroller(comptroller).vault()),
				amount0Max: type(uint128).max,
				amount1Max: type(uint128).max
			})
		);
		emit FeesCollected(amount0, amount1);
	}

	function _burn() private {
		uint256 activeTokenId = _requireActive();
		if (staked) revert PositionIsStaked();
		positionManager.burn(activeTokenId);
		tokenId = 0;
		emit PositionBurned(activeTokenId);
	}

	function _stake() private {
		uint256 activeTokenId = _requireActive();
		if (address(gauge) == address(0)) revert StakingDisabled();
		if (staked) revert PositionIsStaked();
		positionManager.approve(address(gauge), activeTokenId);
		gauge.deposit(activeTokenId);
		staked = true;
		emit PositionStaked(activeTokenId);
	}

	/// @dev CLGauge.withdraw pays the accrued rewards here too: they pay the same fee as a claim (on
	///      what this withdraw brought in), and the rest stays here, as in V1, until a sweep or the
	///      next claim moves it. `staked` implies a gauge: only `_stake` sets it, and it reverts without one.
	function _unstake() private {
		uint256 activeTokenId = _requireActive();
		if (!staked) revert PositionNotStaked();
		IERC20 rewardToken = IERC20(gauge.rewardToken());
		uint256 balanceBefore = rewardToken.balanceOf(address(this));
		gauge.withdraw(activeTokenId);
		staked = false;
		_payRewardFee(rewardToken, rewardToken.balanceOf(address(this)) - balanceBefore);
		emit PositionUnstaked(activeTokenId);
	}

	/// @dev AERO lands here; the factory's `aeroFeeBps` of what THIS claim brought in (the balance
	///      delta, never a balance that could hold donations) goes to its treasury, and everything
	///      else goes straight to the vault, as in V1.
	function _claimRewards() private {
		uint256 activeTokenId = _requireActive();
		if (address(gauge) == address(0)) revert StakingDisabled();
		IERC20 rewardToken = IERC20(gauge.rewardToken());
		uint256 balanceBefore = rewardToken.balanceOf(address(this));
		gauge.getReward(activeTokenId);
		_payRewardFee(rewardToken, rewardToken.balanceOf(address(this)) - balanceBefore);

		uint256 balance = rewardToken.balanceOf(address(this));
		if (balance > 0) {
			rewardToken.safeTransfer(address(Comptroller(comptroller).vault()), balance);
		}
		emit RewardsClaimed(address(rewardToken), balance);
	}

	/// @dev The factory's fee and treasury, read now: `aeroFeeBps` of `claimed` (rounded down) to the treasury.
	function _payRewardFee(IERC20 rewardToken, uint256 claimed) private {
		address treasury = factory.treasury();
		uint256 fee = Math.mulDiv(claimed, factory.aeroFeeBps(), BPS);
		if (fee > 0) {
			rewardToken.safeTransfer(treasury, fee);
		}
		emit RewardFeePaid(address(rewardToken), treasury, claimed, fee);
	}

	function _sweepToVault(address asset) private {
		uint256 balance = IERC20(asset).balanceOf(address(this));
		if (balance > 0) {
			IERC20(asset).safeTransfer(address(Comptroller(comptroller).vault()), balance);
		}
		emit SweptToVault(asset, balance);
	}

	function _requireActive() private view returns (uint256 activeTokenId) {
		activeTokenId = tokenId;
		if (activeTokenId == 0) revert NoActivePosition();
	}

	// ─── Fair pricing ────────────────────────────────────────────────────────────

	/// @dev Q64.96 sqrt price implied by the oracle rates (raw token1 per raw token0), clamped
	///      to the representable range; the two-branch sqrt avoids overflow.
	function _fairSqrtPriceX96(uint256 rate0, uint256 rate1) private view returns (uint160) {
		uint256 ratioX96 = Math.mulDiv(Math.mulDiv(rate0, Q96, rate1), scale1, scale0);

		uint256 sqrtRatio =
			ratioX96 <= type(uint256).max >> 64 ? Math.sqrt(ratioX96 << 64) << 16 : Math.sqrt(ratioX96) << 48;

		if (sqrtRatio < TickMath.MIN_SQRT_RATIO) return TickMath.MIN_SQRT_RATIO;
		if (sqrtRatio > TickMath.MAX_SQRT_RATIO) return TickMath.MAX_SQRT_RATIO;
		return uint160(sqrtRatio);
	}
}

/// @title SlipstreamLPPositionV2Factory
/// @notice Type factory for Slipstream LP positions with the AERO claim fee.
///         initArgs = abi.encode(token0, token1, tickSpacing, gauge); gauge = address(0) disables staking.
///         Holds the claim fee (5–30%, starting at 10%) and its treasury (the FrostyDAO Treasury
///         Safe at deploy); every position it deployed reads both at claim time, so one owner call
///         changes them for all of its positions at once.
contract SlipstreamLPPositionV2Factory is IExternalPositionTypeFactory, ISlipstreamAeroFeeConfig, Ownable2Step {
	/// @notice The FrostyDAO Treasury Safe (Base): the treasury this factory starts with.
	address public constant DAO_TREASURY = 0x47b7702a4789912d0dfFDadC07c50395c293fF0A;
	uint16 public constant INITIAL_AERO_FEE_BPS = 1000; // 10% of claimed rewards
	uint16 public constant MIN_AERO_FEE_BPS = 500; // ≥5%
	uint16 public constant MAX_AERO_FEE_BPS = 3000; // ≤30%

	ISlipstreamNonfungiblePositionManager public immutable positionManager;

	/// @inheritdoc ISlipstreamAeroFeeConfig
	uint16 public aeroFeeBps;
	/// @inheritdoc ISlipstreamAeroFeeConfig
	address public treasury;

	event AeroFeeSet(uint16 bps);
	event TreasurySet(address treasury);

	error ZeroAddress();
	error AeroFeeOutOfBounds(uint16 bps);

	constructor(ISlipstreamNonfungiblePositionManager positionManager_) Ownable(msg.sender) {
		if (address(positionManager_) == address(0)) revert ZeroAddress();
		positionManager = positionManager_;
		aeroFeeBps = INITIAL_AERO_FEE_BPS;
		treasury = DAO_TREASURY;
	}

	/// @inheritdoc IExternalPositionTypeFactory
	function deployPosition(address comptroller, bytes calldata initArgs) external returns (address position) {
		(address token0, address token1, int24 tickSpacing, address gauge) =
			abi.decode(initArgs, (address, address, int24, address));
		_requireSupported(comptroller, token0, token1);
		_requirePoolGauge(token0, token1, tickSpacing, gauge);
		position = address(
			new SlipstreamLPPositionV2(
				comptroller, positionManager, ICLGauge(gauge), IERC20(token0), IERC20(token1), tickSpacing
			)
		);
	}

	/// @notice Set the claim fee every position of this factory pays from its next claim on.
	function setAeroFee(uint16 bps) external onlyOwner {
		if (bps < MIN_AERO_FEE_BPS || bps > MAX_AERO_FEE_BPS) revert AeroFeeOutOfBounds(bps);
		aeroFeeBps = bps;
		emit AeroFeeSet(bps);
	}

	/// @notice Set where every position of this factory pays the claim fee from its next claim on.
	function setTreasury(address newTreasury) external onlyOwner {
		if (newTreasury == address(0)) revert ZeroAddress();
		treasury = newTreasury;
		emit TreasurySet(newTreasury);
	}

	error UnsupportedAsset(address asset);
	error GaugeNotPoolGauge(address gauge, address pool);

	/// @dev Staking hands the NFT to `gauge`, so it must be the pool's own gauge (a fake one would keep the NFT).
	function _requirePoolGauge(address token0, address token1, int24 tickSpacing, address gauge) internal view {
		if (gauge == address(0)) return;
		address pool = ISlipstreamPoolLookup(positionManager.factory()).getPool(token0, token1, tickSpacing);
		if (pool == address(0) || ISlipstreamPoolGauge(pool).gauge() != gauge) revert GaugeNotPoolGauge(gauge, pool);
	}

	/// @dev Both tokens must be priceable: an unpriceable one would brick the fund's calcGav.
	function _requireSupported(address comptroller, address token0, address token1) internal view {
		IValueInterpreter interpreter = Comptroller(comptroller).valueInterpreter();
		if (!interpreter.isSupportedAsset(token0)) revert UnsupportedAsset(token0);
		if (!interpreter.isSupportedAsset(token1)) revert UnsupportedAsset(token1);
	}
}
