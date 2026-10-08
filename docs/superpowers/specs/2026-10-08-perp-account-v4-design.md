# Perp account V4 (VerantaPerpPositionV4): design

Status: design approved section by section by the founder 2026-10-08 ("write the spec and then build it").
Built 2026-10-08 on `feat/perp-account-v4` (funds-core, frosty-terminal), not deployed. Fork results (after the founder's
morning fixes: taker-rate close fee, once-per-pair cost reads, ReturnEth): a real 5× ETH close pays 199.278151 against a V4 NAV
of 198.923900 (0.354 below: that close got the maker rate, and the referral discount; V3 read 0.1946 above); `getManagedAssets`
at 174 pairs costs 1,828,377 gas as a full walk vs 339,694 in list mode with one held pair (cooled); a queue settle with ten V4
accounts takes 859,647 gas. Plan rulings are in the plan's ledger and the founder's morning summary.
Scope: the "Perp accounts (VerantaPerpPositionV3): known gaps" list in `MAINNET_RUNBOOK_FUNDS.md` (founder
2026-10-05: "document it and we will fix it later in the next perp account version"), minus TWAP close
(founder 2026-10-08: "leave TWAP close out for now").

## 1. Goal

A new perp account version for NEW perp accounts that fixes four known gaps of V3:

1. **Valuation reads only the pairs the account holds** (V3 walks all ~175 Veranta pairs: about 2.24M gas per
   account per valuation, which caps a fund at about 5 perp accounts at 175 pairs).
2. **NAV deducts what a close costs** (V3 reads 1.95 bps of notional above a real close payout).
3. **The manager can add margin** (in V3 only the autopilot keeper can, through its delegation).
4. **A held pair whose asset mapping is removed reverts valuation** instead of dropping its coin leg.

