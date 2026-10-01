# TWAP Listing v2 (automatic long-tail listing) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Any token with ≥ $50k of USDC/WETH-side liquidity (within ±10% of its price) in a Uniswap v3 or Aerodrome Slipstream (all three deployments) pool can be listed by anyone, gets a TWAP price in the ValueInterpreter in the same transaction, and becomes tradable by funds.

**Architecture:** Side-by-side contracts, nothing deployed is modified:
- `TwapAggregatorAdapterV2` measures depth on the **quote side only**, which kills the fake-depth attack: one-sided asset liquidity valued at a self-chosen price.
- `TwapListingRegistryV2` adds the third Slipstream factory, plus a margin-gated `repoint` to a deeper pool.
- `PriceListingModule` becomes the ValueInterpreter's owner. Its `list()`/`repoint()` are permissionless but can only write TWAP primitives that passed the registry's checks. Every other VI admin call goes through the owner-only `execute()`.
- `TwapExposurePolicyV2` and `TwapFloorLensV2` bind to the new registry.
- A second instance of the existing `AerodromeSlipstreamSwapAdapter`, pointed at the third Slipstream router, makes those pools tradable.
- Off-chain discovery and auto-listing (keeper) and terminal wiring are follow-up plans B and C.

**Tech Stack:** Solidity 0.8.24, Foundry (forge 1.5), OpenZeppelin 5 (Ownable2Step, ReentrancyGuard), Base mainnet fork tests.

**Spec:**
- Founder decisions, 2026-09-30:
  - "if a token has more than 50k liquidity on uniswap and/or aerodrome it needs to be listed … usdc/weth side".
  - Automatic listing, with no manual routine.
  - Side-by-side deployments only.
- Facts verified on-chain the same day:
  - Third Slipstream factory `0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a`, tick spacings [1,10,50,100,200,500,2000]. Its router is `0xcbBb8035cAc7D4B3Ca7aBb74cF7BdF900215Ce0D` (`router.factory()` = that factory), and its pools support `observe()`.
  - Uniswap v3 fee tiers on Base: 100, 200, 300, 400, 500, 3000, 10000.
  - Slip1 spacings are [1,10,50,100,200,2000]; Slip2 spacings are [1,10,50,80,100,150,200,500,2000].
  - Fake-depth proof: LUMIA `0x550161ae735debee90ba117025db0e83131bf9a6`, pool `0x36523a7a21139e0d85d1d3ba69e9f8aa9a5bd185`, has 0.98 WETH and 150M LUMIA, and v1 `list()` passes.
  - The genesis VI prices WETH via the SVR proxy `0x71041d…Bb70`. The standard proxy is `0x50015f8b17fb2C290Dde41fDc246ed0dcEE93a8b`.

## Global Constraints

- **Solidity and toolchain:** pragma `0.8.24`; tabs; single quotes; follow the style of `src/pricing/TwapListingRegistry.sol` exactly (natspec density, custom errors, events).
- **Side-by-side, never edit deployed code:** do not modify `TwapAggregatorAdapter.sol`, `TwapListingRegistry.sol`, `TwapExposurePolicy.sol`, `TwapFloorLens.sol`, `ValueInterpreter.sol` or `src/pricing/VerantaPriceStore.sol`. New files only.
- **Fixed listing parameters** (constants, not caller choice):
  - `WINDOW = 30 minutes`, `MAX_DEVIATION_BPS = 500`, `MIN_DEPTH_USD = 50_000` (quote side), `DELIST_GRACE = 72 hours`;
  - `REPOINT_MARGIN_BPS = 12_500` (a new pool must be ≥ 1.25× deeper);
  - TWAP primitive heartbeat `3600`.
- **Quotes:** exactly USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (feed `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B`, heartbeat 90000) and WETH `0x4200000000000000000000000000000000000006` (feed = STANDARD proxy `0x50015f8b17fb2C290Dde41fDc246ed0dcEE93a8b`, heartbeat 3600). Never an SVR proxy.
- **Git:** work on branch `feat/twap-listing-v2` created with `git checkout -b feat/twap-listing-v2 --no-track origin/main`, verified with `git branch -vv`. NEVER `git add` / `commit` / `push`: the founder commits. Each task's last step is "hand the diff to the founder", not a commit.
- **Testing:** fork tests run with `BASE_MAINNET_RPC=<thirdweb url from .env BASE_RPC_URL> forge test --match-path <file> -vv`, and must be skipped (`vm.skip(!forked)`) without an RPC. The full suite (`forge test`) must stay green.
- **Model:** only the top-tier model writes Solidity.

## Review Focus

1. **One-sided liquidity.** A pool whose ±10% band holds huge asset-side value but < $50k of quote must be REFUSED. Pinned by `test_fork_oneSidedJunkRefused` (LUMIA) in Task 7.
2. **Hijacking an existing price.** Permissionless `list`/`repoint` must never overwrite a Chainlink-priced or derivative asset (e.g. WETH, NVDAc). Pinned by `test_cannotListOrRepointChainlinkAsset` in Task 3.
3. **Losing VI admin.** After VI ownership moves to the module, governance must still be able to call every VI admin function, and nobody else can. Pinned by `test_executeOnlyOwner` and `test_executeForwardsRevert` in Task 3.
4. **Repoint flapping or griefing.** Repointing to a shallower or equal pool must revert; a delisted/below-floor listing may repoint to any qualifying pool. Pinned by `test_fork_repointNeedsMargin` in Task 7.
5. **Hundreds of listings.** Lens reads must stay within RPC `eth_call` gas limits. Pinned by `test_pagination` in Task 5 (page bounds, offset past the end returns empty).

---

### Task 1: Branch + TwapAggregatorAdapterV2 (quote-side depth)

**Files:**
- Create: `src/pricing/TwapAggregatorAdapterV2.sol`
- Test: `test/TwapAggregatorAdapterV2Fork.t.sol`

