// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {IPolicy} from '../src/interfaces/IPolicy.sol';
import {AllowedExternalPositionTypesPolicy} from '../src/policies/AllowedExternalPositionTypesPolicy.sol';
import {MockERC20, MockAggregator, MockExternalPosition, MockExternalPositionFactory} from './utils/Mocks.sol';

/// @notice The GENERIC external-position machinery: type-registry gating, guardian
///         deregistration, fund-owner auth, and the allowed-types policy. Venue-agnostic
///         on purpose — these rode on HyperliquidPerpPosition until the HL path was
///         removed (2026-09-18); per-venue behaviour lives in VerantaPerp.t.sol,
///         UniV3LP.t.sol, SlipstreamLP.t.sol and LimitOrder.t.sol.
contract ExternalPositionsTest is Test {
	uint256 internal constant TYPE_ID = 1;

	FundFactory internal factory;
	ValueInterpreter internal interpreter;
	Comptroller internal comptroller;
	MockERC20 internal usdc;
	MockExternalPositionFactory internal positionFactory;

	address internal admin = makeAddr('admin');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');

	function setUp() public {
		vm.warp(30 days);
		interpreter = new ValueInterpreter(admin);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		MockAggregator usdcFeed = new MockAggregator(8, 1e8);
		vm.prank(admin);
		interpreter.addPrimitive(address(usdc), address(usdcFeed), 7 days);

		factory = new FundFactory(interpreter, new ComptrollerDeployer(), new SharesVaultDeployer()); // this test = factory owner
		positionFactory = new MockExternalPositionFactory();
		factory.registerPositionType(TYPE_ID, address(positionFactory));

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

		// Seed: 10,000 USDC
		usdc.mint(alice, 10_000e6);
		vm.startPrank(alice);
		usdc.approve(address(comptroller), 10_000e6);
		comptroller.requestDeposit(10_000e6);
		vm.stopPrank();
		skip(30 minutes);
		comptroller.executeDepositRequest(alice);
	}

	function _createPosition() internal returns (MockExternalPosition position) {
		vm.prank(manager);
		position = MockExternalPosition(comptroller.createExternalPosition(TYPE_ID, abi.encode(uint256(1))));
	}

	// ─── Creation & registry ─────────────────────────────────────────────────────

	function test_create_registryGated() public {
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(Comptroller.UnknownPositionType.selector, 99));
		comptroller.createExternalPosition(99, '');

		MockExternalPosition position = _createPosition();
		assertEq(position.comptroller(), address(comptroller));
		assertEq(comptroller.getExternalPositions().length, 1);

		// Guardian can kill a compromised type instantly
		address guardian = makeAddr('guardian');
		factory.setGuardian(guardian);
		vm.prank(guardian);
		factory.deregisterPositionType(TYPE_ID);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(Comptroller.UnknownPositionType.selector, TYPE_ID));
		comptroller.createExternalPosition(TYPE_ID, abi.encode(uint256(1)));
	}

	function test_create_onlyFundOwner() public {
		vm.prank(alice);
		vm.expectRevert(Comptroller.OnlyFundOwner.selector);
		comptroller.createExternalPosition(TYPE_ID, abi.encode(uint256(1)));
	}

	function test_allowedTypesPolicy_gatesCreation() public {
		AllowedExternalPositionTypesPolicy policy =
			new AllowedExternalPositionTypesPolicy(new uint256[](0)); // no types allowed
		vm.prank(address(factory)); // set-once: only the factory registers policies (behavior test shortcut)
		comptroller.addPolicy(IPolicy.PolicyHook.CreateExternalPosition, address(policy));

		vm.prank(manager);
		vm.expectRevert(
			abi.encodeWithSelector(AllowedExternalPositionTypesPolicy.PositionTypeNotAllowed.selector, TYPE_ID)
		);
		comptroller.createExternalPosition(TYPE_ID, abi.encode(uint256(1)));
	}

	function test_receiveCallFromFund_onlyComptroller() public {
		MockExternalPosition position = _createPosition();
		vm.prank(manager);
		vm.expectRevert(MockExternalPosition.OnlyComptroller.selector);
		position.receiveCallFromFund('');
	}
}
