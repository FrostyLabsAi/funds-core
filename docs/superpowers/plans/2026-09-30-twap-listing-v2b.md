# TWAP Listing v2b — $50k-liquidity rule + Uniswap v2 + Aerodrome basic

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** list every token whose pool against USDC or WETH holds at least $25k of REAL USDC/WETH (≈ $50k of pool liquidity, the founder's rule), on Uniswap v3, all three Aerodrome Slipstream factories, Uniswap v2 and Aerodrome basic (volatile) pools. Target ≈ 550 tokens (measured 2026-09-30 from DefiLlama: 554 not-yet-priced tokens with a ≥ $50k USDC/WETH pool outside Uniswap v4).

**Architecture:** extends the UNCOMMITTED, UNDEPLOYED branch `feat/twap-listing-v2` (plan `2026-09-30-twap-listing-v2.md`, ledger rulings 1–16 still bind).
- Listing and the delist floor move from "±10% quote-side band depth ≥ $50k" to "**quote reserves ≥ $25k**", where quote reserves are the USDC/WETH the pool holds × Chainlink.
- Exposure caps, keeper-recorded depth and the repoint margin STAY on the ±10% quote-side band depth. So thin tokens list, but each fund can only hold what the market's real bids can absorb.
- **Price adapters:**
  - A shared interface `ITwapPriceAdapter`.
  - The concentrated-liquidity adapter (existing V2) gains `quoteReserveUsd()`.
  - New `AerodromeBasicTwapAdapter`, which uses the pool's own 30-minute observations of cumulative reserves.
  - New `UniswapV2TwapAdapter`, which uses snapshots from a permissionless `UniswapV2ObservationRecorder`.
- **Deployers:** adapters are created by three small deployer contracts, so the registry (20.5 KB today, 24 KB limit) stops embedding adapter creation code.
- **Swap adapters:** two new ones (Uniswap v2 router, Aerodrome basic router), fee-on-transfer safe.

**Tech stack:** Foundry, solc 0.8.24, OpenZeppelin, Base mainnet fork tests.

**Spec (founder, 2026-09-30, verbatim):** "if a token has more than 50k liquidity on uniswap and or aerodrome its needs to be listed"; "ok lets do that so we can have the 550 or something close to it" (in reply to: listing rule = pool liquidity measured as real USDC/WETH ≥ $25k; caps stay on real bids within 10%; add Uniswap v2 + Aerodrome basic; Uniswap v4 later).

## Global Constraints
- Everything in plan `2026-09-30-twap-listing-v2.md` Global Constraints, plus ledger rulings 1–16. In particular:
  - keeper-only list/repoint/clear (Amendment A);
  - caps = min(live, recorded band depth);
  - CL pools: MIN_TICK_SPACING 10 and MIN_OBSERVATION_CARDINALITY 300;
  - MIN_READ_GAS guard;
  - no commits, no worktrees, Opus only, never edit deployed sources, no broadcast except to a local anvil fork, never print `.env` values.
- `MIN_QUOTE_RESERVE_USD = 25_000` (whole USD) replaces `MIN_DEPTH_USD` as the listing floor and the delist-clock floor. Band depth keeps no floor of its own; it only sizes caps and repoints.
- `Venue` enum APPENDS `UniswapV2, AerodromeBasic` after `Slipstream3`; existing indices are unchanged. For the two new venues, `feeOrTickSpacing` must be 0, or the pool is not found.
- Aerodrome basic: VOLATILE pools only (`factory.getPool(asset, quote, false)`). Stable (sAMM) pools are never listed.
- The v2-style band factor is `1 − √0.9 = 0.05131670…` → `BAND_QUOTE_PPM = 51_316` (rounded down).
- Verified Base addresses (cast, 2026-09-30):

  | Contract | Address | Checked |
  |---|---|---|
  | Uniswap v2 factory | `0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6` | router.factory() |
  | Uniswap v2 router02 | `0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24` | WETH() = 0x4200…0006; `swapExactTokensForTokensSupportingFeeOnTransferTokens` (0x5c11d795) present in bytecode |
  | Aerodrome PoolFactory | `0x420DD381b31aEf6683db6B902084cB0FFECe40Da` | router.defaultFactory() |
  | Aerodrome Router | `0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43` | `swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,(address,address,bool,address)[],address,uint256)` (0x88cd821e) present |

  Aerodrome basic pool views (AERO/USDC vAMM 0x6cDc…971d):
  - `periodSize()` = 1800
  - `observationLength()`
  - `observations(uint256) → (timestamp, reserve0Cumulative, reserve1Cumulative)`
  - `lastObservation()` (same tuple)
  - `currentCumulativePrices() → (reserve0Cumulative, reserve1Cumulative, blockTimestamp)`. These are cumulative RESERVES, despite the name.
  - `getReserves() → (r0, r1, blockTimestampLast)`
  - `stable()`, `token0()`, `token1()`

## Review Focus
1. **Uniswap v2 cumulative math:** the UQ112x112 cumulatives wrap by design. Deltas must use `unchecked`. The counterfactual "now" cumulative follows UniswapV2OracleLibrary. Handle decimals 6 vs 18 in both orientations. Pinned by the adapter's fork test, which compares against the pool's spot within 1%.
2. **Recorder spam can't starve the window.** With MIN_SPACING 10 min and RING 16, the oldest kept snapshot is always ≥ 150 min old once the ring is full, so a ≥ 30-min snapshot always exists after 30 min of history. Pinned by `test_spamCannotStarveWindow`.
3. **Aerodrome observation choice:** when the last observation is < 30 min old, the adapter uses the one before it. With fewer than 2 usable observations it reverts ObservationWindowUnavailable. Stable pools are refused. Pinned by fork tests.
4. **Rule split:** reserves gate listing and the delist clock; band depth sizes caps, recorded depth and repoint. A test lists a token whose band depth is < $50k but whose reserves are ≥ $25k (BRETT's Slipstream WETH pool held $32k band depth on 2026-09-30), and shows its cap is 10% of band depth.
5. **Fee-on-transfer tokens:** both new swap adapters swap the adapter's actual `balanceOf(tokenIn)` through the router's FoT-supporting function. The Comptroller already credits balance deltas. Pinned by a fork test with a real taxed token if one is found among the candidates; otherwise the report states that none was found.

---

### Task 1: `ITwapPriceAdapter` + reserve floor on the concentrated adapter
**Files:**
- Create `src/interfaces/ITwapPriceAdapter.sol`.
- Modify `src/pricing/TwapAggregatorAdapterV2.sol` (new, undeployed).
- Extend `test/TwapAggregatorAdapterV2Fork.t.sol`.

**Interface** (every TWAP adapter implements it, plus AggregatorV3Interface):
```solidity
interface ITwapPriceAdapter {
	function asset() external view returns (address);
	function quoteAsset() external view returns (address);
	function pool() external view returns (address); // see note below
	function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
	function decimals() external view returns (uint8);
	/// USD (1e18) of the QUOTE token the pool holds; reverts if the pool can't serve the TWAP window.
	function quoteReserveUsd() external view returns (uint256);
	/// USD (1e18) of quote-token bids within −10% of the price (caps, recorded depth, repoint).
	function poolDepthUsd() external view returns (uint256);
	/// quoteReserveUsd() < minLiquidityUsd * 1e18
	function isBelowFloor() external view returns (bool);
}
```
- Note: `TwapAggregatorAdapterV2.pool()` returns `IConcentratedPoolOracle`. That's ABI-identical to `address`, so declare the interface with `address` and keep the concrete return type. If the compiler refuses the override, drop `pool()` from the interface; the registry stores the pool anyway.

**Changes to TwapAggregatorAdapterV2:**
- Add `quoteReserveUsd()`: run `_consult()` (so an unservable window reverts), then `Math.mulDiv(IERC20(quoteAsset).balanceOf(address(pool)), _quoteUsd18(), 10 ** quoteDecimals)`.
- `isBelowFloor()` becomes `quoteReserveUsd() < minLiquidityUsd * 1e18`.
- Natspec: `minLiquidityUsd` is now the QUOTE-RESERVE floor (whole USD); `poolDepthUsd()` is unchanged (band).
- Declare `is AggregatorV3Interface, ITwapPriceAdapter` if that compiles cleanly; otherwise just keep matching signatures and note it.

**Tests (fork):**
- `quoteReserveUsd()` on VIRTUAL/USDC 3000 equals `USDC.balanceOf(pool)` × the feed, exactly.
- LUMIA: its reserve (≈ $2.6k of WETH) is < $25k, so it stays below the floor.
- `isBelowFloor()` agrees with `quoteReserveUsd() < min`.
- Existing tests stay green, after updating any that assumed the band floor.

### Task 2: `AerodromeBasicTwapAdapter`
**Files:** create `src/pricing/AerodromeBasicTwapAdapter.sol` and `test/AerodromeBasicTwapAdapterFork.t.sol`.

**Constructor:**
- Signature: `(IAerodromeBasicPool pool_, address asset_, AggregatorV3Interface quoteFeed_, uint32 window_, uint256 minLiquidityUsd_, uint16 maxDeviationBps_, uint32 quoteHeartbeat_, string memory description_)`.
- Same argument checks as the CL adapter: MIN_WINDOW 30 min, MAX_DEVIATION_BPS 2000, decimals ≤ 38, feed decimals ≤ 18.
- Plus `if (pool_.stable()) revert StablePool();`.

**Math** (raw token units; `a` = asset side, `q` = quote side):
```solidity
/// newest observation at least `window` old, then time-averaged reserves up to now
function _twar() internal view returns (uint256 avgA, uint256 avgQ) {
	uint256 len = pool.observationLength();
	(uint256 t, uint256 c0, uint256 c1) = pool.lastObservation();
	if (block.timestamp - t < window) {
		if (len < 2) revert ObservationWindowUnavailable();
		(t, c0, c1) = pool.observations(len - 2);
		if (block.timestamp - t < window) revert ObservationWindowUnavailable();
	}
	(uint256 n0, uint256 n1, uint256 tNow) = pool.currentCumulativePrices(); // cumulative RESERVES
	uint256 dt = tNow - t;
	if (dt == 0) revert ObservationWindowUnavailable();
	(uint256 r0, uint256 r1) = ((n0 - c0) / dt, (n1 - c1) / dt);
	(avgA, avgQ) = assetIsToken0 ? (r0, r1) : (r1, r0);
	if (avgA == 0 || avgQ == 0) revert ObservationWindowUnavailable();
}
```
- **Price:** `quotePerAsset = mulDiv(avgQ, 10 ** assetDecimals, avgA)`, then `price = mulDiv(quotePerAsset, _quoteUsd18(), 10 ** quoteDecimals)`. A zero price reverts `PriceRoundsToZero`.
- **Spot guard:** take spot from `getReserves()` as `mulDiv(rQ, 10**ad, rA)`. Require `max(spot, twap) * BPS <= min(spot, twap) * (BPS + maxDeviationBps)`, else revert `SpotDeviatesFromTwap(spot, twap)`.
- **quoteReserveUsd:** `_twar()` (for the window check), then current `rQ` × `_quoteUsd18()` / 10^qd.
- **poolDepthUsd:** `mulDiv(min(avgQ, rQ), BAND_QUOTE_PPM, 1e6)` × quote USD / 10^qd. This is the quote paid out when x·y=k moves −10%.
- **latestRoundData** `updatedAt` is the read's own timestamp, like the CL adapter.
- **Interface:** declare a minimal `IAerodromeBasicPool` interface in this file with exactly the views listed in Global Constraints. Verify every signature with `cast` first.

**Fork tests:**
- (a) A real volatile pool. Candidates from DefiLlama 2026-09-30: KTA/WETH 0xc063…8973, FAI/WETH 0xb33f…7935. Verify `stable()==false`, that the token isn't VI-priced, and its reserves with cast. Then check:
  - the TWAP is within 2% of spot;
  - `quoteReserveUsd` equals `WETH.balanceOf(pool)`-based USD within 0.1%. Reserves vs balance can differ by dust and fees; document the tolerance.
  - `poolDepthUsd` ≈ 5.13% of quote reserves USD.
- (b) Constructing over a STABLE pool reverts `StablePool` (find a real sAMM pool vs USDC).
- (c) Observation fallback: `vm.warp` to just after the last observation's timestamp so `last` is < 30 min old; the adapter still prices, using `len-2`.
- (d) Real swaps that move spot > 5% make `latestRoundData` revert `SpotDeviatesFromTwap`.

### Task 3: `UniswapV2ObservationRecorder` + `UniswapV2TwapAdapter`
**Files:** create `src/pricing/UniswapV2ObservationRecorder.sol`, `src/pricing/UniswapV2TwapAdapter.sol`, `test/UniswapV2ObservationRecorder.t.sol` (unit; a pair stand-in is acceptable ONLY for ring/spacing logic) and `test/UniswapV2TwapAdapterFork.t.sol`.

**Recorder** (permissionless, ownerless):
```solidity
uint32 public constant MIN_SPACING = 10 minutes;
uint8 public constant RING = 16;
struct Snapshot { uint256 price0Cumulative; uint256 price1Cumulative; uint32 timestamp; }
mapping(address pair => Snapshot[16]) internal ring; mapping(address pair => uint8) public head; mapping(address pair => uint8) public count;
/// Store the pair's counterfactual cumulative prices now; a no-op (returns false) within MIN_SPACING of the last one.
function record(address pair) external returns (bool recorded);
/// Newest snapshot at least `minAge` old; reverts NoSnapshot(pair) if none.
function snapshotAtLeast(address pair, uint32 minAge) external view returns (Snapshot memory);
/// UniswapV2OracleLibrary.currentCumulativePrices, written for 0.8 (unchecked wrap): cumulativeLast plus the
/// current reserves' price × (now − blockTimestampLast), computed counterfactually when time has passed.
function currentCumulativePrices(address pair) public view returns (uint256 price0Cumulative, uint256 price1Cumulative, uint32 timestamp);
```
- `record` reverts on pairs with zero reserves.
- Emits `Recorded(pair, timestamp)`.

**Adapter:**
- Constructor: `(IUniswapV2Pair pair_, address asset_, AggregatorV3Interface quoteFeed_, UniswapV2ObservationRecorder recorder_, uint32 window_, uint256 minLiquidityUsd_, uint16 maxDeviationBps_, uint32 quoteHeartbeat_, string memory description_)`. Same checks as the other adapters.
- **TWAP:** `s = recorder.snapshotAtLeast(pair, window)`, then `(c0, c1, tNow) = recorder.currentCumulativePrices(pair)`.
  - `avgX112 = unchecked((cNow - cThen) / (tNow - s.timestamp))`, using price0 when the asset is token0 (token1 per token0), otherwise price1.
  - `quotePerAsset = mulDiv(avgX112, 10 ** assetDecimals, 2**112)`.
- **Price and spot guard:** as Task 2, with spot from `getReserves()`.
- **quoteReserveUsd:** `snapshotAtLeast` must succeed (window check), then the quote reserve × USD.
- **poolDepthUsd:** `rQ * BAND_QUOTE_PPM / 1e6` → USD. There are no time-weighted reserves on v2; the policy's min(live, recorded) covers inflation.
- **IUniswapV2Pair:** a minimal interface in the recorder file with `token0`, `token1`, `getReserves`, `price0CumulativeLast`, `price1CumulativeLast`.

**Unit tests (recorder):**
- spacing no-op;
- ring wrap;
- `snapshotAtLeast` picks the newest snapshot that is old enough;
- `test_spamCannotStarveWindow`: record every 10 minutes for 5 hours, and a 30-min snapshot always exists.

**Fork tests (adapter):**
- (a) A real Uni v2 pair. Candidates: AGNT/USDC (token 0x7484…9bb9), DINO/WETH (0x85e9…8077), OPAL/WETH (0x119b…cd1f). Verify each and record, then warp/roll 31 min. Check:
  - the TWAP is within 1% of spot when nothing traded;
  - `quoteReserveUsd` matches reserves × feed exactly;
  - depth ≈ 5.13% of reserves.
- (b) Before any snapshot, `latestRoundData` reverts NoSnapshot.
- (c) A real swap moving spot > 5% after the snapshot reverts `SpotDeviatesFromTwap`.
- (d) Both orientations, asset = token0 and asset = token1, each in a test.

### Task 4: Adapter deployers + registry rework
**Files:**
- Create `src/pricing/TwapAdapterDeployers.sol`, holding three contracts: `ConcentratedTwapAdapterDeployer`, `UniswapV2TwapAdapterDeployer`, `AerodromeBasicTwapAdapterDeployer`. Each has one permissionless function, `deploy(<that adapter's constructor args>) external returns (address)`, that runs `new`.
- Modify `src/pricing/TwapListingRegistryV2.sol`, `test/TwapListingRegistryV2.t.sol`.

**Registry changes** (keep everything else, including rulings 4/10/11/15):
- **Constructor:** takes ONE struct to avoid stack-too-deep:

  ```solidity
  struct Venues {
  	IValueInterpreter valueInterpreter;
  	IUniswapV3PoolFactory uniswapV3;
  	ISlipstreamPoolFactory slipstream;
  	ISlipstreamPoolFactory slipstream2;
  	ISlipstreamPoolFactory slipstream3;
  	IUniswapV2Factory uniswapV2;
  	IAerodromeBasicFactory aerodromeBasic;
  	UniswapV2ObservationRecorder recorder;
  	ConcentratedTwapAdapterDeployer clDeployer;
  	UniswapV2TwapAdapterDeployer v2Deployer;
  	AerodromeBasicTwapAdapterDeployer aeroDeployer;
  }
  ```
  Store each as an immutable; any zero field → `ZeroAddress`.
- **Types:** `listings[asset].adapter` becomes `ITwapPriceAdapter`; the 5-field shape stays. `adapterOf` is unchanged.
- **`_qualify` dispatch:**
  - CL venues (0–3): spacing ≥ 10 and cardinality ≥ 300 as now, then `clDeployer.deploy(...)`.
  - `UniswapV2`: `feeOrTickSpacing != 0` → `PoolNotFound`. Otherwise `pool = uniswapV2.getPair(asset, quote)` and `v2Deployer.deploy(pair, asset, feed, recorder, WINDOW, MIN_QUOTE_RESERVE_USD, MAX_DEVIATION_BPS, heartbeat, desc)`.
  - `AerodromeBasic`: `feeOrTickSpacing != 0` → `PoolNotFound`. Otherwise `pool = aerodromeBasic.getPool(asset, quote, false)` and `aeroDeployer.deploy(...)`.
  - Then for every venue:
    1. `adapter.latestRoundData()`.
    2. `reserve = adapter.quoteReserveUsd()`; if `reserve < MIN_QUOTE_RESERVE_USD * 1e18` revert `BelowFloorAtListing(reserve)`.
    3. Return `depth = adapter.poolDepthUsd()` (band) for recording.
- **Reads:** split `_currentDepth` into two gas-guarded reads using the same MIN_READ_GAS rule:
  - `_currentFloor(adapter) → (bool ok, uint256 reserveUsd)`, with `ok = reserveUsd >= floor`;
  - `_currentBandDepth(adapter) → (bool ok, uint256 depthUsd)`.
- **repoint:** after SamePool, refuse with `NotDeepEnough(currentDepth, newDepth)` only when ALL of these hold:
  - the current floor is ok;
  - the current band depth is readable;
  - `newDepth < currentDepth × 1.25`.
- **pokeFloor:**
  - `below = !floorOk`.
  - Clock rules unchanged: anyone starts it, only a lister clears it.
  - A lister records `_currentBandDepth` (0 if unreadable).
- **Constants and natspec:**
  - `MIN_DEPTH_USD` is renamed to `MIN_QUOTE_RESERVE_USD = 25_000`, with natspec: ≈ $50k of pool liquidity, counted as twice the real USDC/WETH so a token's self-priced side can't inflate it.
  - Update the contract natspec bullets: venues, the rule split, volatile-only Aerodrome basic.
- **Size:** `forge build --sizes` must show the registry well under 24,576 B (expected ≈ 10 KB, since no adapter creation code is embedded). Put the number in the report.

**Tests:**
- Unit: the constructor rejects zero fields, and a nonzero `feeOrTickSpacing` on the new venues → `PoolNotFound`.
- Fork:
  - a real Aerodrome basic listing through the registry;
  - a real Uni v2 listing after record + 31 min;
  - a token whose band depth is < $50k but reserves ≥ $25k now lists (BRETT's Slipstream ts200 WETH pool held $32k band on 2026-09-30; re-verify);
  - LUMIA is still refused (`BelowFloorAtListing`, arg ≈ $2.6k);
  - all earlier registry tests are kept and updated to the new constructor.

### Task 5: Swap adapters
**Files:** create `src/adapters/UniswapV2SwapAdapter.sol`, `src/adapters/AerodromeBasicSwapAdapter.sol`, and the interfaces in `src/interfaces/external/IUniswapV2Router02.sol` and `IAerodromeRouter.sol` (only the functions used); `test/fork/V2SwapAdaptersFork.t.sol`.
- **Integration data:** follow `AerodromeSlipstreamSwapAdapter` exactly. `integrationData = abi.encode(tokenIn, tokenOut, amountIn, minAmountOut)`. `parseAssetsForAction` is identical in shape.
- **`executeAction`:**
  1. `uint256 bal = IERC20(tokenIn).balanceOf(address(this))` (fee-on-transfer safe);
  2. `forceApprove(router, bal)`;
  3. call the router's `swapExactTokensForTokensSupportingFeeOnTransferTokens(bal, minAmountOut, path, vault, block.timestamp)`. For Aerodrome, `path` is `Route[]{from, to, stable: false, factory: 0x420D…40Da}`.
- **Fork tests:** the live fund (owner = deployer, prank) registers nothing. Instead, the test deploys the adapter, pranks the factory owner (deployer) to `registerAdapter`, then buys $1 of a real token through each adapter. Check:
  - the vault balance increases;
  - an over-tight `minAmountOut` reverts;
  - if a real fee-on-transfer token exists among the candidates, buy it and show the Comptroller credits the true received amount.

### Task 6: Policy + lens on the interface
**Files:** modify `src/policies/TwapExposurePolicyV2.sol`, `src/pricing/TwapFloorLensV2.sol` and their tests.
- **Policy:** `ITwapPriceAdapter(registry.adapterOf(asset)).poolDepthUsd()` replaces the concrete cast. `min(live, recorded)` is unchanged.
- **Lens:** read the adapter through `ITwapPriceAdapter` and call `isBelowFloor()` (now reserves-based).
- **Tests:** the existing suites pass with the new registry constructor (`Venues` struct). Rescale the mocks so v1 scenarios keep their meaning (Ruling 3). The floor is now reserves: the policy-test mocks' `balanceOf` must make sense; use real token balances where they're already real.

### Task 7: Deploy wiring
**Files:** modify `script/mainnet/TwapListingV2.sol`, `script/mainnet/DeployTwapListingV2.s.sol` and `test/fork/TwapListingV2Fork.t.sol` (setUp compiles).
- **Additional deploys:**
  - the recorder;
  - the three adapter deployers;
  - the registry from `Venues`;
  - `UniswapV2SwapAdapter(0x4752…aD24)` and `AerodromeBasicSwapAdapter(0xcF77…4E43, 0x420D…40Da)`, both `factory.registerAdapter`-ed alongside slipstream3.
- **`Deployed` gains:** `recorder`, `uniswapV2Adapter`, `aerodromeBasicAdapter`. The JSON gains the same keys.
- **`verify()` adds:**
  - every registry immutable equals its intended address;
  - both swap adapters are registered;
  - each router's `factory()`/`defaultFactory()` matches.
- **Rehearsal:** same anvil rehearsal as Task 6 of the first plan (deployer impersonated, `--unlocked --broadcast --slow`, `DEPLOYMENTS_FILE=deployments/rehearsal-twap-v2.json`), then cleanup. If the permission classifier refuses the anvil broadcast, report it. Do NOT work around it.

### Task 8: Acceptance tests
**File:** extend `test/fork/TwapListingV2Fork.t.sol`.
- **Keep all 14 tests.** Update them for the rule split:
  - LUMIA is still refused (reserve under $25k);
  - the under-floor tests now push RESERVES under $25k with real sells. Selling the asset removes quote. Re-size the binary search with `isBelowFloor`.
- **Add:**
  - `test_fork_uniswapV2ListsPricesTrades`: record, wait 31 min, keeper lists a real v2 token, price ≈ spot, the live fund buys via `UniswapV2SwapAdapter`.
  - `test_fork_aerodromeBasicListsPricesTrades`: the same through `AerodromeBasicSwapAdapter`.
  - `test_fork_thinBandListsWithTinyCap`: a token with band < $50k and reserves ≥ $25k lists, and a non-degen fund's buy above 10% of its band depth reverts `PoolShareExceeded`.
  - `test_fork_aerodromeStableNeverListed`: for a token that only has an sAMM pool vs USDC/WETH, listing with `AerodromeBasic` → `PoolNotFound`.
  - `test_fork_lensPagesAcrossVenues`: one CL, one v2 and one Aerodrome basic listing; paging and due-detection across all three.
- **Run:** pinned and unpinned, plus the full suite and the genesis file (8/8).

### Task 9: Coverage measurement (no code changes to src)
**File:** create `script/mainnet/MeasureListable.s.sol` (read-only `forge script`, no broadcast). Its input is a JSON list of candidate pools at `~/FrostyFunds/.ops-scratch/twap-scan/candidates-v2b.json`; build it from the DefiLlama Base pools list (`https://yields.llama.fi/pools`; projects uniswap-v2, uniswap-v3, aerodrome-v1, aerodrome-slipstream; tvlUsd ≥ 50k; one side USDC or WETH).
- **For each candidate pool,** deploy the matching adapter in-script against live state, then report:
  - quote reserves;
  - band depth;
  - whether `latestRoundData` answers;
  - the CL spacing/cardinality gates.
- **Output:** a CSV and the count of tokens that would list now, plus counts per reason for not listing (reserve < $25k, spacing, cardinality, window, deviation, stable-only, VI-priced).
- Uniswap v2 pools have no recorder history on a fork. For them, measure reserves and spot only, and count them as "listable after 30 min of recorder history".
- This is the honest number for the founder. Report it, no rounding up.

## Follow-ups (not in this plan)
- **Plan B keeper.** Everything from the runbook section, plus:
  - `recorder.record(pair)` every 10–15 min for every listed AND candidate v2 pair;
  - before listing, a round-trip buy→sell `eth_call` simulation to skip honeypots and tokens taxed > 5%.
- **Uniswap v4 (founder priority, 2026-09-30):** 415 v4-only tokens with a $50k+ pool, plus the stock-paired memecoin launchpads, which all run on v4 hooks: o1.exchange (41 Coinbase stocks registered as quotes), BStocks, OpenLaunch, oPar.
  - v4 keeps no price history, so it needs a tick recorder plus a v4 swap adapter (vet hooks).
  - Add the 13 Chainlink-priced Coinbase stocks as quotes (`setQuote`, 5-day heartbeat).
  - Details in memory `project_uniswap_v4_listing_notes`.
- **Switch the direct-VI scripts** (`list-coinbase-stocks.sh`, ListVerantaPairs, ListYieldVaults) to `module.execute`.
