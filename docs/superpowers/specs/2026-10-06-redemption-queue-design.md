# Redemption queue with a switched-off perp unwind — design

Date: 2026-10-06. Status: design approved section by section by the founder; awaiting review of this
written spec before the implementation plan.

## 1. Why

A fund's cash redemption (`ComptrollerV2.redeemShares`) is atomic and pays the redeemer's share of
everything, perps and LPs included, in USDC from the vault. When the fund's value sits in a Veranta
perp account or an LP, the vault is short of USDC and the redemption reverts. The only other exit,
`redeemSharesInKind`, pays the redeemer's slice of the vault's tokens and forfeits their share of every
external position to the remaining holders. It also breaks hedges: a 10% redeemer of a fund holding
100 ETH spot and short 100 ETH on Veranta takes 10 ETH, leaving the fund 90 ETH long against a 100 ETH
short.

Prior art (read 2026-10-06):
- **Melon v1** redeems in kind only. A redeemer's share counts assets in exchange orders but is paid
  only from the vault, so a shortfall reverts; `redeemWithConstraints` lets the redeemer give up the
  rest. Orders last at most a day, after which anyone can cancel them and sweep tokens back.
- **Enzyme v4** has `redeemSharesForSpecificAssets` (GAV share including external positions, paid from
  vault tokens, reverts when short, policies can gate it) and `redeemSharesInKind` (vault tokens only,
  external positions forfeited, never gated). It has no liquidity buffer. Liquidity comes from the
  manager unwinding positions, optionally through redemption queues the manager processes in windows,
  which its own audits note leave users stuck if the manager never acts.

Our code also contradicts two README hard rules: #2 says redemptions are async (only deposits are),
and #6 names a "specific-assets redemption" function that doesn't exist.

## 2. Decisions (founder, 2026-10-06)

- "Exits never gated" binds the protocol and third parties (oracles), not managers. A manager may
  delay an exit; the protocol must not.
- Contract changes are fine when they make things better; the protocol is private and unadvertised.
- A fund with no perps and no LPs redeems instantly, exactly as today.
- A fund with any external position (perps or LPs) redeems through a queue: the investor requests,
  the manager raises the cash, settlement pays.
- The investor chooses at request time: **cash** or **in kind**.
- A deadline. Past it, the manager's fees stop.
- An automated pro-rata perp unwind is **built and fork-tested now but switched off**. It is switched
  on only if managers don't respect requests, and then applies to every V3 fund, including those
  created before.
- LPs are never unwound by the protocol. An overdue redeemer's LP share is paid at full value from the
  vault's tokens; only what that can't cover is forfeited.
- Switching on: governance approves the unwinder contract; the guardian may switch an approved one on;
  only governance switches it off or approves a different one.
- Option 1 of three: one shared `RedemptionQueue` for all V3 funds (not one per fund, not logic moved
  into the comptroller).

## 3. Components

### 3.1 `RedemptionQueue` (new; one deployment shared by every V3 fund)

Each V3 comptroller stores the queue's address at construction, through its blueprint deployer, the
same way V2 receives the pool-pricing registrar. The queue holds no fund value except escrowed shares.

| Function | Caller | What it does |
|---|---|---|
| `requestRedeem(comptroller, shares, mode)` | investor | Escrows `shares` (transferred into the queue) and records the request. One open request per investor per fund. `mode` is `Cash` or `InKind`. Reverts if the fund holds no external position (redeem instantly instead). |
| `cancel(comptroller)` | investor | Returns the escrowed shares. Allowed until the request is unwound (§6). |
| `settle(comptroller, maxRequests)` | anyone | Settles fees, values the fund, and pays requests oldest first until one can't be paid in full (§5). Collects unwind proceeds first when a batch was unwound (§6). |
| `unwindOverdue(comptroller, priceUpdates)` | anyone | Only while an unwinder is switched on: closes the overdue redeemers' share of every perp trade (§6). |
| `approveUnwinder(unwinder, approved)` | owner | Approves or withdraws an unwinder contract. Withdrawing also switches it off. |
| `setUnwinderOn(unwinder, on)` | owner, or the factory's `guardian()` to switch on | Switching on needs prior approval. Only the owner switches off. |
| `isOverdue(comptroller)`, `requestOf(comptroller, investor)`, queue views | anyone | For the comptroller's fee stop, the keeper and the terminal. |

