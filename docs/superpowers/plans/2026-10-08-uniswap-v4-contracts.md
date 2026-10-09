# Uniswap v4 + memestocks — contracts (plan A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** funds-core contracts for v4 pricing (sampler, price feed, registrar V2), the four fee-charging swap adapters, the new fund wiring, deploy + owner-step scripts, and Base fork proofs.

**Architecture:** `V4PriceSampler` stores keeper-taken samples of v4 pools; `V4PoolPriceAdapter` clones price a token from the median of the last hour's samples; `PoolPriceRegistrarV2` owns today's registrar (which keeps owning the VI), registers v4 and v3/Aerodrome pools against an extended quote list, and answers `poolPricedAdapter` for both registrars. A shared `ProtocolFeeAdapter` base takes 0–10 bps for the Treasury in `UniswapV4SwapAdapter` and the V2 spot adapters. New funds get the unchanged ComptrollerV3 code through a new blueprint deployer wired to registrar V2, and a new `MinPoolLiquidityPolicy(registrarV2)`.

**Tech Stack:** Solidity 0.8.24, OpenZeppelin 5.x (Ownable2Step, Clones, SafeERC20, Math), Foundry (unit + Base fork).

**Spec:** `docs/superpowers/specs/2026-10-08-uniswap-v4-memestocks-design.md` (§ references below)

## Global Constraints

- Base Uniswap v4: PoolManager `0x498581fF718922c3f8e6A244956aF099B2652b2b`, StateView `0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71`, Quoter `0x0d5e0F971ED27FBfF6c2837bf31316121532048D` (verified 2026-10-08). Interfaces mirror the deployed verified v4-core/periphery sources (no new lib dependency).
- `MIN_LIQUIDITY_USD = 25_000`; valuation minimum `$5,000` (PoolPriceAdapterBase); price window `1 hour`; `MIN_SAMPLES = 4`; sampler `MIN_INTERVAL = 9 minutes`, ring `12` slots; VI heartbeat `1 hours`.
- Fee: `MAX_FEE_BPS = 10` constant, owner-settable 0–10, `5` at deployment, paid to the Treasury Safe `0x47b7702a4789912d0dfFDadC07c50395c293fF0A`.
- Deployed contracts are untouched: today's registrar `0x34AcBA229Aeaf7F1c0f442633F35E26Bc94b4e2A`, its adapter implementations (reused by clone), ComptrollerV3, MinPoolLiquidityPolicy code.
- No `git add/commit/push`, no broadcast. Tabs, single quotes, explicit types, why-comments with dates. Branch `feat/uniswap-v4` (exists, `--no-track`).
- Fork tests `skip` without `BASE_MAINNET_RPC`.

## Review Focus

1. A keeper-free registration must not be buyable before warm-up: both `latestRoundData` and `liquidityUsd` revert with < 4 in-window samples (Task 3 test `test_warmup_refusesPriceAndLiquidity`).
2. A swap that only partially fills (price limit / thin pool) must return the unspent input to the vault, never leave it in the adapter (Task 6 fork test `test_fork_partialFill_returnsLeftover` — on a pool too thin for the trade).
3. Native-ETH pools: the adapter never leaves ETH or WETH behind (Task 6 fork checks adapter balances are zero after every swap).
4. Hook data can only come from the registrar's approval, never the manager's integrationData (Task 6 unit test `test_hookDataComesFromTheRegistrar`).
5. `setQuote` must refuse a pool-priced token as a quote (a long-tail token quoting another) (Task 4 test `test_setQuote_refusesPoolPricedTokens`).

---

### Task 1: v4 interfaces + price math library

**Files:**
- Create: `src/interfaces/external/IUniswapV4.sol` — `struct PoolKey {address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks;}`, `library PoolKeyId { function toId(PoolKey memory) internal pure returns (bytes32) /* keccak256(abi.encode(key)) */ }`, `interface IV4PoolManager { struct SwapParams {bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96;} unlock(bytes) returns (bytes); swap(PoolKey, SwapParams, bytes) returns (int256); sync(address); settle() payable returns (uint256); take(address,address,uint256); }`, `interface IV4UnlockCallback { unlockCallback(bytes) returns (bytes); }`, `interface IV4StateView { getSlot0(bytes32) returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee); getLiquidity(bytes32) returns (uint128); }`, `library V4Delta { amount0(int256) → int128 = int128(delta >> 128); amount1(int256) → int128(delta) }`.
- Create: `src/libraries/PoolPriceMath.sol` — `quoteReserve(uint128 liquidity, uint256 sqrtP, bool assetIsToken0)` (full-range-equivalent quote reserve: asset token0 → `L·√P/2^96`, asset token1 → `L·2^96/√P`) and `usdPerAssetAtSqrtP(sqrtP, assetIsToken0, assetDecimals, quoteDecimals, quoteUsd18)` ported unchanged from `ConcentratedPoolPriceAdapter._usdPerAssetAtTick`.
- Test: `test/PoolPriceMath.t.sol` — the same values as the concentrated adapter for 3 ticks × both orientations (compare against a `ConcentratedPoolPriceAdapter`-equivalent computation), and `PoolKeyId.toId` equals the STFY pool id for its key (`0xa697…5e06`: currency0 0, currency1 0xc640…7bf5, fee 10000, tickSpacing 200, hooks 0x47ec…00cc).

