// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ProtectRegistry} from '../src/protect/ProtectRegistry.sol';
import {FrostyCompounder} from '../src/yield/FrostyCompounder.sol';
import {CompounderPriceFeed} from '../src/pricing/CompounderPriceFeed.sol';
import {CompounderAdapter} from '../src/adapters/CompounderAdapter.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {IUniswapV3NonfungiblePositionManager} from '../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';

/// @notice ONE broadcast for the whole retail+parity suite (supersedes DeployProtect and
///         DeployCompounders — separate scripts would collide on nonce predictions):
///         (1) ProtectRegistry v2 — users self-serve, fund MANAGERS configureFor their
///             fund's Veranta position, NEUTRAL slot reserved;
///         (2) fcETH + fcBTC FrostyCompounders (15% perf fee on harvest, treasury=deployer);
///         (3) FUND PARITY rails: CompounderPriceFeed registered as the derivative feed
///             for both compounders (oracle-fair GAV pricing) + CompounderAdapter
///             registered on the FundFactory (funds deposit via callOnIntegration).
/// @dev Env: FACTORY (wave-6 FundFactory). The deployer must own the ValueInterpreter.
contract DeployRetail is Script {
	IUniswapV3NonfungiblePositionManager constant NPM =
		IUniswapV3NonfungiblePositionManager(0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2);
	address constant TUSDC = 0x75F31B7C00E6282CDCFd7B4124d8ab327bE3Ab4D; // token0 (lower address)
	address constant TETH = 0xB949122bF2991edA2d660A2E99f2393ffE74Ae01;
	address constant TBTC = 0x7b78764b39A56F52b0b983C4e279D1F4564Abe39;

	function run() external {
		FundFactory factory = FundFactory(vm.envAddress('FACTORY'));
		ValueInterpreter interpreter = ValueInterpreter(address(factory.valueInterpreter()));

		vm.startBroadcast();

		ProtectRegistry registry = new ProtectRegistry();

		FrostyCompounder eth = new FrostyCompounder(
			'Frosty Compounding tETH-tUSDC', 'fcETH', NPM, IERC20(TUSDC), IERC20(TETH), 3000, 887220, 1500, msg.sender
		);
		FrostyCompounder btc = new FrostyCompounder(
			'Frosty Compounding tBTC-tUSDC', 'fcBTC', NPM, IERC20(TUSDC), IERC20(TBTC), 3000, 887220, 1500, msg.sender
		);

		CompounderPriceFeed feed = new CompounderPriceFeed(interpreter);
		interpreter.addDerivative(address(eth), address(feed));
		interpreter.addDerivative(address(btc), address(feed));

		CompounderAdapter adapter = new CompounderAdapter();
		factory.registerAdapter(address(adapter));

		vm.stopBroadcast();

		console2.log('PROTECT_REGISTRY', address(registry));
		console2.log('PROTECT_START_BLOCK', block.number);
		console2.log('COMPOUNDER_ETH', address(eth));
		console2.log('COMPOUNDER_BTC', address(btc));
		console2.log('COMPOUNDER_FEED', address(feed));
		console2.log('COMPOUNDER_ADAPTER', address(adapter));
	}
}