Owner: the deployer until the governance handoff, then the timelock (added to `FundsGovernance` and
its rehearsal). The guardian is read live from `FundFactory.guardian()`, so there is one guardian.

The queue values the fund itself from public reads: `getTrackedAssets()`, vault balances, the fund's
ValueInterpreter (`calcCanonicalAssetValue`), the registrar's `poolPricedAdapter` (long-tail split),
and `FundValuation.positionValue` (public) for each external position. It calls the comptroller's
public `settleFees()` first.

### 3.2 `ComptrollerV3` (ComptrollerV2 plus five small hooks)

1. `payOutRedemption(to, sharesToBurn, assets[], amounts[])`, queue only: burns the escrowed shares
   from the queue and pays each amount from the vault. It computes nothing.
2. `forwardUnwind(position, actionData)`, queue only: requires `position` to be one of this fund's
   active external positions and `IExternalPosition(position).isRiskReducing(actionData)`; then calls
   `receiveCallFromFund(actionData)`. Risk-reducing actions on perp accounts are close, cancel, remove
   delegate and return-to-vault, so nothing forwarded can open risk or move value anywhere but the
   vault.
3. Instant cash `redeemShares` reverts `UseRedemptionQueue()` while `getExternalPositions()` is
   non-empty. Pure-spot funds are unchanged. `redeemSharesInKind` stays available to everyone, always.
4. Fee stop: while `queue.isOverdue(this)`, fee settlement mints nothing. The management-fee clock
   still advances (that time is forfeited) and the performance fee doesn't crystallize (high-water
   mark unchanged).
5. `validateSharesTransfer`: a transfer to the queue skips the `PreTransferShares` policies (it is an
   exit, not a transfer to a third party); the shares-action timelock still applies.

**Size risk:** ComptrollerV2 is 23,973 bytes, 603 under the 24,576 limit. If the hooks don't fit,
existing logic moves into a helper contract (as `FundValuation` already is) rather than any hook being
dropped. A test asserts V3's runtime size stays under the limit.

### 3.3 `PerpUnwinder` (new; stateless, holds nothing)

- `supports(position)`: true when `position.positionFactory()` returns the shared Veranta perp config
  (`verantaFactory` in `deployments/base-mainnet.json`). Only Veranta perp accounts (V2, V3, and any
  later version that keeps the config) answer it; LPs and limit orders don't.
- `closeActions(position, fractionWad, prices)`: one `CloseTrade(pairIndex, index, amount, wantedPrice)`
  per open trade, enumerated on-chain the way the account's own valuation does (pair count, then
  `openTradesCount` and slot reads). `amount = collateral × fraction`, or the whole collateral when
  what would remain is under `PairStorage.pairMinLevPosUSDC(pair)` ($100 for NVDA on 2026-10-06).
  `wantedPrice` is the price just stored from the caller's signed update.
- `collectAction(position)`: `ReturnToVault(account's USDC balance)`.
- Requirement on any future perp account version: keep `CloseTrade` = 1 and `ReturnToVault` = 6, and
  keep both risk-reducing.

## 4. Who can do what

- **Investor:** request (cash or in kind), cancel, or the instant in-kind exit at any time.
- **Manager:** raises the cash (one-click pro-rata unwind in the terminal, §8) or doesn't. Cannot block
  cancel, settle, or (once switched on) the fallback.
