# funds-core

Tokenized Hedge Funds — the FrostyFunds protocol contracts.

Melon v1's architecture rebuilt in Solidity 0.8.24 (Foundry + OpenZeppelin 5.x), with Enzyme v4's proven patterns grafted on. Reference sources live in the parent dir and are **read-only**: `../melon-v1/` (do not modify), `../spec/` (Enzyme v4 spec). Project-wide context: `../README.md` (the living doc).

## Layout

```
src/
  core/
    FundFactory.sol      fund deployment + registry        (← melon-v1 FundFactory / v4 FundDeployer)
    Comptroller.sol      per-fund logic + config hub       (← v4 ComptrollerProxy; absorbs melon-v1
                                                              Participation + Accounting duties)
  fund/
    Shares.sol           fund share token, comptroller-gated mint/burn   (← melon-v1 Shares)
    Vault.sol            dumb custody, comptroller-gated withdraw       (← melon-v1 Vault, kept tiny)
  interfaces/
    IExternalPosition.sol  off-vault holdings (HyperCore hedge leg)     (← v4 external positions)
    IPolicy.sol            pass/fail validation hooks                   (← melon-v1 policies + v4 hooks)
    IFee.sol               share-dilution fees, continuous HWM          (← v4 fee formulas)
    IValueInterpreter.sol  oracle-only pricing aggregation              (← v4 ValueInterpreter)
test/
  FundFactory.t.sol      factory wiring, auth gates, deposit request/cancel escrow
```

## Build

```bash
forge build
forge test
```

## Deploy (Base Sepolia — UNVERIFIED by design, never pass --verify)

`cp .env.example .env`, fill in `PRIVATE_KEY` (+ real-infra addresses are pre-filled, all
verified from official docs: Uniswap SwapRouter02/NPM, CCTP **v1** TokenMessenger — v2 has a
different signature, do not swap it in). Then:

1. `source .env && forge script script/DeployTestnet.s.sol --rpc-url base_sepolia --private-key $PRIVATE_KEY --broadcast`
2. Copy logged addresses into `.env` (FACTORY/TUSDC/GPUX/EVRX)
3. Real-router testing: `forge script script/CreateUniV3Pools.s.sol ...` (creates + seeds
   tUSDC/GPUx + tUSDC/EVRx pools on real Uniswap Sepolia at the mock-feed prices)
4. `forge script script/SeedFunds.s.sol ...` → wait ≥10 min → `script/SeedFunds.s.sol:SeedExecute`
5. Post-deploy: `factory.setGuardian(...)`; rotate both position factories' attestors to the
   keeper key. Real CCTP requires `REAL_USDC` (Circle faucet); Aerodrome has no testnet —
   Slipstream adapter keeps the mock router until mainnet/fork tests.

## Hard rules (from the post-mortems and spec — see living doc for sources)

1. Share pricing comes from oracle feeds via ValueInterpreter ONLY — never pool spot state / currentTick (Gamma, Jan 2024).
2. Deposits and redemptions are async (request → execute at a NAV epoch inside market-hours windows). Nothing mints or burns shares atomically with a deposit (kills flash-loan loops and weekend NAV gaming).
3. Tokenized-stock wrappers are never priced 1:1 with their underlying — every wrapper gets its own feed; depeg is a modeled state.
4. Every asset state (idle, in-range, out-of-range, in-flight, external) is explicitly in or out of GAV. No silent residue.
5. Risk parameters get bytecode-level hard caps (frosty-core discipline). Config is attack surface.
6. Funds holding external positions use specific-assets redemption as canonical exit; in-kind forfeits external-position value.

## melon-v1 coverage — every file accounted for (65/65)

Cross-check against `../melon-v1/src/`. Statuses: **PORTED** (equivalent live here), **ABSORBED** (duties live in another contract), **REPLACED** (modern equivalent), **DELETED** (by design decision), **PENDING** (planned, see next PRs).

