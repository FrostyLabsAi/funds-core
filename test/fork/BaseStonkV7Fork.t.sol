// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Vm, console} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {IV4PoolManager, IV4StateView, PoolKey, PoolKeyId} from '../../src/interfaces/external/IUniswapV4.sol';
import {PoolPriceMath} from '../../src/libraries/PoolPriceMath.sol';
import {BaseMainnet} from '../../script/release/BaseMainnet.sol';
import {ReleaseFork} from './utils/ReleaseFork.sol';
import {V4TestRouter} from './utils/V4TestRouter.sol';
import {IBaseStonkToken, IBaseStonkLauncher} from './utils/IBaseStonk.sol';

/// @notice FROST on BaseStonk (founder 2026-11-08: 3% / 3% tax, paired with USDC): BaseStonk's V7 fee hook
///         (AdvancedFeeHookV6 source, verified on Basescan, `0x5c99…E044`) on a Base fork with the release deployed
///         (ReleaseFork). The pool is $BINK / USDC, a live V7 launch on the same terms (3% / 3%, a 3.5% max wallet), since
///         FROST isn't launched yet. Everything is live code: only the whale's cap exemption is pranked; the hook and
///         pool approvals and the keeper's samples are the release owner's and keeper's.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/BaseStonkV7Fork.t.sol -vv
contract BaseStonkV7ForkTest is ReleaseFork {
	uint256 internal constant BINK_FORK_BLOCK = 55_626_950;

	address internal constant POOL_MANAGER = BaseMainnet.UNI_V4_POOL_MANAGER;
	address internal constant STATE_VIEW = BaseMainnet.UNI_V4_STATE_VIEW;

	address internal constant HOOK = 0x5c999109609f9f857F4D58240CcB12Bf219eE044;
	address internal constant LAUNCHER = 0x4BC0E8c2caaB145612956652A5668864FfcC7AF7;
	address internal constant PLATFORM_ADMIN = 0x1Be69223CA8feF61b0D0F7AE05904bb47cda1681;
	address internal constant BINK = 0x46Bbc327b97842bE93F6088B9169f5369B4F5222;
	bytes32 internal constant BINK_POOL_ID = 0xe1fbd8bf44b7d784c5db13c88d3d41a30affb9ae3a550898d48668c6010a7f21;
	/// @dev The Initialize event (block 52,915,591): a launch market cap of $3,000.45 on 1B tokens.
	uint160 internal constant BINK_LAUNCH_SQRT_PRICE = 137_237_589_398_557_490_188;

	bytes32 internal constant FEE_TAKEN = keccak256('FeeTaken(bytes32,address,uint256,uint256)');
	/// @dev v4-core CustomRevert.WrappedError(address target, bytes4 selector, bytes reason, bytes details)
	bytes4 internal constant WRAPPED_ERROR = bytes4(keccak256('WrappedError(address,bytes4,bytes,bytes)'));

	address internal v4Adapter;
	V4TestRouter internal whale;

	function _forkBlock() internal pure override returns (uint256) {
		return BINK_FORK_BLOCK;
	}

	function setUp() public override {
		super.setUp();
		if (!forked) return;
		v4Adapter = address(r.adapters.uniswapV4);
		whale = new V4TestRouter(IV4PoolManager(POOL_MANAGER));
		vm.prank(PLATFORM_ADMIN);
		IBaseStonkLauncher(LAUNCHER).setTokenExempt(BINK, address(whale), true);
	}

	// ─── The $25k check on a BaseStonk pool ─────────────────────────────────────────

	/// The launcher puts the whole supply in one range from the launch price up, so the depth our check reads at the
	/// current price (PoolPriceMath.quoteReserve) is the USDC buyers paid in PLUS the launch market cap: on $BINK today,
	/// about $3.1k counted against about $0.1k a seller could actually take out.
	function test_fork_basestonk_liquidityCheckCountsTheLaunchMarketCap() public {
		vm.skip(!forked);
		PoolKey memory key = _binkKey();
		assertEq(PoolKeyId.toId(key), BINK_POOL_ID, 'the live pool');
		uint256 counted = _countedUsdc();
		uint256 real = _sellEverything(key);
		uint256 launchCap = _launchCapUsdc();
		console.log('counted by our check (USDC, 6 dp)', counted);
		console.log('real, a full sell takes out', real);
		console.log('launch market cap', launchCap);
		assertGt(counted, real * 10, 'the check counts over ten times the real USDC');
		assertApproxEqRel(counted - real, launchCap, 0.05e18, 'the difference is the launch market cap');
	}

	/// $22k of real buying lifts the counted depth over $25k, so registration opens with under $25k a fund could sell into.
	function test_fork_basestonk_registersWithUnder25kOfRealUsdc() public {
		vm.skip(!forked);
		PoolKey memory key = _binkKey();
		_whaleBuys(key, 22_000e6);
		_approve(key);
		r.registrar.registerV4(BINK, key);
		uint256 counted = _countedUsdc();
		uint256 real = _sellEverything(key);
		console.log('after $22k of buys: counted', counted, 'real', real);
		assertGe(counted, 25_000e6, 'the check passes');
		assertLt(real, 25_000e6, 'with under $25k really in the pool');
	}

	// ─── A fund trading through the hook ───────────────────────────────────────────

	/// A $50k fund buys $1,000 of $BINK and sells it back through the live v4 adapter: each side pays the hook's 3%, out of
	/// what the fund receives (exact in), the fund values the token at the sampled price, and the adapter keeps nothing.
	function test_fork_basestonk_fundBuysAndSellsThroughTheHook() public {
		vm.skip(!forked);
		PoolKey memory key = _binkKey();
		_whaleBuys(key, 30_000e6);
		_approve(key);
		r.registrar.registerV4(BINK, key);
		_sampleRounds(4);

		Comptroller fund = _fundWithDeposit(50_000e6);
		address vault = address(fund.vault());
		uint256 usdcBefore = IERC20(USDC).balanceOf(vault);

		vm.recordLogs();
		uint256 gas = gasleft();
		vm.prank(manager);
		fund.callOnIntegration(v4Adapter, abi.encode(key, false, uint256(1_000e6), uint256(1)));
		console.log('buy gas', gas - gasleft());
		uint256 bought = IERC20(BINK).balanceOf(vault);
		(address buyFeeIn, uint256 buyFee) = _feeTaken(vm.getRecordedLogs());
		assertEq(buyFeeIn, BINK, 'the buy pays its tax in the token');
		assertApproxEqAbs(buyFee * 10_000 / (bought + buyFee), 300, 1, 'the 3% buy tax, out of what the fund receives');

		uint256 valued = r.valueInterpreter.calcCanonicalAssetValue(BINK, bought, USDC);
		console.log('bought', bought, 'valued (USDC)', valued);
		assertGt(valued, 900e6, 'valued near what it cost, less the tax');
		assertLt(valued, 1_000e6, 'never above what it cost');
		assertEq(IERC20(BINK).balanceOf(v4Adapter), 0, 'the adapter keeps no token');
		assertEq(IERC20(USDC).balanceOf(v4Adapter), 0, 'nor any USDC');

		vm.recordLogs();
		vm.prank(manager);
		fund.callOnIntegration(v4Adapter, abi.encode(key, true, bought, uint256(1)));
		uint256 usdcAfter = IERC20(USDC).balanceOf(vault);
		(address sellFeeIn, uint256 sellFee) = _feeTaken(vm.getRecordedLogs());
		uint256 back = usdcAfter - (usdcBefore - 1_000e6);
		assertEq(sellFeeIn, USDC, 'the sell pays its tax in USDC');
		assertApproxEqAbs(sellFee * 10_000 / (back + sellFee), 300, 1, 'the 3% sell tax');
		assertEq(IERC20(BINK).balanceOf(vault), 0, 'all sold');
		console.log('round trip: $1,000 in, back (USDC, 6 dp)', back);
		assertGt(back, 930e6, 'two 3% taxes and our 5 bps, little else');
		assertLt(back, 945e6, 'the taxes are really taken');
	}

	/// The tax is value the fund loses on the trade, so it spends the fund's loss budget (CumulativeSlippageTolerancePolicy:
	/// 5% of GAV, refilling over 7 days): a $1,000 buy by a fund worth about $1,000 is refused.
	function test_fork_basestonk_taxSpendsTheFundsLossBudget() public {
		vm.skip(!forked);
		PoolKey memory key = _binkKey();
		_whaleBuys(key, 30_000e6);
		_approve(key);
		r.registrar.registerV4(BINK, key);
		_sampleRounds(4);

		Comptroller fund = _fundWithDeposit(1_000e6);
		vm.prank(manager);
		vm.expectPartialRevert(bytes4(keccak256('CumulativeSlippageExceeded(uint256,uint256)')));
		fund.callOnIntegration(v4Adapter, abi.encode(key, false, uint256(1_000e6), uint256(1)));
	}

	/// The token caps every wallet that isn't exempt, a fund's vault included: a fund already holding 3.5% of $BINK's
	/// supply can't buy more. v4's PoolManager wraps the token's revert (CustomRevert.WrappedError, from its transfer).
	function test_fork_basestonk_maxWalletCapsWhatAFundCanHold() public {
		vm.skip(!forked);
		PoolKey memory key = _binkKey();
		_whaleBuys(key, 30_000e6);
		_approve(key);
		r.registrar.registerV4(BINK, key);
		_sampleRounds(4);

		Comptroller fund = _fundWithDeposit(50_000e6);
		address vault = address(fund.vault());
		assertFalse(IBaseStonkToken(BINK).exemptFromMaxWallet(vault), 'a fund vault is not exempt');
		uint256 cap = IBaseStonkToken(BINK).totalSupply() * IBaseStonkToken(BINK).maxWalletBps() / 10_000;
		deal(BINK, vault, cap);
		vm.prank(manager);
		(bool ok, bytes memory err) = address(fund).call(
			abi.encodeCall(Comptroller.callOnIntegration, (v4Adapter, abi.encode(key, false, uint256(100e6), uint256(1))))
		);
		assertFalse(ok, 'the buy reverts');
		assertEq(bytes4(err), WRAPPED_ERROR, "the PoolManager's wrap of a failed transfer");
		(address target, bytes4 call, bytes memory reason,) = abi.decode(_args(err), (address, bytes4, bytes, bytes));
		assertEq(target, BINK, 'from the token');
		assertEq(call, IERC20.transfer.selector, 'paying the vault');
		assertEq(bytes4(reason), IBaseStonkToken.MaxWalletExceeded.selector, 'over the max wallet');
		console.log('cap (tokens, 18 dp)', cap);
	}

	// ─── helpers ───────────────────────────────────────────────────────────────

	function _binkKey() internal pure returns (PoolKey memory) {
		return PoolKey({currency0: BINK, currency1: USDC, fee: 0, tickSpacing: 60, hooks: HOOK});
	}

	/// The owner approves the hook (no hookData: AdvancedFeeHookV6 ignores it) and the pool, as the launch would.
	function _approve(PoolKey memory key) internal {
		r.registrar.setHook(HOOK, true, '');
		r.registrar.setPoolApproved(PoolKeyId.toId(key), true);
	}

	function _whaleBuys(PoolKey memory key, uint256 usdc) internal {
		deal(USDC, address(whale), usdc);
		whale.swap(key, false, usdc, address(whale));
	}

	/// What our $25k check reads: the pool's in-range liquidity as a USDC reserve at the current price.
	function _countedUsdc() internal view returns (uint256) {
		(uint160 sqrtPriceX96,,,) = IV4StateView(STATE_VIEW).getSlot0(BINK_POOL_ID);
		return PoolPriceMath.quoteReserve(IV4StateView(STATE_VIEW).getLiquidity(BINK_POOL_ID), sqrtPriceX96, true);
	}

	/// The USDC a seller can actually take out: sell far more than the pool can absorb (the swap stops at the launch
	/// price, under which the pool holds no USDC), counting the hook's sell tax as USDC that left the pool too. Run on a
	/// snapshot, so the pool is as it was.
	function _sellEverything(PoolKey memory key) internal returns (uint256 real) {
		uint256 snap = vm.snapshotState();
		address seller = address(new V4TestRouter(IV4PoolManager(POOL_MANAGER)));
		vm.prank(PLATFORM_ADMIN);
		IBaseStonkLauncher(LAUNCHER).setTokenExempt(BINK, seller, true);
		deal(BINK, seller, IBaseStonkToken(BINK).totalSupply());
		vm.recordLogs();
		V4TestRouter(payable(seller)).swap(key, true, IBaseStonkToken(BINK).totalSupply(), seller);
		(, uint256 fee) = _feeTaken(vm.getRecordedLogs());
		real = IERC20(USDC).balanceOf(seller) + fee;
		vm.revertToState(snap);
	}

	function _launchCapUsdc() internal pure returns (uint256) {
		// supply × launch price, both in raw units: 1e27 × (sqrtP / 2^96)^2
		uint256 p = uint256(BINK_LAUNCH_SQRT_PRICE);
		return (1e27 * p / (1 << 96)) * p / (1 << 96);
	}

	/// The hook's FeeTaken for $BINK's pool in these logs (the tax: the platform's cut plus the creator's).
	function _feeTaken(Vm.Log[] memory logs) internal pure returns (address currency, uint256 fee) {
		for (uint256 i; i < logs.length; ++i) {
			if (logs[i].emitter != HOOK || logs[i].topics[0] != FEE_TAKEN || logs[i].topics[1] != BINK_POOL_ID) continue;
			(address c, uint256 platform, uint256 creator) = abi.decode(logs[i].data, (address, uint256, uint256));
			return (c, platform + creator);
		}
		revert('no FeeTaken');
	}

	/// An error's arguments, without its selector.
	function _args(bytes memory err) internal pure returns (bytes memory out) {
		out = new bytes(err.length - 4);
		for (uint256 i; i < out.length; ++i) {
			out[i] = err[i + 4];
		}
	}

	function _sampleRounds(uint256 n) internal {
		bytes32[] memory ids = new bytes32[](1);
		ids[0] = BINK_POOL_ID;
		for (uint256 i; i < n; ++i) {
			vm.warp(block.timestamp + 10 minutes);
			vm.roll(block.number + 3_000);
			vm.prank(keeper);
			r.sampler.sample(ids);
		}
	}
}
