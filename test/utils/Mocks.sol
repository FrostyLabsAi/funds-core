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

import {ERC4626} from '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import {IERC20 as OZIERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/// @dev Real OZ ERC4626 vault; yield is simulated by donating underlying to the vault.
contract MockERC4626Vault is ERC4626 {
	constructor(OZIERC20 asset_) ERC4626(asset_) ERC20('Mock Yield Vault', 'yUSDC') {}
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