**Interfaces:**
- Produces: `contract TwapAggregatorAdapterV2 is AggregatorV3Interface` with the IDENTICAL constructor, public getters and errors of `TwapAggregatorAdapter` (`pool()`, `asset()`, `quoteAsset()`, `assetIsToken0()`, `quoteFeed()`, `window()`, `minLiquidityUsd()`, `maxDeviationBps()`, `quoteHeartbeat()`, `description()`, `decimals()`, `latestRoundData()`, `poolDepthUsd()`, `isBelowFloor()`, `spotBandDepthUsd()`, `consult()`), and the interface `IConcentratedPoolOracle` re-exported (import it from v1, don't redeclare).
  - Semantics change: `poolDepthUsd()`, `isBelowFloor()` and `spotBandDepthUsd()` measure ONLY the quote token held within ±10% of the price.

- [ ] **Step 1: Create the branch**

```bash
cd ~/FrostyFunds/funds-core
git status --short        # expect only untracked deployments/*.json
git checkout -b feat/twap-listing-v2 --no-track origin/main
git branch -vv | grep '^\*'   # must show NO [origin/...] upstream
```

- [ ] **Step 2: Write the failing fork test**

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {TwapAggregatorAdapterV2} from '../src/pricing/TwapAggregatorAdapterV2.sol';
import {TwapAggregatorAdapter, IConcentratedPoolOracle} from '../src/pricing/TwapAggregatorAdapter.sol';
import {AggregatorV3Interface} from '../src/interfaces/AggregatorV3Interface.sol';

/// @notice Quote-side depth on real Base pools: a two-sided pool keeps a real depth; LUMIA's
///         one-sided pool (0.98 WETH vs 150M LUMIA) collapses to its ~$2.6k of WETH.
///         Run: BASE_MAINNET_RPC=<url> forge test --match-path test/TwapAggregatorAdapterV2Fork.t.sol -vv
contract TwapAggregatorAdapterV2ForkTest is Test {
	address internal constant WETH = 0x4200000000000000000000000000000000000006;
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant ETH_USD = 0x50015f8b17fb2C290Dde41fDc246ed0dcEE93a8b; // standard proxy
	address internal constant USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
	address internal constant LUMIA = 0x550161ae735debee90ba117025db0e83131bf9a6;
	address internal constant LUMIA_POOL = 0x36523a7a21139e0d85d1d3ba69e9f8aa9a5bd185; // UniV3 0.3% vs WETH
	address internal constant VIRTUAL = 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b;
	address internal constant VIRTUAL_POOL = 0x529d2863a1521d0b57db028168fdE2E97120017C; // UniV3 0.3% vs USDC

	bool internal forked;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc);
		forked = true;
	}

	function _pair(address pool, address asset, address feed, uint32 hb)
		internal
		returns (TwapAggregatorAdapter v1, TwapAggregatorAdapterV2 v2)
	{
		v1 = new TwapAggregatorAdapter(IConcentratedPoolOracle(pool), asset, AggregatorV3Interface(feed), 30 minutes, 50_000, 500, hb, 'v1');
		v2 = new TwapAggregatorAdapterV2(IConcentratedPoolOracle(pool), asset, AggregatorV3Interface(feed), 30 minutes, 50_000, 500, hb, 'v2');
	}

	function test_fork_oneSidedPoolIsShallow() public {
		vm.skip(!forked);
		(TwapAggregatorAdapter v1, TwapAggregatorAdapterV2 v2) = _pair(LUMIA_POOL, LUMIA, ETH_USD, 3600);
		assertGt(v1.poolDepthUsd(), 1_000_000e18, 'v1 counts the self-priced asset side');
		assertLt(v2.poolDepthUsd(), 10_000e18, 'v2 counts only the WETH side');
		assertTrue(v2.isBelowFloor());
	}

	function test_fork_twoSidedPoolKeepsDepth() public {
		vm.skip(!forked);
		(, TwapAggregatorAdapterV2 v2) = _pair(VIRTUAL_POOL, VIRTUAL, USDC_USD, 90_000);
		assertGt(v2.poolDepthUsd(), 50_000e18, 'real USDC bids within 10%');
		assertFalse(v2.isBelowFloor());
		(, int256 answer,,,) = v2.latestRoundData();
		assertGt(answer, 0);
	}

	function test_fork_quoteSideNeverExceedsTwoSided() public {
		vm.skip(!forked);
		(TwapAggregatorAdapter v1, TwapAggregatorAdapterV2 v2) = _pair(VIRTUAL_POOL, VIRTUAL, USDC_USD, 90_000);
		assertLe(v2.poolDepthUsd(), v1.poolDepthUsd());
	}
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `set -a && . ./.env && set +a && BASE_MAINNET_RPC=$BASE_RPC_URL forge test --match-path test/TwapAggregatorAdapterV2Fork.t.sol -vv`
Expected: compile FAIL, "TwapAggregatorAdapterV2.sol: No such file".

- [ ] **Step 4: Create `TwapAggregatorAdapterV2.sol`**

Copy `src/pricing/TwapAggregatorAdapter.sol` to `src/pricing/TwapAggregatorAdapterV2.sol`. Then:
1. Delete the `IConcentratedPoolOracle` interface declaration, and add `import {IConcentratedPoolOracle} from './TwapAggregatorAdapter.sol';`.
2. Rename `contract TwapAggregatorAdapter` to `contract TwapAggregatorAdapterV2`, and change the title to `/// @title TwapAggregatorAdapterV2`.
3. Replace the natspec depth sentence (lines 34–38 of v1) with:

```solidity
///      The liquidity floor does not revert: `isBelowFloor()` reports it, the registry runs a
///      72-hour clock, and the exposure caps bound what a thin pool can move. Depth = USD of the
///      QUOTE token (USDC/WETH) held within ±10% of the price — the real bids an asset seller
///      meets — the lower of the window's harmonic-mean liquidity over the band and what current
///      liquidity actually holds in it. The asset side is never counted: a one-sided position of
///      a self-priced token is not depth (v1 counted it; see LUMIA in the fork test).
///      `updatedAt` is the read's own timestamp.
```

4. Replace the bodies of `_spotBandDepthUsd18` and `_depthUsd18` with quote-only versions:

```solidity
	/// @dev Walks the initialized ticks within ±10% of spot outward from the current price,
	///      summing the QUOTE token each segment's active liquidity holds.
	function _spotBandDepthUsd18(int24, uint256 quoteUsd18) internal view returns (uint256) {
		(bool ok, bytes memory data) = address(pool).staticcall(abi.encodeWithSignature('slot0()'));
		if (!ok || data.length < 64) revert ObservationWindowUnavailable();
		(uint160 sqrtPrice, int24 spotTick) = abi.decode(data, (uint160, int24));
		BandWalk memory w = BandWalk(sqrtPrice, pool.tickSpacing(), int256(uint256(pool.liquidity())), spotTick, 0, 0);
		int256 current = w.active;

		int24 upper = spotTick + BAND_UP_TICKS > TickMath.MAX_TICK ? TickMath.MAX_TICK : spotTick + BAND_UP_TICKS;
		_walkUp(w, spotTick, upper);
		w.active = current;
		w.prev = spotTick;
		int24 lower = spotTick - BAND_DOWN_TICKS < TickMath.MIN_TICK ? TickMath.MIN_TICK : spotTick - BAND_DOWN_TICKS;
		_walkDown(w, spotTick, lower);

		uint256 quoteAmount = assetIsToken0 ? w.amount1 : w.amount0;
		return Math.mulDiv(quoteAmount, quoteUsd18, 10 ** quoteDecimals);
	}
```

```solidity
	/// @dev USD of the QUOTE token `liquidity` holds between −10% and +10% of the mean price.
	function _depthUsd18(int24 meanTick, uint128 liquidity, uint256 quoteUsd18) internal view returns (uint256) {
		int24 lowerTick = meanTick - BAND_DOWN_TICKS < TickMath.MIN_TICK ? TickMath.MIN_TICK : meanTick - BAND_DOWN_TICKS;
		int24 upperTick = meanTick + BAND_UP_TICKS > TickMath.MAX_TICK ? TickMath.MAX_TICK : meanTick + BAND_UP_TICKS;
		(uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
			TickMath.getSqrtRatioAtTick(meanTick),
			TickMath.getSqrtRatioAtTick(lowerTick),
			TickMath.getSqrtRatioAtTick(upperTick),
			liquidity
		);
		uint256 quoteAmount = assetIsToken0 ? amount1 : amount0;
		return Math.mulDiv(quoteAmount, quoteUsd18, 10 ** quoteDecimals);
	}
```

The `spotBandDepthUsd()` and `_depthUsd()` callers stay unchanged (`_spotBandDepthUsd18(meanTick, …)` still compiles; the unnamed first parameter is intentional).

- [ ] **Step 5: Run the test to verify it passes, plus the full suite**

Run: `BASE_MAINNET_RPC=$BASE_RPC_URL forge test --match-path test/TwapAggregatorAdapterV2Fork.t.sol -vv`
Expected: 3 passed.
Run: `forge test`
Expected: all previously passing tests still pass (the fork tests skip without an RPC).

