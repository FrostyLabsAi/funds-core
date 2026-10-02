# Fee Compounders (Aerodrome + Uniswap v3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** an auto-compounding vault for EVERY Aerodrome Slipstream pool on the Yield board, plus Uniswap v3 pools.
- Fees are harvested, 10% (adjustable 5–30%) goes to the FrostyDAO Treasury Safe, and the rest is added back to the position. There's no AERO and no swaps.
- Funds deposit through the existing CompounderAdapter.
- NAV values the shares through the existing CompounderPriceFeed.

**Architecture:**
- **New `FeeCompounderBase`** (abstract): ERC20 shares, compounding logic and fee bounds, with exactly the external interface of the Sepolia-deployed `FrostyCompounder`. The deployed `CompounderAdapter` and `CompounderPriceFeed` therefore serve the new vaults unchanged.
- **Two thin venue contracts:** `SlipstreamFeeCompounder` (Aerodrome Slipstream 1/2/3) and `UniswapV3FeeCompounder`.
- **`CompounderFactory`:** creates one vault per canonical pool and owns every vault, so governance sets fees through the factory. Creation is restricted to owner-granted CREATORS (founder 2026-10-01), so no branded junk vaults: the role goes to the FrostyFi workflow's signing Vault wallet, which is also a PriceListingModule keeper.
- **`PriceListingModule`** (TWAP listing v2, undeployed) gains a keeper-only `listCompounder`, which registers a factory-made vault as a VI derivative. Coverage stays automatic after the VI moves to the module.

**Tech stack:** Foundry, solc 0.8.24, OpenZeppelin, Base mainnet forks.

**Spec (founder 2026-10-01, verbatim):**
- "it needs to cover any and all aerodrome pools that we add to the yield farm";
- (no AERO compounder:) "i dont like that, there will be too many moving parts";
- "make the fee adjustable from 5% to 30% but we will start at 10% and send the fees to the FrostyDAO Treasury Safe".

## Global Constraints
- **Fee:** `MIN_PERF_FEE_BPS = 500`, `MAX_PERF_FEE_BPS = 3000`, initial `1000`. `setPerfFee` reverts outside [500, 3000].
- **Treasury:** FrostyDAO Treasury Safe `0x47b7702a4789912d0dfFDadC07c50395c293fF0A`. Verified on Base 2026-10-01: Safe v1.4.1, 2-of-3, owners 0xaE51…/0x3765…/0x6a31….
- **Side-by-side:** NEVER edit `src/yield/FrostyCompounder.sol` (deployed on Base Sepolia), `CompounderAdapter.sol` or `CompounderPriceFeed.sol`. New files only. The one exception is `src/pricing/PriceListingModule.sol`, which is undeployed and on the branch.
- **Interface compatibility (load-bearing):** the new compounders expose, with byte-identical signatures:
  - `token0()`/`token1()` returning `IERC20`;
  - `tickLower()`/`tickUpper()` returning `int24`;
  - `deposit(uint256,uint256,uint256,uint256,uint256) returns (uint256)`;
  - `withdraw(uint256,uint256,uint256) returns (uint256,uint256)`;
  - `compound()`;
  - `positionState() returns (uint128,uint128,uint128)`;
  - `perfFeeBps()`, `treasury()`, `tokenId()`, ERC20.

  A fork test calls the DEPLOYED-shape CompounderAdapter and CompounderPriceFeed against them.
- **Venues and position managers:**
  - Uniswap v3 NPM `0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1`.
  - Slipstream-1 NPM `0x827922686190790b37229fd06084350E74485b72` and Slipstream-2 NPM `0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53` (FundsMainnet constants).
  - The Slipstream-3 NPM is NOT known yet: find it in Aerodrome's official docs or contracts repo, and verify `npm.factory() == 0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a` on-chain. If it can't be verified, ship Slipstream 1/2 + Uniswap v3 and leave venue 3 unset (create reverts `VenueNotSupported`).
  - Verify every NPM's `factory()` against its pool factory with cast before use.