### Task 2: `V4PriceSampler`

**Files:** Create `src/pricing/V4PriceSampler.sol`; Test `test/V4PriceSampler.t.sol` (+ `MockStateView` in `test/utils/V4Mocks.sol`: settable slot0/liquidity per id).

Contract (Ownable2Step, owner set in constructor):
- `struct Sample { uint32 time; int24 tick; uint128 liquidity; }` (one slot); `mapping(bytes32 => Sample[12]) _ring; mapping(bytes32 => uint256) public sampleCount;`
- `setKeeper(address, bool)` onlyOwner, `isKeeper`; `sample(bytes32[] ids)`: keeper only (`NotKeeper`); per id skip if the newest sample is younger than `MIN_INTERVAL` or `sqrtPriceX96 == 0`; write `(time, tick, liquidity)` at `count % 12`, `++count`, `emit Sampled`.
- `samples(bytes32 id) view returns (Sample[] memory)` newest first, up to 12.

Tests: keeper-only; 9-minute skip (sample at t, t+8m59 skipped, t+9m written); ring wraps after 12; uninitialized pool skipped; owner-only setKeeper.

### Task 3: `V4PoolPriceAdapter`

**Files:** Create `src/pricing/V4PoolPriceAdapter.sol`; Test `test/V4PoolPriceAdapter.t.sol`.

