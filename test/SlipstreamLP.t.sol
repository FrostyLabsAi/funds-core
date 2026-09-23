// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {SlipstreamLPPosition, SlipstreamLPPositionFactory} from '../src/positions/SlipstreamLPPosition.sol';
import {ISlipstreamNonfungiblePositionManager} from
	'../src/interfaces/external/ISlipstreamNonfungiblePositionManager.sol';
import {TickMath} from '../src/libraries/TickMath.sol';
import {LiquidityAmounts} from '../src/libraries/LiquidityAmounts.sol';
import {MockERC20, MockAggregator, MockPositionManager, MockCLGauge} from './utils/Mocks.sol';

contract SlipstreamLPTest is Test {
	uint256 internal constant LP_TYPE_ID = 2;
	int24 internal constant TICK_LOWER = -887_220;
	int24 internal constant TICK_UPPER = 887_220;
	uint128 internal constant LIQUIDITY = 5e15;

	FundFactory internal factory;
	ValueInterpreter internal interpreter;
	Comptroller internal comptroller;
	MockERC20 internal usdc; // token0, 6 dec, $1
	MockERC20 internal nvdax; // token1, 18 dec, $180
	MockERC20 internal aero; // gauge reward, 18 dec, $1.30
	MockAggregator internal usdcFeed;
	MockAggregator internal nvdaxFeed;
	MockPositionManager internal positionManager;
	MockCLGauge internal gauge;
	SlipstreamLPPosition internal position;

	address internal admin = makeAddr('admin');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');

	function setUp() public {
		vm.warp(30 days);
		interpreter = new ValueInterpreter(admin);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		nvdax = new MockERC20('NVDA Wrapper', 'NVDAx', 18);
		aero = new MockERC20('Aerodrome', 'AERO', 18);
		usdcFeed = new MockAggregator(8, 1e8);
		nvdaxFeed = new MockAggregator(8, 180e8);
		MockAggregator aeroFeed = new MockAggregator(8, 1.3e8);
		vm.startPrank(admin);
		interpreter.addPrimitive(address(usdc), address(usdcFeed), 7 days);
		interpreter.addPrimitive(address(nvdax), address(nvdaxFeed), 7 days);
		interpreter.addPrimitive(address(aero), address(aeroFeed), 7 days);
		vm.stopPrank();

		factory = new FundFactory(interpreter, new ComptrollerDeployer(), new SharesVaultDeployer());
		positionManager = new MockPositionManager();
		gauge = new MockCLGauge(aero);
		factory.registerPositionType(
			LP_TYPE_ID, address(new SlipstreamLPPositionFactory(ISlipstreamNonfungiblePositionManager(address(positionManager))))
		);

		comptroller = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Glacier Delta Neutral',
					symbol: 'frGDN',
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

		// Seed: 10,000 USDC deposit + 20 NVDAx PnL into the vault (tracked)
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

		// Create the LP position (staking enabled)
		vm.prank(manager);
		position = SlipstreamLPPosition(
			comptroller.createExternalPosition(
				LP_TYPE_ID, abi.encode(address(usdc), address(nvdax), int24(100), address(gauge))
			)
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
				uint8(SlipstreamLPPosition.Action.Mint),
				abi.encode(TICK_LOWER, TICK_UPPER, amount0, amount1, uint256(0), uint256(0))
			)
		);
	}

	function _action(SlipstreamLPPosition.Action action, bytes memory args, address[] memory receive_) internal {
		vm.prank(manager);
		comptroller.callOnExternalPosition(
			address(position), new address[](0), new uint256[](0), receive_, abi.encode(uint8(action), args)
		);
	}

	/// @dev Expected principal amounts at the ORACLE-fair sqrt price, mirroring the position's math.
	function _expectedPrincipal() internal view returns (uint256 amount0, uint256 amount1) {
		// rate0/rate1 in 1e18 USD; ratioX96 = rate0/rate1 * 2^96 * scale1/scale0
		uint256 ratioX96 = (uint256(1e18) * 2 ** 96 / uint256(180e18)) * 1e18 / 1e6;
		uint256 sqrtPrice = ratioX96 <= type(uint256).max >> 64
			? Math_sqrt(ratioX96 << 64) << 16
			: Math_sqrt(ratioX96) << 48;
		(amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
			uint160(sqrtPrice),
			TickMath.getSqrtRatioAtTick(TICK_LOWER),
			TickMath.getSqrtRatioAtTick(TICK_UPPER),
			LIQUIDITY
		);
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

	// ─── Fair-value pricing ──────────────────────────────────────────────────────

	function test_positionValuedAtOracleFairPrice_notPoolState() public {
		uint256 gavBefore = comptroller.calcGav(); // 10,000 USDC + 20 NVDAx * 180 = 13,600e6
		assertEq(gavBefore, 13_600e6);

		_mintPosition(1800e6, 10e18);

		// Vault paid out 1800 USDC + 10 NVDAx; position re-valued at the SAME oracle prices
		(uint256 expected0, uint256 expected1) = _expectedPrincipal();
		uint256 positionValue = expected0 + (expected1 * 180e6) / 1e18;
		assertEq(comptroller.calcGav(), 13_600e6 - 1800e6 - 1800e6 + positionValue);

		// Only ORACLE prices move the valuation. NVDAx +10%:
		nvdaxFeed.setAnswer(198e8);
		uint256 gavAfterPump = comptroller.calcGav();
		assertGt(gavAfterPump, comptroller.defaultSharePrice()); // sanity: GAV recomputed, no revert
		// (There is no pool state in this valuation to manipulate — liquidity/ticks are the
		//  position's own, prices are the oracle's. That is the whole design.)
	}

	function test_uncollectedFeesAndIdleBalances_countInGav() public {
		_mintPosition(1800e6, 10e18);
		uint256 gavBefore = comptroller.calcGav();

		// Pool fees accrue as tokensOwed: +90 USDC +0.5 NVDAx (= 90 + 90 = 180 USDC of value)
		positionManager.addOwedFees(position.tokenId(), 90e6, 0.5e18);
		assertEq(comptroller.calcGav(), gavBefore + 90e6 + 90e6);

		// Collect sends them STRAIGHT to the vault; GAV unchanged through the move
		uint256 vaultUsdcBefore = usdc.balanceOf(address(comptroller.vault()));
		_action(SlipstreamLPPosition.Action.Collect, '', new address[](0));
		assertEq(usdc.balanceOf(address(comptroller.vault())), vaultUsdcBefore + 90e6);
		assertEq(comptroller.calcGav(), gavBefore + 90e6 + 90e6);
	}

	// ─── Dual mode: stake / claim / unstake ──────────────────────────────────────

	function test_stakedMode_aeroRewardsFlowToVault() public {
		_mintPosition(1800e6, 10e18);
		uint256 gavBefore = comptroller.calcGav();

		_action(SlipstreamLPPosition.Action.Stake, '', new address[](0));
		assertTrue(position.staked());
		assertTrue(gauge.isDeposited(position.tokenId()));

		// Principal still valued while staked
		assertEq(comptroller.calcGav(), gavBefore);

		// Collect is fee-mode machinery — blocked while staked
		vm.prank(manager);
		vm.expectRevert(SlipstreamLPPosition.PositionIsStaked.selector);
		comptroller.callOnExternalPosition(
			address(position),
			new address[](0),
			new uint256[](0),
			new address[](0),
			abi.encode(uint8(SlipstreamLPPosition.Action.Collect), '')
		);

		// Claim 100 AERO → straight to vault, tracked via assetsToReceive, priced at $1.30
		gauge.setNextReward(100e18);
		address[] memory receiveAero = new address[](1);
		receiveAero[0] = address(aero);
		_action(SlipstreamLPPosition.Action.ClaimRewards, '', receiveAero);

		assertEq(aero.balanceOf(address(comptroller.vault())), 100e18);
		assertEq(comptroller.calcGav(), gavBefore + 130e6);

		_action(SlipstreamLPPosition.Action.Unstake, '', new address[](0));
		assertFalse(position.staked());
	}

	// ─── Wind-down: decrease → collect → burn → dust removal ────────────────────

	function test_fullWindDown_toDustRemoval() public {
		_mintPosition(1800e6, 10e18);

		// Decrease all liquidity; principal becomes tokensOwed (mock: 1800 USDC + 10 NVDAx)
		positionManager.setNextDecreaseAmounts(1800e6, 10e18);
		_action(
			SlipstreamLPPosition.Action.DecreaseLiquidity,
			abi.encode(LIQUIDITY, uint256(0), uint256(0)),
			new address[](0)
		);

		_action(SlipstreamLPPosition.Action.Collect, '', new address[](0));
		_action(SlipstreamLPPosition.Action.Burn, '', new address[](0));
		assertEq(position.tokenId(), 0);

		// Everything is home: GAV = original 13,600
		assertEq(comptroller.calcGav(), 13_600e6);

		// Position is dust now → removable
		vm.prank(manager);
		comptroller.removeExternalPosition(address(position));
		assertEq(comptroller.getExternalPositions().length, 0);
	}

	function test_positionAuth_onlyComptroller() public {
		vm.prank(manager);
		vm.expectRevert(SlipstreamLPPosition.OnlyComptroller.selector);
		position.receiveCallFromFund(abi.encode(uint8(SlipstreamLPPosition.Action.Collect), ''));
	}
}
