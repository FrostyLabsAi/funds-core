// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {
	ComptrollerDeployer, ComptrollerBlueprintDeployer, SharesVaultDeployer
} from '../src/core/FundComponentDeployers.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {IValueInterpreter} from '../src/interfaces/IValueInterpreter.sol';
import {IComptrollerDeployer} from '../src/interfaces/IComptrollerDeployer.sol';
import {Shares} from '../src/fund/Shares.sol';
import {Vault} from '../src/fund/Vault.sol';
import {IPolicy} from '../src/interfaces/IPolicy.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';

/// @dev Stand-in for a fixed Comptroller build: the real Comptroller plus new code. Bigger than
///      the embedding ComptrollerDeployer can carry (5 bytes of EIP-170 headroom), so it can only
///      ship through the blueprint path — which is the point being proven.
contract FixedComptroller is Comptroller {
	constructor(
		address factory_,
		address fundOwner_,
		IERC20 denominationAsset_,
		IValueInterpreter valueInterpreter_,
		FeeConfig memory feeConfig_,
		uint256 sharesActionTimelock_,
		uint256 minRequestDuration_,
		uint256 executionWindow_,
		bool allowRiskyAssets_
	)
		Comptroller(
			factory_,
			fundOwner_,
			denominationAsset_,
			valueInterpreter_,
			feeConfig_,
			sharesActionTimelock_,
			minRequestDuration_,
			executionWindow_,
			allowRiskyAssets_
		)
	{}

	function fixVersion() external pure returns (uint256) {
		return 2;
	}
}