Existing V3 (and V2) accounts are deployed and immutable; they keep their behavior. Out of scope: TWAP
close, withdrawing margin, partial take-profit at a price (already works through the keeper delegation;
Veranta only accepts those orders signed by the trader or its delegate, and a contract can't sign).

## 2. Constraints

- Same shared config as V3: the deployed `VerantaPerpPositionV2Factory` (pair map, autopilot keeper,
  referral). `positionFactory()` returns it, so every reader that recognizes a perp account by it keeps
  working (`PerpUnwinder.canUnwind`, keeper, terminal).
- Action ordinals 0–7 unchanged; `CloseTrade = 1` and `ReturnToVault = 6` stay risk-reducing
  (`PerpUnwinder` builds exactly those). New actions take new ordinals.
- `isRiskReducing` keeps V3's set (close, cancel limit, cancel pending, remove autopilot, return to vault).
- Hard rule 4 (no silent residue): every Veranta state of the account is in GAV or valuation reverts.
- Shipping = deploy a stateless, ownerless V4 type factory + re-point position type 6 to it (the deployer
  still owns the FundFactory). Funds' type-6 policies need no change.

## 3. Valuation

### 3.1 Held-pairs list and the two modes

- Storage: an OpenZeppelin `EnumerableSet.UintSet` of pair indexes ("held pairs").
- **Added** when the manager opens a trade or places a limit order through `OpenTrade` (before the router
  call, so a pending market order's pair is listed before Veranta's operator fills it).
- **List mode** (`activeDelegate == 0`): valuation walks the listed pairs only.
- **Full-walk mode** (`activeDelegate != 0`): valuation walks every pair `0 … pairsCount−1`, exactly as V3.
  While a keeper delegation is on, the keeper can open trades through Veranta's `delegatedAction` without
  the account seeing them (autopilot hedges, Protect), so only a full walk is complete (founder option A,
  2026-10-08).
- **RemoveAutopilot** removes the Veranta delegation, clears `activeDelegate`, then runs one full walk that
  adds every pair holding a trade, a limit order or a pending market order (`SyncedHeldPairs` event). After
  that, list mode is complete again.
- **SetAutopilot** first removes a different previous delegate on Veranta (V3 left it delegated on keeper
  rotation), so at most one keeper can ever act; list mode is only entered through RemoveAutopilot's sync.
- **Pruning:** at the end of every manager action, pairs with no trade, no limit order and no pending
  market order are removed from the list (cost bounded by the list length).
- **Final review 2026-10-08:** "pending market order" is read from TradingStorage's per-pair counters
  (`pendingMarketOpenCount` / `pendingMarketCloseCount`), which also cover coin-sized opens
  (`openTradeWithCoinExposure`, which the keeper can place); `Multicall.getPendingOrder` returns those zeroed,
  so their escrow is read from `reqIdPendingMarketOrderWithCoinExposure`, and an order neither mapping
  attributes to the account reverts `PendingOrderUnreadable`.
- Pending market orders: counted at escrowed collateral from `getPendingOrder` (per-trader list, all pairs),
  as V3.

Research (2026-10-08, PairStorage impl `0x2511…cad0` verified source): Veranta's "position roll"
(`startPositionRoll` / `stopPositionRoll`, roll keepers) swaps a pair's Lazer feed id and blocks new opens
on that pair while it runs; it never moves a trade to another pair index. So nothing but the account
itself or its delegate can put a trade on a pair the account hasn't listed.

### 3.2 A held pair without a mapping (item 4)

If a pair the account holds anything on (trade, limit order) maps to `address(0)` in the config,
valuation reverts `PairUnmapped(pairIndex)` instead of keeping the USDC leg and dropping the coin leg.
Deposits, cash redemptions and fee settlement stop until the owner restores the mapping (one transaction);
closes, cancels and return-to-vault still work because they skip pricing, and the in-kind exit doesn't
value positions.

### 3.3 Close costs in NAV (item 2)

Each open trade's USDC leg is reduced by an estimated close cost:

`closeCost = leveragedSize × (closeFeeP + spreadP) / (100 × 1e10)`, where

- `leveragedSize = collateral × leverage / 1e10` (USDC, 1e6), Veranta's own position size;
- `closeFeeP = max(closeMakerFeeP, closeTakerFeeP)` from `pairStorage.additionalPairParams2(pairIndex)`
  (1e10 = 1%; ETH and BTC 1e8 / 4.5e8, pair 129 0 / 0, read 2026-10-08). Founder 2026-10-08 ("fix the fee
  choice issue"): Veranta's own `pairCloseFeeP` returns maker, taker or a blend from live open-interest skew
  (PairStorageExtension `_makerOrTakerFee`), which a large trader can move, so V4 takes the higher rate:
  NAV never reads above what a close pays whatever the skew, at the cost of reading up to
  (taker − maker) low (3.5 bps of notional on ETH/BTC). The rates are plain PairStorage storage, so no
  swappable extension sits in the valuation path;
- `spreadP` = the pair's base spread from `pairStorage.pairs(pairIndex)` (ETH 1e8 = 0.01%, BTC 0, pair 129
  5e8, read 2026-10-08).

Both rates are read once per held pair and shared by its trades (gas, 2026-10-08).

Check against the measured V3 gap (`test_fork_navIsAboveTheRealClosePayoutByTheCloseCosts`, 5× ETH long
of ≈ $998 notional, gap 0.194573 USDC): that close paid the maker rate, 0.01% × 998 × 0.95 (the referral's
5% discount) ≈ 0.0948, plus the 0.01% spread the operator applied ≈ 0.0998: 0.1946. V4 deducts the taker
rate, so on that close NAV reads 0.354 below the payout (fork test). The referral discount is not applied in
valuation (keeps NAV a little conservative).

Not deducted, with the reason:
- **Max-gain cap:** Veranta caps every trade's take-profit at the pair's max gain (`tp 0` = the cap) and
  closes it there itself; NAV can only read above the cap for the seconds before that close.
- **Profit share:** only Veranta's zero-fee "PnL" trades pay it. V4 refuses that order type (below).
- **Close gas fee:** `getGasFees(…, isClose = true)` reports 2 USDC, but a market close doesn't pay it (the
  V3 fork close above paid exactly fee + spread); it applies to the PnL path, which V4 refuses.
- **The operator's dynamic spread above the base** (size/skew impact): not readable on chain. The fork
  test states the residual gap after the deduction.

Effect: NAV drops by the estimated close cost the moment a trade opens (about 1–2 bps of notional on top
of the open fee). The slippage policy sees it as part of the open's measured loss.

### 3.4 Refused order type

`OpenTrade` refuses `orderType > 2` (`UnsupportedOrderType`): 0 market, 1 stop-limit, 2 limit are allowed;
3 (`MARKET_PNL`, Veranta's zero-fee "Upside" trades that pay a profit share instead of fees) is refused.
The terminal never offered it and Veranta doesn't allow it on ETH (`isPnlOrderTypeAllowed(0) = false`).

## 4. Add margin (item 3)

- New action `AddMargin = 8`, args `(pairIndex, tradeIndex, amount, bytes[] priceUpdateData, uint8
  priceSourcing, uint256 fee)`. The manager's call moves the USDC from the vault in the same transaction
  (`assetsToTransfer`), as an open does; the account calls
  `router.updateMargin{value: fee}(pairIndex, tradeIndex, DEPOSIT, amount, priceUpdateData, priceSourcing)`.
- Veranta only changes margin against a signed price under 30 s old and not ahead of the chain's clock
  (fork test 2026-10-05). The terminal fetches it from Veranta's feed (the keeper top-up's source) and
  passes it through; the margin lands in the same transaction.
