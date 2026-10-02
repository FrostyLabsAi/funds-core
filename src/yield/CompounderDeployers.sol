// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IUniswapV3NonfungiblePositionManager} from
	'../interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {ISlipstreamNonfungiblePositionManager} from
	'../interfaces/external/ISlipstreamNonfungiblePositionManager.sol';
import {ICompounderRoles} from './FeeCompounderBase.sol';
import {UniswapV3FeeCompounder} from './UniswapV3FeeCompounder.sol';
import {SlipstreamFeeCompounder} from './SlipstreamFeeCompounder.sol';

// The two deployers hold the vaults' creation code so CompounderFactory doesn't (both together
// would pass EIP-170's 24,576-byte limit). Unlike TwapAdapterDeployers they are NOT permissionless:
// the factory creates both in its constructor and is each one's only caller, and every vault made
// here is owned by the factory and reads its compounder role. So no "Frosty Compounding" vault
// exists that didn't pass the factory's creator gate.

/// @notice The caller check both deployers share: the creator (the factory) is the only caller.
abstract contract CompounderDeployerBase {
	/// @notice A vault's constructor arguments, less the owner and role holder (always the factory).
	///         `feeOrTickSpacing`: the Uniswap fee tier or the Slipstream tick spacing (> 0).
	struct VaultParams {
		string name;
		string symbol;
		address positionManager;
		address token0;
		address token1;
		int24 feeOrTickSpacing;
		uint16 perfFeeBps;
		address treasury;
	}

	/// @notice The CompounderFactory that created this deployer: its only caller, and the owner and
	///         role holder of every vault it makes.
	address public immutable factory;

	error NotFactory();

	constructor() {
		factory = msg.sender;
	}

	modifier onlyFactory() {
		if (msg.sender != factory) revert NotFactory();
		_;
	}
}

/// @title UniswapV3CompounderDeployer
/// @notice Creates UniswapV3FeeCompounder vaults for the factory (owner = roles = factory);
///         `feeOrTickSpacing` is the fee tier, which the factory has checked is positive.
contract UniswapV3CompounderDeployer is CompounderDeployerBase {
	function deploy(VaultParams memory p) external onlyFactory returns (address) {
		return address(
			new UniswapV3FeeCompounder(
				p.name,
				p.symbol,
				IUniswapV3NonfungiblePositionManager(p.positionManager),
				IERC20(p.token0),
				IERC20(p.token1),
				uint24(p.feeOrTickSpacing),
				p.perfFeeBps,
				p.treasury,
				factory,
				ICompounderRoles(factory)
			)
		);
	}
}

/// @title SlipstreamCompounderDeployer
/// @notice Creates SlipstreamFeeCompounder vaults for the factory (owner = roles = factory), on
///         whichever Slipstream deployment's position manager the factory passes.
contract SlipstreamCompounderDeployer is CompounderDeployerBase {
	function deploy(VaultParams memory p) external onlyFactory returns (address) {
		return address(
			new SlipstreamFeeCompounder(
				p.name,
				p.symbol,
				ISlipstreamNonfungiblePositionManager(p.positionManager),
				IERC20(p.token0),
				IERC20(p.token1),
				p.feeOrTickSpacing,
				p.perfFeeBps,
				p.treasury,
				factory,
				ICompounderRoles(factory)
			)
		);
	}
}
