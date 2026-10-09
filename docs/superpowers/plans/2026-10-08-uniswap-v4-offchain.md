# Uniswap v4 + memestocks — plan B (keeper, terminal, health)

Spec: `docs/superpowers/specs/2026-10-08-uniswap-v4-memestocks-design.md` (§6–§8). Contracts: plan A
(`2026-10-08-uniswap-v4-contracts.md`), built and fork-proven on `feat/uniswap-v4`. Founder 2026-10-08: build straight
through. Branches: `feat/uniswap-v4` (`--no-track`, from local `origin/main`) in funds-keeper and frosty-terminal; frostyflow
in a separate worktree (the main checkout has the founder's uncommitted work). Nothing is committed, pushed or deployed.

## Facts the plan rests on (checked 2026-10-08)

- **Pool discovery**: GeckoTerminal's token-pools endpoint lists v4 pools (`dex` `uniswap-v4-base`, `address` = the 32-byte
  pool id, `pool_created_at`), never the key. Base blocks are exactly 2 s from genesis timestamp 1,686,789,347, so the
  creation block is `(createdAt − genesis) / 2`; the PoolManager's `Initialize(id, currency0, currency1, fee, tickSpacing,
  hooks, sqrtPriceX96, tick)` log is found within ±60 blocks (STFY: found at 0x2fdc88b). Our RPC caps `eth_getLogs` at a
  10,000-block range, so a full-range search by id is impossible. The key is self-checked: `keccak256(abi.encode(key)) == id`.
- **Keeper** (funds-keeper): one loop per process; new jobs are sub-jobs in protect's `fullPass` (60 s loop) with an
  env-gated ON switch, an `X=0` kill switch, a `due()` timer and their own try/catch (pattern: `redemption-settler.ts`).
  Writes: `simulateContract` → `wallet.writeContract` → receipt, through the Engine wallet; `DRY_RUN=1` logs instead.
  Protect's HTTP server already serves `/prices` to the terminal (`PROTECT_API_URL`).
- **Terminal**: the spot ticket (`FundTokenTicket.tsx`) branches on `registrar.poolPricedAdapter(asset)`; venues come from a
  pool's `factory()`; v4 has no pool contract, so it gets its own leg type. Adapters come from `INFRA`
  (`mainnetDeployments.ts`, synced by `indexer/mainnet-deployments.ts`). Next.js 16: read `node_modules/next/dist/docs/`
  before any route handler.
- **Tracking**: `addTrackedAsset` needs only a VI price, not a balance, so a manager can re-arm sampling for a v4 token by
  tracking it.

## Keeper (funds-keeper)

**K1. v4 sampler sub-job** (`src/v4/sampler.ts`, wired in `src/protect/index.ts`):
- ON when `V4_REGISTRAR` and `V4_SAMPLER` are set; `V4_SAMPLER_ENABLED=0` turns it off. Every `V4_SAMPLE_EVERY_SECONDS`
  (600).
- Pools to sample, in priority order, capped at `V4_MAX_POOLS` (30; an `ALERT` line when the cap cuts any):
  1. v4 tokens with a balance in any verified fund's vault;
  2. v4 tokens tracked by a verified fund (the re-arm path);
  3. tokens registered or re-pointed on registrar V2 in the last 24 h (`RegisteredV4` / `PoolSetV4` logs, 10,000-block
     chunks over the last 43,200 blocks).
  A token is a v4 token when `registrarV2.v4KeyOf(asset)` has a nonzero `currency1` and `adapterOf(asset)` is still the
  VI's aggregator (`poolPricedAdapter(asset) == adapterOf(asset)`).
- One `sample(poolIds)` per pass; pools sampled under 9 minutes ago are left out (the contract skips them anyway); nothing
  sent when empty. Status kept in memory for `GET /v4`.
- Pure functions (selection, cap, dueness, status) unit-tested; chain calls mocked as in `redemption-settler.test.ts`.

**K2. o1 referrer sweep** (`src/v4/o1-sweep.ts`, protect sub-job): every `O1_SWEEP_EVERY_SECONDS` (86,400); `O1_SWEEP=0`
turns it off. Escrows (Base): `0x1D8c…d02f` → `claim(recipient, currency)`, `0xB3F1…6866` → `claimFor(recipient, currency)`;
currencies `O1_SWEEP_CURRENCIES` (default native ETH, NVDAc, SPCXc, AAPLc). For each pair with `owed(TREASURY, currency) > 0`,
simulate then send. The Treasury receives; the keeper pays gas (cents).

**K3. Status route**: protect's HTTP server answers `GET /v4` → `{ lastPassAt, lastPassAgeSec, pools: [{ asset, poolId,
reason, newestSampleAgeSec }], capped, failed }`.

**K4. Config**: `compose.production.yml` protect service: `V4_REGISTRAR`, `V4_SAMPLER`, `V4_SAMPLE_EVERY_SECONDS`,
`V4_MAX_POOLS`, `V4_SAMPLER_ENABLED`, `O1_SWEEP`, `O1_SWEEP_EVERY_SECONDS`, `O1_SWEEP_CURRENCIES`, `TREASURY`. Until the
v4 book exists the sampler stays off (unset addresses).

## Terminal (frosty-terminal)

**T1. Address sync**: `indexer/mainnet-deployments.ts` reads `../funds-core/deployments/base-mainnet-v4.json` when present →
`LATER_KEYS`: `v4Registrar`, `v4Sampler`, `v4Adapter`, `uniAdapterV2`, `slipstreamAdapterV2`, `slipstream2AdapterV2`,
`slipstream3AdapterV2`, `aerodromeBasicAdapterV2`, `v4FundDeployer`; `INFRA` fields; test in `mainnet-deployments.test.ts`.

**T2. Fee adapters for every fund**: once the V2 adapters exist, `adapterForVenue` returns them; the quote is taken on the
amount after the adapter's `feeBps` (read on chain) so minOut matches; the ticket shows the protocol fee. Manage-page
adapter labels gain the new adapters (and the missing slipstream3 / basic).

**T3. v4 library** (`src/lib/v4.ts`): PoolKey type, `poolId`, integrationData `(PoolKey, zeroForOne, amountIn, minOut)`,
the block-from-timestamp rule, `Initialize` log decoding with the id self-check, venue labels by hook (Stockify, o1,
hookless "Uniswap v4"; any other hook "unsupported hook"), V4Quoter `quoteExactInputSingle` args with the registrar's
hookData, warm-up status from `sampler.samples(id)` (readings in the last hour, minutes until four).

**T4. Discovery route** `GET /api/spot/v4-pools?token=` (server): GeckoTerminal token pools → v4 ones → keys resolved from
`Initialize` logs → `[{ id, key, label, reserveUsd, hookAllowed }]`, cached 10 minutes.

**T5. Ticket**:
- The fund's own `registrar()` replaces the global registrar in `FundTokenTicket` (an old fund keeps today's behaviour).
- A token priced by a V4PoolPriceAdapter (its `config().pool` is the PoolManager) gets the v4 leg: key from
  `registrarV2.v4KeyOf`, warm-up status, quote, minOut, `callOnIntegration(v4Adapter, data)`; a stock- or WETH-quoted pool
  is a two-step buy ("buy NVDAc first"), the first step through the stock's own route.
- An unpriced token with a v4 pool (funds on registrar V2 only): "enable pricing" simulates `registerV4(asset, key)` and
  names the blocker (hook not approved, quote not allowed, pool too thin, already priced, not initialized).
- Market list from `registrarV2.getRegisteredAssets()` when it exists.

**T6. Untracked tokens**: the desk checks the vault's balance of the STFY payout stocks and the market tokens that the fund
doesn't track; a banner lists them with "track" (`addTrackedAsset`).

**T7. Keeper proxy**: `GET /api/keeper/v4` → `PROTECT_API_URL/v4` (502 when unreachable), for the health line.

## Health (frostyflow, worktree)

**F1.** Builder line "v4 prices": the terminal's `/api/keeper/v4`; NEEDS ATTENTION when a pool kept for a holding (reason
`held`) has no sample for 25 minutes, the pass is over 30 minutes old, the cap cut pools, or the route isn't 200. Ops
script in `.ops-scratch/` (dry run / send / undo) for the prod workflows, as before.

## Order

K1–K4, then T1–T7, then F1; each repo's tests and typecheck green; then one review across the three branches.
