// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IValueInterpreter} from '../../src/interfaces/IValueInterpreter.sol';
import {IFrostyClmVault, IFrostyClmStrategy} from '../../src/interfaces/external/IFrostyClm.sol';
import {ClmVaultPriceFeed} from '../../src/pricing/ClmVaultPriceFeed.sol';
import {ClmFixture, MockClmVi, IClmHarvest} from './utils/ClmFixture.sol';

/// @notice ClmVaultPriceFeed against FrostyFi's real CLM vault on a Base fork. Rates come from the real VI at the fork
///         block and are then held fixed (MockClmVi), so tests can skip time without Chainlink going stale.
contract ClmVaultPriceFeedForkTest is ClmFixture {
	address internal constant REAL_VI = 0x3CDbaBE5Bf4E6cfE10A2A326E0ad31b2d16398D4;
	address internal constant BEEFY_MSTRC_VAULT = 0x7ec3a9cB1E2512f6318a18aA69eBF113cb1759f0; // same bytecode, Beefy's factory
	bool internal ready;
	MockClmVi internal vi;
	ClmVaultPriceFeed internal feed;
	address internal keeper = makeAddr('keeper');
	address internal vault;
	address internal strategy;
	uint256 internal shares;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0 || !_clmReady()) return;
		vm.createSelectFork(rpc, 52_385_115);
		ready = true;
		vi = new MockClmVi();
		vi.set(USDC, IValueInterpreter(REAL_VI).calcUsdRate(USDC), 6);
		vi.set(CBBTC, IValueInterpreter(REAL_VI).calcUsdRate(CBBTC), 8);
		vi.set(AERO, IValueInterpreter(REAL_VI).calcUsdRate(AERO), 18);
		(address strategyFactory, address poolDeployer) = _deployClm(keeper, address(vi));
		(vault, strategy) = _deployCbBtcVault(poolDeployer);
		feed = new ClmVaultPriceFeed(IValueInterpreter(address(vi)), strategyFactory);

		deal(USDC, address(this), 50_000e6);
		_buyCbBtc(address(this), 0.5e8);
		_settle(strategy);
		IERC20(USDC).approve(vault, type(uint256).max);
		IERC20(CBBTC).approve(vault, type(uint256).max);
		IFrostyClmVault(vault).deposit(50_000e6, 0.5e8, 0);
		shares = IFrostyClmVault(vault).balanceOf(address(this));
		_settle(strategy);
	}

	function _usd(uint256 usdc, uint256 cbBtc) internal view returns (uint256) {
		return usdc * vi.usdRate(USDC) / 1e6 + cbBtc * vi.usdRate(CBBTC) / 1e8;
	}

	function _feedUsd(uint256 amount) internal view returns (uint256) {
		(, uint256[] memory a) = feed.calcUnderlyingValues(vault, amount);
		return _usd(a[0], a[1]);
	}

	function test_feed_matchesWhatAWithdrawalPays() public {
		vm.skip(!ready);
		uint256 valued = _feedUsd(shares);
		uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
		uint256 btcBefore = IERC20(CBBTC).balanceOf(address(this));
		IFrostyClmVault(vault).withdraw(shares, 0, 0);
		uint256 paid = _usd(IERC20(USDC).balanceOf(address(this)) - usdcBefore, IERC20(CBBTC).balanceOf(address(this)) - btcBefore);
		// The pool's price sits a little off the oracle's, so the split differs slightly: within 0.3%.
		assertApproxEqRel(valued, paid, 0.003e18);
	}

	function test_feed_underlyingsAreThePoolTokensOnly() public {
		vm.skip(!ready);
		(address[] memory u,) = feed.calcUnderlyingValues(vault, shares);
		assertEq(u.length, 2);
		assertEq(u[0], USDC);
		assertEq(u[1], CBBTC);
	}

	function test_feed_ignoresAPushedPool() public {
		vm.skip(!ready);
		(, uint256[] memory before) = feed.calcUnderlyingValues(vault, shares);
		_pushPrice(-1_000); // about 10% down: a flash swap's worth
		(, uint256[] memory after_) = feed.calcUnderlyingValues(vault, shares);
		assertEq(after_[0], before[0], 'USDC side unchanged');
		assertEq(after_[1], before[1], 'cbBTC side unchanged');
	}

	function test_feed_releasesProceedsOverTheLock() public {
		vm.skip(!ready);
		skip(1 days);
		uint256 beforeHarvest = _feedUsd(shares);
		vm.prank(keeper);
		IClmHarvest(strategy).harvest();
		assertApproxEqRel(_feedUsd(shares), beforeHarvest, 0.0001e18, 'no jump at the harvest');
		(uint256 l0, uint256 l1) = feed.locked(vault);
		assertGt(l0 + l1, 0, 'proceeds are locked');
		skip(feed.LOCK_DURATION());
		(l0, l1) = feed.locked(vault);
		assertEq(l0 + l1, 0, 'all released after the lock');
		assertGt(_feedUsd(shares), beforeHarvest, 'and now in the value');
	}

	function test_lockDuration_matchesTheStrategy() public {
		vm.skip(!ready);
		skip(1 days);
		vm.prank(keeper);
		IClmHarvest(strategy).harvest();
		for (uint256 i; i < 3; ++i) {
			skip(6 hours);
			(uint256 f0, uint256 f1) = feed.locked(vault);
			(uint256 s0, uint256 s1) = IClmHarvest(strategy).lockedProfit();
			assertEq(f0, s0, 'token0 lock = the strategy own (no cap hit)');
			assertEq(f1, s1, 'token1 lock = the strategy own');
		}
	}

	function test_isSupportedAsset_onlyOurFactorysVaults() public {
		vm.skip(!ready);
		assertTrue(feed.isSupportedAsset(vault));
		assertFalse(feed.isSupportedAsset(BEEFY_MSTRC_VAULT), "Beefy's vault: same bytecode, another factory");
		assertFalse(feed.isSupportedAsset(USDC));
		assertFalse(feed.isSupportedAsset(makeAddr('nobody')));
		assertFalse(feed.isSupportedAsset(strategy), 'the strategy is not a vault');
	}

	function test_feed_zeroForZero() public {
		vm.skip(!ready);
		(, uint256[] memory a) = feed.calcUnderlyingValues(vault, 0);
		assertEq(a[0] + a[1], 0);
	}
}
