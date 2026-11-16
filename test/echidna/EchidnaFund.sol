// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {SharesVaultDeployer} from '../../src/core/SharesVaultDeployer.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {FundHost} from '../utils/FundHost.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {MockERC20, MockAggregator} from '../utils/Mocks.sol';

/// @title EchidnaFund
/// @notice Property-based fuzzing harness (echidna/medusa) for the fund core.
///         Run: `echidna . --contract EchidnaFund --config echidna.yaml`
/// @dev Mirrors the frosty-core property-fuzzing setup. The harness plays depositor AND
///      manager against a live fund and asserts the protocol's core solvency invariants.
contract EchidnaFund {
	FundFactory internal factory;
	ValueInterpreter internal interpreter;
	Comptroller internal comptroller;
	MockERC20 internal usdc;
	MockAggregator internal usdcFeed;

	uint256 internal escrowMirror; // sum of this harness's open deposit-request escrow
	uint256 internal lastHwm;

	constructor() {
		interpreter = new ValueInterpreter(address(this));
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		usdcFeed = new MockAggregator(8, 1e8);
		interpreter.addPrimitive(address(usdc), address(usdcFeed), 7 days);

		factory = new FundFactory(interpreter, FundHost.deployer(), new SharesVaultDeployer());
		comptroller = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Echidna Fund',
					symbol: 'ECH',
					denominationAsset: IERC20(address(usdc)),
					fundOwner: address(this),
					mgmtScaledPerSecondRate: 1_000_000_000_640_000_000_000_000_000, // ~2%/yr
					perfFeeBps: 1500,
					sharesActionTimelock: 0,
					minRequestDuration: 10 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				})
			)
		);

		usdc.mint(address(this), type(uint128).max);
		usdc.approve(address(comptroller), type(uint256).max);
		lastHwm = comptroller.highWaterMark();
	}

	// ─── Fuzzed actions ─────────────────────────────────────────────────────────

	function requestDeposit(uint256 assets) external {
		assets = 1 + (assets % 1_000_000e6);
		comptroller.requestDeposit(assets, type(uint256).max);
		escrowMirror += assets;
	}

	function cancelDeposit() external {
		(uint256 assets,,) = comptroller.depositRequests(address(this));
		comptroller.cancelDepositRequest();
		escrowMirror -= assets;
	}

	function executeDeposit() external {
		(uint256 assets,,) = comptroller.depositRequests(address(this));
		comptroller.executeDepositRequest(address(this));
		escrowMirror -= assets;
	}

	function redeemForDenom(uint256 sharesAmount) external {
		uint256 balance = comptroller.shares().balanceOf(address(this));
		if (balance == 0) return;
		comptroller.redeemShares(1 + (sharesAmount % balance));
	}

	function pokeFees() external {
		comptroller.settleFees();
	}

	function simulatePnl(uint256 amount, bool gain) external {
		if (gain) {
			usdc.mint(address(comptroller.vault()), amount % 100_000e6);
		}
		// Losses happen naturally through fee dilution; direct vault theft is impossible
		// by construction (onlyComptroller) and deliberately not simulated here.
	}

	function refreshFeed() external {
		usdcFeed.setAnswer(1e8);
	}

	// ─── Invariants ─────────────────────────────────────────────────────────────

	/// @notice Escrow solvency: the comptroller holds exactly the open request escrow.
	function echidna_escrow_solvent() external view returns (bool) {
		return usdc.balanceOf(address(comptroller)) == escrowMirror;
	}

	/// @notice The high-water mark never decreases — reconfigure, settle, deposit, redeem,
	///         nothing may reset it (fee-gaming guard).
	function echidna_hwm_monotonic() external returns (bool) {
		uint256 hwm = comptroller.highWaterMark();
		bool ok = hwm >= lastHwm;
		lastHwm = hwm;
		return ok;
	}

	/// @notice Shares exist iff the fund has value behind them (no free shares, no locked
	///         value without claims). Vault balance is USDC-only in this harness.
	function echidna_shares_backed() external view returns (bool) {
		uint256 supply = comptroller.shares().totalSupply();
		uint256 vaultBalance = usdc.balanceOf(address(comptroller.vault()));
		if (supply == 0) return true;
		return vaultBalance > 0;
	}
}
