# Uniswap v4 tokens and memestocks: design

Status: designed with the founder 2026-10-08, section by section ("yes this looks correct"). Not built.
Supersedes the 2026-09-28 plan "P-3 · Uniswap v4 tokens held at a sampled price" in `frosty-terminal/TASKS.md`, which
predates the 2026-10-04 "no list" pool pricing (`PoolPriceRegistrar`).

## 1. Goal

New funds can buy and hold tokens whose liquidity is on Uniswap v4, starting with stock-dividend memecoins
("memestocks") such as STFY, and tokens paired against stock tokens (o1 launchpad, Bankr). They are long-tail tokens with
exactly today's protections (fund v2/v3 rules):

- priced from their own pool; a buy needs ≥ $25k of quote liquidity; valued at ≈ $0 under $5k;
- paid in kind on redemption; performance fee only on gains realized by selling.

Also in scope (founder 2026-10-08): stock tokens as price quotes, a protocol fee on all four spot adapters, and the
o1 referrer share.

## 2. Facts this design rests on (verified 2026-10-08)

- **Uniswap v4 on Base** (developers.uniswap.org deployments, code checked on chain; `StateView.poolManager()` and
  `Quoter.poolManager()` both return the PoolManager): PoolManager `0x498581fF718922c3f8e6A244956aF099B2652b2b`,
  StateView `0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71`, Quoter `0x0d5e0F971ED27FBfF6c2837bf31316121532048D`,
  PositionManager `0x7C5f5A4bBd8fD63184577525326123B519429bDc`, Universal Router `0x6fF5693b99212Da76ad316178A184AB56D299b43`,
  Permit2 `0x000000000022D473030F116dDEE9F6B43aC78BA3`.
- **v4 pools keep no price history** (no `observe()`); one pool = one `PoolKey` (currency0, currency1, fee, tickSpacing,
  hooks), one hook fixed at creation. Pool tokens sit in the PoolManager (a pool holds no balance of its own).
- **STFY** (`StockifyToken` 0xc640…7bf5): main pool ETH/STFY, native ETH, fee 1% (10000), tickSpacing 200, hook
  `StockifyFeeHook` 0x47ec…00cc (verified; one-pool hook; 3% ETH fee on every buy and sell to its `DividendVault`
  0x4Ee3…4f98), ≈ $110k liquidity. Dividends: any address holding ≥ 100,000 STFY (owner-settable 10k–100k; ≈ $61 today)
  is on the token's on-chain holder registry unless the owner excludes it; every hour the vault's keeper snapshots the
  registry and **pushes** its index stocks (NVDAc, AAPLc, GOOGLc, METAc, SPCXc, 20% each — all priced in our VI) to
  holders. A simulated payout transfer into a fund vault (TestFund4's) succeeds.
- **o1 launchpad**: its pools are ordinary v4 pools (StateView reads them) under a shared `LaunchHook` per deployment
  suite (two: 0x3b2b…eacc, the first, and 0x1f91…2acc, the newer one, which takes both stock- and ETH-paired launches;
  verified). GeckoTerminal lists them under its own venue (`o1-launchpad`), not `uniswap-v4-base`. Liquidity is one permanently locked launch position. Per-swap base fee
  (BLUECHIP/NVDAc: 1%) split creator 50% / platform 30% / **referrer 20%**, the referrer read from the first 32 bytes of
  the swap's hookData and credited in that hook's own `FeeEscrow` (`feeEscrow()`): the stock-paired hook's escrow
  (0x1D8c…d02f) pays out with `claim(recipient, currency)`, the ETH-paired hook's (0xB3F1…6866, a later version) with
  `claimFor(recipient, currency)`; both are permissionless and pay the recipient (fork-proven 2026-10-08). Anti-snipe surcharge from up to 99%, decaying (16 s in the pool read). o1's admin can raise the base fee
  up to a 10% ceiling. o1 tokens do not pay holders. o1's top 20 pools traded ≈ $1.2M in 24 h.
- **Bankr** pools are v4 pools under Doppler's shared hook (`DopplerHookInitializer`); Doppler pools run a launch auction
  and then "graduate".
- **Pairings**: STFY against native ETH; many memestocks against the stock token itself (BLUECHIP/NVDAc and SI/NVDAc on
  o1, MOONBASE/SPCXc, IPOD/AAPL on v4, ElonRWA/SPCXc on Slipstream, ISTONKS/AAPL on v3). ElonRWA's pool actually holds
  ≈ 101 SPCXc (≈ $16k, 2026-10-08), so today it is under the $25k floor and can't be registered or bought.
- **Fund wiring**: `ComptrollerV3`, `FundValuation` and `MinPoolLiquidityPolicy` ask their registrar only
  `poolPricedAdapter(asset)` and `MIN_LIQUIDITY_USD()`; the adapters answer `liquidityUsd()`. The registrar is an
  immutable constructor argument of each fund and of the policy. Today's `PoolPriceRegistrar` (0x34Ac…4e2A) only accepts
  Uniswap v3 / Slipstream / Aerodrome pools against USDC/WETH/cbBTC and cannot be upgraded. `ValueInterpreter.addPrimitive`
  reads only `decimals()`, never a price.
- **Sampling cost** (fork, 2026-10-08, measured cold as its own transaction): `sample` for 1 pool 20,743 gas, for 10 pools
  178,239 once each pool's 12 slots are full (first readings: 65,624 / 552,017); + 21,000 per transaction; Base L1 data fee ≈ 5.8e10 wei per transaction. Base gas usually ≈ 0.006 gwei (spike seen:
  0.02). thirdweb Engine: first 1,000 requests a month free, then $1 per 1,000 (same on every plan).

