// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test, console2} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {IPolicy} from '../src/interfaces/IPolicy.sol';
import {IExternalPosition} from '../src/interfaces/IExternalPosition.sol';
import {CumulativeSlippageTolerancePolicy} from '../src/policies/CumulativeSlippageTolerancePolicy.sol';
import {UniswapV3SwapAdapter} from '../src/adapters/UniswapV3SwapAdapter.sol';
import {ERC4626Adapter} from '../src/adapters/ERC4626Adapter.sol';
import {ERC4626PriceFeed} from '../src/pricing/ERC4626PriceFeed.sol';
import {UniswapV3LPPositionFactory} from '../src/positions/UniswapV3LPPosition.sol';
import {SlipstreamLPPositionFactory} from '../src/positions/SlipstreamLPPosition.sol';
import {VerantaPerpPositionV2, VerantaPerpPositionV2Factory} from '../src/positions/VerantaPerpPositionV2.sol';
import {IUniswapV3SwapRouter} from '../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {IUniswapV3NonfungiblePositionManager} from
	'../src/interfaces/external/IUniswapV3NonfungiblePositionManager.sol';
import {ISlipstreamNonfungiblePositionManager} from
	'../src/interfaces/external/ISlipstreamNonfungiblePositionManager.sol';
import {IVerantaTradingRouter, IVerantaMulticall, IVerantaPairStorage} from '../src/interfaces/external/IVeranta.sol';