- **Anyone (normally the keeper):** settle; once switched on, unwind overdue requests.
- **Guardian:** may switch on an approved unwinder.
- **Governance:** approves or withdraws unwinders, switches them off.
- **Nobody:** can make the queue or the unwinder open a trade, add margin, or move value anywhere
  except into the fund's vault and out to a redeemer as their computed share.

## 5. Request lifecycle and payout

- **Request.** Shares move into the queue. One open request per investor per fund; to change it,
  cancel and request again. Escrowed shares stay in `totalSupply` and bear fees like everyone's until
  burned.
- **Settle.** Anyone. The caller stores fresh perp prices first (Multicall3: `store.submit`, then
  `settle`), as the keeper already does before deposits. Fees are settled, the fund is valued, and
  requests are paid oldest first at that moment's NAV. If the next request can't be paid in full, the
  batch stops there; nobody behind it is paid first.
- **Payout** for a redeemer holding `f = shares / totalSupply` (both at settlement). All amounts round
  down. "Positions" means the fund's external positions at `FundValuation.positionValue`.

| Mode | Paid in USDC | Paid in kind | Needs vault USDC of |
|---|---|---|---|
| Cash | `f × (GAV − long-tail value)` | `f ×` each long-tail (pool-priced or unreadable) token's balance | `f × (GAV − long-tail value)` |
| In kind | `f × (vault USDC + positions)` | `f ×` each other tracked vault token's balance | `f × (vault USDC + positions)` |

In kind is built so a pro-rata unwind funds it exactly: the manager closes `f` of each perp trade and
removes `f` of each LP's liquidity, the proceeds land in the vault, and the remaining holders keep
`1 − f` of everything, hedges intact. Cash also needs the manager to sell `f` of the spot.

- **Cancel.** Any time until the request is unwound (§6).
- **Deadline: 4 days** from the request. A Friday-afternoon request in a three-day holiday weekend
  waits about 89 h for the next US stock open; an honest manager with stock perps must never be
  penalized for a closed market. Past the deadline the fund is overdue and fees stop (§3.2 hook 4)
  until every overdue request is settled.

## 6. The fallback unwind (built, switched off)

Applies only to requests past their deadline, and only while an approved unwinder is switched on.

1. **Unwind.** Anyone calls `unwindOverdue(comptroller, priceUpdates)`.
   - The overdue requests form one batch; `F = their shares / totalSupply`. They can no longer be
     cancelled.
   - The signed Lazer updates are stored (`store.submit`); each close uses the stored price as its
     `wantedPrice`.
   - For each of the fund's external positions the unwinder `supports`, the queue forwards
     `closeActions(position, F, prices)` through `comptroller.forwardUnwind`.
   - One unwind per batch. LPs, limit orders and pending opens are left alone.
