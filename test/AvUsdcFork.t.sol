// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {FundHost} from './utils/FundHost.sol';
import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {SharesVaultDeployer} from '../src/core/SharesVaultDeployer.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {ERC4626Adapter} from '../src/adapters/ERC4626Adapter.sol';
import {ERC4626PriceFeed} from '../src/pricing/ERC4626PriceFeed.sol';
import {ERC4626ExitValueFeed} from '../src/pricing/ERC4626ExitValueFeed.sol';

/// @notice Veranta's LP vault (avUSDC) held by a fund, on a Base mainnet fork: the REAL
///         vault, its REAL 1.5% withdrawal fee. Proves the exit-value mark: what NAV says the
///         avUSDC is worth is exactly what redeeming it pays, so no investor is paid a value
///         the vault never honours.
///         Run: BASE_MAINNET_RPC=<url> [BASE_FORK_BLOCK=<n>] forge test --match-path test/AvUsdcFork.t.sol
contract AvUsdcForkTest is Test {
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant CHAINLINK_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
	address internal constant AV_USDC = 0x944766f715b51967E56aFdE5f0Aa76cEaCc9E7f9; // tx-builder /v2/meta tranche

	Comptroller internal comptroller;
	ERC4626Adapter internal adapter;
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');
	bool internal forked;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		uint256 blockNumber = vm.envOr('BASE_FORK_BLOCK', uint256(0));
		if (blockNumber > 0) vm.createSelectFork(rpc, blockNumber);
		else vm.createSelectFork(rpc, 53_390_931); // pinned: live state moves under a fork at the latest block (2026-11-01)
		forked = true;

		ValueInterpreter interpreter = new ValueInterpreter(address(this));
		interpreter.addPrimitive(USDC, CHAINLINK_USDC_USD, 2 days);
		interpreter.addDerivative(AV_USDC, address(new ERC4626ExitValueFeed()));

		FundFactory factory = new FundFactory(interpreter, FundHost.deployer(), new SharesVaultDeployer());
		adapter = new ERC4626Adapter();
		factory.registerAdapter(address(adapter));
		comptroller = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'avUSDC Fork Fund',
					symbol: 'frAV',
					denominationAsset: IERC20(USDC),
					fundOwner: manager,
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: 0,
					sharesActionTimelock: 0,
					minRequestDuration: 1 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				})
			)
		);

		deal(USDC, alice, 10_000e6);
		vm.startPrank(alice);
		IERC20(USDC).approve(address(comptroller), 10_000e6);
		comptroller.requestDeposit(10_000e6, type(uint256).max);
		vm.stopPrank();
		skip(1 minutes);
		comptroller.executeDepositRequest(alice);
	}

	function _deposit(uint256 assets) internal returns (uint256 shares) {
		uint256 before = IERC20(AV_USDC).balanceOf(address(comptroller.vault()));
		vm.prank(manager);
		comptroller.callOnIntegration(address(adapter), abi.encode(uint8(0), AV_USDC, assets, uint256(0)));
		shares = IERC20(AV_USDC).balanceOf(address(comptroller.vault())) - before;
	}

	function test_fork_depositMarksAtExitValue() public {
		vm.skip(!forked);
		assertEq(comptroller.calcGav(), 10_000e6);
		uint256 shares = _deposit(5_000e6);
		assertGt(shares, 0);

		uint256 exitValue = IERC4626(AV_USDC).previewRedeem(shares);
		// the fund holds 5,000 cash + the avUSDC at what redeeming it pays
		assertEq(comptroller.calcGav(), 5_000e6 + exitValue);
		// the live withdrawal fee (1.5% on 2026-09-24) shows in NAV from the deposit on
		uint256 feeBps = ((5_000e6 - exitValue) * 10_000) / 5_000e6;
		emit log_named_uint('avUSDC exit fee on deposit, bps', feeBps);
		assertGe(feeBps, 140);
		assertLe(feeBps, 160);
	}

	function test_fork_redeemPaysExactlyWhatNavSaid() public {
		vm.skip(!forked);
		uint256 shares = _deposit(5_000e6);
		uint256 gavBefore = comptroller.calcGav();
		uint256 cashBefore = IERC20(USDC).balanceOf(address(comptroller.vault()));

		vm.prank(manager);
		comptroller.callOnIntegration(address(adapter), abi.encode(uint8(1), AV_USDC, shares, uint256(0)));

		uint256 received = IERC20(USDC).balanceOf(address(comptroller.vault())) - cashBefore;
		assertEq(IERC20(AV_USDC).balanceOf(address(comptroller.vault())), 0);
		// exit value == what the vault paid: redeeming moves NAV by nothing
		assertEq(comptroller.calcGav(), gavBefore);
		assertEq(received, gavBefore - cashBefore);
	}

	/// Why the generic feed is wrong for this vault: it marks the fee-free value, so NAV
	/// would drop by the fee the moment the fund actually leaves — paid by whoever stays.
	function test_fork_genericFeedWouldOverstateByTheFee() public {
		vm.skip(!forked);
		uint256 shares = _deposit(5_000e6);
		(, uint256[] memory generic) = new ERC4626PriceFeed().calcUnderlyingValues(AV_USDC, shares);
		uint256 exitValue = IERC4626(AV_USDC).previewRedeem(shares);
		assertGt(generic[0], exitValue);
		assertApproxEqRel(generic[0] - exitValue, (generic[0] * 150) / 10_000, 0.05e18); // ≈1.5% of the mark
	}
}
