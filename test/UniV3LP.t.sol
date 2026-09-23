// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {UniswapV3LPPosition, UniswapV3LPPositionFactory} from '../src/positions/UniswapV3LPPosition.sol';
import {IUniswapV3NonfungiblePositionManager} from
	'../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {TickMath} from '../src/libraries/TickMath.sol';
import {LiquidityAmounts} from '../src/libraries/LiquidityAmounts.sol';
import {MockERC20, MockAggregator, MockUniV3PositionManager} from './utils/Mocks.sol';

contract UniV3LPTest is Test {
	uint256 internal constant LP_TYPE_ID = 3;
	int24 internal constant TICK_LOWER = -887_220;
	int24 internal constant TICK_UPPER = 887_220;
	uint128 internal constant LIQUIDITY = 5e15;

	FundFactory internal factory;
	ValueInterpreter internal interpreter;
	Comptroller internal comptroller;
	MockERC20 internal usdc;
	MockERC20 internal nvdax;
	MockUniV3PositionManager internal positionManager;
	UniswapV3LPPosition internal position;

	address internal admin = makeAddr('admin');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');

	function setUp() public {
		vm.warp(30 days);
		interpreter = new ValueInterpreter(admin);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		nvdax = new MockERC20('NVDA Wrapper', 'NVDAx', 18);
		MockAggregator usdcFeed = new MockAggregator(8, 1e8);
		MockAggregator nvdaxFeed = new MockAggregator(8, 180e8);
		vm.startPrank(admin);
		interpreter.addPrimitive(address(usdc), address(usdcFeed), 7 days);
		interpreter.addPrimitive(address(nvdax), address(nvdaxFeed), 7 days);
		vm.stopPrank();

		factory = new FundFactory(interpreter, new ComptrollerDeployer(), new SharesVaultDeployer());
		positionManager = new MockUniV3PositionManager();
		factory.registerPositionType(
			LP_TYPE_ID,
			address(
				new UniswapV3LPPositionFactory(IUniswapV3NonfungiblePositionManager(address(positionManager)))
			)
		);

		comptroller = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Permafrost LP',
					symbol: 'frPLP',
					denominationAsset: IERC20(address(usdc)),
					fundOwner: manager,
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: 0,
					sharesActionTimelock: 0,
					minRequestDuration: 30 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				})
			)
		);

		usdc.mint(alice, 10_000e6);
		vm.startPrank(alice);
		usdc.approve(address(comptroller), 10_000e6);
		comptroller.requestDeposit(10_000e6);
		vm.stopPrank();
		skip(30 minutes);
		comptroller.executeDepositRequest(alice);

		vm.prank(manager);
		comptroller.addTrackedAsset(address(nvdax));
		nvdax.mint(address(comptroller.vault()), 20e18);

		vm.prank(manager);
		position = UniswapV3LPPosition(
			comptroller.createExternalPosition(LP_TYPE_ID, abi.encode(address(usdc), address(nvdax), uint24(500)))
		);
	}

	function _mintPosition(uint256 amount0, uint256 amount1) internal {
		positionManager.setNextLiquidity(LIQUIDITY);
		address[] memory assets = new address[](2);
		assets[0] = address(usdc);
		assets[1] = address(nvdax);
		uint256[] memory amounts = new uint256[](2);
		amounts[0] = amount0;
		amounts[1] = amount1;

		vm.prank(manager);
		comptroller.callOnExternalPosition(
			address(position),
			assets,
			amounts,
			new address[](0),
			abi.encode(
				uint8(UniswapV3LPPosition.Action.Mint),
				abi.encode(TICK_LOWER, TICK_UPPER, amount0, amount1, uint256(0), uint256(0))
			)
		);
	}

	function _action(UniswapV3LPPosition.Action action, bytes memory args) internal {
		vm.prank(manager);
		comptroller.callOnExternalPosition(
			address(position), new address[](0), new uint256[](0), new address[](0), abi.encode(uint8(action), args)
		);
	}

	function test_mintValueAndFeeKeying() public {
		assertEq(comptroller.calcGav(), 13_600e6);
		_mintPosition(1800e6, 10e18);

		// Fee key recorded by the canonical manager
		(,,,, uint24 fee,,,,,,,) = positionManager.positions(position.tokenId());
		assertEq(fee, 500);

		// Same fair-value identity as the Slipstream twin: value only from oracle rates
		uint256 ratioX96 = (uint256(1e18) * 2 ** 96 / uint256(180e18)) * 1e18 / 1e6;
		uint256 sqrtPrice = ratioX96 <= type(uint256).max >> 64
			? Math_sqrt(ratioX96 << 64) << 16
			: Math_sqrt(ratioX96) << 48;
		(uint256 expected0, uint256 expected1) = LiquidityAmounts.getAmountsForLiquidity(
			uint160(sqrtPrice),
			TickMath.getSqrtRatioAtTick(TICK_LOWER),
			TickMath.getSqrtRatioAtTick(TICK_UPPER),
			LIQUIDITY
		);
		uint256 positionValue = expected0 + (expected1 * 180e6) / 1e18;
		assertEq(comptroller.calcGav(), 13_600e6 - 1800e6 - 1800e6 + positionValue);
	}

	function test_feesCollect_windDown() public {
		_mintPosition(1800e6, 10e18);
		uint256 gavBefore = comptroller.calcGav();

		// Fees accrue (100% to the LP on Uniswap — no unstaked-fee skim here).
		// Fund the mock pool with the fee inventory (in reality swappers paid it in).
		usdc.mint(address(positionManager), 45e6);
		nvdax.mint(address(positionManager), 0.25e18);
		positionManager.addOwedFees(position.tokenId(), 45e6, 0.25e18);
		assertEq(comptroller.calcGav(), gavBefore + 45e6 + 45e6);

		_action(UniswapV3LPPosition.Action.Collect, '');
		assertEq(comptroller.calcGav(), gavBefore + 45e6 + 45e6); // value moved, not created

		// Wind down: decrease all → collect principal → burn → dust removal
		positionManager.setNextDecreaseAmounts(1800e6, 10e18);
		_action(UniswapV3LPPosition.Action.DecreaseLiquidity, abi.encode(LIQUIDITY, uint256(0), uint256(0)));
		_action(UniswapV3LPPosition.Action.Collect, '');
		_action(UniswapV3LPPosition.Action.Burn, '');
		assertEq(position.tokenId(), 0);

		vm.prank(manager);
		comptroller.removeExternalPosition(address(position));
		assertEq(comptroller.getExternalPositions().length, 0);
	}

	function Math_sqrt(uint256 x) internal pure returns (uint256) {
		if (x == 0) return 0;
		uint256 z = (x + 1) / 2;
		uint256 y = x;
		while (z < y) {
			y = z;
			z = (x / z + z) / 2;
		}
		return y;
	}
}
