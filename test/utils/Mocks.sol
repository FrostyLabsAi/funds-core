// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

contract MockERC20 is ERC20 {
	uint8 private immutable tokenDecimals;

	constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
		tokenDecimals = decimals_;
	}

	function decimals() public view override returns (uint8) {
		return tokenDecimals;
	}

	function mint(address to, uint256 amount) external {
		_mint(to, amount);
	}
}

import {IUniswapV3SwapRouter} from '../../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {ISlipstreamSwapRouter} from '../../src/interfaces/external/ISlipstreamSwapRouter.sol';

/// @dev Pulls tokenIn from the caller, pays a pre-configured fixed output of tokenOut to the
///      recipient. Supports both the Uni v3 (fee) and Slipstream (tickSpacing) param shapes.
contract MockSwapRouter {
	uint256 public nextAmountOut;
	uint24 public lastFee;
	int24 public lastTickSpacing;
	address public lastRecipient;

	function setNextAmountOut(uint256 amountOut) external {
		nextAmountOut = amountOut;
	}

	function exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams calldata params)
		external
		payable
		returns (uint256 amountOut)
	{
		lastFee = params.fee;
		return _swap(params.tokenIn, params.tokenOut, params.amountIn, params.amountOutMinimum, params.recipient);
	}

	function exactInputSingle(ISlipstreamSwapRouter.ExactInputSingleParams calldata params)
		external
		payable
		returns (uint256 amountOut)
	{
		lastTickSpacing = params.tickSpacing;
		return _swap(params.tokenIn, params.tokenOut, params.amountIn, params.amountOutMinimum, params.recipient);
	}

	/// @dev Deliberately ignores minOut so tests can exercise the Comptroller's own
	///      balance-delta enforcement rather than the router's.
	function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256, address recipient)
		internal
		returns (uint256 amountOut)
	{
		amountOut = nextAmountOut;
		lastRecipient = recipient;
		MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
		MockERC20(tokenOut).mint(recipient, amountOut);
	}
}

import {ISlipstreamNonfungiblePositionManager} from
	'../../src/interfaces/external/ISlipstreamNonfungiblePositionManager.sol';