- [ ] **Step 6: Hand the diff to the founder** (`git status --short`, `git diff --stat`). No commit.

---

### Task 2: TwapListingRegistryV2

**Files:**
- Create: `src/pricing/TwapListingRegistryV2.sol`
- Test: `test/TwapListingRegistryV2.t.sol` (unit: access control and config), with fork coverage in Task 7.

**Interfaces:**
- Consumes: `TwapAggregatorAdapterV2` (Task 1); `IUniswapV3PoolFactory`, `ISlipstreamPoolFactory`, `IValueInterpreterAssetInfo` imported from `./TwapListingRegistry.sol`.
- Produces:
  - `enum Venue { UniswapV3, Slipstream, Slipstream2, Slipstream3 }`
  - `function list(address asset, address quote, Venue venue, int24 feeOrTickSpacing) external returns (TwapAggregatorAdapterV2)` (listers only)
  - `function repoint(address asset, address quote, Venue venue, int24 feeOrTickSpacing) external returns (TwapAggregatorAdapterV2)` (listers only)
  - `function pokeFloor(address asset) external returns (bool below)` (anyone)
  - `function listings(address) external view returns (TwapAggregatorAdapterV2 adapter, address pool, address quote, uint64 listedAt, uint64 belowFloorSince)`. This is the SAME 5-field shape as v1, so the deployed `TwapFloorLens` still reads it.
  - `function venueOf(address) external view returns (Venue)`
  - `function adapterOf(address) external view returns (address)`
  - `function isDelisted(address) public view returns (bool)`
  - `function isTwapPriced(address) public view returns (bool)`
  - `function getListedAssets() external view returns (address[] memory)`
  - `function listedCount() external view returns (uint256)`
  - `function getListedAssetsPage(uint256 offset, uint256 limit) external view returns (address[] memory)`
  - owner: `setQuote(address quote, AggregatorV3Interface feed, uint32 heartbeat)`, `setLister(address lister, bool allowed)`

- [ ] **Step 1: Write the failing unit test**

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {TwapListingRegistryV2} from '../src/pricing/TwapListingRegistryV2.sol';
import {IUniswapV3PoolFactory, ISlipstreamPoolFactory} from '../src/pricing/TwapListingRegistry.sol';
import {IValueInterpreter} from '../src/interfaces/IValueInterpreter.sol';
import {AggregatorV3Interface} from '../src/interfaces/AggregatorV3Interface.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

contract TwapListingRegistryV2Test is Test {
	TwapListingRegistryV2 internal r;
	address internal vi = makeAddr('vi');
	address internal stranger = makeAddr('stranger');

	function setUp() public {
		r = new TwapListingRegistryV2(
			IValueInterpreter(vi),
			IUniswapV3PoolFactory(makeAddr('uni')),
			ISlipstreamPoolFactory(makeAddr('s1')),
			ISlipstreamPoolFactory(makeAddr('s2')),
			ISlipstreamPoolFactory(makeAddr('s3'))
		);
	}

	function test_constructorRejectsZero() public {
		vm.expectRevert(TwapListingRegistryV2.ZeroAddress.selector);
		new TwapListingRegistryV2(
			IValueInterpreter(vi),
			IUniswapV3PoolFactory(makeAddr('uni')),
			ISlipstreamPoolFactory(makeAddr('s1')),
			ISlipstreamPoolFactory(makeAddr('s2')),
			ISlipstreamPoolFactory(address(0))
		);
	}

	function test_deployerIsNotALister() public view {
		assertFalse(r.listers(address(this)), 'v2 listers are granted explicitly (the module)');
	}

	function test_listAndRepointAreListerOnly() public {
		vm.prank(stranger);
		vm.expectRevert(TwapListingRegistryV2.NotLister.selector);
		r.list(makeAddr('a'), makeAddr('q'), TwapListingRegistryV2.Venue.UniswapV3, 3000);
		vm.prank(stranger);
		vm.expectRevert(TwapListingRegistryV2.NotLister.selector);
		r.repoint(makeAddr('a'), makeAddr('q'), TwapListingRegistryV2.Venue.UniswapV3, 3000);
	}

	function test_configIsOwnerOnly() public {
		vm.startPrank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		r.setQuote(makeAddr('q'), AggregatorV3Interface(makeAddr('f')), 3600);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		r.setLister(stranger, true);
		vm.stopPrank();
	}

	function test_pagination() public view {
		assertEq(r.listedCount(), 0);
		assertEq(r.getListedAssetsPage(0, 50).length, 0);
		assertEq(r.getListedAssetsPage(10, 50).length, 0, 'offset past the end is empty, never reverts');
	}

	function test_pokeUnlistedReverts() public {
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.NotListed.selector, makeAddr('a')));
		r.pokeFloor(makeAddr('a'));
	}
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `forge test --match-path test/TwapListingRegistryV2.t.sol -vv`
Expected: compile FAIL (file missing).

- [ ] **Step 3: Write `src/pricing/TwapListingRegistryV2.sol`**

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {AggregatorV3Interface} from '../interfaces/AggregatorV3Interface.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {IConcentratedPoolOracle} from './TwapAggregatorAdapter.sol';
import {TwapAggregatorAdapterV2} from './TwapAggregatorAdapterV2.sol';
import {IUniswapV3PoolFactory, ISlipstreamPoolFactory, IValueInterpreterAssetInfo} from './TwapListingRegistry.sol';

