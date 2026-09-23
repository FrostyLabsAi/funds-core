# Audit Tooling Results — funds-core

Run 2026-09-13, protocol feature-complete (62 unit/integration tests green). Same toolchain discipline as frosty-core.

## Tools & commands

| Tool | Version | Command |
|---|---|---|
| forge tests | 1.5.0 | `forge test` — 62/62 pass |
| Slither | 0.11.6 | `slither . --filter-paths 'lib/|test/|script/' --exclude-informational --exclude-optimization --json slither_results.json` |
| Aderyn | (installed) | `aderyn . -o aderyn-report.md` |
| Echidna | (installed) | `echidna . --contract EchidnaFund --config echidna.yaml` — property harness at `test/echidna/EchidnaFund.sol` |
| Coverage | forge | `forge coverage --ir-minimum --report summary` |

## Echidna property campaign

3/3 properties held over 20,116 fuzzed calls (corpus persisted in `echidna-corpus/`; run longer campaigns with `--test-limit 500000` before audit submission):
- `echidna_escrow_solvent` — the Comptroller holds exactly the open deposit-request escrow at all times.
- `echidna_hwm_monotonic` — the high-water mark never decreases under any action sequence (fee-gaming guard).
- `echidna_shares_backed` — shares never exist without vault value behind them.

## Slither triage (1 High, 33 Medium, 91 Low)

**Fixed during this pass:** zero-address checks added to Vault/Shares constructors + `migrateComptroller`, Comptroller constructor (fundOwner/denomination/ValueInterpreter), HyperliquidPerpPosition and SlipstreamLPPosition constructors.

| Finding | Count | Verdict |
|---|---|---|
| High `reentrancy-balance` (MaxConcentrationPolicy) | 1 | **False positive.** The policy is validation-only (writes no state) and executes inside `callOnIntegration`, which is `nonReentrant`; external calls are to the protocol-owned ValueInterpreter/Comptroller. No reentrant path exists to change the balance mid-validation. |
| `unused-return` | 14 | **Acknowledged, intentional.** (a) `EnumerableSet.add/remove` where prior `contains` checks or idempotence make the bool redundant; (b) swap-router return values — vault balance deltas are the accounting truth, never venue return values (by design); (c) partial destructuring of `positions()`. |
| `reentrancy-no-eth` / `reentrancy-events` / `reentrancy-benign` | 23 | **Acknowledged.** All state-changing entrypoints are `nonReentrant`; external calls go to registry-curated contracts (adapters, position types) or protocol singletons. Cross-function reentrancy from a malicious adapter/position is pre-empted by the curation requirement — a hostile plugin is a governance failure, not a code path. |
| `incorrect-equality` | 5 | **Acknowledged.** All are `== 0` emptiness checks (balances, tokenId, elapsed), not value comparisons. |
| `uninitialized-local` | 5 | **Acknowledged.** Accumulators intentionally starting at zero. |
| `divide-before-multiply` (TickMath) | 1 | **Acknowledged.** Canonical Uniswap TickMath, imported verbatim (via frosty-core); battle-tested. |
| `erc20-interface` (positionManager.approve) | 1 | **False positive.** ERC-721 `approve(address,uint256)` on the NFT manager, not an ERC-20. |
| `calls-loop` | 54 | **Acknowledged, inherent.** GAV aggregation prices each tracked asset/position via the ValueInterpreter in a loop — the v4 design. Bounded by bytecode caps (20 assets, 10 positions). |
| `timestamp` | 14 | **Acknowledged.** Heartbeats, TTLs, and timelocks are timestamp-based by definition; all windows are ≥ minutes, far beyond miner drift. |
| `missing-zero-check` | 7 | **False positive post-fix.** Guards exist as `if (x == address(0)) revert ...` custom errors; the detector does not credit this pattern at these sites. Verified present in source. |

## Aderyn triage

- **H-1 state-change-after-external-call** — same reasoning as Slither reentrancy family: `nonReentrant` entrypoints + curated callees. Acknowledged.
- **H-2 storage-array-to-memory (ValueInterpreter#104)** — intentional read-only copy of the asset struct; nothing is written back. False positive for this use.
- **H-3 unsafe downcast (CumulativeSlippageTolerance `uint128(lossBps)`)** — bounded: `lossBps ≤ BPS (10,000)` by construction and the accumulator reverts above `toleranceBps` immediately after. Cannot overflow uint128. Acknowledged.
- Lows: PUSH0 (Base supports Shanghai — fine), centralization notes (factory owner/guardian are the design, migrating to timelock/guardian multisig per Phase 5), remainder stylistic.

## Coverage (lines / functions)

Core contracts: Comptroller 95.9%/97.4%, FundFactory 100%/100%, ValueInterpreter 89.7%/85.7%, adapters 100%/100%, HyperliquidPerpPosition 95.6%/100%, SlipstreamLPPosition 80.6%/88.9%, Shares/Vault 100%/100%. Overall src 74% lines — dragged by TickMath (21.7%), the canonical Uniswap lookup-table lib where exhaustive branch coverage is impractical and unnecessary (imported verbatim). Policies sit at 55–90%; their unexercised lines are mostly `implementedHooks()` views and constructor loops.

## Addendum (same-day extensions: 4626 + Uni v3 LP)

ValueInterpreter derivative support + ERC4626PriceFeed/Adapter + UniswapV3LPPosition added after the main pass. Re-runs: 68/68 forge tests, echidna 3/3 (10k regression), slither re-run — no new findings beyond the already-triaged families (strict `== 0` emptiness checks; `tokenId = 0` write after `burn()` flagged as cross-function reentrancy is the same curated-callee + nonReentrant-entrypoint pattern as the Slipstream twin). New trust surface documented in ERC4626PriceFeed: the feed trusts `convertToAssets` — register only audited 4626 vaults with manipulation-resistant accounting.

### Side-pocket class (same day)

Zero-priced asset registry in the ValueInterpreter + immutable per-fund `allowRiskyAssets` flag gating acquisition (checked in `_trackAsset`, covering both explicit tracking and trade auto-tracking). Security property: value is a constant 0 — no oracle, no manipulation surface, no fee crystallization on unrealized "gains"; gains enter GAV only on sale into a priced asset. 72/72 tests, echidna 3/3 re-run.

### SolanaAccountPosition (same day)

Model-1 cross-chain position: fund-dedicated Solana account, keeper-operated, equity attested via the factory-pinned attestor (same machinery as the Hyperliquid position). Hardening beyond HL: the outbound leg burns native USDC via Circle CCTP with `mintRecipient` locked to the position's immutable `solanaWallet` — Base-side funds structurally cannot be redirected, by anyone. Wallet + declared mandate are public (attestations are auditable against the live Solana account). 76/76 tests, echidna 3/3 re-run.

## Pre-audit checklist (before engaging auditors)

- [ ] Long echidna campaign (500k+) + medusa run on the same harness
- [x] **Attestor pinning (2026-09-13)**: managers can no longer choose who prices their Hyperliquid leg — the type factory holds one protocol-wide attestor, resolved live by every position, rotatable via owner-only `setAttestor` (one call rotates all positions; key loss cannot brick funds). This closes the marketplace self-attestation vector. Optional further hardening: multi-attestor median / equity-delta bounds
- [ ] Freeze the adapter/position-type registries' intended mainnet contents
- [ ] Governance handoff plan documented (factory owner → timelock, guardian → multisig)