/// @dev Minimal Slipstream NFT position manager: positions are created with a test-set
///      liquidity, decrease credits test-set owed amounts, collect pays them out.
contract MockPositionManager {
	struct MockPosition {
		address token0;
		address token1;
		int24 tickSpacing;
		int24 tickLower;
		int24 tickUpper;
		uint128 liquidity;
		uint128 owed0;
		uint128 owed1;
	}

	uint256 public nextTokenId = 1;
	uint128 public nextLiquidity;
	uint128 public nextDecreaseAmount0;
	uint128 public nextDecreaseAmount1;
	mapping(uint256 => MockPosition) public mockPositions;
	mapping(uint256 => address) public approved;
	/// @dev Plays the Slipstream factory + pool too, so a position factory can authenticate a
	///      gauge against "the pool's gauge" (SlipstreamLPPositionFactory._requirePoolGauge)
	address public poolGauge;

	function setPoolGauge(address gauge_) external {
		poolGauge = gauge_;
	}

	function factory() external view returns (address) {
		return address(this);
	}

	function getPool(address, address, int24) external view returns (address) {
		return address(this);
	}

	function gauge() external view returns (address) {
		return poolGauge;
	}

	function setNextLiquidity(uint128 liquidity) external {
		nextLiquidity = liquidity;
	}

	function setNextDecreaseAmounts(uint128 amount0, uint128 amount1) external {
		nextDecreaseAmount0 = amount0;
		nextDecreaseAmount1 = amount1;
	}

	function addOwedFees(uint256 tokenId, uint128 fee0, uint128 fee1) external {
		mockPositions[tokenId].owed0 += fee0;
		mockPositions[tokenId].owed1 += fee1;
	}

	function mint(ISlipstreamNonfungiblePositionManager.MintParams calldata params)
		external
		payable
		returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
	{
		MockERC20(params.token0).transferFrom(msg.sender, address(this), params.amount0Desired);
		MockERC20(params.token1).transferFrom(msg.sender, address(this), params.amount1Desired);
		tokenId = nextTokenId++;
		liquidity = nextLiquidity;
		mockPositions[tokenId] = MockPosition({
			token0: params.token0,
			token1: params.token1,
			tickSpacing: params.tickSpacing,
			tickLower: params.tickLower,
			tickUpper: params.tickUpper,
			liquidity: nextLiquidity,
			owed0: 0,
			owed1: 0
		});
		return (tokenId, liquidity, params.amount0Desired, params.amount1Desired);
	}

	function increaseLiquidity(ISlipstreamNonfungiblePositionManager.IncreaseLiquidityParams calldata params)
		external
		payable
		returns (uint128 liquidity, uint256 amount0, uint256 amount1)
	{
		MockPosition storage position = mockPositions[params.tokenId];
		MockERC20(position.token0).transferFrom(msg.sender, address(this), params.amount0Desired);
		MockERC20(position.token1).transferFrom(msg.sender, address(this), params.amount1Desired);
		position.liquidity += nextLiquidity;
		return (nextLiquidity, params.amount0Desired, params.amount1Desired);
	}

	function decreaseLiquidity(ISlipstreamNonfungiblePositionManager.DecreaseLiquidityParams calldata params)
		external
		payable
		returns (uint256 amount0, uint256 amount1)
	{
		MockPosition storage position = mockPositions[params.tokenId];
		position.liquidity -= params.liquidity;
		position.owed0 += nextDecreaseAmount0;
		position.owed1 += nextDecreaseAmount1;
		return (nextDecreaseAmount0, nextDecreaseAmount1);
	}

	function collect(ISlipstreamNonfungiblePositionManager.CollectParams calldata params)
		external
		payable
		returns (uint256 amount0, uint256 amount1)
	{
		MockPosition storage position = mockPositions[params.tokenId];
		amount0 = position.owed0 > params.amount0Max ? params.amount0Max : position.owed0;
		amount1 = position.owed1 > params.amount1Max ? params.amount1Max : position.owed1;
		position.owed0 -= uint128(amount0);
		position.owed1 -= uint128(amount1);
		MockERC20(position.token0).transfer(params.recipient, amount0);
		MockERC20(position.token1).transfer(params.recipient, amount1);
	}

	function burn(uint256 tokenId) external payable {
		MockPosition memory position = mockPositions[tokenId];
		require(position.liquidity == 0 && position.owed0 == 0 && position.owed1 == 0, 'not cleared');
		delete mockPositions[tokenId];
	}

	function positions(uint256 tokenId)
		external
		view
		returns (
			uint96,
			address,
			address token0,
			address token1,
			int24 tickSpacing,
			int24 tickLower,
			int24 tickUpper,
			uint128 liquidity,
			uint256,
			uint256,
			uint128 tokensOwed0,
			uint128 tokensOwed1
		)
	{
		MockPosition memory position = mockPositions[tokenId];
		return (
			0,
			address(0),
			position.token0,
			position.token1,
			position.tickSpacing,
			position.tickLower,
			position.tickUpper,
			position.liquidity,
			0,
			0,
			position.owed0,
			position.owed1
		);
	}

	function approve(address to, uint256 tokenId) external {
		approved[tokenId] = to;
	}
}

/// @dev Minimal CLGauge: records staking, mints a test-set AERO reward on getReward.
contract MockCLGauge {
	MockERC20 public immutable aero;
	uint256 public nextReward;
	mapping(uint256 => bool) public isDeposited;

	constructor(MockERC20 aero_) {
		aero = aero_;
	}

	function setNextReward(uint256 reward) external {
		nextReward = reward;
	}

	function rewardToken() external view returns (address) {
		return address(aero);
	}

	function deposit(uint256 tokenId) external {
		isDeposited[tokenId] = true;
	}

	function withdraw(uint256 tokenId) external {
		isDeposited[tokenId] = false;
	}

	function getReward(uint256) external {
		aero.mint(msg.sender, nextReward);
	}

	function earned(address, uint256) external view returns (uint256) {
		return nextReward;
	}
}