/// @title TwapListingRegistryV2
/// @notice Lists long-tail assets on the TWAP price tier, open to automation: a listing is
///         checked, not trusted.
///         - The pool comes from a canonical factory: Uniswap v3, or one of Aerodrome's three
///           Slipstream deployments (`getPool`).
///         - The quote token is allow-listed with its Chainlink USD feed (USDC, WETH).
///         - The asset has no price in the ValueInterpreter yet (a higher tier always wins).
///         - The adapter is deployed here with fixed parameters, must price now, and must hold at
///           least MIN_DEPTH_USD of the QUOTE token within ±10% of the price. One-sided liquidity
///           of a self-priced token is not depth.
///         `repoint` moves a listing to a pool at least 25% deeper, or to any qualifying pool once
///         the current one is under the floor. `pokeFloor` (anyone) runs the 72-hour delist clock
///         exactly like v1.
/// @dev Listers are granted explicitly (the PriceListingModule, which also writes the VI
///      primitive in the same transaction). `listings()` keeps v1's 5-field shape so v1 readers
///      (TwapFloorLens) keep working.
contract TwapListingRegistryV2 is Ownable2Step {
	/// @notice Fixed adapter parameters, not the lister's choice.
	uint32 public constant WINDOW = 30 minutes;
	uint16 public constant MAX_DEVIATION_BPS = 500;
	uint256 public constant MIN_DEPTH_USD = 50_000;
	/// @notice How long a pool may stay under the floor before its asset is delisted.
	uint256 public constant DELIST_GRACE = 72 hours;
	/// @notice A repoint must reach a pool this much deeper (125%), unless the current one is under the floor.
	uint256 public constant REPOINT_MARGIN_BPS = 12_500;
	uint256 private constant BPS = 10_000;

	enum Venue {
		UniswapV3,
		Slipstream,
		Slipstream2,
		Slipstream3
	}

	struct Quote {
		AggregatorV3Interface feed;
		uint32 heartbeat;
	}

	struct Listing {
		TwapAggregatorAdapterV2 adapter;
		address pool;
		address quote;
		uint64 listedAt;
		uint64 belowFloorSince; // 0 = at/over the floor (as of the last poke)
	}

	IValueInterpreter public immutable valueInterpreter;
	IUniswapV3PoolFactory public immutable uniswapFactory;
	ISlipstreamPoolFactory public immutable slipstreamFactory;
	ISlipstreamPoolFactory public immutable slipstream2Factory;
	ISlipstreamPoolFactory public immutable slipstream3Factory;

	mapping(address => Quote) public quotes;
	mapping(address => Listing) public listings;
	mapping(address => Venue) public venueOf;
	mapping(address => bool) public listers;
	address[] internal listedAssets;

	event QuoteSet(address indexed quote, address feed, uint32 heartbeat);
	event ListerSet(address indexed lister, bool allowed);
	event Listed(address indexed asset, address indexed adapter, address pool, address quote, Venue venue, uint256 depthUsd18);
	event Repointed(address indexed asset, address indexed adapter, address pool, address quote, Venue venue, uint256 depthUsd18);
	event FloorBreached(address indexed asset, uint256 since);
	event FloorRestored(address indexed asset);

	error ZeroAddress();
	error NotLister();
	error QuoteNotAllowed(address quote);
	error AlreadyPriced(address asset);
	error AlreadyListed(address asset);
	error NotListed(address asset);
	error PoolNotFound(address asset, address quote);
	error SamePool(address pool);
	error BelowFloorAtListing(uint256 depthUsd18);
	error NotDeepEnough(uint256 currentDepthUsd18, uint256 newDepthUsd18);

	constructor(
		IValueInterpreter valueInterpreter_,
		IUniswapV3PoolFactory uniswapFactory_,
		ISlipstreamPoolFactory slipstreamFactory_,
		ISlipstreamPoolFactory slipstream2Factory_,
		ISlipstreamPoolFactory slipstream3Factory_
	) Ownable(msg.sender) {
		if (
			address(valueInterpreter_) == address(0) || address(uniswapFactory_) == address(0)
				|| address(slipstreamFactory_) == address(0) || address(slipstream2Factory_) == address(0)
				|| address(slipstream3Factory_) == address(0)
		) {
			revert ZeroAddress();
		}
		valueInterpreter = valueInterpreter_;
		uniswapFactory = uniswapFactory_;
		slipstreamFactory = slipstreamFactory_;
		slipstream2Factory = slipstream2Factory_;
		slipstream3Factory = slipstream3Factory_;
	}

	// ─── owner config ───────────────────────────────────────────────────────────

	/// @notice Allow a quote token with its Chainlink USD feed; feed = 0 disallows it for new listings.
	function setQuote(address quote, AggregatorV3Interface feed, uint32 heartbeat) external onlyOwner {
		if (quote == address(0)) revert ZeroAddress();
		quotes[quote] = Quote(feed, heartbeat);
		emit QuoteSet(quote, address(feed), heartbeat);
	}

	function setLister(address lister, bool allowed) external onlyOwner {
		listers[lister] = allowed;
		emit ListerSet(lister, allowed);
	}

	// ─── listing ────────────────────────────────────────────────────────────────

	/// @notice List `asset` against `quote` on the canonical pool of `venue`
	///         (`feeOrTickSpacing`: Uniswap fee tier, or Slipstream tick spacing).
	function list(address asset, address quote, Venue venue, int24 feeOrTickSpacing)
		external
		returns (TwapAggregatorAdapterV2 adapter)
	{
		if (!listers[msg.sender]) revert NotLister();
		if (valueInterpreter.isSupportedAsset(asset)) revert AlreadyPriced(asset);
		if (address(listings[asset].adapter) != address(0)) revert AlreadyListed(asset);

		address pool;
		uint256 depth;
		(adapter, pool, depth) = _qualify(asset, quote, venue, feeOrTickSpacing);

		listedAssets.push(asset);
		listings[asset] = Listing(adapter, pool, quote, uint64(block.timestamp), 0);
		venueOf[asset] = venue;
		emit Listed(asset, address(adapter), pool, quote, venue, depth);
	}

	/// @notice Move `asset`'s listing to another canonical pool: at least REPOINT_MARGIN_BPS
	///         deeper, or any qualifying pool while the current one is under the floor / unanswerable.
	function repoint(address asset, address quote, Venue venue, int24 feeOrTickSpacing)
		external
		returns (TwapAggregatorAdapterV2 adapter)
	{
		if (!listers[msg.sender]) revert NotLister();
		Listing storage l = listings[asset];
		if (address(l.adapter) == address(0)) revert NotListed(asset);

		address pool;
		uint256 depth;
		(adapter, pool, depth) = _qualify(asset, quote, venue, feeOrTickSpacing);
		if (pool == l.pool) revert SamePool(pool);

		(bool currentOk, uint256 currentDepth) = _currentDepth(l.adapter);
		if (currentOk && depth < Math.mulDiv(currentDepth, REPOINT_MARGIN_BPS, BPS)) {
			revert NotDeepEnough(currentDepth, depth);
		}

		l.adapter = adapter;
		l.pool = pool;
		l.quote = quote;
		l.belowFloorSince = 0;
		venueOf[asset] = venue;
		emit Repointed(asset, address(adapter), pool, quote, venue, depth);
	}

	/// @notice Start or clear `asset`'s 72-hour clock from the pool's current state. Anyone may call
	///         it; a pool that can no longer serve the window counts as under the floor.
	/// @return below whether the pool is under the floor now
	function pokeFloor(address asset) external returns (bool below) {
		Listing storage l = listings[asset];
		if (address(l.adapter) == address(0)) revert NotListed(asset);
		try l.adapter.isBelowFloor() returns (bool b) {
			below = b;
		} catch {
			below = true;
		}
		if (below && l.belowFloorSince == 0) {
			l.belowFloorSince = uint64(block.timestamp);
			emit FloorBreached(asset, block.timestamp);
		} else if (!below && l.belowFloorSince != 0) {
			l.belowFloorSince = 0;
			emit FloorRestored(asset);
		}
	}

	// ─── views ──────────────────────────────────────────────────────────────────

	/// @notice The adapter a listing prices through; 0 if never listed.
	function adapterOf(address asset) external view returns (address) {
		return address(listings[asset].adapter);
	}

	/// @notice True once the pool has been under the floor for DELIST_GRACE (as of the last poke).
	function isDelisted(address asset) public view returns (bool) {
		uint64 since = listings[asset].belowFloorSince;
		return since != 0 && block.timestamp >= since + DELIST_GRACE;
	}

	/// @notice True while the VI prices `asset` through this registry's adapter (what the
	///         exposure policy caps and what `repoint` may rewrite).
	function isTwapPriced(address asset) public view returns (bool) {
		Listing storage l = listings[asset];
		if (address(l.adapter) == address(0)) return false;
		(address aggregator,,,) = IValueInterpreterAssetInfo(address(valueInterpreter)).getAssetInfo(asset);
		return aggregator == address(l.adapter);
	}

	function getListedAssets() external view returns (address[] memory) {
		return listedAssets;
	}

	function listedCount() external view returns (uint256) {
		return listedAssets.length;
	}

	/// @notice `limit` listed assets from `offset`, in listing order; empty past the end.
	function getListedAssetsPage(uint256 offset, uint256 limit) external view returns (address[] memory page) {
		uint256 n = listedAssets.length;
		if (offset >= n) return new address[](0);
		uint256 end = offset + limit > n ? n : offset + limit;
		page = new address[](end - offset);
		for (uint256 i = offset; i < end; ++i) {
			page[i - offset] = listedAssets[i];
		}
	}

	// ─── internals ──────────────────────────────────────────────────────────────

	/// @dev Resolve the canonical pool, deploy its adapter, and require it to price now and hold the
	///      quote-side floor.
	function _qualify(address asset, address quote, Venue venue, int24 feeOrTickSpacing)
		internal
		returns (TwapAggregatorAdapterV2 adapter, address pool, uint256 depth)
	{
		Quote memory q = quotes[quote];
		if (address(q.feed) == address(0)) revert QuoteNotAllowed(quote);

		pool = _getPool(asset, quote, venue, feeOrTickSpacing);
		if (pool == address(0)) revert PoolNotFound(asset, quote);

		adapter = new TwapAggregatorAdapterV2(
			IConcentratedPoolOracle(pool),
			asset,
			q.feed,
			WINDOW,
			MIN_DEPTH_USD,
			MAX_DEVIATION_BPS,
			q.heartbeat,
			string.concat(IERC20Metadata(asset).symbol(), ' / USD (TWAP)')
		);
		// must price NOW (window served, spot on the average) with the quote side over the floor
		adapter.latestRoundData();
		depth = adapter.poolDepthUsd();
		if (depth < MIN_DEPTH_USD * 1e18) revert BelowFloorAtListing(depth);
	}

	function _getPool(address asset, address quote, Venue venue, int24 feeOrTickSpacing) internal view returns (address) {
		if (venue == Venue.UniswapV3) {
			if (feeOrTickSpacing <= 0) return address(0);
			return uniswapFactory.getPool(asset, quote, uint24(feeOrTickSpacing));
		}
		ISlipstreamPoolFactory f = venue == Venue.Slipstream
			? slipstreamFactory
			: (venue == Venue.Slipstream2 ? slipstream2Factory : slipstream3Factory);
		return f.getPool(asset, quote, feeOrTickSpacing);
	}

	/// @dev (answerable, depth) of the current adapter; an adapter that reverts or sits under the
	///      floor counts as not answerable, so any qualifying pool may replace it.
	function _currentDepth(TwapAggregatorAdapterV2 adapter) internal view returns (bool ok, uint256 depth) {
		try adapter.poolDepthUsd() returns (uint256 d) {
			return (d >= MIN_DEPTH_USD * 1e18, d);
		} catch {
			return (false, 0);
		}
	}
}
```

- [ ] **Step 4: Run the unit test and the full suite**

Run: `forge test --match-path test/TwapListingRegistryV2.t.sol -vv`, expect 6 passed. Then `forge test`, expect everything else green.

- [ ] **Step 5: Hand the diff to the founder.** No commit.

---

### Task 3: PriceListingModule (VI owner, permissionless TWAP listing)

**Files:**
- Create: `src/pricing/PriceListingModule.sol`
- Test: `test/PriceListingModule.t.sol` (unit, real `ValueInterpreter`, with the registry pranked where needed)

**Interfaces:**
- Consumes: `ValueInterpreter` (`addPrimitive`, `isSupportedAsset`, `getAssetInfo`, Ownable2Step), `TwapListingRegistryV2` (Task 2).
- Produces:
  - `contract PriceListingModule is Ownable2Step, ReentrancyGuard`
  - `constructor(ValueInterpreter vi_, TwapListingRegistryV2 registry_)`
  - `function list(address asset, address quote, TwapListingRegistryV2.Venue venue, int24 feeOrTickSpacing) external returns (address adapter)` (anyone)
  - `function repoint(address asset, address quote, TwapListingRegistryV2.Venue venue, int24 feeOrTickSpacing) external returns (address adapter)` (anyone)
  - `function execute(bytes calldata data) external returns (bytes memory)` (owner only; forwards to the VI; bubbles reverts)
  - `uint32 public constant TWAP_HEARTBEAT = 3600`

- [ ] **Step 1: Write the failing test**

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {PriceListingModule} from '../src/pricing/PriceListingModule.sol';
import {TwapListingRegistryV2} from '../src/pricing/TwapListingRegistryV2.sol';
import {IUniswapV3PoolFactory, ISlipstreamPoolFactory} from '../src/pricing/TwapListingRegistry.sol';
import {IValueInterpreter} from '../src/interfaces/IValueInterpreter.sol';
import {MockERC20} from './utils/Mocks.sol';

/// @dev A Chainlink-style feed the VI accepts (8 decimals, fresh).
contract FixedFeed {
	int256 public answer = 1e8;
	function decimals() external pure returns (uint8) { return 8; }
	function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
		return (1, answer, block.timestamp, block.timestamp, 1);
	}
}

contract PriceListingModuleTest is Test {
	ValueInterpreter internal vi;
	TwapListingRegistryV2 internal registry;
	PriceListingModule internal module;
	MockERC20 internal priced;
	address internal stranger = makeAddr('stranger');

	function setUp() public {
		vi = new ValueInterpreter(address(this));
		registry = new TwapListingRegistryV2(
			IValueInterpreter(address(vi)),
			IUniswapV3PoolFactory(makeAddr('uni')),
			ISlipstreamPoolFactory(makeAddr('s1')),
			ISlipstreamPoolFactory(makeAddr('s2')),
			ISlipstreamPoolFactory(makeAddr('s3'))
		);
		module = new PriceListingModule(vi, registry);
		registry.setLister(address(module), true);
		priced = new MockERC20('Priced', 'PRC', 18);
		vi.addPrimitive(address(priced), address(new FixedFeed()), 3600);
		// hand the VI to the module (two-step): transfer, then the module's owner accepts through execute
		vi.transferOwnership(address(module));
		module.execute(abi.encodeWithSignature('acceptOwnership()'));
	}

	function test_moduleOwnsTheVi() public view {
		assertEq(vi.owner(), address(module));
	}

	function test_executeOnlyOwner() public {
		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		module.execute(abi.encodeCall(ValueInterpreter.removePrimitive, (address(priced))));
		// governance still administers the VI through the module
		module.execute(abi.encodeCall(ValueInterpreter.removePrimitive, (address(priced))));
		assertFalse(vi.isSupportedAsset(address(priced)));
	}

	function test_executeForwardsRevert() public {
		vm.expectRevert(abi.encodeWithSelector(ValueInterpreter.UnsupportedAsset.selector, stranger));
		module.execute(abi.encodeCall(ValueInterpreter.removePrimitive, (stranger)));
	}

	function test_cannotListOrRepointChainlinkAsset() public {
		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(PriceListingModule.AlreadyPriced.selector, address(priced)));
		module.list(address(priced), makeAddr('q'), TwapListingRegistryV2.Venue.UniswapV3, 3000);
		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(PriceListingModule.NotTwapPriced.selector, address(priced)));
		module.repoint(address(priced), makeAddr('q'), TwapListingRegistryV2.Venue.UniswapV3, 3000);
	}
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `forge test --match-path test/PriceListingModule.t.sol -vv`
Expected: compile FAIL (file missing). If `ValueInterpreter.UnsupportedAsset` or `MockERC20`'s path differ, read `src/core/ValueInterpreter.sol` / `test/utils/Mocks.sol` and match the real names. Don't invent them.

- [ ] **Step 3: Write `src/pricing/PriceListingModule.sol`**

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {ValueInterpreter} from '../core/ValueInterpreter.sol';
import {TwapListingRegistryV2} from './TwapListingRegistryV2.sol';

/// @title PriceListingModule
/// @notice Owns the ValueInterpreter so TWAP listings go live without a governance round.
///         - `list` / `repoint` are open to anyone. Each runs the registry's checks (canonical
///           pool, allowed quote, prices now, ≥ $50k quote-side depth) and then writes the TWAP
///           primitive in the same transaction.
///         - They can never touch an asset the VI already prices another way: Chainlink,
///           derivative, zero-priced, or another registry's adapter.
///         - Every other VI admin call goes through `execute`, which only this module's owner
///           (governance) can make.
contract PriceListingModule is Ownable2Step, ReentrancyGuard {
	/// @notice VI staleness bound for TWAP primitives; the adapter stamps each read with its own timestamp.
	uint32 public constant TWAP_HEARTBEAT = 3600;

	ValueInterpreter public immutable valueInterpreter;
	TwapListingRegistryV2 public immutable registry;

	event TwapListed(address indexed asset, address indexed adapter, address indexed caller);
	event TwapRepointed(address indexed asset, address indexed adapter, address indexed caller);
	event Executed(bytes data);

	error ZeroAddress();
	error AlreadyPriced(address asset);
	error NotTwapPriced(address asset);

	constructor(ValueInterpreter valueInterpreter_, TwapListingRegistryV2 registry_) Ownable(msg.sender) {
		if (address(valueInterpreter_) == address(0) || address(registry_) == address(0)) revert ZeroAddress();
		valueInterpreter = valueInterpreter_;
		registry = registry_;
	}

	/// @notice List `asset` on the TWAP tier and price it in the VI (anyone).
	function list(address asset, address quote, TwapListingRegistryV2.Venue venue, int24 feeOrTickSpacing)
		external
		nonReentrant
		returns (address adapter)
	{
		if (valueInterpreter.isSupportedAsset(asset)) revert AlreadyPriced(asset);
		adapter = address(registry.list(asset, quote, venue, feeOrTickSpacing));
		valueInterpreter.addPrimitive(asset, adapter, TWAP_HEARTBEAT);
		emit TwapListed(asset, adapter, msg.sender);
	}

	/// @notice Move a TWAP listing to a deeper pool and repoint the VI (anyone; the registry
	///         enforces the depth margin).
	function repoint(address asset, address quote, TwapListingRegistryV2.Venue venue, int24 feeOrTickSpacing)
		external
		nonReentrant
		returns (address adapter)
	{
		if (!registry.isTwapPriced(asset)) revert NotTwapPriced(asset);
		adapter = address(registry.repoint(asset, quote, venue, feeOrTickSpacing));
		valueInterpreter.addPrimitive(asset, adapter, TWAP_HEARTBEAT);
		emit TwapRepointed(asset, adapter, msg.sender);
	}

	/// @notice Governance passthrough: any VI admin call (addPrimitive for Chainlink assets,
	///         derivatives, bounds, sequencer feed, ownership…). Reverts bubble up unchanged.
	function execute(bytes calldata data) external onlyOwner returns (bytes memory result) {
		bool ok;
		(ok, result) = address(valueInterpreter).call(data);
		if (!ok) {
			assembly ('memory-safe') {
				revert(add(result, 32), mload(result))
			}
		}
		emit Executed(data);
	}
}
```

