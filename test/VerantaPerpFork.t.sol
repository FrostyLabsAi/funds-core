// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {VerantaPerpPosition, VerantaPerpPositionFactory} from '../src/positions/VerantaPerpPosition.sol';
import {IVerantaTradingRouter, IVerantaMulticall} from '../src/interfaces/external/IVeranta.sol';

/// @notice E2E against the REAL Veranta v2 contracts on a Base mainnet fork — the test HL
///         never allowed. Their operator does not run on our fork, so market opens stay
///         PENDING: this exercises exactly the two-step reality the position must tolerate
///         (escrowed-collateral valuation, cancel/refund), plus proves the contracts accept
///         a CONTRACT as trader.
///         Run: BASE_MAINNET_RPC=<url> forge test --match-path test/VerantaPerpFork.t.sol
contract VerantaPerpForkTest is Test {
	// Base mainnet
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant WETH = 0x4200000000000000000000000000000000000006;
	address internal constant CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
	address internal constant CHAINLINK_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
	// Veranta v2 (verified proxies, from GET /v2/meta 2026-09-14)
	address internal constant VERANTA_ROUTER = 0x44914408af82bC9983bbb330e3578E1105e11d4e;
	address internal constant VERANTA_STORAGE = 0x8a311D7048c35985aa31C131B9A13e03a5f7422d;
	address internal constant VERANTA_MULTICALL = 0xA7cFc43872F4D7B0E6141ee8c36f1F7FEe5d099e;
	uint256 internal constant ETH_PAIR = 0; // Crypto.ETH/USD per the live pair catalog

	Comptroller internal comptroller;
	VerantaPerpPosition internal position;
	IVerantaMulticall internal multicall = IVerantaMulticall(VERANTA_MULTICALL);

	address internal admin = makeAddr('admin');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');
	address internal keeper = makeAddr('autopilotKeeper');

	bool internal forked;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		// Pin a block (env BASE_FORK_BLOCK) so forge's fork cache survives across runs —
		// public Base RPCs rate-limit the storage fan-out of an unpinned fork.
		uint256 blockNumber = vm.envOr('BASE_FORK_BLOCK', uint256(0));
		if (blockNumber > 0) vm.createSelectFork(rpc, blockNumber);
		else vm.createSelectFork(rpc);
		forked = true;

		ValueInterpreter interpreter = new ValueInterpreter(admin);
		vm.startPrank(admin);
		interpreter.addPrimitive(USDC, CHAINLINK_USDC_USD, 2 days);
		interpreter.addPrimitive(WETH, CHAINLINK_ETH_USD, 1 days);
		vm.stopPrank();

		VerantaPerpPositionFactory positionFactory = new VerantaPerpPositionFactory(
			IERC20(USDC),
			IVerantaTradingRouter(VERANTA_ROUTER),
			IVerantaMulticall(VERANTA_MULTICALL),
			VERANTA_STORAGE,
			keeper
		);
		positionFactory.setPairAsset(ETH_PAIR, WETH);

		FundFactory factory = new FundFactory(interpreter, new ComptrollerDeployer(), new SharesVaultDeployer());
		factory.registerPositionType(6, address(positionFactory));

		comptroller = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Veranta Fork Fund',
					symbol: 'frVF',
					denominationAsset: IERC20(USDC),
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

		deal(USDC, alice, 10_000e6);
		vm.startPrank(alice);
		IERC20(USDC).approve(address(comptroller), 10_000e6);
		comptroller.requestDeposit(10_000e6);
		vm.stopPrank();
		skip(30 minutes);
		comptroller.executeDepositRequest(alice);

		vm.prank(manager);
		position = VerantaPerpPosition(comptroller.createExternalPosition(6, ''));
	}

	function test_fork_openShort_pendingAcceptedFromContractTrader() public {
		vm.skip(!forked);
		assertEq(comptroller.calcGav(), 10_000e6);

		// 200 USDC × 2x short at the live oracle-ish price (wide slippage; operator absent)
		address[] memory transferAssets = new address[](1);
		transferAssets[0] = USDC;
		uint256[] memory transferAmounts = new uint256[](1);
		transferAmounts[0] = 200e6;
		address[] memory noAssets = new address[](0);

		(, int256 ethPrice,,,) = AggregatorV3Like(CHAINLINK_ETH_USD).latestRoundData();
		uint256 refPrice1e10 = uint256(ethPrice) * 1e2; // 8dp feed → 1e10 scale

		bytes memory open = abi.encode(
			uint8(VerantaPerpPosition.Action.OpenTrade),
			abi.encode(ETH_PAIR, uint256(200e6), uint256(2e10), false, refPrice1e10, uint256(5e10), uint8(0))
		);
		vm.prank(manager);
		comptroller.callOnExternalPosition(address(position), transferAssets, transferAmounts, noAssets, open);

		// The REAL contracts accepted a contract as trader: collateral escrowed, order pending
		IVerantaMulticall.PendingOrder[] memory pending = multicall.getPendingOrder(address(position));
		assertEq(pending.length, 1);
		assertEq(pending[0].orderInfo.trade.trader, address(position));
		assertEq(pending[0].orderInfo.trade.positionSizeUSDC, 200e6);
		assertEq(IERC20(USDC).balanceOf(address(position)), 0);

		// Valuation carries the escrow — GAV whole through the pending window
		assertEq(comptroller.calcGav(), 10_000e6);

		// Operator never fills on a fork → cancel refunds the escrow to the position
		bytes memory cancel = abi.encode(
			uint8(VerantaPerpPosition.Action.CancelPendingMarketOrder), abi.encode(pending[0].orderId)
		);
		vm.prank(manager);
		comptroller.callOnExternalPosition(address(position), noAssets, new uint256[](0), noAssets, cancel);
		assertEq(IERC20(USDC).balanceOf(address(position)), 200e6);
		assertEq(comptroller.calcGav(), 10_000e6);
	}

	function test_fork_setDelegate_acceptedForContractTrader() public {
		vm.skip(!forked);
		bytes memory setAp = abi.encode(
			uint8(VerantaPerpPosition.Action.SetAutopilot), abi.encode(block.timestamp + 90 days)
		);
		vm.prank(manager);
		comptroller.callOnExternalPosition(address(position), new address[](0), new uint256[](0), new address[](0), setAp);

		(bool enabled, uint256 expiry) =
			IVerantaTradingRouter(VERANTA_ROUTER).multipleDelegations(address(position), keeper);
		assertTrue(enabled);
		assertEq(expiry, block.timestamp + 90 days);
		assertEq(position.activeDelegate(), keeper);
	}
}

interface AggregatorV3Like {
	function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