/// @title MainnetRehearsalFork
/// @notice Pre-mainnet rehearsal of a whole fund lifecycle against REAL Base markets on a
///         fork: real Chainlink feeds, real Uniswap v3 + Aerodrome Slipstream pools, a real
///         Morpho vault (Steakhouse USDC), real Veranta v2 router. Answers the questions
///         testnet cannot: do fills track the MARKET (not a stale demo pool), does a real
///         vault's yield show up in NAV, do LP legs value sanely, does NAV stay whole
///         through a perp's pending window, and do redemptions pay NAV.
///         NOT covered (by construction, see the report): B20 stock tokens are Base-node
///         precompiles (OpcodeNotFound on anvil); Veranta fills need their operator + signed
///         Pyth updates; Chainlink never updates on a frozen fork (warps stay < heartbeat).
///         Run: REHEARSAL_RPC=<base rpc> REHEARSAL_BLOCK=<pinned block> \
///              forge test --match-path test/MainnetRehearsalFork.t.sol -vv
contract MainnetRehearsalForkTest is Test {
	// ── Base mainnet (each verified on-chain 2026-09-23) ─────────────────────────
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant WETH = 0x4200000000000000000000000000000000000006;
	address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
	address internal constant CL_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B; // "USDC / USD"
	address internal constant CL_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70; // "ETH / USD"
	address internal constant CL_BTC_USD = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F; // "BTC / USD"
	address internal constant SWAP_ROUTER02 = 0x2626664c2603336E57B271c5C0b26F421741e481;
	address internal constant UNI_NPM = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
	address internal constant SLIPSTREAM_NPM = 0x827922686190790b37229fd06084350E74485b72;
	address internal constant STEAKHOUSE_USDC = 0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183; // Morpho vault
	address internal constant VERANTA_ROUTER = 0x44914408af82bC9983bbb330e3578E1105e11d4e;
	address internal constant VERANTA_STORAGE = 0x8a311D7048c35985aa31C131B9A13e03a5f7422d;
	address internal constant VERANTA_MULTICALL = 0xA7cFc43872F4D7B0E6141ee8c36f1F7FEe5d099e;
	address internal constant VERANTA_PAIR_STORAGE = 0x5db3772136e5557EFE028Db05EE95C84D76faEC4; // multicall.pairsStorage()

	uint24 internal constant UNI_FEE = 500; // WETH/USDC + cbBTC/USDC 0.05% pools ($4-5M USDC deep)
	int24 internal constant UNI_FULL = 887_270; // full range at tick spacing 10
	int24 internal constant CL_SPACING = 100;
	int24 internal constant CL_FULL = 887_200; // full range at tick spacing 100
	uint128 internal constant MGMT_2PCT = 1_000_000_000_640_000_000_000_000_000; // ≈2%/yr
	uint256 internal constant SLIPPAGE_TOLERANCE_BPS = 300;
	uint256 internal constant ETH_PAIR = 0;

	ValueInterpreter internal interpreter;
	Comptroller internal comptroller;
	address internal uniAdapter;
	address internal erc4626Adapter;

	address internal admin = makeAddr('admin');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');
	address internal keeper = makeAddr('keeper');
	address internal feeRecipient = makeAddr('protocolFeeRecipient');

	bool internal forked;

	function setUp() public {
		string memory rpc = vm.envOr('REHEARSAL_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		// Pin a block (REHEARSAL_BLOCK) so forge's fork cache survives across runs — the
		// run touches thousands of pool / vault / venue slots
		uint256 blockNumber = vm.envOr('REHEARSAL_BLOCK', uint256(0));
		if (blockNumber > 0) vm.createSelectFork(rpc, blockNumber);
		else vm.createSelectFork(rpc);
		forked = true;

		interpreter = new ValueInterpreter(admin);
		address erc4626Feed = address(new ERC4626PriceFeed());
		vm.startPrank(admin);
		interpreter.addPrimitive(USDC, CL_USDC_USD, 2 days);
		interpreter.addPrimitive(WETH, CL_ETH_USD, 1 days);
		interpreter.addPrimitive(CBBTC, CL_BTC_USD, 1 days);
		interpreter.addDerivative(STEAKHOUSE_USDC, erc4626Feed);
		vm.stopPrank();

		FundFactory factory = new FundFactory(interpreter, new ComptrollerDeployer(), new SharesVaultDeployer());
		factory.setProtocolFee(25, feeRecipient);
		uniAdapter = address(new UniswapV3SwapAdapter(IUniswapV3SwapRouter(SWAP_ROUTER02)));
		erc4626Adapter = address(new ERC4626Adapter());
		factory.registerAdapter(uniAdapter);
		factory.registerAdapter(erc4626Adapter);
		factory.registerPositionType(
			3, address(new UniswapV3LPPositionFactory(IUniswapV3NonfungiblePositionManager(UNI_NPM)))
		);
		factory.registerPositionType(
			4, address(new SlipstreamLPPositionFactory(ISlipstreamNonfungiblePositionManager(SLIPSTREAM_NPM)))
		);
		// V2: the bounded read (V1's getPositions costs ≈215M gas against live Veranta)
		VerantaPerpPositionV2Factory perps = new VerantaPerpPositionV2Factory(
			IERC20(USDC),
			IVerantaTradingRouter(VERANTA_ROUTER),
			IVerantaMulticall(VERANTA_MULTICALL),
			VERANTA_STORAGE,
			IVerantaPairStorage(VERANTA_PAIR_STORAGE),
			keeper
		);
		perps.setPairAsset(ETH_PAIR, WETH);
		factory.registerPositionType(6, address(perps));

		// The slippage brake measures every swap / position call against the ORACLE
		CumulativeSlippageTolerancePolicy slippage = new CumulativeSlippageTolerancePolicy(SLIPPAGE_TOLERANCE_BPS);
		FundFactory.PolicyReg[] memory regs = new FundFactory.PolicyReg[](2);
		regs[0] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnIntegration, policy: address(slippage)});
		regs[1] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnExternalPosition, policy: address(slippage)});

		comptroller = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Mainnet Rehearsal Fund',
					symbol: 'frREH',
					denominationAsset: IERC20(USDC),
					fundOwner: manager,
					mgmtScaledPerSecondRate: MGMT_2PCT,
					perfFeeBps: 1000,
					sharesActionTimelock: 0,
					minRequestDuration: 1 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				}),
				regs
			)
		);
	}

	// Phases are independent tests (each from a fresh subscription) so every one fits a
	// non-archive RPC's recent-state window and reports on its own:
	//   forge test --match-path test/MainnetRehearsalFork.t.sol --match-test <phase>

	/// @dev 100k USDC subscription — every phase starts here.
	function _subscribe() internal {
		deal(USDC, alice, 100_000e6);
		vm.startPrank(alice);
		IERC20(USDC).approve(address(comptroller), 100_000e6);
		comptroller.requestDeposit(100_000e6);
		vm.stopPrank();
		skip(1 minutes);
		comptroller.executeDepositRequest(alice);
		assertEq(comptroller.calcGav(), 100_000e6, 'GAV after subscription');
		console2.log('REHEARSAL fork block', block.number);
	}

	/// Phase 1 — spot on REAL pools: fills must track the market, not a demo pool.
	function test_phase1_spotFillsTrackTheMarket() public {
		vm.skip(!forked);
		_subscribe();
		int256 ethGapBps = _swapAndMeasure(WETH, 20_000e6);
		int256 btcGapBps = _swapAndMeasure(CBBTC, 20_000e6);
		// fee 5 bps + tiny impact ± Chainlink's deviation band; the testnet artefact was ±800
		assertLt(_abs(ethGapBps), 100, 'WETH fill within 1% of oracle');
		assertLt(_abs(btcGapBps), 100, 'cbBTC fill within 1% of oracle');
		_log('1 spot legs bought');
	}

	/// Phase 2 — real Morpho vault: the deposit is worth what went in, and yield accrues
	/// into NAV over time (warp stays inside the Chainlink heartbeat); fees accrue too.
	function test_phase2_realVaultYieldAndFees() public {
		vm.skip(!forked);
		_subscribe();
		uint256 shares = _deposit4626(30_000e6);
		uint256 vaultValue0 = interpreter.calcCanonicalAssetValue(STEAKHOUSE_USDC, shares, USDC);
		console2.log('RESULT vault value at deposit (1e6)', vaultValue0);
		assertApproxEqRel(vaultValue0, 30_000e6, 0.001e18, 'vault shares worth the deposit');

		skip(20 hours);
		uint256 vaultValue1 = interpreter.calcCanonicalAssetValue(STEAKHOUSE_USDC, shares, USDC);
		console2.log('RESULT vault value after 20h (1e6)', vaultValue1);
		console2.log('RESULT vault earned over 20h (1e6)', vaultValue1 - vaultValue0);
		assertGt(vaultValue1, vaultValue0, 'real Morpho yield shows up in NAV');

		uint256 supplyBefore = comptroller.shares().totalSupply();
		comptroller.settleFees();
		uint256 feeShares = comptroller.shares().totalSupply() - supplyBefore;
		console2.log('RESULT mgmt+protocol fee shares minted over 20h (1e18)', feeShares);
		assertGt(feeShares, 0, 'management fee accrued');
		_log('2 after 20h + fee settlement');
	}

	/// Phase 3 — Uniswap v3 LP (type 3) + Aerodrome Slipstream LP (type 4) on real pools.
	function test_phase3_realLpPositions() public {
		vm.skip(!forked);
		_subscribe();
		_swapAndMeasure(WETH, 20_000e6);
		address uniLp = _openLp(3, abi.encode(WETH, USDC, UNI_FEE), UNI_FULL, 0.5e18);
		address clLp = _openLp(4, abi.encode(WETH, USDC, CL_SPACING, address(0)), CL_FULL, 0.5e18);
		assertGt(_leg(uniLp, WETH), 0, 'uniswap LP holds WETH');
		assertGt(_leg(clLp, WETH), 0, 'slipstream LP holds WETH');
		_log('3 LPs minted');
	}

	/// Phase 4 — perp hedge on the REAL Veranta router: NAV whole while pending, and the
	/// NAV calculation's gas with a live V2 account (V1: ≈215M).
	function test_phase4_perpPendingKeepsNavWhole() public {
		vm.skip(!forked);
		_subscribe();
		_swapAndMeasure(WETH, 20_000e6);
		uint256 ethExposure = IERC20(WETH).balanceOf(address(comptroller.vault()));
		console2.log('RESULT ETH exposure (1e18)', ethExposure);
		_perpPending(ethExposure);
		_log('4 perp opened + pending (trader cancel is operator-only)');
	}

	/// Phase 5 — a redemption pays shares × share price, with holdings on real markets.
	function test_phase5_redemptionPaysNav() public {
		vm.skip(!forked);
		_subscribe();
		_swapAndMeasure(WETH, 20_000e6);
		_swapAndMeasure(CBBTC, 20_000e6);
		uint256 redeemShares = comptroller.shares().balanceOf(alice) / 10;
		uint256 price = comptroller.calcGrossShareValue();
		uint256 before = IERC20(USDC).balanceOf(alice);
		vm.prank(alice);
		comptroller.redeemSharesForDenominationAsset(redeemShares);
		uint256 paid = IERC20(USDC).balanceOf(alice) - before;
		console2.log('RESULT redeemed 10% of shares, paid (1e6)', paid);
		assertApproxEqRel(paid, redeemShares * price / 1e18, 0.0001e18, 'paid = shares x share price');
		_log('5 after 10% redemption');
	}

	// ─── steps ───────────────────────────────────────────────────────────────────

	/// @dev Buys `token` for `usdcIn` through the fund's Uniswap adapter; returns the
	///      fill's gap vs the oracle in bps (+ = the fund received MORE than oracle value).
	function _swapAndMeasure(address token, uint256 usdcIn) internal returns (int256 gapBps) {
		uint256 oracleOut = _oracleUnits(token, usdcIn);
		uint256 before = IERC20(token).balanceOf(address(comptroller.vault()));
		vm.prank(manager);
		comptroller.callOnIntegration(uniAdapter, abi.encode(USDC, token, UNI_FEE, usdcIn, oracleOut * 97 / 100));
		uint256 received = IERC20(token).balanceOf(address(comptroller.vault())) - before;
		uint256 receivedValue = interpreter.calcCanonicalAssetValue(token, received, USDC);
		gapBps = (int256(receivedValue) - int256(usdcIn)) * 10_000 / int256(usdcIn);
		console2.log('RESULT fill', token);
		console2.log('  spent USDC (1e6)       ', usdcIn);
		console2.log('  received (token units) ', received);
		console2.log('  oracle value (1e6)     ', receivedValue);
		console2.log('  gap vs oracle (bps)    ', gapBps);
	}

	function _deposit4626(uint256 assets) internal returns (uint256 shares) {
		uint256 minShares = IERC4626(STEAKHOUSE_USDC).previewDeposit(assets) * 99 / 100;
		vm.prank(manager);
		comptroller.callOnIntegration(erc4626Adapter, abi.encode(uint8(0), STEAKHOUSE_USDC, assets, minShares));
		shares = IERC20(STEAKHOUSE_USDC).balanceOf(address(comptroller.vault()));
		assertGe(shares, minShares, 'vault shares received');
	}

	/// @dev Opens an LP position and mints full range with `ethAmount` WETH + the oracle-
	///      matched USDC. GAV must survive the move (the slippage brake measures it too).
	function _openLp(uint256 typeId, bytes memory initArgs, int24 fullRange, uint256 ethAmount)
		internal
		returns (address position)
	{
		uint256 usdcAmount = interpreter.calcCanonicalAssetValue(WETH, ethAmount, USDC);
		uint256 gav0 = comptroller.calcGav();
		vm.startPrank(manager);
		position = comptroller.createExternalPosition(typeId, initArgs);
		address[] memory assets = new address[](2);
		assets[0] = WETH; // WETH (0x42…) sorts before USDC (0x83…) → token0
		assets[1] = USDC;
		uint256[] memory amounts = new uint256[](2);
		amounts[0] = ethAmount;
		amounts[1] = usdcAmount;
		bytes memory mint =
			abi.encode(uint8(0), abi.encode(-fullRange, fullRange, ethAmount, usdcAmount, uint256(0), uint256(0)));
		comptroller.callOnExternalPosition(position, assets, amounts, new address[](0), mint);
		vm.stopPrank();
		uint256 gav1 = comptroller.calcGav();
		console2.log('RESULT LP type', typeId);
		console2.log('  WETH leg (1e18)        ', _leg(position, WETH));
		console2.log('  USDC leg (1e6)         ', _leg(position, USDC));
		console2.log('  GAV before / after     ', gav0, gav1);
		// oracle-fair valuation of the minted liquidity + refunds: whole to within 0.5%
		assertApproxEqRel(gav1, gav0, 0.005e18, 'GAV whole through the LP mint');
	}

	function _perpPending(uint256 ethExposure) internal {
		(, int256 ethPrice,,,) = AggregatorLike(CL_ETH_USD).latestRoundData();
		uint256 collateral = ethExposure * uint256(ethPrice) / 1e8 / 1e12 / 2; // 2x → half the notional
		console2.log('GAS calcGav, no perp account     ', _gavGas());
		vm.prank(manager);
		address position = comptroller.createExternalPosition(6, '');
		console2.log('GAS calcGav, empty perp account  ', _gavGas());
		// (Multicall.getPositions — V1's read — is deliberately NOT called: it scans every
		// pair × 40 slots, ≈215M gas; measured via eth_estimateGas on Base instead)
		_coolVenue();
		uint256 g = gasleft();
		IVerantaMulticall(VERANTA_MULTICALL).getPendingOrder(position);
		console2.log('GAS   venue getPendingOrder      ', g - gasleft());
		uint256 gav0 = comptroller.calcGav();

		address[] memory assets = new address[](1);
		assets[0] = USDC;
		uint256[] memory amounts = new uint256[](1);
		amounts[0] = collateral;
		bytes memory open = abi.encode(
			uint8(VerantaPerpPositionV2.Action.OpenTrade),
			abi.encode(ETH_PAIR, collateral, uint256(2e10), false, uint256(ethPrice) * 1e2, uint256(1e10), uint8(0), uint256(0), uint256(0))
		);
		vm.prank(manager);
		comptroller.callOnExternalPosition(position, assets, amounts, new address[](0), open);

		IVerantaMulticall.PendingOrder[] memory pending = IVerantaMulticall(VERANTA_MULTICALL).getPendingOrder(position);
		assertEq(pending.length, 1, 'order pending with the real venue');
		console2.log('GAS calcGav, one pending order   ', _gavGas());
		uint256 gavPending = comptroller.calcGav();
		console2.log('RESULT perp short collateral (1e6)', collateral);
		console2.log('  GAV before / pending   ', gav0, gavPending);
		assertEq(gavPending, gav0, 'escrowed collateral keeps NAV whole while pending');

		// Cancelling is NOT possible for a trader on today's Veranta: the router's
		// cancelPendingMarketOrder is `onlyOperator` (a "fallback method" — verified source,
		// error OnlyOperator() 0x27e1f1e5). The operator fills or refunds; until then the
		// escrow stays valued at face, which is what this phase proves.
		vm.expectRevert(bytes4(0x27e1f1e5));
		vm.prank(manager);
		comptroller.callOnExternalPosition(
			position, new address[](0), new uint256[](0), new address[](0),
			abi.encode(uint8(VerantaPerpPositionV2.Action.CancelPendingMarketOrder), abi.encode(pending[0].orderId))
		);
		assertEq(comptroller.calcGav(), gav0, 'NAV stays whole while the operator holds the order');
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	function _coolVenue() internal {
		vm.cool(VERANTA_STORAGE);
		vm.cool(VERANTA_MULTICALL);
		vm.cool(VERANTA_ROUTER);
		vm.cool(VERANTA_PAIR_STORAGE);
	}

	/// @dev Gas of one NAV calculation — every deposit, redemption and fee settlement pays it.
	function _gavGas() internal returns (uint256 used) {
		_coolVenue(); // a real deposit tx reads the venue's storage cold
		uint256 g = gasleft();
		comptroller.calcGav();
		used = g - gasleft();
	}

	function _oracleUnits(address token, uint256 usdcAmount) internal view returns (uint256) {
		uint256 unit = 10 ** _decimals(token);
		return usdcAmount * unit / interpreter.calcCanonicalAssetValue(token, unit, USDC);
	}

	function _leg(address position, address asset) internal returns (uint256 amount) {
		(address[] memory assets, uint256[] memory amounts) = IExternalPosition(position).getManagedAssets();
		for (uint256 i; i < assets.length; ++i) {
			if (assets[i] == asset) amount += amounts[i];
		}
	}

	function _decimals(address token) internal view returns (uint8) {
		return DecimalsLike(token).decimals();
	}

	function _abs(int256 x) internal pure returns (uint256) {
		return uint256(x >= 0 ? x : -x);
	}

	function _log(string memory step) internal {
		console2.log('STEP', step);
		console2.log('  GAV (1e6)              ', comptroller.calcGav());
		console2.log('  gross share value (1e6)', comptroller.calcGrossShareValue());
	}
}

interface AggregatorLike {
	function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface DecimalsLike {
	function decimals() external view returns (uint8);
}
