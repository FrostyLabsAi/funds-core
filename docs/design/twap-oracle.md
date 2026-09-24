# Design: on-chain TWAP price tier (review draft — 2026-09-23)

Status: **proposal, not built.** For founder review before any contract is written.

## Problem

Every asset a fund holds must have a manipulation-resistant price, because deposits and
redemptions settle at NAV — a mispriced holding lets one investor take value from the
others. Today the ValueInterpreter (VI) accepts exactly three kinds of asset:

| tier | source | limit |
|---|---|---|
| Chainlink primitive | Chainlink push feed | only assets Chainlink covers |
| Pyth primitive | `PythAggregatorAdapter` | only Pyth Core ids; needs a pusher keeper |
| zero-priced side pocket | none — valued at $0 | degen funds only; unfair to joiners/leavers; owner-listed |

Every tier is **owner-listed**. So the investable universe is whatever the protocol owner
has had time to list, and the long tail — including many tokens with deep Base liquidity —
is off-limits or stuck at $0. That is a real ceiling on the product (and a known reason
Enzyme-style funds stay narrow).

## Proposal

A fourth tier priced by the market itself: **the time-weighted average price (TWAP) of a
deep on-chain pool**, composed with a Chainlink-priced quote asset, exposed as an
AggregatorV3 feed so the VI prices it through the existing `addPrimitive` path — the same
pattern as `PythAggregatorAdapter`.

Order of preference per asset: **Chainlink → Pyth → TWAP → side pocket.**

### Contract 1 — `TwapAggregatorAdapter` (one per listed asset)

```
constructor(pool, asset, quoteAsset, quoteFeed /*Chainlink*/, window, minLiquidityUsd,
            maxSpotDeviationBps, quoteHeartbeat)
latestRoundData() → (answer = asset USD price, 8 decimals, updatedAt = block.timestamp)
```

Price = `TWAP(asset/quote over window)` × `Chainlink(quote/USD)`.

Reads use the pool's own oracle: `observe([window, 0])` → mean tick over the window
(price) and `secondsPerLiquidityCumulativeX128` → **harmonic-mean liquidity** over the
window. Both verified live on Base 2026-09-23: Uniswap v3 WETH/USDC (observation
cardinality 5000) and Slipstream USDC/NVDAc + USDC/METAc (cardinality 2048) answer
`observe(1800, 0)`.

**Guards — every one REVERTS rather than misprices** (same philosophy as the Pyth
adapter's confidence guard; a revert blocks NAV-dependent actions for funds holding the
asset, in-kind redemption always stays open):

1. **Window** — minimum 30 min (constructor-enforced floor). Moving a 30-min TWAP means
   holding the pool off-price for 30 min against every arbitrageur.
2. **Liquidity floor** — the window's harmonic-mean liquidity, converted to USD, must be
   ≥ `minLiquidityUsd`. Harmonic mean punishes a brief liquidity *withdrawal* during the
   window (the classic trick: pull liquidity, then move the thin pool cheaply).
3. **Spot-vs-TWAP deviation** — if the current tick sits more than `maxSpotDeviationBps`
   from the TWAP, revert. During a manipulation attempt or a genuine crash the fund
   pauses instead of dealing at a stale price. This also closes the *lag* attack:
   depositing at a TWAP that hasn't caught up to a move the attacker can see.
4. **Quote leg** — the Chainlink quote feed is checked for staleness (`quoteHeartbeat`)
   and non-positive answers inside the adapter.
5. **Observation history** — reverts if the pool cannot serve the full window
   (cardinality too low / pool too young).

### Contract 2 — `TwapListingRegistry` (permissionless listing)

Anyone may list an asset if it passes the checks on-chain at listing time:

- pool is canonical — resolved via the Uniswap v3 factory or the Aerodrome CL factory
  `getPool(...)`, never a caller-supplied address taken on trust;
- quote asset is on a short protocol allow-list (USDC, WETH, cbBTC) that is itself
  Chainlink-priced;
- liquidity ≥ the protocol floor, observation cardinality ≥ window / block time;
- asset is not already listed at a higher tier.

The registry deploys the adapter with **protocol-fixed parameters** (window, floor,
deviation — not caller-chosen) and registers it in the VI.