- [ ] **Step 4: Run the tests**

Run: `forge test --match-path test/PriceListingModule.t.sol -vv`, expect 4 passed. Then `forge test`, all green.

- [ ] **Step 5: Hand the diff to the founder.** No commit.

---

### Task 4: TwapExposurePolicyV2

**Files:**
- Create: `src/policies/TwapExposurePolicyV2.sol`
- Test: `test/TwapExposurePolicyV2.t.sol`

**Interfaces:**
- Consumes: `TwapListingRegistryV2` (`isTwapPriced`, `isDelisted`, `adapterOf`), `TwapAggregatorAdapterV2.poolDepthUsd()` (quote-side).
- Produces: `contract TwapExposurePolicyV2 is IPolicy` with v1's exact constants, hooks, errors and behaviour, bound to `TwapListingRegistryV2 public immutable registry`.

- [ ] **Step 1: Create the file by copying v1 and changing only the types**

```bash
cd ~/FrostyFunds/funds-core
sed -e 's/contract TwapExposurePolicy is/contract TwapExposurePolicyV2 is/' \
    -e 's/@title TwapExposurePolicy$/@title TwapExposurePolicyV2/' \
    -e "s#import {TwapListingRegistry} from '../pricing/TwapListingRegistry.sol';#import {TwapListingRegistryV2} from '../pricing/TwapListingRegistryV2.sol';#" \
    -e "s#import {TwapAggregatorAdapter} from '../pricing/TwapAggregatorAdapter.sol';#import {TwapAggregatorAdapterV2} from '../pricing/TwapAggregatorAdapterV2.sol';#" \
    -e 's/TwapListingRegistry public immutable registry/TwapListingRegistryV2 public immutable registry/' \
    -e 's/constructor(TwapListingRegistry registry_)/constructor(TwapListingRegistryV2 registry_)/' \
    -e 's/TwapAggregatorAdapter(registry.adapterOf(asset))/TwapAggregatorAdapterV2(registry.adapterOf(asset))/' \
    src/policies/TwapExposurePolicy.sol > src/policies/TwapExposurePolicyV2.sol
grep -n "TwapListingRegistry\b\|TwapAggregatorAdapter\b" src/policies/TwapExposurePolicyV2.sol   # must print nothing
```

