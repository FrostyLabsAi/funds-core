// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IFrostyClmVault, IFrostyClmStrategy} from '../../src/interfaces/external/IFrostyClm.sol';
import {ClmFixture, MockClmVi} from './utils/ClmFixture.sol';

/// @notice The funds-yield CLM deploys from ../funds-yield/out on a Base fork and takes a deposit.
///         Run: (cd ../funds-yield && forge build) && BASE_MAINNET_RPC=<archive> forge test --match-contract ClmFixtureFork
contract ClmFixtureForkTest is ClmFixture {
	bool internal ready;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0 || !_clmReady()) return;
		vm.createSelectFork(rpc, 52_385_115);
		ready = true;
	}

	function test_fixture_deploysTheRealVaultAndTakesADeposit() public {
		vm.skip(!ready);
		(address strategyFactory, address poolDeployer) = _deployClm(makeAddr('keeper'), address(new MockClmVi()));
		(address vault, address strategy) = _deployCbBtcVault(poolDeployer);
		assertEq(IFrostyClmStrategy(strategy).factory(), strategyFactory);
		assertEq(IFrostyClmStrategy(strategy).vault(), vault);
		assertEq(IFrostyClmStrategy(strategy).compoundToken(), USDC);
		(, address s1Strategy) = _deployWethCbLtcVault(poolDeployer);
		assertEq(IFrostyClmStrategy(s1Strategy).compoundToken(), WETH, 'a Slipstream-1 pair without USDC deploys too');

		deal(USDC, address(this), 10_000e6);
		_buyCbBtc(address(this), 0.1e8);
		_settle(strategy);
		IERC20(USDC).approve(vault, type(uint256).max);
		IERC20(CBBTC).approve(vault, type(uint256).max);
		IFrostyClmVault(vault).deposit(5_000e6, 0.1e8, 0);
		assertGt(IFrostyClmVault(vault).balanceOf(address(this)), 0);
	}
}