- Fee: Veranta's Lazer verification fee in ETH (1 wei today), paid from the account's own ETH. V4 has a
  `receive()`; the terminal sends a few wei the first time. The account's ETH is not in NAV (a fee float);
  `AddMargin` reverts `FeeBalanceTooLow(fee, balance)` when it can't pay. `ReturnEth = 9` (2026-10-08)
  sends all of it to the fund owner, who paid it in; not risk-reducing.
- Not risk-reducing: priced like an open (during a price outage the manager can close or reduce, not add
  margin from the vault).

## 5. Interface

`VerantaPerpPositionV4` keeps V3's public surface (`comptroller`, `positionFactory`, `usdc`, `router`,
`verantaMulticall`, `tradingStorage`, `pairStorage`, `activeDelegate`, `linkReferral`, `isRiskReducing`,
`receiveCallFromFund`, `getManagedAssets`, `getDebtAssets`, V3's events and errors) and adds:

- `function heldPairs() external view returns (uint256[] memory)` — the list (the terminal reads only these
  in list mode, and uses the call to tell V4 apart);
- `receive() external payable`;
- `enum Action { …V3…, AddMargin, ReturnEth }`;
- events `MarginAdded(uint256 indexed pairIndex, uint256 index, uint256 amount)`,
  `EthReturned(address indexed to, uint256 amount)`,
  `HeldPairAdded(uint256 indexed pairIndex)`, `HeldPairRemoved(uint256 indexed pairIndex)`,
  `SyncedHeldPairs(uint256 count)`;
- errors `PairUnmapped(uint256 pairIndex)`, `UnsupportedOrderType(uint8 orderType)`,
  `FeeBalanceTooLow(uint256 fee, uint256 balance)`.

`VerantaPerpPositionV4Factory(config)`: stateless, ownerless, `deployPosition(comptroller, '')`.

New external interfaces: `IVerantaPairCosts` (pairStorage): `additionalPairParams2(uint256)` returning the
four open/close maker/taker rates, and `pairs(uint256)` returning the leading static fields up to `spreadP`;
`IVerantaPendingOrders` (tradingStorage): `pendingMarketOpenCount`, `pendingMarketCloseCount`,
`reqIdPendingMarketOrderWithCoinExposure`.

## 6. Testing

Unit (MockVeranta, extended with per-pair close fee and spread):
- the list: added on open (market and limit), kept while an order is pending, pruned when empty;
- list mode values only listed pairs; full-walk mode values a keeper-opened trade on an unlisted pair;
  RemoveAutopilot syncs it into the list and list mode still values it;
- SetAutopilot with a new keeper removes the old delegate;
- unmapped held pair reverts `PairUnmapped`; unmapped pair with nothing held doesn't;
- close cost deducted per trade (fee + spread, both sides);
- `orderType 3` refused; AddMargin moves USDC into the trade and pays the fee from the account's ETH;
  `FeeBalanceTooLow` without ETH; AddMargin not risk-reducing; V3's actions and valuation cases ported.

Fork (live Veranta):
- at the V3 suite's pinned block 52014634 with its real ETH Lazer packet: NAV after the deduction vs a
  real close payout (residual stated); AddMargin with the real packet and 1 wei fee; list-mode gas vs a
  full walk; a keeper-delegated open counted in full-walk mode and after RemoveAutopilot's sync;
- at PerpUnwinderFork's block 52230324 with its pair-129 packet: the redemption fallback unwinds a V4
  account (canUnwind, close, return to vault, settle);
- rollout rehearsal at the latest block: the deploy script's factory, type 6 re-pointed, a new account in
  a fresh fund is V4 in list mode and `PerpUnwinder.canUnwind` is true; an existing V3 account is unchanged.

## 7. Rollout

1. Founder merges funds-core `feat/perp-account-v4`, then runs
   `script/mainnet/DeployPerpAccountV4.s.sol` (one transaction, writes `deployments/base-mainnet-perp-v4.json`).
2. Founder re-points type 6: `factory.registerPositionType(6, <v4Factory>)` from the deployer.
3. Terminal: V4 ABI, "add margin" on trade rows of V4 accounts (signed price + fee + first-time ETH),
   list-mode accounts read only `heldPairs()` in the perp book. Keeper and subgraph: no change.
4. Runbook: new section; the known-gaps list says which gaps V4 closes.