/// @notice The Comptroller fix path end to end: governance points the factory at a fixed build
///         (blueprint deployer), and a LIVE fund with holders moves onto it only when its owner
///         reconfigures — holders, vault, HWM and ruleset carried, nothing forced.
contract ComptrollerFixPathTest is Test {
	FundFactory internal factory;
	ValueInterpreter internal interpreter;
	MockERC20 internal usdc;
	MockAggregator internal usdcFeed;
	Comptroller internal liveFund;

	address internal admin = makeAddr('admin');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');
	address internal guardian = makeAddr('guardian');

	event ComptrollerDeployerSet(address indexed deployer);

	function setUp() public {
		vm.warp(30 days);
		interpreter = new ValueInterpreter(admin);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		usdcFeed = new MockAggregator(8, 1e8);
		vm.prank(admin);
		interpreter.addPrimitive(address(usdc), address(usdcFeed), 7 days);

		factory = new FundFactory(interpreter, new ComptrollerDeployer(), new SharesVaultDeployer());
		factory.setGuardian(guardian);
		liveFund = Comptroller(factory.createFund(_config('Frosty Alpha', 0)));

		usdc.mint(alice, 10_000e6);
		vm.startPrank(alice);
		usdc.approve(address(liveFund), 10_000e6);
		liveFund.requestDeposit(10_000e6);
		vm.stopPrank();
		skip(30 minutes);
		liveFund.executeDepositRequest(alice);
	}

	function _config(string memory name, uint16 perfBps) internal view returns (FundFactory.FundConfig memory) {
		return FundFactory.FundConfig({
			name: name,
			symbol: 'frFIX',
			denominationAsset: IERC20(address(usdc)),
			fundOwner: manager,
			mgmtScaledPerSecondRate: 0,
			perfFeeBps: perfBps,
			sharesActionTimelock: 0,
			minRequestDuration: 30 minutes,
			executionWindow: 1 days,
			allowRiskyAssets: false
		});
	}

	function _blueprint() internal returns (ComptrollerBlueprintDeployer) {
		return new ComptrollerBlueprintDeployer(type(FixedComptroller).creationCode);
	}

	function _reconfigure() internal returns (address newComptroller) {
		vm.prank(manager);
		newComptroller = factory.createReconfigurationRequest(address(liveFund), _config('Frosty Alpha', 0));
		skip(2 days);
		usdcFeed.setAnswer(1e8); // fresh round for the handover fee settlement
		vm.prank(manager);
		factory.executeReconfiguration(address(liveFund));
	}

	function _isFixed(address comptroller) internal view returns (bool) {
		(bool ok, bytes memory ret) = comptroller.staticcall(abi.encodeCall(FixedComptroller.fixVersion, ()));
		return ok && ret.length == 32 && abi.decode(ret, (uint256)) == 2;
	}

	function test_fixedBuildOutgrowsTheEmbeddingDeployer() public {
		uint256 growth = type(FixedComptroller).creationCode.length - type(Comptroller).creationCode.length;
		assertGt(address(new ComptrollerDeployer()).code.length + growth, 24_576, 'would fit the old deployer');
	}

	function test_blueprintStoresTheBuildByteForByte() public {
		ComptrollerBlueprintDeployer blueprint = _blueprint();
		bytes memory build = type(FixedComptroller).creationCode;
		assertEq(blueprint.initcode(), build);
		assertEq(blueprint.initcodeHash(), keccak256(build));
		assertEq(blueprint.initcodeLength(), build.length);
		assertEq(blueprint.chunkCount(), (build.length + 23_999) / 24_000); // > 24,000 bytes → split
		assertGt(blueprint.chunkCount(), 1);
	}

	function test_blueprintRejectsEmptyInitcode() public {
		vm.expectRevert(ComptrollerBlueprintDeployer.EmptyInitcode.selector);
		new ComptrollerBlueprintDeployer('');
	}

	function test_onlyTheOwnerMovesTheDeployer() public {
		ComptrollerBlueprintDeployer blueprint = _blueprint();

		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
		factory.setComptrollerDeployer(blueprint);

		vm.expectRevert(FundFactory.ZeroAddress.selector);
		factory.setComptrollerDeployer(IComptrollerDeployer(address(0)));

		vm.expectEmit(true, false, false, false, address(factory));
		emit ComptrollerDeployerSet(address(blueprint));
		factory.setComptrollerDeployer(blueprint);
		assertEq(address(factory.comptrollerDeployer()), address(blueprint));
	}

	function test_fixReachesALiveFundOnlyThroughItsOwner() public {
		factory.setComptrollerDeployer(_blueprint());
		Shares shares = liveFund.shares();
		Vault vault = liveFund.vault();
		uint256 aliceShares = shares.balanceOf(alice);
		uint256 hwm = liveFund.highWaterMark();

		// Setting the deployer changes NOTHING on the live fund
		assertFalse(_isFixed(address(liveFund)));
		assertEq(shares.comptroller(), address(liveFund));

		// The owner opts in; the fixed build takes over after the investor window
		address fixedFund = _reconfigure();
		assertTrue(_isFixed(fixedFund));
		assertEq(Comptroller(fixedFund).factory(), address(factory)); // the blueprint passes the factory through
		assertEq(shares.comptroller(), fixedFund);
		assertEq(vault.comptroller(), fixedFund);
		assertEq(address(Comptroller(fixedFund).shares()), address(shares));
		assertEq(address(Comptroller(fixedFund).vault()), address(vault));
		assertEq(shares.balanceOf(alice), aliceShares);
		assertGe(Comptroller(fixedFund).highWaterMark(), hwm);
		assertEq(Comptroller(fixedFund).calcGav(), 10_000e6);
		assertEq(
			Comptroller(fixedFund).getPolicies(IPolicy.PolicyHook.PostCallOnIntegration)[0],
			factory.unrestrictedMandate()
		);

		// It runs: a new deposit and an existing holder's redemption through the fixed build
		address bob = makeAddr('bob');
		usdc.mint(bob, 1000e6);
		vm.startPrank(bob);
		usdc.approve(fixedFund, 1000e6);
		Comptroller(fixedFund).requestDeposit(1000e6);
		vm.stopPrank();
		skip(30 minutes);
		Comptroller(fixedFund).executeDepositRequest(bob);
		assertGt(shares.balanceOf(bob), 0);

		vm.prank(alice);
		Comptroller(fixedFund).redeemSharesForDenominationAsset(1000e18);
		assertEq(usdc.balanceOf(alice), 1000e6);
	}

	/// The runbook sequence: guardian pauses → governance sets the fixed build → the owner
	/// reconfigures WHILE PAUSED → the fixed build starts paused → governance reopens.
	function test_emergencySequence_pauseFixReopen() public {
		vm.prank(guardian);
		factory.pauseFundDeposits(address(liveFund));
		factory.setComptrollerDeployer(_blueprint());

		address fixedFund = _reconfigure();
		assertTrue(_isFixed(fixedFund));
		assertTrue(Comptroller(fixedFund).guardianDepositsPaused(), 'the fix reopened deposits by itself');

		// holders can leave the whole time — the pause only ever blocks new money
		vm.prank(alice);
		Comptroller(fixedFund).redeemSharesForDenominationAsset(500e18);
		assertEq(usdc.balanceOf(alice), 500e6);

		factory.unpauseFundDeposits(fixedFund); // governance (this test = factory owner)
		usdc.mint(alice, 100e6);
		vm.startPrank(alice);
		usdc.approve(fixedFund, 100e6);
		Comptroller(fixedFund).requestDeposit(100e6);
		vm.stopPrank();
		skip(30 minutes);
		Comptroller(fixedFund).executeDepositRequest(alice);
		assertGt(liveFund.shares().balanceOf(alice), 0);
	}

	function test_requestInItsWindowKeepsTheBuildTheOwnerReviewed() public {
		vm.prank(manager);
		address reviewed = factory.createReconfigurationRequest(address(liveFund), _config('Frosty Alpha', 0));

		factory.setComptrollerDeployer(_blueprint()); // governance moves mid-window

		skip(2 days);
		usdcFeed.setAnswer(1e8);
		vm.prank(manager);
		factory.executeReconfiguration(address(liveFund));

		assertEq(liveFund.shares().comptroller(), reviewed);
		assertFalse(_isFixed(reviewed));
	}

	function test_newFundsUseTheFixedBuild() public {
		factory.setComptrollerDeployer(_blueprint());
		address fresh = factory.createFund(_config('Frosty Beta', 1000));
		assertTrue(_isFixed(fresh));
		(, uint16 perfBps) = Comptroller(fresh).feeConfig();
		assertEq(perfBps, 1000); // constructor args reached the build intact

		usdc.mint(alice, 500e6);
		vm.startPrank(alice);
		usdc.approve(fresh, 500e6);
		Comptroller(fresh).requestDeposit(500e6);
		vm.stopPrank();
		skip(30 minutes);
		Comptroller(fresh).executeDepositRequest(alice);
		assertGt(Comptroller(fresh).shares().balanceOf(alice), 0);
	}
}