> **Requires one VI change:** `addPrimitive` is `onlyOwner` today. Permissionless listing
> needs a narrow `LISTER` role on the VI that can only add primitives whose feed is a
> registry-deployed TWAP adapter. Owner keeps removal + the higher tiers.

### Contract 3 — `TwapExposurePolicy` (fund-level cap)

A set-once policy capping the share of GAV held in TWAP-tier assets (e.g. ≤ 20%), with a
protocol maximum. Conservative funds can set 0% and never touch the tier.

## Attack surface and answers

| attack | answer |
|---|---|
| Push the pool price, deposit/redeem at the skewed NAV | 30-min window + spot deviation guard + liquidity floor → cost scales with pool depth × window; the deviation guard makes a skewed window revert instead of pricing |
| Withdraw liquidity, then move a thin pool | harmonic-mean liquidity floor over the window |
| Lag: a real move the TWAP hasn't caught up to | deviation guard pauses NAV until TWAP converges; deposits are already async (request → cooldown → execute) |
| List a fake pool for a real-looking token | pool resolved from canonical factories only; quote must be allow-listed |
| Asset rugs / liquidity leaves after listing | reads revert → NAV-dependent actions for holders pause; in-kind exits stay open; owner can demote. **Open decision below.** |
| A fund concentrates in a thin asset | `TwapExposurePolicy` cap |

## Open decisions for the founder

1. **Fail mode when a guard trips.** *Revert* (proposed — never misprices, but pauses the
   fund's NAV actions until the market settles) vs *fall back to $0* (fund keeps running,
   but marks the asset down to zero, which hurts leavers). A hybrid: revert on deviation,
   fall to $0 only on sustained liquidity loss (delisting path).
2. **Protocol parameters:** window (30 min proposed), liquidity floor (proposal: $250k
   harmonic-mean), deviation cap (proposal: 5% for majors-quoted pools, looser tiers
   later), max TWAP share of GAV (proposal: 20%).
3. **Permissionless listing at launch, or owner-listed TWAP first** and open it after the
   adapters have run in production.

## Scope and cost

- 3 new contracts (adapter, registry, policy) + the VI `LISTER` role — Solidity written by
  the top-tier model only, full red/green tests, **audit item**.
- Fork tests against the verified live pools above (Uniswap WETH/USDC, Slipstream stock
  pools — note B20 stock tokens themselves cannot execute on anvil, but their *pools'*
  `observe()` can be read on a fork).
- Terminal: show each holding's price tier (Chainlink / Pyth / TWAP / side pocket) on the
  tear sheet — investors should see how every mark is made.

## Not solved by TWAP

- **Perps on pairs with no on-chain price** (16 Veranta pairs: 14 equities + WTI/Brent
  are Pyth Lazer-only) — a perp has no pool to TWAP. → Lazer tier below.
- Assets with no deep on-chain pool at all.

---

# Addendum: Pyth Pro (Lazer) tier — research 2026-09-23

## Findings (verified)

- **Verifier deployed on Base mainnet:** `0xACeA761c27A909d4D3895128EBe6370FDE2dF481`
  (listed in Pyth's Pro contract-address docs; on-chain: live proxy, `verification_fee()`
  = **1 wei**).
- **Verification API:** `verifyUpdate{value: verification_fee}(update)` returns the
  verified payload; `PythLazerLib` parses a header (timestamp, channel, feed count) and per
  feed `Price`, `BestBidPrice`, `BestAskPrice`.
- **Coverage:** every one of the 16 pairs we cannot price today has a Lazer feed id in
  Veranta's live catalog — e.g. WTI 3454, BRENT 3045, LLY 1246, DELL 1074, ARM 968,
  MRNA 1288, RKLB 1373, NOW 1308.
- **Access:** signed updates need a **Pyth Pro API key**. Pricing/tiers are not published
  on the getting-started page — **open: does the founder's existing Pyth key cover Pro,
  or only Hermes (Core)?**

## Design sketch (not built)

Lazer is a pull oracle like Pyth Core, but its updates are verified per call rather than
stored by Pyth. So:

1. **`LazerPriceStore`** — keeper submits a signed update; the store calls
   `verifyUpdate`, parses it, and records `(price, bestBid, bestAsk, timestamp)` per feed
   id. Rejects updates older than what is stored (no rewinding to cherry-picked prints —
   the same H-3 lesson as the Pyth Core adapter).
