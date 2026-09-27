// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IUniswapV3NonfungiblePositionManager as INpm} from '../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {TwapListingRegistry} from '../src/pricing/TwapListingRegistry.sol';
import {TwapFloorLens} from '../src/pricing/TwapFloorLens.sol';

/// @notice The lens against the LIVE Veranta-testnet registry (Veranta's devnet — a Base fork
///         that keeps chain id 8453; real pools, real adapters): for every listed asset, poking
///         changes the clock exactly when the lens named it, and afterwards the lens has nothing
///         left to say. Then the real tMEME/USDC pool goes through a full thin → recover cycle.
///         Run: VERANTA_DEVNET_RPC_URL=https://devnet-rpc.veranta.xyz forge test --match-path test/TwapFloorLensFork.t.sol
contract TwapFloorLensForkTest is Test {
	TwapListingRegistry internal constant VT_REGISTRY = TwapListingRegistry(0xDD19b0d0f37E3893F5564C3559c35B1033e00Aa0);
	INpm internal constant UNI_NPM = INpm(0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1);
	// DeployTmemeDemoPool's position: the tMEME/USDC 0.3% pool's liquidity, owned by the VT deployer
	address internal constant TMEME = 0x20495fe07aFcBc431230e4DdaF4D473E6e2eB4F2;
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	uint256 internal constant TMEME_POSITION = 5_777_057;
	address internal constant TMEME_LP = 0xeA5A24A5D97C924921e1dD2a32a21840F6e9070a;

	bool internal forked;

	function setUp() public {
		string memory rpc = vm.envOr('VERANTA_DEVNET_RPC_URL', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc);
		forked = true;
	}

	function _since(address asset) internal view returns (uint64 since) {
		(,,,, since) = VT_REGISTRY.listings(asset);
	}

	function test_fork_lensAgreesWithPokeFloor_onTheLiveRegistry() public {
		vm.skip(!forked);
		TwapFloorLens lens = new TwapFloorLens();
		address[] memory assets = VT_REGISTRY.getListedAssets();
		assertGt(assets.length, 0, 'the VT registry lists assets');
		address[] memory due = lens.assetsNeedingPoke(VT_REGISTRY);

		for (uint256 i; i < assets.length; ++i) {
			bool named;
			for (uint256 j; j < due.length; ++j) {
				if (due[j] == assets[i]) named = true;
			}
			uint64 before = _since(assets[i]);
			VT_REGISTRY.pokeFloor(assets[i]);
			bool changed = (before == 0) != (_since(assets[i]) == 0);
			assertEq(named, changed, 'lens and pokeFloor disagree on a live listing');
		}
		assertEq(lens.assetsNeedingPoke(VT_REGISTRY).length, 0);
	}

	function _named(address[] memory due, address asset) internal pure returns (bool) {
		for (uint256 j; j < due.length; ++j) {
			if (due[j] == asset) return true;
		}
		return false;
	}

	/// the live cycle the keeper workflow automates: the LP pulls out → the lens names tMEME →
	/// the poke starts the clock → the LP comes back → the lens names it again → the poke clears
	function test_fork_tmemeThinAndRecover_lensDrivesTheClock() public {
		vm.skip(!forked);
		TwapFloorLens lens = new TwapFloorLens();
		// settle whatever the live chain has pending, so only this test's moves show up
		address[] memory pending = lens.assetsNeedingPoke(VT_REGISTRY);
		for (uint256 i; i < pending.length; ++i) {
			VT_REGISTRY.pokeFloor(pending[i]);
		}
		assertEq(_since(TMEME), 0, 'tMEME starts over the floor');

		(,,,,,,, uint128 liquidity,,,,) = UNI_NPM.positions(TMEME_POSITION);
		vm.startPrank(TMEME_LP);
		UNI_NPM.decreaseLiquidity(INpm.DecreaseLiquidityParams(TMEME_POSITION, liquidity, 0, 0, block.timestamp));
		(uint256 amount0, uint256 amount1) =
			UNI_NPM.collect(INpm.CollectParams(TMEME_POSITION, TMEME_LP, type(uint128).max, type(uint128).max));
		vm.stopPrank();
		// VT's adapter predates M-1: its depth is the 30-min harmonic mean alone, so a pull shows
		// once the window has rolled over (the mainnet adapter also takes the live band depth)
		skip(31 minutes);

		assertTrue(_named(lens.assetsNeedingPoke(VT_REGISTRY), TMEME), 'thinned: the lens names tMEME');
		VT_REGISTRY.pokeFloor(TMEME);
		assertEq(_since(TMEME), block.timestamp, 'the poke started the clock');
		assertFalse(_named(lens.assetsNeedingPoke(VT_REGISTRY), TMEME), 'clock running: nothing to do');

		vm.startPrank(TMEME_LP);
		IERC20(TMEME).approve(address(UNI_NPM), type(uint256).max);
		IERC20(USDC).approve(address(UNI_NPM), type(uint256).max);
		UNI_NPM.increaseLiquidity(INpm.IncreaseLiquidityParams(TMEME_POSITION, amount0, amount1, 0, 0, block.timestamp));
		vm.stopPrank();
		skip(31 minutes);

		assertTrue(_named(lens.assetsNeedingPoke(VT_REGISTRY), TMEME), 'recovered: the lens names tMEME');
		VT_REGISTRY.pokeFloor(TMEME);
		assertEq(_since(TMEME), 0, 'the poke cleared the clock');
		assertEq(lens.assetsNeedingPoke(VT_REGISTRY).length, 0);
	}
}