2. **Collect and pay.** `settle` on an unwound batch waits until the fund's perp accounts have no
   pending orders, or 1 hour after the unwind. Then it forwards `collectAction` for each perp account
   (USDC back to the vault) and pays each overdue redeemer:
   - in kind: `f ×` each non-USDC vault token;
   - USDC: up to `f × (vault USDC + positions)`, from the vault's USDC;
   - any of their value still unpaid (perp closes that didn't fill, LPs, limit orders, pending opens)
     as extra vault tokens, pro-rata by value at VI prices;
   - only what the vault can't cover is forfeited, and the event records it.
   - A cash request settled this way is paid the same way (the protocol never swaps).

**Edge cases:**
- **Stock market closed:** that pair's close doesn't fill. The redeemer is covered from the vault's
  tokens; the remaining holders keep slightly more of that perp than pro-rata. Nothing waits on
  market hours.
- **Remainder under Veranta's minimum:** the whole trade closes. Payouts are value-based, so the extra
  USDC stays with the remaining holders.
- **Keepers:** the autopilot and Protect already skip while orders are pending. After settlement the
  spot and perps both shrank, so the autopilot sees a consistent hedge.

## 7. Keeper (funds-keeper, protect process)

- **Settle job**, beside the deposit executor: for each V3 fund with queued requests (from the
  subgraph), simulate `settle` with fresh stored prices; send only if it would succeed.
- **Fallback job**, only while an unwinder is switched on: for overdue requests, `unwindOverdue` with
  Veranta's signed updates for the fund's held pairs, then `settle` once fills land.
- **Health report:** a line alerting the founder 24 h before any request's deadline and when it passes.
- Env: `REDEMPTION_QUEUE` in `compose.production.yml`.

## 8. Terminal

- **Investor, pure-spot fund:** instant redeem, unchanged.
- **Investor, fund with perps or LPs:** "Request redemption" with a cash or in-kind choice and an
  estimated payout at today's NAV; a one-time share approval for the queue, then the request; place
  in line, deadline countdown, cancel. A fund with an overdue request shows "redemption overdue —
  manager fees stopped".
- **In-kind exit (V2 and V3 funds):** stays available behind a clear warning that it forfeits the
  investor's share of perps and LPs and can break the fund's hedge.
- **Manager, "Redemptions due" panel:** queued fraction, deadline, USDC needed. One click builds the
  pro-rata unwind: close `f` of each perp trade (the partial close shipped 2026-10-06), return the USDC
  to the vault, remove `f` of each LP's liquidity, signed as one transaction per action (the
  comptroller has no batching). Cash requests also show "sell $X of spot" with the spot ticket
  prefilled. The keeper settles once the vault can pay.

## 9. Subgraph and plumbing

- Subgraph: a data source for the queue's events (requested, cancelled, settled, unwound, unwinder
  approved and switched).
- ABIs from `funds-core/out/` to `funds-subgraph/abis/` and `frosty-terminal/src/abi/`.
- `deployments/base-mainnet-redemption.json` (queue, unwinder, V3 blueprint deployer), synced to the
  terminal by `indexer/mainnet-deployments.ts`; the queue address in the keeper's prod compose.
- README hard rules #2 and #6 rewritten to match the code.

## 10. Testing

- **Unit (Foundry):** the request lifecycle; oldest-first with stop-at-first-unpayable; cash and
  in-kind math at settlement NAV; escrowed shares bear fees; the 4-day deadline and the fee stop;
  cancel refused once unwound; only the queue can use hooks 1–2; `forwardUnwind` refuses anything not
  risk-reducing and any position not the fund's; instant cash refused with positions held and
  unchanged without; transfer to the queue skips share-transfer policies; the guardian rule.
- **Fuzz/invariant:** a redeemer is never paid more than their share; nobody is paid ahead of an older
  request; a settlement never lowers the remaining holders' share price except by the unwind's own
  close costs (about 2 bps of the closed notional, shared by all holders because NAV is struck after
  the unwind).
- **Fork (live Base, real Veranta fills as in `VerantaPerpPositionV3Fork`):** a manager pro-rata unwind
  plus an in-kind settle keeps a hedge's ratio; the full fallback with real fills; a pair whose close
  doesn't fill, covered from the vault; a whole-trade close under the pair minimum; an LP share
  covered at full value; `supports` true for a V3 account and false for an LP; ComptrollerV3 runtime
  size under 24,576 bytes.
- **Keeper, terminal, subgraph:** the settle job sends only what simulates OK; the fallback job runs
  only while switched on; payout previews and the manager panel's numbers; the subgraph builds.

## 11. Rollout

Each step is safe on its own.

1. funds-core: deploy the queue, the perp unwinder (approved, **switched off**) and the V3 blueprint
   deployer with the deployer keystore, rehearsed on a fork first.
2. Keeper (settle job), subgraph (queue data source), terminal: merge and deploy.
3. `FundFactory.setComptrollerDeployer(V3 deployer)`: new funds are V3 from then on. Existing funds
   stay V2 unless their manager migrates (`executeReconfiguration` requires no external positions).