import {ERC4626} from '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import {IERC20 as OZIERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IUniswapV3NonfungiblePositionManager} from
	'../../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';

/// @dev Real OZ ERC4626 vault; yield is simulated by donating underlying to the vault.
contract MockERC4626Vault is ERC4626 {
	constructor(OZIERC20 asset_) ERC4626(asset_) ERC20('Mock Yield Vault', 'yUSDC') {}
}

/// @dev Uniswap v3 flavor of the mock position manager (fee-keyed, no sqrtPriceX96 in mint).
contract MockUniV3PositionManager {
	struct MockPosition {
		address token0;
		address token1;
		uint24 fee;
		int24 tickLower;
		int24 tickUpper;
		uint128 liquidity;
		uint128 owed0;
		uint128 owed1;
	}

	uint256 public nextTokenId = 1;
	uint128 public nextLiquidity;
	uint128 public nextDecreaseAmount0;
	uint128 public nextDecreaseAmount1;
	mapping(uint256 => MockPosition) public mockPositions;

	function setNextLiquidity(uint128 liquidity) external {
		nextLiquidity = liquidity;
	}

	function setNextDecreaseAmounts(uint128 amount0, uint128 amount1) external {
		nextDecreaseAmount0 = amount0;
		nextDecreaseAmount1 = amount1;
	}

	function addOwedFees(uint256 tokenId, uint128 fee0, uint128 fee1) external {
		mockPositions[tokenId].owed0 += fee0;
		mockPositions[tokenId].owed1 += fee1;
	}

	function mint(IUniswapV3NonfungiblePositionManager.MintParams calldata params)
		external
		payable
		returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
	{
		MockERC20(params.token0).transferFrom(msg.sender, address(this), params.amount0Desired);
		MockERC20(params.token1).transferFrom(msg.sender, address(this), params.amount1Desired);
		tokenId = nextTokenId++;
		liquidity = nextLiquidity;
		mockPositions[tokenId] = MockPosition({
			token0: params.token0,
			token1: params.token1,
			fee: params.fee,
			tickLower: params.tickLower,
			tickUpper: params.tickUpper,
			liquidity: nextLiquidity,
			owed0: 0,
			owed1: 0
		});
		return (tokenId, liquidity, params.amount0Desired, params.amount1Desired);
	}

	function increaseLiquidity(IUniswapV3NonfungiblePositionManager.IncreaseLiquidityParams calldata params)
		external
		payable
		returns (uint128 liquidity, uint256 amount0, uint256 amount1)
	{
		MockPosition storage position = mockPositions[params.tokenId];
		MockERC20(position.token0).transferFrom(msg.sender, address(this), params.amount0Desired);
		MockERC20(position.token1).transferFrom(msg.sender, address(this), params.amount1Desired);
		position.liquidity += nextLiquidity;
		return (nextLiquidity, params.amount0Desired, params.amount1Desired);
	}

	function decreaseLiquidity(IUniswapV3NonfungiblePositionManager.DecreaseLiquidityParams calldata params)
		external
		payable
		returns (uint256 amount0, uint256 amount1)
	{
		MockPosition storage position = mockPositions[params.tokenId];
		position.liquidity -= params.liquidity;
		position.owed0 += nextDecreaseAmount0;
		position.owed1 += nextDecreaseAmount1;
		return (nextDecreaseAmount0, nextDecreaseAmount1);
	}

	function collect(IUniswapV3NonfungiblePositionManager.CollectParams calldata params)
		external
		payable
		returns (uint256 amount0, uint256 amount1)
	{
		MockPosition storage position = mockPositions[params.tokenId];
		amount0 = position.owed0 > params.amount0Max ? params.amount0Max : position.owed0;
		amount1 = position.owed1 > params.amount1Max ? params.amount1Max : position.owed1;
		position.owed0 -= uint128(amount0);
		position.owed1 -= uint128(amount1);
		MockERC20(position.token0).transfer(params.recipient, amount0);
		MockERC20(position.token1).transfer(params.recipient, amount1);
	}

	function burn(uint256 tokenId) external payable {
		MockPosition memory position = mockPositions[tokenId];
		require(position.liquidity == 0 && position.owed0 == 0 && position.owed1 == 0, 'not cleared');
		delete mockPositions[tokenId];
	}

	function positions(uint256 tokenId)
		external
		view
		returns (
			uint96,
			address,
			address token0,
			address token1,
			uint24 fee,
			int24 tickLower,
			int24 tickUpper,
			uint128 liquidity,
			uint256,
			uint256,
			uint128 tokensOwed0,
			uint128 tokensOwed1
		)
	{
		MockPosition memory position = mockPositions[tokenId];
		return (
			0,
			address(0),
			position.token0,
			position.token1,
			position.fee,
			position.tickLower,
			position.tickUpper,
			position.liquidity,
			0,
			0,
			position.owed0,
			position.owed1
		);
	}
}


