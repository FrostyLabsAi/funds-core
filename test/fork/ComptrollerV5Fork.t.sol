// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/FundComponentDeployers.sol';
import {ComptrollerV3} from '../../src/core/ComptrollerV3.sol';
import {ComptrollerV5} from '../../src/core/ComptrollerV5.sol';
import {InKindRedemption} from '../../src/core/InKindRedemption.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {ComptrollerV5Deploy} from '../../script/mainnet/ComptrollerV5Deploy.sol';

/// @notice Rehearsal of script/mainnet/DeployComptrollerV5.s.sol on live Base after the v4 rollout (2026-10-09, block
///         52,385,115): deploy the V5 blueprint deployer on the live registrar V2 and queue as the genesis deployer,
///         point the factory at it (the separate reviewed step), then V5 funds with a real Veranta perp account redeem
///         in kind at the whole value, or revert when the vault can't cover it; a pure-spot V5 fund pays its slice.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/ComptrollerV5Fork.t.sol
contract ComptrollerV5ForkTest is Test {
	uint256 internal constant FORK_BLOCK = 52_385_115;
	address internal constant USDC = FundsMainnet.USDC;

	bool internal forked;
	FundFactory internal factory;
	address internal registrarV2;
	address internal queue;
	ComptrollerBlueprintDeployer internal fundV5Deployer;
	address internal manager = makeAddr('manager');
	address internal investor = makeAddr('investor');

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, FORK_BLOCK);
		forked = true;
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		address deployer = vm.parseJsonAddress(genesis, '.deployer');
		factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		registrarV2 = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-v4.json'), '.registrar');
		queue = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-redemption.json'), '.queue');

		vm.startPrank(deployer);
		fundV5Deployer = ComptrollerV5Deploy.deploy(registrarV2, queue);
		factory.setComptrollerDeployer(fundV5Deployer); // the separate reviewed step
		vm.stopPrank();
	}

	/// A real perp account holding 4,000 USDC: a tenth is paid the whole value (its slice of the vault and the
	/// account's share) from the vault's USDC; the account keeps its USDC.
	function test_fork_aV5FundWithARealPerpAccount_paysTheWholeValueInKind() public {
		vm.skip(!forked);
		ComptrollerV3 fund = _fundWithDeposit('V5 perp rehearsal', 10_000e6);
		assertTrue(ComptrollerV5(address(fund)).inKindPaysFullValue(), 'a V5 fund');
		assertEq(address(fund.registrar()), registrarV2, 'priced by registrar V2');
		assertEq(address(fund.redemptionQueue()), queue, 'bound to the live queue');
		address account = _perpAccountHolding(fund, 4_000e6);

		uint256 tenth = fund.shares().balanceOf(investor) / 10;
		uint256 supply = fund.shares().totalSupply();
		vm.prank(investor);
		fund.redeemSharesInKind(tenth);
		assertEq(IERC20(USDC).balanceOf(investor), 14_000e6 * tenth / supply, 'a tenth of the vault and the account');
		assertEq(IERC20(USDC).balanceOf(account), 4_000e6, 'the perp account untouched');
	}

	/// The account holds most of the value and the vault can't pay the account's share: the exit reverts and the
	/// investor keeps every share (the queue is then the exit).
	function test_fork_whatTheVaultCantCover_reverts_theSharesStay() public {
		vm.skip(!forked);
		ComptrollerV3 fund = _fundWithDeposit('V5 thin vault', 1_000e6);
		_perpAccountHolding(fund, 9_000e6);
		uint256 half = fund.shares().balanceOf(investor) / 2;
		vm.prank(investor);
		vm.expectRevert(InKindRedemption.InKindNotCovered.selector);
		fund.redeemSharesInKind(half);
		assertEq(fund.shares().balanceOf(investor), half * 2);
	}

	function test_fork_aPureSpotV5Fund_paysItsSlice() public {
		vm.skip(!forked);
		ComptrollerV3 fund = _fundWithDeposit('V5 spot rehearsal', 10_000e6);
		uint256 tenth = fund.shares().balanceOf(investor) / 10;
		uint256 supply = fund.shares().totalSupply();
		vm.prank(investor);
		fund.redeemSharesInKind(tenth);
		assertEq(IERC20(USDC).balanceOf(investor), 10_000e6 * tenth / supply);
	}

	function _fundWithDeposit(string memory name, uint256 amount) internal returns (ComptrollerV3 fund) {
		fund = ComptrollerV3(
			factory.createFund(
				FundFactory.FundConfig({
					name: name,
					symbol: 'frV5',
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
		deal(USDC, investor, amount);
		vm.startPrank(investor);
		IERC20(USDC).approve(address(fund), amount);
		fund.requestDeposit(amount, type(uint256).max);
		vm.stopPrank();
		vm.warp(block.timestamp + 1 minutes);
		vm.roll(block.number + 30);
		fund.executeDepositRequest(investor);
	}

	/// A real Veranta perp account (type 6) with `amount` of idle USDC (counted in its value).
	function _perpAccountHolding(ComptrollerV3 fund, uint256 amount) internal returns (address account) {
		vm.prank(manager);
		account = fund.createExternalPosition(FundsMainnet.VERANTA_PERP_TYPE, '');
		deal(USDC, account, amount);
	}
}