- `contract V4PoolPriceAdapter is PoolPriceAdapterBase`; clone args = `abi.encode(Config c, V4Extra e)` with `struct V4Extra { V4PriceSampler sampler; IV4StateView stateView; bytes32 poolId; }` (the base's `config()` decodes the leading `Config`; `c.pool` = the PoolManager address for display); `v4Extra()` view.
- `SAMPLE_WINDOW = 1 hours`, `MIN_SAMPLES = 4`, `error NoPriceHistory()` (base already declares it — reuse).
- `_read(c, quoteUsd18)`: collect samples with `time >= block.timestamp - SAMPLE_WINDOW`; `< MIN_SAMPLES` → revert `NoPriceHistory()`; median tick (sorted; even count → average of the two middles, rounded toward −∞) and median liquidity (lower middle); current `(sqrtNow, L_now)` from StateView; liquidity = `min(quoteReserve(L_med, sqrt(medTick)), quoteReserve(L_now, sqrtNow))` × `quoteUsd18 / 10^quoteDecimals`; price = `usdPerAssetAtSqrtP(sqrt(medTick), …)`.

Tests (sampler + MockStateView + VI with MockAggregator quotes): price at a constant tick equals the concentrated formula; median ignores 2 outliers of 6; `test_warmup_refusesPriceAndLiquidity` (3 samples: both revert; 4: both answer); samples older than 1 h ignored; liquidity takes the lower of now/median (JIT add now doesn't raise it); under $5k → 1 wei; native-ETH quote config (quote = WETH) prices with WETH's rate.

### Task 4: `PoolPriceRegistrarV2`

**Files:** Create `src/pricing/PoolPriceRegistrarV2.sol`; Test `test/PoolPriceRegistrarV2.t.sol` (reuses `test/utils/PoolPriceMocks.sol` + the real `PoolPriceRegistrar` and `ValueInterpreter`; V4 via `MockStateView`).

- Constructor `(PoolPriceRegistrar oldRegistrar, IV4StateView stateView, address poolManager, V4PriceSampler sampler, address weth, address[] quotes, address owner)`; deploys the `V4PoolPriceAdapter` implementation; reads `valueInterpreter`, the factory addresses and `concentratedAdapter`/`basicAdapter` implementations from `oldRegistrar`; each quote must be a VI primitive.
- `acceptOldRegistrar()` onlyOwner → `oldRegistrar.acceptOwnership()`; `callOldRegistrar(bytes)` onlyOwner (low-level call, bubbles reverts; covers `execute`, `setPool`, `transferOwnership`).
- `registerV4(address asset, PoolKey key)` (anyone) per spec §4.3: id = `PoolKeyId.toId(key)`; `sqrtPriceX96 != 0` (`PoolNotInitialized`); asset is a currency and nonzero (`AssetNotInPool`); quote = the other currency, `address(0)` → `weth` (`QuoteNotAllowed`); hook `address(0)` or approved (`HookNotApproved`); not VI-supported (`AlreadyPriced`); decimals ≤ 38; current liquidity (`quoteReserve(L, sqrtP)` × quote USD) ≥ `MIN_LIQUIDITY_USD * 1e18` (`NotEnoughLiquidity`); clone `V4PoolPriceAdapter`; `_point`; `v4KeyOf[asset] = key`; `emit RegisteredV4(asset, id, adapter, msg.sender)`.
- `register(address asset, address pool)` (anyone): today's `_deploy`/`_canonicalImplementation` logic against own `isQuote`, cloning today's implementations, growing observation cardinality to 450; liquidity check via the clone's `liquidityUsd()`; `emit Registered`.
- `setPoolV4(asset, key)` / `setPool(asset, pool)` onlyOwner: no liquidity check (corrections).
- `setHook(address hook, bool approved, bytes hookData)`, `hookOf(hook) → (approved, hookData)`, `isHookAllowed(hook)` (`hook == address(0) || approved`); `setQuote(address token, bool approved)` — must be VI-supported and `poolPricedAdapter(token) == address(0)` (`QuoteIsPoolPriced`).
- `_point`: `oldRegistrar.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (asset, adapter, HEARTBEAT)))`; `adapterOf`, `registeredAssets` (first time only).
- `poolPricedAdapter(asset)`: own adapter if still the VI aggregator, else `oldRegistrar.poolPricedAdapter(asset)`; `MIN_LIQUIDITY_USD()`; `getRegisteredAssets()` = old ++ own.

Tests: v4 happy path (VI primitive points at the clone; `poolPricedAdapter` returns it); each refusal (uninitialized, hook not approved, quote not allowed, already priced, thin); native ETH counts as WETH; v3 register with a stock-token quote; `test_setQuote_refusesPoolPricedTokens`; fallback to the old registrar's adapters; owner-only setters; `callOldRegistrar` + `acceptOldRegistrar` ownership flow; `getRegisteredAssets` concatenation.

### Task 5: `ProtocolFeeAdapter` + three V2 spot adapters

**Files:** Create `src/adapters/ProtocolFeeAdapter.sol` (abstract: `MAX_FEE_BPS = 10`, `treasury` immutable, `feeBps`, `setFeeBps` onlyOwner (Ownable2Step), `_takeFee(token, amount) returns (uint256 net)` sends `amount·feeBps/10_000` to the treasury and emits `FeePaid`), `src/adapters/UniswapV3SwapAdapterV2.sol`, `src/adapters/AerodromeSlipstreamSwapAdapterV2.sol`, `src/adapters/AerodromeBasicSwapAdapterV2.sol` (today's code; `executeAction` swaps `_takeFee(tokenIn, amountIn)` — basic: of the received balance). Test `test/ProtocolFeeAdapters.t.sol` (Mocks.sol `MockSwapRouter`; a minimal Slipstream/Aerodrome router mock if needed).

Tests: fee cap (`setFeeBps(11)` reverts), 5 bps default sent to the treasury, swap amount net of fee, `minAmountOut` still applies, owner-only.

### Task 6: `UniswapV4SwapAdapter`

**Files:** Create `src/adapters/UniswapV4SwapAdapter.sol`; Test `test/UniswapV4SwapAdapter.t.sol` (unit: gate, hook approval, hookData source, fee, parse mapping) + fork in Task 7.

- `is ProtocolFeeAdapter, IIntegrationAdapter, IV4UnlockCallback`; immutables `poolManager`, `registrar` (V2), `weth`.
- integrationData = `abi.encode(PoolKey key, bool zeroForOne, uint256 amountIn, uint256 minAmountOut)`; `parseAssetsForAction` maps `address(0)` → `weth`.
- `executeAction(vault, data)`: caller's `registrar()` must be `registrar` (`NotANewFund`); `registrar.isHookAllowed(key.hooks)` (`HookNotApproved`); `hookData = registrar.hookOf(key.hooks).hookData`; `net = _takeFee(assetIn, amountIn)`; native in → `WETH.withdraw(net)`; `poolManager.unlock(abi.encode(key, zeroForOne, net, hookData, vault))`.
- `unlockCallback`: only `poolManager` (`NotPoolManager`); `swap(key, (zeroForOne, -int256(net), zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1), hookData)`; owed input = `-amountIn(delta)`, out = `amountOut(delta)`; settle (native: `settle{value: owed}`; ERC20: `sync` → `safeTransfer(poolManager, owed)` → `settle`); take output (native: take to self → `WETH.deposit` → transfer to vault; ERC20: take to vault); return `net - owed` input leftover to the vault (WETH-wrapped if native).
- `receive()` only from `weth` or `poolManager`.

Unit tests (a `MockV4PoolManager` that calls back and applies a scripted delta is enough for gate/hook/fee/parse; swap mechanics are proven on the fork): old-fund caller refused; unapproved hook refused; `test_hookDataComesFromTheRegistrar`; fee taken before the swap; parse maps native ETH to WETH.

### Task 7: Base fork proofs

**Files:** Create `test/fork/UniswapV4Fork.t.sol` (latest block; registrar V2 + sampler + adapters deployed in setUp exactly as the deploy library does, owner steps pranked as the deployer).

1. `test_fork_stfy_registerWarmupBuyValueRedeemInKind` — approve StockifyFeeHook; `registerV4(STFY, key)`; 3 samples (warped 10 min apart) → buy refused; 4th → a new fund (new deployer) buys STFY with WETH through the real PoolManager; the 3% hook fee shows in the output; GAV values STFY; a redemption pays STFY in kind; adapter holds no ETH/WETH/STFY afterwards.
2. `test_fork_stfy_pumpAtFewerThanHalfTheSamplesLeavesTheMedian` — pump with a real large buy before 2 of 6 samples, unwind; adapter price within 1% of unpumped.
3. `test_fork_stfy_dividendCyclePushesStocksIntoTheVault` — fund holds ≥ 100k STFY; prank STFY's DividendVault keeper through `snapshotHolders`/`startCycle`/`distributeBatch` (after `buyStocks` or with stocks dealt into the vault); stock tokens arrive in the fund vault; after `addTrackedAsset` GAV rises by their VI value.
4. `test_fork_o1_twoStepBuy_referrerCredited_claimPays` — fund buys NVDAc (UniswapV3/Slipstream V2 adapter, real pool), then BLUECHIP with NVDAc via the v4 adapter (o1 LaunchHook approved with hookData = Treasury); o1 FeeEscrow balance for the Treasury rises; `FeeEscrow.claim(treasury, currency)` pays the Treasury.
5. `test_fork_slipstream_stockQuotedRegistration` — `register(ElonRWA, its Slipstream pool)` with SPCXc approved as a quote.
6. `test_fork_oldFundRefused` — TestFund4 (old registrar) → `NotANewFund`.
7. `test_fork_feeAdaptersOnRealPools` — V3/Slipstream/Aerodrome-basic V2 swaps on real pools: Treasury receives 5 bps, vault receives ≥ min.
8. `test_fork_partialFill_returnsLeftover` — a trade larger than a thin hookless v4 pool can fill at the limit price returns the unspent input to the vault.
9. `test_fork_samplerGas` — log `sample` gas for 1 and 10 pools.

### Task 8: Deploy + owner-step scripts, rollout rehearsal

**Files:** Create `script/mainnet/V4Pricing.sol` (library: `deploy(...)` and `ownerSteps(...)`), `script/mainnet/DeployV4Pricing.s.sol` (writes `deployments/base-mainnet-v4.json` on broadcast only), `script/mainnet/V4PricingOwnerSteps.s.sol`, `test/fork/V4PricingRolloutFork.t.sol`.

- deploy: sampler(owner deployer), registrar V2 (old registrar, StateView, PoolManager, sampler, WETH, quotes [USDC, WETH, cbBTC], owner deployer), UniswapV4SwapAdapter, UniswapV3SwapAdapterV2, AerodromeSlipstreamSwapAdapterV2 ×3 (CL1/CL2/CL3 routers read from today's adapters' `router()`), AerodromeBasicSwapAdapterV2 (router + factory from today's adapter), MinPoolLiquidityPolicy(registrarV2), ComptrollerBlueprintDeployer(ComptrollerV3 creationCode, (registrarV2, queue)).
- owner steps (deployer): old registrar `transferOwnership(v2)` → `v2.acceptOldRegistrar()`; `setHook` StockifyFeeHook (''), o1 LaunchHook ×2 (`abi.encode(treasury)`); `setQuote` NVDAc, SPCXc, AAPLc; `sampler.setKeeper(KEEPER)`; `factory.registerAdapter` ×6; `factory.setMandatoryPolicies([(4|5|6, newPolicy)])`; `factory.setComptrollerDeployer(newDeployer)`.
- Rehearsal at the latest block: both scripts' library calls as the deployer; a fresh fund is a V3 fund on registrar V2 with the new policy on hooks 4/5/6; `registerV4(STFY)` works; TestFund4 unchanged; old adapters still registered (deregistration is later).

### Task 9: Governance handoff + docs

- `script/mainnet/FundsGovernance.sol`: when `deployments/base-mainnet-v4.json` exists, hand registrar V2 (which owns today's registrar) to the timelock instead of today's registrar, and check `oldRegistrar.owner() == registrarV2`; the existing pinned-block rehearsal keeps passing (file absent there).
- `MAINNET_RUNBOOK_FUNDS.md`: new section (deploy, owner steps, keeper/terminal/health follow-ups, deregistration of the old adapters, known limits).