4. Add the queue's ownership to the governance handoff script and its fork rehearsal.

Switching the unwinder on later is one transaction (guardian or governance).

## 12. Known effects and limits

- **Close costs are shared.** NAV is struck after the unwind, so about 2 bps of the closed notional is
  borne by all holders, not only the redeemer.
- **Closed markets tilt the remaining holders** slightly toward the perp that didn't close (fallback
  only).
- **LPs are never unwound by the protocol.** An overdue redeemer's LP share comes from the vault's
  tokens; the remaining holders' mix tilts toward LPs.
- **One shared queue.** A bug in it affects every V3 fund bound to it. New funds can be pointed at a
  fixed queue through a new blueprint deployer; funds already bound to the old one can only move by
  migrating.
- **The manager's unwind is several transactions** (one per position action).
- **Existing V2 funds** (FTF and the rest) keep today's behavior; they get the terminal warning only.
- **Guardian power:** switching on an approved unwinder affects only overdue requests and only
  through risk-reducing actions; it could over-close if the approved contract were wrong, which is
  why approval stays with governance.

## 13. Out of scope

- Instant LP delivery (new LP position versions with a pro-rata remove-and-send action).
- Any protocol swap on a DEX.
- The next perp account version's own items (close costs in NAV, manager add-margin, refusing to
  remove a held pair, TWAP close), tracked separately.
- Pausing deposits while a fund is overdue.

## 14. Revisions after the final review (2026-10-07)

The whole-branch review found two critical and four important issues; the code now differs from
the sections above as follows.

- **Nothing is forfeited** (replaces §2's and §6's "only what the vault can't cover is forfeited").
  After an unwind, settlement pays the largest part of each overdue request the vault can cover at
  full value and burns only those shares. The rest stays queued as an ordinary request: cancellable,
  still overdue (fees stay stopped), and unwindable again. Confirmed by the founder 2026-10-07.
- **A stale price reverts the whole unwind** instead of being caught: nothing is marked, and the
  requests stay cancellable. The caller stores fresh prices for every held pair in the same
  transaction; a stock pair whose market is closed waits for the open.
- **`unwindOverdue(comptroller, maxRequests)`** takes a batch size in place of price updates (prices
  are stored through Multicall3, plan deviation 2).
- **Open requests are a linked list** per fund, so request/cancel spam can't push the oldest
  request's cancel or settlement past a block. `nextOpen(comptroller, id)` walks it off-chain.
- **A payout that reverts bounces the request** (closed, shares returned, `RedemptionBounced`) and
  the queue moves on. A failure is acted on only when the call had its full gas allowance (payout 3M,
  close or collect 2M, unwinder views 1M), so a caller can't starve a call to bounce a request or
  skip a close.
- **Oracles never freeze the queue.** Settlement and cancel try to settle fees and go on without
  them; a token whose price can't be read is paid in kind. A cancel while overdue settles fees
  first, so the overdue period stays fee-free.
- **A pending batch is derived** from the oldest open request being unwound, never stored.
- **A cancel's fee settlement can't be starved** (2026-10-07): it runs with a 15M gas allowance
  (`FEE_GAS`) and a failure counts only when all of it was available. Otherwise a wallet's gas
  estimate (the least gas that succeeds) skipped it and handed the manager the overdue period.
- **One valuation per settlement** (2026-10-07). `ComptrollerV3.settleFeesForRedemption()`
  (queue-only) settles fees the way `redeemShares` does and returns the payout snapshot from the
  same pass (`FundValuation.valueDetailed`). Settling twice cost ~1.7 valuations, so 5 perp accounts
  (175 Veranta pairs, ~2.2M gas each) went over the 16.78M transaction cap. Settle now costs one
  valuation + ~70k and fits up to 7, the same limit as the fund's own valuation (8 accounts:
  17.7M).