## 3. Decisions (founder 2026-10-08)

1. **Pricing: on-chain sampling every 10 minutes** (option 1 of 6; rejected: on-demand warm-up, our own signed price,
   oracle hook, spot price, other venues only). Price = median of the last hour's samples; only approved keepers sample.
2. **New funds only** (option A): v4 and stock-quoted tokens are long-tail only for funds on the new deployer; existing funds
   (all internal test funds) are refused by the v4 adapter and can opt in by reconfiguring.
3. **Signing through thirdweb Engine** (no key on the host).
4. **Defaults accepted**: hooks need owner approval (hookless pools are open); 4-sample warm-up before the first buy;
   liquidity = lower of now and the sampled median; native ETH counts as WETH; only held or warming tokens are sampled.
5. **Protocol fee on all four spot adapters** (v4 + new versions of Uniswap v3, Slipstream, Aerodrome basic): owner-set
   0–10 bps, hard cap 10 bps in code, 5 bps at deployment, paid to the Treasury Safe.
6. **Stock tokens as quotes; two-step buys** for stock-paired tokens (terminal chains them); **per-hook referrer setting**;
   **add o1** (approve its LaunchHooks with the Treasury as referrer).
7. Out of scope: v4 LP positions (yields phase), limit orders on long-tail tokens (refused by the buy-floor policy),
   launchpads with their own non-Uniswap curves, a FrostyFi launchpad/hook.

## 4. Pricing contracts

### 4.1 `V4PriceSampler` (one contract)
- `sample(PoolId[] ids)`: approved keepers only (`setKeeper(address, bool)`, owner). Per pool, reads `StateView.getSlot0`
  (tick) and `getLiquidity` (in-range liquidity) and writes one packed slot (timestamp, tick, liquidity) into a 12-slot ring.
- A pool sampled less than `MIN_INTERVAL = 9 minutes` ago is skipped (no revert), so a keeper bug can't flood a history.
- Views: the ring for a pool (the adapter reads it).

### 4.2 `V4PoolPriceAdapter` (one minimal clone per token, like today's pool feeds)
- Extends `PoolPriceAdapterBase` (feed shape, `latestRoundData` stamped with the read time, `MIN_VALUATION_LIQUIDITY_USD =
  5,000` → 1 wei).