Then edit the `@notice` line "per asset, at most 10% of its pool's ±10% depth" to read "per asset, at most 10% of its pool's ±10% QUOTE-side depth (50% once ≥ $250k)".

- [ ] **Step 2: Write the test by porting v1's policy test**

Copy `test/TwapExposurePolicy.t.sol` to `test/TwapExposurePolicyV2.t.sol` and make these substitutions:
- `TwapExposurePolicy` → `TwapExposurePolicyV2`;
- `TwapListingRegistry` → `TwapListingRegistryV2`;
- `TwapAggregatorAdapter` → `TwapAggregatorAdapterV2`.

Update every registry constructor call to pass a fifth factory. v1 lists from `address(this)`, so wherever the v1 test lists, first call `registry.setLister(address(this), true)`. Keep every assertion. The ported suite must pass unchanged in meaning: caps, delisted buy block, deposit pause, degen skip.

- [ ] **Step 3: Run it**

Run: `forge test --match-path test/TwapExposurePolicyV2.t.sol -vv`
Expected: the same test count as `test/TwapExposurePolicy.t.sol`, all passed.

- [ ] **Step 4: Hand the diff to the founder.** No commit.

---

### Task 5: TwapFloorLensV2 (paginated)

**Files:**
- Create: `src/pricing/TwapFloorLensV2.sol`
- Test: `test/TwapFloorLensV2.t.sol`

**Interfaces:**
- Consumes: `TwapListingRegistryV2.getListedAssetsPage`, `listings`, `listedCount`.
- Produces: `function assetsNeedingPoke(TwapListingRegistryV2 registry, uint256 offset, uint256 limit) external view returns (address[] memory due, uint256 nextOffset)`. `nextOffset == registry.listedCount()` means done.

- [ ] **Step 1: Write the failing test** (empty registry, then paging bounds)

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {TwapFloorLensV2} from '../src/pricing/TwapFloorLensV2.sol';
import {TwapListingRegistryV2} from '../src/pricing/TwapListingRegistryV2.sol';
import {IUniswapV3PoolFactory, ISlipstreamPoolFactory} from '../src/pricing/TwapListingRegistry.sol';
import {IValueInterpreter} from '../src/interfaces/IValueInterpreter.sol';

