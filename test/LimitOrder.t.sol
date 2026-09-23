// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {LimitOrderPosition, LimitOrderPositionFactory} from '../src/positions/LimitOrderPosition.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';

contract LimitOrderTest is Test {
	uint256 internal constant LIMIT_ORDER_TYPE_ID = 2;

	FundFactory internal factory;
	ValueInterpreter internal interpreter;
	Comptroller internal comptroller;
	MockERC20 internal usdc;
	MockERC20 internal gpux; // $100 feed price

	address internal admin = makeAddr('admin');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');
	address internal taker = makeAddr('taker');

	function setUp() public {
		vm.warp(30 days);
		interpreter = new ValueInterpreter(admin);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		gpux = new MockERC20('GigaPU', 'GPUx', 18);
		vm.startPrank(admin);
		interpreter.addPrimitive(address(usdc), address(new MockAggregator(8, 1e8)), 7 days);
		interpreter.addPrimitive(address(gpux), address(new MockAggregator(8, 100e8)), 7 days);
		vm.stopPrank();

		factory = new FundFactory(interpreter, new ComptrollerDeployer(), new SharesVaultDeployer());
		factory.registerPositionType(LIMIT_ORDER_TYPE_ID, address(new LimitOrderPositionFactory()));

		comptroller = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Orderbook Fund',
					symbol: 'frOB',
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
	}

	// ─── helpers ────────────────────────────────────────────────────────────────

	function _createPosition() internal returns (LimitOrderPosition position) {
		vm.prank(manager);
		position = LimitOrderPosition(comptroller.createExternalPosition(LIMIT_ORDER_TYPE_ID, ''));
	}

	function _none() internal pure returns (address[] memory a, uint256[] memory b) {
		a = new address[](0);
		b = new uint256[](0);
	}

	/// @dev Escrow 5,000 USDC into the position and place: sell 5,000 USDC for ≥ 50 GPUx
	///      (limit rate $100/GPUx, at oracle parity).
	function _placeStandardOrder(LimitOrderPosition position) internal returns (uint256 orderId) {
		address[] memory transferAssets = new address[](1);
		transferAssets[0] = address(usdc);
		uint256[] memory transferAmounts = new uint256[](1);
		transferAmounts[0] = 5_000e6;
		(address[] memory noAssets,) = _none();

		bytes memory place = abi.encode(
			uint8(LimitOrderPosition.Action.PlaceOrder),
			abi.encode(address(usdc), address(gpux), uint128(5_000e6), uint128(50e18), uint64(block.timestamp + 1 days))
		);
		vm.prank(manager);
		comptroller.callOnExternalPosition(address(position), transferAssets, transferAmounts, noAssets, place);
		orderId = position.orderCount();
	}

	// ─── tests ──────────────────────────────────────────────────────────────────

	function test_placeOrder_escrowsAndValuesIntoGav() public {
		LimitOrderPosition position = _createPosition();
		uint256 gavBefore = comptroller.calcGav();
		_placeStandardOrder(position);

		assertEq(usdc.balanceOf(address(position)), 5_000e6, 'escrowed');
		assertEq(position.committed(address(usdc)), 5_000e6, 'committed');
		// Escrow moved vault → position but stays in GAV (position is priced)
		assertEq(comptroller.calcGav(), gavBefore, 'GAV unchanged by escrow');
	}

	function test_fullFill_atLimitRate() public {
		LimitOrderPosition position = _createPosition();
		uint256 orderId = _placeStandardOrder(position);

		gpux.mint(taker, 50e18);
		vm.startPrank(taker);
		gpux.approve(address(position), 50e18);
		position.fill(orderId, 50e18);
		vm.stopPrank();

		assertEq(usdc.balanceOf(taker), 5_000e6, 'taker got the inventory');
		assertEq(gpux.balanceOf(address(position)), 50e18, 'position got proceeds');
		assertEq(position.committed(address(usdc)), 0, 'commitment cleared');
		// At oracle parity ($100/GPUx) GAV is unchanged by the swap
		assertEq(comptroller.calcGav(), 10_000e6, 'GAV holds at parity fill');
	}

	function test_partialFill_proRata_andRateFixed() public {
		LimitOrderPosition position = _createPosition();
		uint256 orderId = _placeStandardOrder(position);

		gpux.mint(taker, 20e18);
		vm.startPrank(taker);
		gpux.approve(address(position), 20e18);
		position.fill(orderId, 20e18); // 40% of buyRemaining → 40% of inventory
		vm.stopPrank();

		assertEq(usdc.balanceOf(taker), 2_000e6, 'pro-rata inventory out');
		(,, uint128 sellRemaining, uint128 buyRemaining,) = position.orders(orderId);
		assertEq(sellRemaining, 3_000e6, 'remaining inventory');
		assertEq(buyRemaining, 30e18, 'remaining ask (rate unchanged)');
		assertEq(position.committed(address(usdc)), 3_000e6, 'commitment tracks remainder');
	}

	function test_overpayingFill_paysExactRemainder() public {
		LimitOrderPosition position = _createPosition();
		uint256 orderId = _placeStandardOrder(position);

		gpux.mint(taker, 80e18);
		vm.startPrank(taker);
		gpux.approve(address(position), 80e18);
		position.fill(orderId, 80e18);
		vm.stopPrank();

		assertEq(gpux.balanceOf(taker), 30e18, 'taker charged only the ask');
		assertEq(usdc.balanceOf(taker), 5_000e6, 'full inventory out');
	}

	function test_cancel_releasesCommitment_thenReturnToVault() public {
		LimitOrderPosition position = _createPosition();
		uint256 orderId = _placeStandardOrder(position);
		address vaultAddress = address(comptroller.vault());
		uint256 vaultBefore = usdc.balanceOf(vaultAddress);

		(address[] memory noAssets, uint256[] memory noAmounts) = _none();
		bytes memory cancel =
			abi.encode(uint8(LimitOrderPosition.Action.CancelOrder), abi.encode(orderId));
		vm.prank(manager);
		comptroller.callOnExternalPosition(address(position), noAssets, noAmounts, noAssets, cancel);
		assertEq(position.committed(address(usdc)), 0, 'commitment released');

		address[] memory receiveAssets = new address[](1);
		receiveAssets[0] = address(usdc);
		bytes memory sweep =
			abi.encode(uint8(LimitOrderPosition.Action.ReturnToVault), abi.encode(address(usdc), uint256(5_000e6)));
		vm.prank(manager);
		comptroller.callOnExternalPosition(address(position), noAssets, noAmounts, receiveAssets, sweep);
		assertEq(usdc.balanceOf(vaultAddress), vaultBefore + 5_000e6, 'escrow home');
	}

	function test_returnToVault_cannotStripCommittedInventory() public {
		LimitOrderPosition position = _createPosition();
		_placeStandardOrder(position);

		(address[] memory noAssets, uint256[] memory noAmounts) = _none();
		bytes memory sweep =
			abi.encode(uint8(LimitOrderPosition.Action.ReturnToVault), abi.encode(address(usdc), uint256(1)));
		vm.prank(manager);
		vm.expectRevert(LimitOrderPosition.InventoryCommitted.selector);
		comptroller.callOnExternalPosition(address(position), noAssets, noAmounts, noAssets, sweep);
	}

	function test_expiredOrder_cannotFill() public {
		LimitOrderPosition position = _createPosition();
		uint256 orderId = _placeStandardOrder(position);

		skip(1 days + 1);
		gpux.mint(taker, 50e18);
		vm.startPrank(taker);
		gpux.approve(address(position), 50e18);
		vm.expectRevert(abi.encodeWithSelector(LimitOrderPosition.OrderExpired.selector, orderId));
		position.fill(orderId, 50e18);
		vm.stopPrank();
	}

	function test_cannotOvercommitInventoryAcrossOrders() public {
		LimitOrderPosition position = _createPosition();
		_placeStandardOrder(position); // commits the full 5,000 escrow

		(address[] memory noAssets, uint256[] memory noAmounts) = _none();
		bytes memory place = abi.encode(
			uint8(LimitOrderPosition.Action.PlaceOrder),
			abi.encode(address(usdc), address(gpux), uint128(1), uint128(1), uint64(block.timestamp + 1 days))
		);
		vm.prank(manager);
		vm.expectRevert(LimitOrderPosition.InsufficientInventory.selector);
		comptroller.callOnExternalPosition(address(position), noAssets, noAmounts, noAssets, place);
	}

	function test_unpricedBuyToken_rejected() public {
		LimitOrderPosition position = _createPosition();
		MockERC20 junk = new MockERC20('Junk', 'JNK', 18);
		address junkAddress = address(junk);

		address[] memory transferAssets = new address[](1);
		transferAssets[0] = address(usdc);
		uint256[] memory transferAmounts = new uint256[](1);
		transferAmounts[0] = 1_000e6;
		(address[] memory noAssets,) = _none();
		bytes memory place = abi.encode(
			uint8(LimitOrderPosition.Action.PlaceOrder),
			abi.encode(address(usdc), junkAddress, uint128(1_000e6), uint128(1e18), uint64(block.timestamp + 1 days))
		);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(LimitOrderPosition.UnsupportedAsset.selector, junkAddress));
		comptroller.callOnExternalPosition(address(position), transferAssets, transferAmounts, noAssets, place);
	}

	function test_dustGate_blocksRemovalWhileFunded_thenAllowsAfterSweep() public {
		LimitOrderPosition position = _createPosition();
		uint256 orderId = _placeStandardOrder(position);
		address positionAddress = address(position);

		vm.prank(manager);
		vm.expectRevert();
		comptroller.removeExternalPosition(positionAddress);

		// Cancel + sweep everything home, then removal passes the dust gate
		(address[] memory noAssets, uint256[] memory noAmounts) = _none();
		bytes memory cancel = abi.encode(uint8(LimitOrderPosition.Action.CancelOrder), abi.encode(orderId));
		vm.prank(manager);
		comptroller.callOnExternalPosition(positionAddress, noAssets, noAmounts, noAssets, cancel);
		address[] memory receiveAssets = new address[](1);
		receiveAssets[0] = address(usdc);
		bytes memory sweep =
			abi.encode(uint8(LimitOrderPosition.Action.ReturnToVault), abi.encode(address(usdc), uint256(5_000e6)));
		vm.prank(manager);
		comptroller.callOnExternalPosition(positionAddress, noAssets, noAmounts, receiveAssets, sweep);

		vm.prank(manager);
		comptroller.removeExternalPosition(positionAddress);
	}

	function test_onlyComptroller_callsActions() public {
		LimitOrderPosition position = _createPosition();
		vm.expectRevert(LimitOrderPosition.OnlyComptroller.selector);
		position.receiveCallFromFund(abi.encode(uint8(0), bytes('')));
	}
}
