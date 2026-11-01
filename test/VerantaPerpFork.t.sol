// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {V6Host} from './utils/V6Host.sol';
import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {ComptrollerV6 as Comptroller} from '../src/core/ComptrollerV6.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {VerantaPerpPositionV2, VerantaPerpPositionV2Factory} from '../src/positions/VerantaPerpPositionV2.sol';
import {
	IVerantaTradingRouter,
	IVerantaMulticall,
	IVerantaPairStorage,
	IVerantaReferral
} from '../src/interfaces/external/IVeranta.sol';

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
	address internal constant VERANTA_PAIR_STORAGE = 0x5db3772136e5557EFE028Db05EE95C84D76faEC4; // multicall.pairsStorage()
	address internal constant VERANTA_REFERRAL = 0x1A110bBA13A1f16cCa4b79758BD39290f29De82D; // tx-builder /v2/meta
	bytes32 internal constant FROSTYFI_CODE = 'frostyfi'; // registered 2026-09-22
	uint256 internal constant ETH_PAIR = 0; // Crypto.ETH/USD per the live pair catalog

	Comptroller internal comptroller;
	VerantaPerpPositionV2 internal position;
	VerantaPerpPositionV2Factory internal positionFactory;
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
		else vm.createSelectFork(rpc, 53_390_931); // pinned: live state moves under a fork at the latest block (2026-11-01)
		forked = true;

		ValueInterpreter interpreter = new ValueInterpreter(admin);
		vm.startPrank(admin);
		interpreter.addPrimitive(USDC, CHAINLINK_USDC_USD, 2 days);
		interpreter.addPrimitive(WETH, CHAINLINK_ETH_USD, 1 days);
		vm.stopPrank();

		positionFactory = new VerantaPerpPositionV2Factory(
			IERC20(USDC),
			IVerantaTradingRouter(VERANTA_ROUTER),
			IVerantaMulticall(VERANTA_MULTICALL),
			VERANTA_STORAGE,
			IVerantaPairStorage(VERANTA_PAIR_STORAGE),
			keeper
		);
		positionFactory.setPairAsset(ETH_PAIR, WETH);

		FundFactory factory = new FundFactory(interpreter, V6Host.deployer(), new SharesVaultDeployer());
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
		comptroller.requestDeposit(10_000e6, type(uint256).max);
		vm.stopPrank();
		skip(30 minutes);
		comptroller.executeDepositRequest(alice);

		vm.prank(manager);
		position = VerantaPerpPositionV2(comptroller.createExternalPosition(6, ''));
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
			uint8(VerantaPerpPositionV2.Action.OpenTrade),
			abi.encode(ETH_PAIR, uint256(200e6), uint256(2e10), false, refPrice1e10, uint256(5e10), uint8(0), uint256(0), uint256(0))
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

		// A trader cannot cancel a pending market order on today's Veranta: the router's
		// cancelPendingMarketOrder is onlyOperator (verified source; OnlyOperator() =
		// 0x27e1f1e5). The operator fills or refunds; the escrow stays valued meanwhile.
		bytes memory cancel = abi.encode(
			uint8(VerantaPerpPositionV2.Action.CancelPendingMarketOrder), abi.encode(pending[0].orderId)
		);
		vm.prank(manager);
		vm.expectRevert(bytes4(0x27e1f1e5));
		comptroller.callOnExternalPosition(address(position), noAssets, new uint256[](0), noAssets, cancel);
		assertEq(comptroller.calcGav(), 10_000e6);
	}

	/// TP/SL at open on the REAL router: the levels ride the pending order to the operator.
	function test_fork_openShortWithTpSl_levelsStoredOnPendingOrder() public {
		vm.skip(!forked);
		(, int256 ethPrice,,,) = AggregatorV3Like(CHAINLINK_ETH_USD).latestRoundData();
		uint256 ref = uint256(ethPrice) * 1e2;
		uint256 tp = (ref * 90) / 100; // short: profit below
		uint256 sl = (ref * 110) / 100; // short: stop above

		_openShort(ref, tp, sl);
		IVerantaMulticall.PendingOrder[] memory pending = multicall.getPendingOrder(address(position));
		assertEq(pending.length, 1);
		assertEq(pending[0].orderInfo.trade.tp, tp);
		assertEq(pending[0].orderInfo.trade.sl, sl);
		assertEq(comptroller.calcGav(), 10_000e6);
	}

	/// A stop on the wrong side (short, stop BELOW the price) is refused at placement by the
	/// live router — WrongSl() = 0x62dd5ee3 — so a bad level never escrows collateral.
	function test_fork_openShortWithWrongSideSl_revertsWrongSl() public {
		vm.skip(!forked);
		(, int256 ethPrice,,,) = AggregatorV3Like(CHAINLINK_ETH_USD).latestRoundData();
		uint256 ref = uint256(ethPrice) * 1e2;
		vm.expectRevert(bytes4(0x62dd5ee3));
		this.openShortExternal(ref, 0, (ref * 90) / 100);
	}

	function openShortExternal(uint256 ref, uint256 tp, uint256 sl) external {
		_openShort(ref, tp, sl);
	}

	function _openShort(uint256 ref, uint256 tp, uint256 sl) internal {
		address[] memory transferAssets = new address[](1);
		transferAssets[0] = USDC;
		uint256[] memory transferAmounts = new uint256[](1);
		transferAmounts[0] = 200e6;
		bytes memory open = abi.encode(
			uint8(VerantaPerpPositionV2.Action.OpenTrade),
			abi.encode(ETH_PAIR, uint256(200e6), uint256(2e10), false, ref, uint256(5e10), uint8(0), tp, sl)
		);
		vm.prank(manager);
		comptroller.callOnExternalPosition(address(position), transferAssets, transferAmounts, new address[](0), open);
	}

	/// Referral linking is caller-scoped — proves the live Referral accepts a CONTRACT
	/// trader linking our registered code.
	function test_fork_linkReferral_acceptedForContractTrader() public {
		vm.skip(!forked);
		positionFactory.setReferral(IVerantaReferral(VERANTA_REFERRAL), FROSTYFI_CODE);
		bytes memory link = abi.encode(uint8(VerantaPerpPositionV2.Action.LinkReferral), '');
		vm.prank(manager);
		comptroller.callOnExternalPosition(address(position), new address[](0), new uint256[](0), new address[](0), link);

		assertEq(IVerantaReferral(VERANTA_REFERRAL).traderReferralCodes(address(position)), FROSTYFI_CODE);
	}

	function test_fork_setDelegate_acceptedForContractTrader() public {
		vm.skip(!forked);
		bytes memory setAp = abi.encode(
			uint8(VerantaPerpPositionV2.Action.SetAutopilot), abi.encode(block.timestamp + 90 days)
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