- **Window**: samples from the last `1 hour`; needs at least `MIN_SAMPLES = 4`, else both `latestRoundData` and
  `liquidityUsd` revert `NoPriceHistory()` (the VI read fails, so long-tail rules pay it in kind; the buy-floor policy can't
  read liquidity, so buys are refused — this is the warm-up).
- **Price**: median tick of the window's samples → USD per whole token via the quote's VI USD rate (today's
  `_usdPerAssetAtTick` math; native ETH quote priced as WETH).
- **Liquidity**: the full-range-equivalent quote reserve of in-range liquidity (`L·√P` or `L/√P`, as the concentrated
  adapter's windowed term), taking the lower of the current pool and the median sampled liquidity, in USD.
- Config (clone args): VI, PoolManager/StateView, sampler, PoolKey/PoolId, asset, quote, `assetIsCurrency0`, decimals.

### 4.3 `PoolPriceRegistrarV2`
- Owns today's `PoolPriceRegistrar` (which keeps owning the VI); writes prices with `oldRegistrar.execute(VI.addPrimitive)`.
- `registerV4(asset, PoolKey key)` — anyone:
  - the pool is initialized in the PoolManager (sqrtPrice ≠ 0) and `key.toId()` is the pool;
  - `key.hooks` is `address(0)` or an approved hook;
  - the other currency is an approved quote (native ETH ↔ WETH);
  - the asset isn't priced yet; decimals ≤ 38;
  - current liquidity, read by the registrar from the pool itself (no samples exist yet) ≥ `MIN_LIQUIDITY_USD = 25,000`;
  - deploys the adapter clone, adds the VI primitive (heartbeat 1 h), records it, emits `RegisteredV4`.
- `register(asset, pool)` — anyone: Uniswap v3 / Slipstream 1–3 / Aerodrome basic pools as today, using the existing
  adapter implementations, but against the extended quote list (stock tokens).
- `poolPricedAdapter(asset)`: own registrations (if still the VI aggregator), else `oldRegistrar.poolPricedAdapter(asset)`.
  `MIN_LIQUIDITY_USD()` = 25,000. `getRegisteredAssets()` = old + new.
- Owner: `setHook(hook, approved, hookData)` (the bytes the v4 adapter passes for that hook — for o1, the Treasury as
  referrer), `setQuote(token, approved)` (only VI primitives that are not pool-priced), `setPool(asset, …)` for corrections,
  `executeOld(bytes)` passthrough to today's registrar (Chainlink listings, Veranta pairs, `setPool`), `acceptOldRegistrar()`.
- Doppler/Bankr: approving Doppler's hook waits for a review of graduation (only graduated pools priced).

## 5. Swap adapters

All four: exact-input, single pool, output straight to the vault, `minAmountOut` enforced by the fund as today; protocol fee
taken from the input before the swap and sent to the Treasury Safe: `feeBps` owner-set within `[0, MAX_FEE_BPS = 10]`,
5 at deployment, emitted on change.

- **`UniswapV4SwapAdapter`**: `PoolManager.unlock` → `unlockCallback`: `swap(key, params, hookData)`, settle the input,
  take the output. Native-ETH pools: unwrap the vault's WETH in, wrap ETH out. The pool's hook must be `address(0)` or
  approved in the registrar; `hookData` comes from the registrar's approval, never from the manager. Refuses a caller
  whose `registrar()` isn't `PoolPriceRegistrarV2` (new funds only). Hook fees (STFY 3%, o1 1% + anti-snipe) reduce the
  output and are covered by `minAmountOut` and the slippage policy; the terminal's quote (v4 Quoter) includes them.
- **`UniswapV3SwapAdapterV2`, `AerodromeSlipstreamSwapAdapterV2`, `AerodromeBasicSwapAdapterV2`**: today's code plus the
  fee; no new-funds gate.

## 6. Fund wiring, keeper, monitoring

- **New fund deployer**: `ComptrollerBlueprintDeployer(type(ComptrollerV3).creationCode, abi.encode(registrarV2, queue))`;
  `factory.setComptrollerDeployer(...)`. Same fund code.
- **New `MinPoolLiquidityPolicy(registrarV2)`** replaces today's instance in `factory.setMandatoryPolicies(...)`.
- **Ownership**: deployer `oldRegistrar.transferOwnership(registrarV2)` → `registrarV2.acceptOldRegistrar()`; registrarV2
  owner = deployer; `script/mainnet/FundsGovernance.sol` hands registrarV2 to the timelock instead of today's registrar.
- **Approvals at launch**: the Admin Safe as v4 pool approver; the pools of STFY and of o1's BLUECHIP, RAWR, MOONBASE and
  BASEASS (founder 2026-10-08; the last three are under $25k of quote-side liquidity today and open once they reach it);
  BLUECHIP is priced from its USDC pool on Slipstream (≈ $49.6k USDC; founder 2026-10-08), not its o1 pair — no stock
  feed in between (frozen outside US market hours) and real USDC behind the figure; the o1 pair stays approved for
  trading (referrer share), the route picked on the desk later (UI/UX backlog 15). BLUECHIP pays holders nothing;
  hooks `StockifyFeeHook`, o1 `LaunchHook` ×2 (hookData = Treasury referrer); quotes: the stock tokens memestocks pair
  against (NVDAc, SPCXc, AAPLc, GOOGLc, METAc; each must already be a Chainlink-priced VI primitive); register the four adapters; old fee-free adapters deregistered after the terminal moves.
- **Keeper (funds-keeper)**: sampler every 10 min — v4 tokens held by any fund (subgraph) plus tokens with fewer than 4
  samples registered in the last day — one batched `sample` via Engine, none when empty; o1 referrer sweep daily — for each
  o1 escrow and currency with a balance owed to the Treasury, `claim` (stock-paired escrow) or `claimFor` (ETH-paired). Settings added to `compose.production.yml`.
- **Health (FrostyFlow)**: new line when a held v4 token's newest sample is older than 25 minutes.

## 7. Terminal

- Spot ticket: token search shows v4 pools with venue labels (o1, Stockify, Bankr); unpriced token with a qualifying pool →
  "enable pricing" (register) → warm-up countdown → buy; quotes via the v4 Quoter; fee breakdown (pool, hook, protocol).
- Stock-paired tokens: "buy NVDAc first", trades chained.
- Untracked tokens in the vault (e.g. STFY's stock dividends): banner + "track" button (`addTrackedAsset`).
- All spot routes move to the fee-charging adapters; the v4 ticket shows only for funds on the new deployer.
- Address sync (`indexer/mainnet-deployments.ts`) for the new contracts; market list from `registrarV2.getRegisteredAssets()`.

## 8. Cost

At 10 minutes, 0.006 gwei and ETH ≈ $2,420, with the L1 data fee: ≈ $3.3/month for one held v4 token, ≈ $13.5/month for 10
batched (measured cold on the fork 2026-10-08; the design-time figures were $2.89 and $11); at a 0.02 gwei spike ≈ $9.4 and
$43; plus ≈ $4/month Engine. Referrer sweep: ~30 transactions/month, cents. Revenue to set against it: 5 bps protocol fee on
fund spot trades, and o1's referrer share (0.2% of fund trades routed through o1 pools at a 1% base fee).

## 9. Testing

- **Unit**: sampler (keeper-only, 9-min skip, ring wrap); adapter (median, 4-sample warm-up, liquidity min, $5k → 1 wei,
  stock-token and native-ETH quotes); registrar V2 (hook/quote approvals, PoolKey ↔ PoolId, $25k, fallback to today's
  registrar, `executeOld`); adapters (fee cap, Treasury payment, minOut net of fee, new-funds gate).
- **Fork (Base)**: STFY registered on its real pool, 4 samples across warped time, a new fund buys through the real
  PoolManager (3% hook fee), values it, redemption pays it in kind; a price pumped at fewer than half the sample times leaves
  the median unchanged; STFY's DividendVault cycle pushes stocks into the fund vault, which count after tracking; o1
  BLUECHIP/NVDAc two-step buy (NVDAc on Slipstream, then BLUECHIP through the stock-paired hook) and an ETH-paired o1 buy,
  each crediting the Treasury 20% of the 1% base fee in that hook's escrow and the permissionless claim paying it;
  ElonRWA/SPCXc refused without the SPCXc quote, then refused for liquidity ($16k) with it, and priced by the owner's
  `setPool`; an old fund is refused by the v4 adapter; the fee adapters on real pools; a partial fill on a thin hookless pool
  returns the rest; sample transaction gas; the deploy + owner steps + governance handoff rehearsed at the latest block.
  Coinbase B20 tokens (the stock tokens, every o1 launch token) are Base precompiles Foundry can't run: the proofs give their
  addresses plain ERC-20 code and the balances involved; that a real B20 stock reaches a fund vault was checked on Base
  itself (eth_call: all five STFY payout stocks transfer into TestFund4's vault).

## 10. Known limits

- Existing funds: can't trade v4 tokens (unless reconfigured); a manager could still transfer a v4/stock-quoted token into
  an old fund's vault and track it as an ordinary token (internal test funds only; the old deployer is retired).
- A fund tracks at most 20 tokens (`MAX_TRACKED_ASSETS`); STFY alone pays 5 stocks.
- STFY's owner can exclude any address from dividends; o1's admin can raise its base fee to 10%.
- A stopped sampler pauses deposits for funds holding v4 tokens (health line); long-tail redemptions stay in kind.
- Hooks are trusted only after review; a hook can change what a swap pays.
- **Approved v4 pools only (final review 2026-10-08, H1; founder 2026-10-08: option 1 with an approver role).** v4
  liquidity has no balance cap: a pool's tokens sit in the shared PoolManager, and L·√P counts in-range liquidity even when
  it holds no quote token. A fork proof met the $25k buy floor with a one-tick position holding 0 USDC (and passed
  registration with a flash add/remove costing 1 wei), letting a manager sell his own token to his fund. So every v4 pool is
  approved by its PoolId before it can be registered (`registerV4`) or traded (UniswapV4SwapAdapter): by registrar V2's
  owner or a pool approver — the Admin Safe, so after the governance handoff an approval is one Safe transaction, not a
  2-day timelock proposal. An approver can only approve or revoke pools. The owner's `setPoolV4` approves the pool it
  points at. Five pools are approved at launch (§6). Uniswap v3 / Slipstream / Aerodrome registration stays open (their
  liquidity is capped by the pool's balance). Open v4 registration would need a real-depth measurement (the quote token
  within a band of the price, read by the keeper) — not built.
- The ≈ $0 rule reads the sampled median only (review M1: a v4 LP can pull liquidity for one call at no cost), so a real
  rug reaches 1 wei once half the hour's readings show it; until then the token keeps its median price (deposits in that
  window pay that price; redemptions pay it in kind).
- The fee-taking V2 spot adapters have no new-funds gate (review L2): an old fund could buy a token registered only on
  registrar V2 and hold it as an ordinary token. Old funds are internal test funds (founder 2026-10-08).
- On a partial fill (the price limit reached) the protocol fee was taken on the whole input, including the part returned
  (review L3): at most 5 bps of that part.
- StockifyFeeHook doesn't restrict pool creation (`beforeInitialize: false`, review I1): approving it lets any pool on it be
  registered, as a hookless one would.
- A stopped keeper ends a v4 token's price within the hour; a fund that enabled CumulativeSlippageTolerancePolicy then can't
  sell it either (the policy values the spent token) until readings resume (review I5).