| melon-v1 | Files | Status → where |
|---|---|---|
| `dependencies/` (DSAuth, DSGuard, DSMath, SafeMath, StandardToken, BurnableToken, PreminedToken, IERC20, TokenUser, WETH) | 10 | REPLACED → OZ 5.x (ERC20/SafeERC20/EnumerableSet/Math), native 0.8 checked math, custom-error modifiers |
| `engine/` (Engine, AmguConsumer, IEngine) | 3 | DELETED → FROST protocol machinery (splitter → PolVault → FeeDistributor) replaces MLN/AMGU economics; no per-operation fees ever |
| `exchanges/` (ExchangeAdapter + 8 venue adapters + 7 venue interfaces) | 16 | REPLACED → `interfaces/IIntegrationAdapter.sol` + `adapters/UniswapV3SwapAdapter.sol` + `adapters/AerodromeSlipstreamSwapAdapter.sol` (swaps; Slipstream router verified from source — `int24 tickSpacing` vs Uni's `uint24 fee`). All v1 venues were dead. Slipstream LP (dual-mode) lands as an External Position type, not an adapter |
| `factory/Factory.sol` | 1 | DELETED → per-spoke factories obsolete (Comptroller deploys components directly) |
| `factory/FundFactory.sol` | 1 | PORTED → `core/FundFactory.sol` (createFund, registry, + bytecode-cap enforcement) |
| `fund/accounting/` (Accounting, IAccounting) | 2 | ABSORBED → Comptroller: `calcGav`, `calcGrossShareValue`, tracked assets (MAX 20 kept), `defaultSharePrice`. v1's `updateOwnedAssets` auto-prune → explicit `removeTrackedAsset` w/ zero-balance rule (no silent residue). `getShareCostInAsset` (multi-asset invest) dropped by design — denomination-asset deposits only, per v4 |
| `fund/fees/` (FeeManager, ManagementFee, PerformanceFee, IFee, IFeeManager) | 5 | ABSORBED → Comptroller `_settleManagementFee` (spec continuous compounding, rpow) + `_settlePerformanceFee` (v4 continuous HWM, replaces v1's period/redeem-window model). v1's `getOwedPerformanceFees`-on-redemption → settled pre-burn via share price (equivalent, simpler). `interfaces/IFee.sol` reserved for the future plugin refactor |
| `fund/hub/` (Hub, Spoke) | 2 | REPLACED → Comptroller-centric wiring, immutable refs, OZ auth. v1 `shutDownFund` PORTED → one-way `Comptroller.shutDownFund` + owner pause toggle + factory-guardian emergency pause (deposits only; exits never gated) |
| `fund/participation/` (Participation, IParticipation) | 2 | ABSORBED → Comptroller: `requestDeposit`/`cancelDepositRequest`/`executeDepositRequest` (+ `REQUEST_TTL` = v1 `REQUEST_LIFESPAN`), `redeemSharesInKind` (= `redeemQuantity`), `redeemSharesForDenominationAsset` (new canonical). Dropped by design: multi-asset `investAllowed` lists, AMGU incentives, ETH executor bribes (keeper executes), `historicalInvestors` (subgraph's job). v1's price-update request gating → `minRequestDuration` + feed-heartbeat market-hours gate |
| `fund/policies/` (PolicyManager, IPolicyManager, IPolicy, AddressList, TradingSignatures, UserWhitelist, AssetBlacklist, AssetWhitelist, MaxConcentration, MaxPositions, PriceTolerance) | 11 | PolicyManager/IPolicy ABSORBED/PORTED → Comptroller policy hooks + `interfaces/IPolicy.sol` (v4 hook taxonomy; investor-restricting hooks lock after launch). UserWhitelist PORTED → `policies/AllowedDepositorsPolicy.sol`. MaxConcentration PORTED → `policies/MaxConcentrationPolicy.sol` (PostCallOnIntegration). + new `MinMaxDepositPolicy` (v4) + `CumulativeSlippageTolerancePolicy` (v4 drain rate-limiter, 7d linear replenish). AddressList → OZ EnumerableSet. TradingSignatures obsolete. MaxPositions → covered by bytecode caps (MAX_TRACKED_ASSETS/MAX_EXTERNAL_POSITIONS). PriceTolerance → superseded by CumulativeSlippageTolerance (same goal, better mechanism). PENDING: Asset{Black,White}list per-fund policies + dust policies |
| `fund/shares/` (Shares, IShares) | 2 | PORTED → `fund/Shares.sol` (`createFor/destroyFor` → `mint/burn`; v1 blocked all transfers — ours allows w/ timelock + PreTransferShares policies) |
| `fund/trading/` (Trading, ITrading) | 2 | PORTED → `Comptroller.callOnIntegration` (v4 IntegrationManager model: factory-curated adapter registry, vault-balance-delta accounting, auto-tracked incoming assets, PostCallOnIntegration policies; v1's open-make-order escrow accounting is obsolete) |
| `fund/vault/` (Vault, IVault) | 2 | PORTED → `fund/Vault.sol` (1:1 dumb custody, + SafeERC20 + explicit `to`) |
| `prices/` (IPriceSource, KyberPriceFeed) | 2 | REPLACED → `core/ValueInterpreter.sol` (pull oracles, per-asset heartbeat; equity heartbeat = market-hours gate). `hasValidPrice` → `isSupportedAsset` + revert-on-stale |
| `registry/IRegistry.sol`, `version/` (Registry, Version, IVersion) | 4 | SPLIT: asset registry → ValueInterpreter primitives; fund registry + **name reservation** (`reserveFundName`/`canUseFundName` → `isFundNameTaken`) → FundFactory; adapter/position-type registries → FundFactory; MLN/engine/incentive plumbing DELETED. Version's reconfiguration → `createReconfigurationRequest`/`executeReconfiguration` (2-day timelock); protocol-level `shutDownFund` → guardian deposit-pause + adapter/type deregistration (exits never blockable — stricter than v1) |

## Status / next PRs

DONE: ValueInterpreter (oracle-only pricing, staleness/market-hours gate) · GAV + share price · executeDepositRequest (async, TTL, min-duration) · management fee (continuous compounding) · performance fee (continuous HWM) · redemptions (denomination-asset canonical + in-kind 24/7 fallback) · sharesActionTimelock (redeem + transfer) · policy hooks + AllowedDepositors/MinMaxDeposit · tracked-asset rules · external positions in GAV (managed − debt, floored per position) · `settleFees()` public poke · shutdown/pause lane (one-way `shutDownFund`, owner subscription switch, factory-guardian instant pause with owner-only unpause; redemptions NEVER gated) · trading via `callOnIntegration` (factory-curated adapter registry w/ guardian insta-deregister, balance-delta accounting, auto-tracking) · UniswapV3 + AerodromeSlipstream swap adapters · MaxConcentration + CumulativeSlippageTolerance trading policies · **external-position lifecycle** (typed registry on factory, create/callOn/dust-gated remove, policy hooks on each) · **HyperliquidPerpPosition** (attested-equity hedge leg: keeper attests account equity, 1-day attestation TTL gates GAV like a market-hours heartbeat; immutable bridge account; vault→bridge→vault flows as fund actions) · AllowedExternalPositionTypes policy · **reconfiguration** (signal → 2-day investor exit window → execute: new Comptroller adopts existing Shares/Vault/holders, HWM + tracked assets carry, old comptroller dies for deposits, external positions must wind down first) · Allowed/Disallowed adapter-incoming-asset policies · in-kind redemption skip-list (one broken asset can never block the guaranteed exit) · fund-name reservation · holdings views (calcAssetGav, getFundHoldings) · Base Sepolia deploy + two-phase seed scripts (`script/`). **57 tests green. Function-level melon-v1 audit complete 2026-09-13 — see coverage table.**

**PROTOCOL FEATURE-COMPLETE 2026-09-13** (+ same-day extensions: **derivative pricing** in the ValueInterpreter — v4-style feeds, primitives-only underlyings so cycles are impossible, quote must be primitive — with the generic **ERC4626PriceFeed** + **ERC4626Adapter** (deposit/redeem into any curated 4626 vault: Morpho/Euler/Yearn-class yield) and the **UniswapV3LPPosition** twin (fee-keyed, no gauge, 100% LP fees, same oracle-fair valuation) and the **side-pocket class**: zero-priced assets (unpriceable moonshots) holdable ONLY by funds created with the immutable `allowRiskyAssets` flag — valued at ZERO in GAV until realized by sale, so no oracle to manipulate and no fees on paper gains; in-kind redemption pays out the bag pro-rata; the slippage policy auto-rate-limits moonshot deployment; and **SolanaAccountPosition** — Model-1 native-Solana access: keeper-operated fund wallet on Solana, CCTP outbound locked on-chain to the immutable wallet, factory-pinned attestor, public mandate string; Squads-policy upgrade (Model 2) and CCIP-PDA control (Model 3) staged in the living doc). Also: **SlipstreamLPPosition** (dual-mode LP leg — unstaked fees-to-vault vs gauge-staked AERO-to-vault; valued at the ORACLE-fair sqrt price ported from frosty-core PriceOracle, never pool state) + TickMath/LiquidityAmounts libs + `ValueInterpreter.calcUsdRate`. **62 tests green · Slither/Aderyn triaged (zero-check fixes applied) · Echidna 3/3 properties over 20k calls · coverage: core contracts 90–100% — see AUDIT_TOOLING_RESULTS.md.**

Remaining before mainnet (not blocking testnet/subgraph/terminal work):
1. (optional) Attestation depth: multi-attestor median / equity-delta bounds — the self-attestation vector is already closed by factory-pinned attestors (managers cannot choose who prices their hedge; protocol key rotates globally via one setAttestor)
2. Long fuzz campaigns (echidna 500k+ / medusa) + external audits ×2
3. Proxy/beacon deployments (gas + upgradability polish; reconfiguration already covers config swaps)
4. Pending-fee preview views if the terminal wants them (workaround: eth_call staticcall `settleFees()`)