- **Full range:** ticks are ±`(887272 / spacing) * spacing` (Uniswap: spacing from `feeAmountTickSpacing(fee)`; Slipstream: the pool's spacing).
- **Never stake:** compounders stay unstaked; they earn trading fees, not AERO.
- **Cap safety:** `listCompounder` refuses a vault if either token is TWAP-priced by TwapListingRegistryV2 (`isTwapPriced`). The exposure policy doesn't look through derivatives, so a compounder must not become a cap bypass.
- **B20 stock tokens can't run on a Foundry fork.** Fork tests use non-B20 pools (WETH/USDC, cbBTC/USDC, AERO/USDC…) on each venue. Stock-pool vaults are proven on mainnet with cast after deploy, as a small live test with the founder's capital.
- **RPC budget (Ruling 22):** pinned `BASE_FORK_BLOCK`, `-j 1`, ≤ 20 req/s, no batching.
- **Git and safety:** no git add/commit/push by agents; no broadcast except to a local anvil fork; never print `.env` values; Opus only; the controller does the final review.

## Review Focus
1. **Share math under compounding:** a later depositor never captures fees earned before their deposit; `_compound()` runs before every deposit and withdraw, as in FrostyCompounder. Pinned by a fork test with real swaps generating fees between two deposits.
2. **Fee bounds and destination:** the fee can never exceed 30% or drop below 5%; it's paid only to `treasury`; principal is never charged. Pinned by unit + fork tests (treasury balance delta == 10% of harvested).
3. **Slipstream specifics:** mint with `sqrtPriceX96 = 0` (the pool exists); spacing-aligned full-range ticks; `positions()` layout (tickSpacing in place of fee); the 3 deployments map to the right NPM. Pinned by fork tests on CL1 + CL2 (+ CL3 if its NPM is verified).
4. **Inflation and donation:** same bootstrap-shares sink and `minShares` as FrostyCompounder. A donation before the first deposit cannot steal it. Pinned by a fork test.
5. **Listing gate:** only factory-made vaults whose tokens are both VI-priced and NOT TWAP-priced can be listed; only keepers can list. Pinned by module unit tests and a fork test.

---

### Task 1: `FeeCompounderBase` + `SlipstreamFeeCompounder` + `UniswapV3FeeCompounder`
**Files:** create `src/yield/FeeCompounderBase.sol`, `src/yield/SlipstreamFeeCompounder.sol`, `src/yield/UniswapV3FeeCompounder.sol`, and `test/fork/FeeCompounderFork.t.sol`.
- **Base:**
  - Port `FrostyCompounder`'s deposit / withdraw / compound / positionState logic VERBATIM where it isn't venue-specific: bootstrap sink, `minShares`, refunds, `try increaseLiquidity` dust tolerance, events.
  - `compound()` is ROLE-ONLY (founder 2026-10-01): `onlyCompounder` checks the FACTORY's `compounders` mapping. That role goes to the FrostyFi workflow's Vault wallet, which compounds on a schedule. No outsider can time a compound around a price push. `deposit` and `withdraw` still run `_compound()` internally, so fees are never lost if the workflow stalls, only delayed.
  - Venue-specific calls go through internal virtual hooks: `_mintPosition`, `_increase`, `_decrease`, `_collect`, `_positions` (returning liquidity, owed0, owed1).
  - Fee bounds per Global Constraints.
  - `constructor(name, symbol, token0, token1, tickLower, tickUpper, perfFeeBps, treasury, owner)`, with the owner explicit (the factory).
  - `setPerfFee` / `setTreasury` are onlyOwner.
- **`SlipstreamFeeCompounder(npm, token0, token1, tickSpacing, perfFeeBps, treasury, owner)`:** full-range ticks from the spacing; `mint` with `sqrtPriceX96 = 0`.
- **`UniswapV3FeeCompounder(npm, token0, token1, fee, perfFeeBps, treasury, owner)`.**
- **Fork tests:** real pools on Uni v3 + Slipstream 1 + Slipstream 2, each with:
  - first deposit, then real swaps through the real router to generate fees;
  - a second depositor joins AFTER the fees accrued, then `compound()`;
  - assert the treasury got exactly `perfFeeBps` of harvested, liquidity grew, and the first depositor's withdraw returns more than it put in (net of fee) while the second's doesn't capture the earlier fees;
  - fee bounds;
  - the donation-before-first-deposit attack fails;
  - the DEPLOYED-shape `CompounderAdapter` + `CompounderPriceFeed` (new instances of the existing code) work against the new vaults: a fund deposits and withdraws through the adapter, and the feed values shares within 1% of the oracle-fair value.

### Task 2: `CompounderFactory`
**Files:** create `src/yield/CompounderFactory.sol`, `test/CompounderFactory.t.sol` (unit), plus fork coverage in Task 4.
- `Ownable2Step`.
- **Immutables:** the Uni v3 factory, the Slipstream 1/2/3 factories, and the four NPMs (zero allowed only for venue 3 → `VenueNotSupported`).
- **Storage:** `defaultPerfFeeBps` (init 1000, bounded 500–3000) and `treasury` (init the DAO Safe).
- **`create(Venue venue, address tokenA, address tokenB, int24 feeOrTickSpacing) returns (address)`:**
  - CREATOR-ONLY: `mapping(address => bool) public creators`, owner-only `setCreator(address, bool)` (zero address → `ZeroAddress`), anyone else → `NotCreator`. The role goes to the funds-keeper wallet, which also gets the PriceListingModule keeper role for `listCompounder`.
  - A SEPARATE role, `mapping(address => bool) public compounders`, owner-only `setCompounder(address, bool)`, read by every vault's `compound()`. It goes to the FrostyFi workflow wallet. Each wallet gets only its own job (least privilege).
  - resolves the canonical pool through the venue's factory (zero → `PoolNotFound`);
  - one vault per pool (`compounderOf[pool]`; a second create → `AlreadyExists`);
  - deploys the venue vault with owner = this factory;
  - records `isCompounder[vault] = true`;
  - names it `Frosty Compounding <SYM0>-<SYM1>` (symbol `fc<SYM0><SYM1>`);
  - emits `CompounderCreated(pool, vault, venue)`.
  - Creator-only so every vault branded "Frosty Compounding …" is one we chose; listing in the VI (keeper-only) remains the gate for funds.
- **Owner-only controls:**
  - `setDefaultPerfFee`;
  - `setTreasury`, which also pushes the new treasury to every vault via a paged `syncTreasury(offset, limit)`;
  - `setPerfFee(vault, bps)`, forwarded to the vault, bounded.
- **Views:** `allCompounders` + `compoundersPage(offset, limit)`.
- Keep the factory under EIP-170. If the two vault creation codes don't fit, split into per-venue deployer contracts as TwapAdapterDeployers does, and report the size.

### Task 3: `PriceListingModule.listCompounder`
**Files:** modify `src/pricing/PriceListingModule.sol` and `test/PriceListingModule.t.sol`.
- Owner-only `setCompounderListing(CompounderFactory factory, address compounderFeed)`, settable once. A zero factory or feed → `ZeroAddress`.
- Keeper-only `listCompounder(address vault)`, which requires:
  - `factory.isCompounder(vault)` (else `NotFactoryCompounder`);
  - `!vi.isSupportedAsset(vault)` (else `AlreadyPriced`);
  - both `token0`/`token1` VI-supported (else `UnpricedUnderlying`);
  - neither `registry.isTwapPriced` (else `TwapUnderlying`, the cap-bypass guard).

  Then it calls `vi.addDerivative(vault, compounderFeed)` and emits `CompounderListed`.
- Update the natspec.
- The unit tests use the real VI (as the existing module tests do) with mocks only for pure gating where unavoidable. Real-pool coverage is in Task 4.

### Task 3b: AERO claim fee: `SlipstreamLPPositionV2` + factory (founder 2026-10-01: "10% when funds claim AERO")
**Files:** create `src/positions/SlipstreamLPPositionV2.sol` (with its factory) and `test/fork/SlipstreamLPPositionV2Fork.t.sol`. NEVER edit the deployed `SlipstreamLPPosition.sol`.
- **Port verbatim:** a copy of `SlipstreamLPPosition` (including both 2026-09-27 fixes: the gauge must equal the pool's own `gauge()`, and `onERC721Received` accepts only its own NFT from its own NPM).
- **One change, ClaimRewards:** after claiming from the gauge, send `aeroFeeBps` of the claimed AERO to `treasury` and the rest to the fund's vault, exactly as today. Trading-fee `Collect` is untouched (no cut).
- **Fee and treasury live on the V2 position FACTORY:**
  - `aeroFeeBps`, bounded 500–3000, init 1000;
  - `treasury` = the DAO Safe;
  - owner-only setters;
  - every position reads them at claim time, so governance adjusts them for all positions at once.
- **Deploy (Task 4):** re-point types 4 and 7 with `FundFactory.registerPositionType(4, newFactoryCL1)` / `(7, newFactoryCL2)`. Verified 2026-10-01: the Comptroller reads `positionTypeFactories` ONLY in `createExternalPosition`. So existing positions (ALPHA's two LPs) keep the old fee-free contract and keep working, while every NEW position uses V2. The type ids are unchanged, so fund policies (AllowedExternalPositionTypes) and the terminal labels need nothing.
- **Fork tests:** a real CL1 + CL2 non-B20 pool;
  - open → mint → stake → advance time → claim: the treasury gets 10% of the AERO and the vault gets 90%;
  - fee bounds;
  - an existing V1 position still works after the re-point (claim/collect/remove on a V1 position made before the re-point);
  - NAV of the V2 position equals V1's for the same liquidity.

### Task 3c: Perp accounts auto-link the DAO referral code (founder 2026-10-01: "yes build task 3c"; code `frostydao` owned by the DAO Safe)
**Files:** create `src/positions/VerantaPerpPositionV3.sol` (position + factory) and `test/fork/VerantaPerpPositionV3Fork.t.sol`. NEVER edit the deployed `VerantaPerpPositionV2.sol`.
- **Port verbatim:** a copy of `VerantaPerpPositionV2` with the same Action enum ordinals (the terminal sends them), valuation, `isRiskReducing` and the comptroller `LinkReferral` action.
- **One config, two generations:** `positionFactory` is the EXISTING `VerantaPerpPositionV2Factory` (0x6B15…D8a9), passed in by the V3 factory instead of `msg.sender`. Pair map, autopilot keeper and referral stay in one place, and every reader of `positionFactory()` keeps working unchanged: the terminal's VerantaPanel and `authorizeOwner` in funds-keeper.
- **Auto-link at creation, best-effort:** if the config's referral and code are both non-zero, the constructor calls `setTraderReferralCodeByUser(code)` inside try/catch and emits success or failure. A paused or private code never blocks opening a perp account.
- **Permissionless `linkReferral()`:** anyone (the keeper, the DAO) can (re)link a V3 position, but only to the config's current code. This fixes a failed or gas-griefed auto-link and follows a future DAO code change.
- **`VerantaPerpPositionV3Factory`:** stateless and ownerless. Its constructor takes the V2 factory (non-zero); `deployPosition` creates a V3 position bound to it.
- **Deploy (Task 4):** `FundFactory.registerPositionType(6, v3Factory)`. Existing V2 accounts (ALPHA 0x33C7…844d) keep working and link through the existing `LinkReferral` action, sent by the fund owner.
- **Founder ops (before Task 4):**
  1. The DAO Safe calls `registerCode("frostydao")`.
  2. The deployer calls `V2Factory.setReferral(0x1A11…De82D, "frostydao")`, before the timelock accepts ownership.

### Task 4: Deploy wiring + rehearsal + acceptance
**Files:** create `script/mainnet/DeployCompoundersMainnet.s.sol` (plus a shared library if useful) and `test/fork/CompoundersMainnetFork.t.sol`.
- **Runs AFTER DeployTwapListingV2** (it reads `deployments/base-mainnet-twap-v2.json`). As the genesis deployer, it:
  1. deploys a `CompounderPriceFeed(vi)` instance and a `CompounderAdapter` instance (existing code, new addresses);
  2. deploys `CompounderFactory` (treasury = DAO Safe, 10%);
  3. calls `FundFactory.registerAdapter(compounderAdapter)`;
  4. calls `module.setCompounderListing(factory, feed)` (the deployer owns the module pre-handoff);
  5. writes `deployments/base-mainnet-compounders.json`.
- `verify()` checks: adapter registered; module wired; factory defaults (1000 bps, DAO Safe); every NPM `factory()` correct.
- **Acceptance fork test,** run on top of the TWAP v2 wiring library:
  - a keeper creates + lists vaults for real non-B20 pools on each venue;
  - a fresh NON-degen fund deposits through the adapter, real swaps make fees, a keeper calls `compound()`, the treasury receives 10%, and the fund's NAV rises by the reinvested part;
  - a pool with a TWAP-priced token is refused at listing.
- **Anvil rehearsal**, as in the earlier plans, run after the TWAP v2 rehearsal on the same anvil.
- **Update** FundsGovernance verify (the module's compounder wiring and the factory owner in the handoff list) and the runbook.

## Follow-ups (not in this plan)
- **Keeper (Plan B), two additions:**
  - create + list a vault for every Aerodrome pool on the Yield board, plus Uniswap v3 pools; same pool source as the terminal's yield rows; skip B20-unpriced or TWAP-token pools;
  - call `compound()` on every vault on a schedule (FrostyFi workflow, daily or when pending fees > ~10× gas).
- **Terminal (Plan C):**
  - Yield page compounder rows for Aerodrome pools (generalize the compounder card from Uniswap-only);
  - discovery via `compoundersPage`;
  - INFRA `compounderAdapter` / `compounderFactory` on mainnet;
  - show "10% performance fee → FrostyDAO treasury".
- **Stock-pool vaults (B20):** a $5–10 live mainnet test with cast after deploy.