/// @dev Minimal CCTP TokenMessenger: burns (pulls) USDC and records the destination.
contract MockTokenMessenger {
	uint256 public lastAmount;
	uint32 public lastDomain;
	bytes32 public lastMintRecipient;

	function depositForBurn(uint256 amount, uint32 destinationDomain, bytes32 mintRecipient, address burnToken)
		external
		returns (uint64 nonce)
	{
		MockERC20(burnToken).transferFrom(msg.sender, address(this), amount);
		lastAmount = amount;
		lastDomain = destinationDomain;
		lastMintRecipient = mintRecipient;
		return 1;
	}
}

contract MockAggregator {
	uint8 public immutable decimals;
	int256 public answer;
	uint256 public updatedAt;

	constructor(uint8 decimals_, int256 answer_) {
		decimals = decimals_;
		answer = answer_;
		updatedAt = block.timestamp;
	}

	function setAnswer(int256 answer_) external {
		answer = answer_;
		updatedAt = block.timestamp;
	}

	function setUpdatedAt(uint256 updatedAt_) external {
		updatedAt = updatedAt_;
	}

	function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
		return (1, answer, updatedAt, updatedAt, 1);
	}
}

import {IExternalPosition} from '../../src/interfaces/IExternalPosition.sol';
import {IExternalPositionTypeFactory} from '../../src/interfaces/IExternalPositionTypeFactory.sol';

/// @notice Minimal IExternalPosition used to exercise the GENERIC external-position
///         machinery — registry gating, fund-owner auth, the allowed-types policy —
///         without coupling those tests to any one venue. (They previously rode on
///         HyperliquidPerpPosition, which was removed with the HL path on 2026-09-18.)
contract MockExternalPosition is IExternalPosition {
	address public immutable comptroller;
	bytes public initArgs;
	bytes public lastAction;

	error OnlyComptroller();

	constructor(address comptroller_, bytes memory initArgs_) {
		comptroller = comptroller_;
		initArgs = initArgs_;
	}

	function getManagedAssets() external pure returns (address[] memory assets, uint256[] memory amounts) {
		assets = new address[](0);
		amounts = new uint256[](0);
	}

	function getDebtAssets() external pure returns (address[] memory assets, uint256[] memory amounts) {
		assets = new address[](0);
		amounts = new uint256[](0);
	}

	function isRiskReducing(bytes calldata) external pure returns (bool) {
		return false;
	}

	function receiveCallFromFund(bytes calldata actionData) external {
		if (msg.sender != comptroller) revert OnlyComptroller();
		lastAction = actionData;
	}
}

contract MockExternalPositionFactory is IExternalPositionTypeFactory {
	function deployPosition(address comptroller, bytes calldata initArgs) external returns (address position) {
		return address(new MockExternalPosition(comptroller, initArgs));
	}
}