2. **`LazerAggregatorAdapter`** — one per feed, AggregatorV3-shaped like the other two
   adapters, reading the store; guards: max age (market-hours gate stays in the VI
   heartbeat), and a **spread guard** (bid/ask width as bps of price — Lazer's equivalent
   of Pyth Core's confidence interval).
3. **Price-marker tokens for non-token underlyings** — a perp leg is valued as
   `coinExposure × price(pairAsset)`, and `pairAsset` must be an ERC-20 the VI prices
   (the position reads its `decimals()`). WTI, Brent, FX, indexes have no token, so each
   gets a supply-less `PriceMarker` ERC-20 (decimals only) registered in the VI with its
   Lazer adapter, and mapped with `setPairAsset(pair, marker)`.
4. **Pusher keeper** — one job for Pyth Core and Lazer: before NAV-dependent actions on
   funds holding those assets, push fresh updates.

Result: Veranta's whole universe (crypto, equities, FX, metals, **energy**) becomes
tradeable and valued on-chain from institutional exchange data.

---

# Update 2026-09-23 (later): Pyth Pro is unaffordable — free sources instead

Founder: Pyth Pro costs $500 or $2,500/month; not viable. The free Pyth key is entitled
**feed by feed** (verified live via Hermes): BTC, ETH, SOL, TSLA, EUR/USD, XAU work;
AERO, NVDA, the long-tail equities and all oil feeds return "Not entitled". So the Pyth
Core tier is majors-only, and the Lazer tier above is shelved.

**RedStone replaces it.** The public gateway (`oracle-gateway-1.a.redstone.finance`,
data service `redstone-primary-prod`) serves **959 signed feeds, no key, no fee**, each
package signed by 5 signers, ~22 s fresh — verified live. Relevant coverage: **AERO,
WTI (WTI.T / WTI.Y / 24_7 / PERP), natural gas (GAS.T / GAS.Y), SK Hynix, STRC, NVDA,
META, TSLA, XAU.** Consumed on-chain through RedStone's EVM connector (signature
verification against the signer set) — same store / adapter / pusher-keeper shape as the
Lazer sketch, at $0. **Open:** confirm RedStone's terms for commercial on-chain use.

Revised ladder: **Chainlink → RedStone → TWAP → side pocket** (Pyth Core optional for
majors only).

Still uncovered by any free source (checked): **Brent** and 11 equities — LLY, DELL, ARM,
RKLB, MRNA, NOW, WDC, IREN, NBIS, LITE, BE. Those Veranta pairs stay disabled for funds
(the on-chain pair map already enforces it) until a free source appears or revenue
justifies a paid feed.

---

# Founder decisions — 2026-09-23

1. **Guard trips → HYBRID:** fast price move vs the average pauses NAV-dependent actions
   until it settles (in-kind exits stay open); a sustained liquidity collapse demotes the
   asset to $0 (keeper/owner), so a rugged asset cannot freeze a fund.
2. **Parameters → proposed defaults:** 30-min window · 5% spot-vs-TWAP cap · max 20% of NAV
   in TWAP-priced assets. Liquidity floor → decided in item 4.
3. **Listing → owner-listed at launch.** Later: FROST-bonded permissionless listing
   (refundable USD-sized FROST bond, automatic slashing only, small burned slice — sizes
   to tune), plus a **community-vote path** for tokens many holders want (vote cost in
   FROST). Registry is built owner-gated now, with the bond/vote hooks designed in.
4. **Liquidity rules (decided):** listing floor **$50k active liquidity** (harmonic-mean,
   in-range — NOT market cap; memecoins run ~10–20× cap-to-liquidity on Base). Per-fund,
   per-asset holding cap scales with pool depth: **pool < $250k → max 10% of the pool's
   liquidity; pool ≥ $250k → max 50% (soft cap)**. Plus the fund-wide 20%-of-NAV cap and
   the 5% spot-vs-TWAP guard. The caps apply to EVERY fund holding a TWAP-priced asset
   (attached by the factory, not opt-in) — they protect co-investors from a mark the pool
   could never pay out in cash.