contract TwapFloorLensV2Test is Test {
	function test_pagination() public {
		TwapListingRegistryV2 r = new TwapListingRegistryV2(
			IValueInterpreter(makeAddr('vi')),
			IUniswapV3PoolFactory(makeAddr('uni')),
			ISlipstreamPoolFactory(makeAddr('s1')),
			ISlipstreamPoolFactory(makeAddr('s2')),
			ISlipstreamPoolFactory(makeAddr('s3'))
		);
		TwapFloorLensV2 lens = new TwapFloorLensV2();
		(address[] memory due, uint256 next) = lens.assetsNeedingPoke(r, 0, 50);
		assertEq(due.length, 0);
		assertEq(next, 0);
		(due, next) = lens.assetsNeedingPoke(r, 99, 50);
		assertEq(due.length, 0, 'offset past the end is empty');
		assertEq(next, 0, 'next clamps to listedCount');
	}
}
```

Real listings are covered by the Task 7 fork test (`test_fork_lensPagesRealListings`).

- [ ] **Step 2: Run it (FAIL), then write the lens**

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {TwapListingRegistryV2} from './TwapListingRegistryV2.sol';
import {TwapAggregatorAdapterV2} from './TwapAggregatorAdapterV2.sol';

/// @title TwapFloorLensV2
/// @notice Paged version of TwapFloorLens for a registry with hundreds of listings: which assets
///         in [offset, offset+limit) would `pokeFloor` change now?
/// @dev Same rule as v1 (an adapter that cannot answer counts as under the floor), per page, so
///      one eth_call stays within RPC gas caps.
contract TwapFloorLensV2 {
	function assetsNeedingPoke(TwapListingRegistryV2 registry, uint256 offset, uint256 limit)
		external
		view
		returns (address[] memory due, uint256 nextOffset)
	{
		address[] memory assets = registry.getListedAssetsPage(offset, limit);
		uint256 n = registry.listedCount();
		nextOffset = offset + assets.length;
		if (nextOffset > n) nextOffset = n;
		due = new address[](assets.length);
		uint256 count;
		for (uint256 i; i < assets.length; ++i) {
			(TwapAggregatorAdapterV2 adapter,,,, uint64 belowFloorSince) = registry.listings(assets[i]);
			bool below;
			try adapter.isBelowFloor() returns (bool b) {
				below = b;
			} catch {
				below = true;
			}
			if (below != (belowFloorSince != 0)) due[count++] = assets[i];
		}
		assembly ('memory-safe') {
			mstore(due, count)
		}
	}
}
```

- [ ] **Step 3: Run it.** Expect 1 passed; `forge test` green.

- [ ] **Step 4: Hand the diff to the founder.** No commit.

---

### Task 6: Deploy script (mainnet wiring)

**Files:**
- Create: `script/mainnet/DeployTwapListingV2.s.sol`
- Modify: `script/mainnet/FundsMainnet.sol`, the `CL_ETH_USD` constant only: set it to the standard proxy `0x50015f8b17fb2C290Dde41fDc246ed0dcEE93a8b` so a future genesis never repeats the SVR feed. Nothing reads this constant after genesis, so no deployed behaviour changes.

**Interfaces:**
- Consumes: the live genesis addresses from `deployments/base-mainnet.json` (`valueInterpreter`, `factory`, `twapPolicy`).
- Produces: `deployments/base-mainnet-twap-v2.json` with keys `registry`, `module`, `policy`, `lens`, `slipstream3Adapter`, `startBlock`. Plans B (keeper) and C (terminal) consume this file.

The script, run by the deployer, which still owns the VI and the FundFactory:
1. Deploys `TwapListingRegistryV2(vi, uniV3 0x33128a…FDfD, slip1 0x5e7B…809A, slip2 0xf8f2…61Ef, slip3 0xaDe6…716a)`, then calls `setQuote(USDC, 0x7e86…bc6B, 90000)` and `setQuote(WETH, 0x5001…3a8b, 3600)`.
2. Deploys `PriceListingModule(vi, registry)` and calls `registry.setLister(module, true)`.
3. Deploys `TwapExposurePolicyV2(registry)` and `TwapFloorLensV2`.
4. Deploys `AerodromeSlipstreamSwapAdapter(0xcbBb8035cAc7D4B3Ca7aBb74cF7BdF900215Ce0D)` and calls `factory.registerAdapter(it)`.
5. Calls `factory.setMandatoryPolicies(list)`: read `factory.getMandatoryPolicies()` and replace EVERY entry whose `policy == deployments.twapPolicy` with the V2 policy, keeping each entry's hook. On mainnet today that's 4 entries (hooks 4, 0, 5, 6), all `0xB2be…E2Df`, verified 2026-09-30. Require exactly 4 replacements and 4 entries after.
6. Fixes the WETH feed: `vi.addPrimitive(WETH, 0x5001…3a8b, 3600)`.
7. Hands the VI to the module: `vi.transferOwnership(module)` then `module.execute(abi.encodeWithSignature('acceptOwnership()'))`. Then assert `vi.owner() == module`, `module.owner() == deployer`, `registry.listers(module)` and `!registry.listers(deployer)`.

