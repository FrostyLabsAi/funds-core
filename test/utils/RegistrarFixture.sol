// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {V4PriceSampler} from '../../src/pricing/V4PriceSampler.sol';
import {IValueInterpreterAdmin} from '../../src/interfaces/IValueInterpreterAdmin.sol';
import {IV4StateView} from '../../src/interfaces/external/IUniswapV4.sol';
import {MockSlipstreamFactory} from './PoolPriceMocks.sol';
import {MockStateView} from './V4Mocks.sol';

/// @notice Builds the PoolPriceRegistrar for suites that price tokens from v3, Slipstream and Aerodrome pools: the given
///         venue mocks, plus stand-ins for the parts they don't use (an Aero CL factory, Uniswap v4's StateView,
///         PoolManager and sampler, WETH). A suite that tests v4 or Aero builds the registrar itself.
library RegistrarFixture {
	address internal constant POOL_MANAGER = address(0xB0B);
	address internal constant WETH = address(0xE7E);

	function deploy(
		address valueInterpreter,
		address uniswapV3Factory,
		address[3] memory slipstreamFactories,
		address aerodromeBasicFactory,
		address[] memory quotes,
		address owner
	) internal returns (PoolPriceRegistrar) {
		IV4StateView stateView = IV4StateView(address(new MockStateView()));
		return new PoolPriceRegistrar(
			PoolPriceRegistrar.Wiring({
				valueInterpreter: IValueInterpreterAdmin(valueInterpreter),
				uniswapV3Factory: uniswapV3Factory,
				slipstreamFactories: slipstreamFactories,
				aerodromeBasicFactory: aerodromeBasicFactory,
				aeroFactory: address(new MockSlipstreamFactory()),
				stateView: stateView,
				poolManager: POOL_MANAGER,
				sampler: new V4PriceSampler(stateView, owner),
				weth: WETH,
				quotes: quotes
			}),
			owner
		);
	}
}