Known limit, to record in the script natspec and the runbook:
- Funds created BEFORE this script keep `TwapExposurePolicy` v1, which reads the empty v1 registry, so V2 listings are uncapped for them and the delisted-buy block doesn't apply.
- Today that's only the founder's degen fund, where caps are skipped anyway.
- A later `createReconfigurationRequest` can move it to V2 (the factory's `setPolicyReplacement(v1, v2)` path).

- [ ] **Step 1: Write the script** with exactly those steps in `vm.startBroadcast()`/`vm.stopBroadcast()`. Follow `script/mainnet/DeployProtectMainnet.s.sol` for the file-writing pattern (`vm.serializeAddress`, `vm.writeJson`, `DEPLOYMENTS_FILE` override) and `require(block.chainid == 8453)`.

- [ ] **Step 2: Rehearse on a Base fork as the real deployer**

```bash
set -a && . ./.env && set +a
anvil --port 8549 --chain-id 8453 --fork-url "$BASE_RPC_URL" --silent &
cast rpc anvil_impersonateAccount 0xaE51f2EfE70e57b994BE8F7f97C4dC824c51802a --rpc-url http://127.0.0.1:8549
DEPLOYMENTS_FILE=deployments/rehearsal-twap-v2.json forge script script/mainnet/DeployTwapListingV2.s.sol \
  --rpc-url http://127.0.0.1:8549 --sender 0xaE51f2EfE70e57b994BE8F7f97C4dC824c51802a --unlocked --broadcast --slow
```

Expected: `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`. Then `cast call <vi> 'owner()(address)'` must equal the module.

- [ ] **Step 3: Clean up.** Kill anvil (by PID, not `pkill -f` with a pattern matching the shell), delete `deployments/rehearsal-twap-v2.json`, and delete the `broadcast/`/`cache/` `DeployTwapListingV2.s.sol/8453` folders the rehearsal wrote.

- [ ] **Step 4: Hand the diff to the founder.** No commit.

---

### Task 7: Fork rehearsal of the whole flow (the acceptance test)

**Files:**
- Create: `test/fork/TwapListingV2Fork.t.sol`

**Interfaces:**
- Consumes: everything above, plus the live genesis (VI `0x3CDbaBE5Bf4E6cfE10A2A326E0ad31b2d16398D4`, FundFactory `0x42F213d7f6018BF293bF0ecB727C59A25b5029a3`, UniswapV3SwapAdapter `0x969cBFc5BCB84301EA5690f9ABF2edf9356Ae976`, the live fund's Comptroller `0x833a506d761a4756af279abc24183db407823de9` owned by `0xaE51…802a`).

The test's `setUp` forks Base, pranks the deployer `0xaE51…802a`, and runs the same wiring as Task 6. Put the wiring in an `internal` function of a shared library `script/mainnet/TwapListingV2.sol`, used by both the script and the test (the `FundsMainnet.sol`/`DeployFundsMainnet.s.sol` pattern).

Tests (each `vm.skip(!forked)`):
- `test_fork_permissionlessListRealToken`
  - A stranger calls `module.list(VIRTUAL, USDC, UniswapV3, 3000)`.
  - Then `vi.isSupportedAsset(VIRTUAL)` is true and `vi.calcUsdRate(VIRTUAL) > 0`.
  - `registry.venueOf(VIRTUAL) == UniswapV3`.
- `test_fork_oneSidedJunkRefused`
  - `module.list(LUMIA, WETH, UniswapV3, 3000)` reverts with `TwapListingRegistryV2.BelowFloorAtListing` (selector match).
- `test_fork_wethQuotedListsAndPrices`
  - BRETT `0x532f27101965dd16442E59d40670FaF5eBB142E4` lists on the Slipstream ts200 WETH pool.
  - Use the scan's `batch.json` row: read `~/FrostyFunds/.ops-scratch/twap-scan/batch.json` and copy the exact pool/params into the test as constants, verified with `cast`.
- `test_fork_slipstream3ListsAndTrades`
  - Pick one token whose deepest qualifying pool is ONLY on the third factory. From the scan's "Third Aerodrome factory" list, dry-run with `cast` first, and use a real one, e.g. TRX on Slip3.
  - It lists via `Venue.Slipstream3`.
  - The live fund (as its owner) buys ~1 USDC of it through the new `slipstream3Adapter` with `callOnIntegration`. The vault balance of the token must increase.
- `test_fork_repointNeedsMargin`
  - After listing an asset on its second-deepest real pool, `repoint` to the SAME pool reverts `SamePool`.
  - Repoint to a shallower pool reverts `NotDeepEnough`.
  - Repoint to the deepest pool succeeds only if it's ≥ 1.25× deeper. If no such real pair exists, assert the `NotDeepEnough` path and document it in the test comment.
- `test_fork_cannotHijackPricedAsset`
  - `module.list(WETH, USDC, UniswapV3, 500)` reverts `AlreadyPriced`.
  - `module.repoint(NVDAc, …)` reverts `NotTwapPriced`.
- `test_fork_governancePassthrough`
  - The deployer calls `module.execute(addPrimitive(<a Chainlink token from the 16-token list, e.g. LINK 0x88Fb…e196 with feed 0x17CA…9D65, 90000>))`.
  - `vi.calcUsdRate(LINK) > 0`.
  - A stranger's `execute` reverts.
- `test_fork_policyV2CapsQuoteSide`
  - For a non-degen fund, `TwapExposurePolicyV2` caps a buy at 10% of the quote-side depth.
  - Create a fresh non-degen fund through the factory (it now carries policy V2 as mandatory), deposit, and try to buy more than 10% of VIRTUAL's quote-side depth: it reverts `PoolShareExceeded`.
  - Scale the deposit so the cap binds. If USDC dealing is needed, use `deal` on USDC.
- `test_fork_lensPagesRealListings`
  - After listing 3 real tokens, `lens.assetsNeedingPoke(registry, 0, 2)` returns `next = 2`, and `(…, 2, 2)` returns `next = 3`.

- [ ] **Step 1: Write the test file with the 9 tests above.** Use real constants verified with `cast call` before pasting.
- [ ] **Step 2: Run it:** `BASE_MAINNET_RPC=$BASE_RPC_URL forge test --match-path test/fork/TwapListingV2Fork.t.sol -j 1 -vv`. Expect 9 passed.
- [ ] **Step 3: Run the full suite:** `forge test` (fork tests skip), then the existing genesis rehearsal `BASE_MAINNET_RPC=$BASE_RPC_URL forge test --match-path test/fork/FundsMainnetGenesisFork.t.sol -j 1`. Expect 7 passed.
- [ ] **Step 4: Hand the diff to the founder**, with the test output. No commit.

---

### Task 8: Governance scripts know the new owners

**Files:**
- Modify: `script/mainnet/FundsGovernance.sol`, `script/mainnet/TransferFundsGovernance.s.sol`
- Test: extend `test/fork/FundsMainnetGenesisFork.t.sol` with `test_fork_handoffWithTwapV2`

The handoff must now move: the **module** (which owns the VI) instead of the VI directly; the **registry V2**; the FundFactory; the Veranta factory; and the v1 TWAP registry (still owned, now unused). `verify()` must check:
- `vi.owner() == module` and `module.owner() == timelock`;
- `registryV2.owner() == timelock`;
- `registryV2.listers(module)`, and `!registryV2.listers(deployer)`;
- the mandatory policies are still 4, including `TwapExposurePolicyV2`.

Load the V2 addresses from `deployments/base-mainnet-twap-v2.json` when it exists. If it doesn't, behave exactly as today, so the genesis rehearsal stays green.

- [ ] **Step 1: Write `test_fork_handoffWithTwapV2`.** Genesis → Task 6 wiring → Start → the Safe schedules (impersonated) → warp 2 days → Finish → verify passes. The deployer then holds nothing and cannot call `module.execute`.
- [ ] **Step 2: Implement the `FundsGovernance` changes** (owned list, start, acceptBatch and verify each take an optional V2 struct).
- [ ] **Step 3: Run** the genesis fork file. Expect 7 existing tests + 1 new, all passed.
- [ ] **Step 4: Hand the diff to the founder.** No commit.

---

## Follow-up plans (written after this plan lands; they consume `deployments/base-mainnet-twap-v2.json`)

- **Plan B: keeper auto-lister** (funds-keeper).
  - An hourly job in the protect process:
    1. Incremental `PoolCreated` log scan of the four factories, restricted to pools where token0 or token1 is USDC/WETH (thirdweb getLogs ≤ 1000 blocks per call), plus a one-time backfill.
    2. Each hour, for each unlisted candidate, compute quote-side depth with `TwapAggregatorAdapterV2` bytecode deployed inside `eth_call`, and pick the deepest qualifying pool.
    3. Call `module.list(...)` for it from the keeper wallet (Engine), and `repoint` when a ≥ 1.25× deeper pool appears.
    4. Keep a state file.
  - Also: the prod "TWAP Floor Poke" FrostyFi workflow pages `TwapFloorLensV2`; the health monitor reads V2.
- **Plan C: terminal** (frosty-terminal).
  - Read V2 listings: SPOT + `twap` tag, `venueOf`.
  - The TWAP ticket maps `Slipstream3` → `slipstream3Adapter`.
  - Show the caps from `TwapExposurePolicyV2`.
  - Sync the new addresses into `src/lib/deployments/base-mainnet.json`.
- **Plan D (coverage):** Uniswap v2 and Aerodrome basic (v2) pools. Aerodrome basic pools have built-in 30-min observations; Uniswap v2 needs a cumulative-price sampler. Each needs a swap adapter.
- **Plan E (coverage):** Uniswap v4 (TASKS P-3): a sampled-median price and a v4 swap adapter.
