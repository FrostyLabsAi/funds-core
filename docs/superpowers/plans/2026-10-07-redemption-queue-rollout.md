# Redemption Queue Rollout Implementation Plan (subgraph, keeper, terminal, health)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Everything outside funds-core that the RedemptionQueue needs to work for real people: the subgraph indexes queued redemptions, the keeper settles them (and runs the fallback unwind once switched on), investors request / follow / cancel in the terminal, managers get a "Redemptions due" panel with a one-click pro-rata unwind, and the founder's health report warns 24 h before a deadline.

**Architecture:** Four repos, one feature branch each. The subgraph adds a `RedemptionQueue` data source (Base mainnet only) and `RedemptionRequest` / `RedemptionPayout` entities; the keeper's `protect` process gains a redemption pass beside the deposit executor (simulate `settle`, store perp prices only when the simulation says they are stale, send only what succeeds); the terminal detects fund v3, swaps the instant cash redeem for a queue request when the fund holds positions, and gives the manager per-step unwind buttons; the FrostyFlow health workflows read open requests from the subgraph and alert through the existing Telegram path.

**Tech Stack:** graph-cli 0.95 / graph-ts 0.35 / matchstick 0.6 (AssemblyScript); TypeScript + viem 2.56 + vitest 2.1 (keeper); Next.js 16 App Router + wagmi/viem + Tailwind 4 + vitest (terminal); FrostyFlow builder (pnpm, Biome) plus a DevTools console patch for prod.

**Spec:** `funds-core/docs/superpowers/specs/2026-10-06-redemption-queue-design.md` — §7 keeper, §8 terminal, §9 subgraph and plumbing, §11 rollout, §14 revisions (`unwindOverdue(comptroller, maxRequests)`, `RedemptionBounced`, `nextOpen`, `settleFeesForRedemption`, no `RedemptionForfeited`, nothing is ever forfeited).

## Global Constraints

- Branches: in funds-subgraph, funds-keeper and frosty-terminal run `git fetch origin && git switch -c feat/redemption-queue --no-track origin/main`. In frostyflow (`/home/dude/FrostyLabs/frostyflow`) branch `feat/health-redemptions --no-track` from the founder's committed `feat/health-perp-on-demand` (it has an uncommitted builder diff today — Task 6 waits for that commit).
- Founder rule: **never `git add`, `git commit` or `git push`.** Every task ends with the diff left in the working tree for the founder's review; "commit" steps in this plan mean exactly that.
- No untracked artifacts left in a repo (`generated/`, `build/`, `out/` are gitignored; anything else you create must be part of the change).
- Code style per repo: tabs + single quotes in the keeper, the terminal and the subgraph; Biome style (2 spaces, double quotes) in frostyflow. Comments carry the why with dates and rulings, as the surrounding code does.
- Contract facts (RedemptionQueue, funds-core `feat/redemption-queue`):
  - `requestRedeem(address comptroller, uint256 shares, uint8 mode)` — `mode` 0 = Cash, 1 = InKind; one open request per investor per fund; request ids count per fund.
  - `cancel(address comptroller)`; `settle(address comptroller, uint256 maxRequests) returns (uint256 settled)` (reverts `NothingSettled()` when nothing could be paid, `UnwindPending()` while an unwind's fills are pending); `unwindOverdue(address comptroller, uint256 maxRequests)`.
  - Views: `isOverdue(address)`, `deadline()` (= `DEADLINE` = 345600 s, 4 days; overdue is strictly `block.timestamp > requestedAt + deadline`), `requestOf(address comptroller, address investor) returns (bool exists, uint256 id, (address investor, uint64 requestedAt, uint8 mode, bool open, bool unwound, uint256 shares) request)`, `requestAt`, `queueBounds`, `nextOpen`, `unwinders()`, `isUnwinderOn(address)`.
  - Events: `RedemptionRequested(indexed address comptroller, indexed address investor, indexed uint256 id, uint256 shares, uint8 mode)`, `RedemptionCancelled(indexed address, indexed address, indexed uint256)`, `RedemptionSettled(indexed address comptroller, indexed address investor, indexed uint256 id, uint256 shares, address[] assets, uint256[] amounts)` (shares may be a PART of the request: it then stays open with the rest), `RedemptionBounced(indexed address, indexed address, indexed uint256, bytes reason)`, `RedemptionsUnwound(indexed address comptroller, uint256 requests, uint256 fractionWad)`, `UnwindCloseFailed`, `UnwindReleased`, `UnwinderApproved(indexed address, bool)`, `UnwinderSwitched(indexed address, bool)`, `FactorySet(indexed address)`.
  - Errors the UI meets: `RequestExists()`, `NoRequest()`, `ZeroShares()`, `Unwound()`, `NoExternalPositions(address)`, `NotOurFund(address)`; ComptrollerV3 adds `UseRedemptionQueue()` (instant `redeemShares` while the fund holds a position).
  - ComptrollerV3 = ComptrollerV2's ABI plus `redemptionQueue() returns (address)`, `settleFeesForRedemption()`, `payOutRedemption`, `forwardUnwind`, events `RedemptionPaidOut`, `UnwindForwarded` (verified: every V2 event and function signature is unchanged).
  - PerpUnwinder closes only at a Veranta price stored in its `store()` within the last 120 s (`PRICE_MAX_AGE`), for EVERY pair with an open trade — Chainlink-priced pairs (ETH, BTC) included. `VerantaPriceStore.submit` accepts any pair Veranta maps to a Lazer feed.
- Addresses come from `funds-core/deployments/base-mainnet-redemption.json` (`queue`, `perpUnwinder`, `fundV3Deployer`, `startBlock`), written only by the founder's real broadcast. Until it exists: the subgraph's Base manifest drops the queue data source, the keeper job is off (`REDEMPTION_QUEUE` unset), the terminal's `INFRA.redemptionQueue` is ZERO and every queue surface stays hidden. No queue exists on Base Sepolia or the Veranta testnet.
- Base per-transaction gas cap: 16,777,216. Settle costs one fund valuation + ~70k (≈2.24M gas per perp account at 175 Veranta pairs).
- Next.js 16 differs from training data: read `frosty-terminal/node_modules/next/dist/docs/` before writing Next-specific code (frosty-terminal/AGENTS.md). Terminal tests import with relative paths (`../src/lib/...`), there is no `@/` alias in vitest.

## Review Focus

1. **A partial payment** (fallback: `RedemptionSettled` with fewer shares than are open) must leave the request OPEN with the rest everywhere — subgraph `sharesOpen`, keeper (keeps settling), terminal (place in line and the manager's queued fraction use what is still open). Pinned by Task 1's partial-payment test and Task 4's `placeInLine` test.
2. **The queue's escrow is not an investor**: shares moving into the queue must not give the queue an `Investment` or bump `investorCount`, and the investor's own row must not vanish from views that matter. Pinned by Task 1's escrow test.
3. **Fund v3 without positions keeps instant redeem; fund v1/v2 keep their buttons**: the terminal must pick the redeem path by version AND positions held (a v3 fund answers `registrar()` too, so the old v1/v2 probe alone would call a reverting `redeemShares`). Pinned by Task 3's `fundVersionFrom` test and Task 4's `redeemPath` test.
4. **Unwinding a fund that holds a Chainlink-priced perp (ETH, BTC)**: the keeper's fallback must store a Veranta price for every pair the fund's perp accounts hold, not only store-priced ones, or `PerpUnwinder` reverts `NoPrice` and nothing ever unwinds. Pinned by Task 2's `pairsToStore` test.
5. **Schema rollout order**: a client that queries `redemptionRequests` against a subgraph version without it gets a GraphQL error for the whole query. The terminal queries it in its own query, only when the queue is deployed; the health patch is applied only after the new subgraph version is published. Pinned by Task 3's `useRedemptionRequests` (own query, enabled only when `INFRA.redemptionQueue` is set — checked by hand in Task 4 Step 6 on base-sepolia) and Task 7's runbook order.

---

### Task 1: funds-subgraph — the queue's data source

**Files:**
- Create: `funds-subgraph/abis/RedemptionQueue.json`
- Modify: `funds-subgraph/schema.graphql` (Fund derived field + 5 entities)
- Modify: `funds-subgraph/subgraph.yaml` (RedemptionQueue data source; `Queue` in the Shares template's entities)
- Create: `funds-subgraph/src/redemptionQueue.ts`
- Modify: `funds-subgraph/src/shares.ts`
- Modify: `funds-subgraph/scripts/manifest-base-mainnet.sh`, `funds-subgraph/scripts/manifest-veranta-testnet.sh`
- Test: `funds-subgraph/tests/redemption-queue.test.ts`

**Interfaces:**
- Produces (GraphQL, consumed by Tasks 2, 3, 4, 6): `RedemptionRequest { id ("<comptroller>-<requestId>"), fund, account, requestId, mode ("CASH" | "IN_KIND"), sharesRequested, sharesOpen, status ("OPEN" | "SETTLED" | "CANCELLED" | "BOUNCED"), requestedAt, closedAt, payouts }`, `RedemptionPayout { id, request, fund, account, shares, assets, amounts, timestamp }`, `RedemptionUnwind { id, fund, requests, fractionWad, timestamp }`, `Queue { id, factory }`, `Unwinder { id, approved, on }`; `Fund.redemptionRequests`.

- [ ] **Step 1: Branch and copy the ABI**

```bash
cd /home/dude/FrostyFunds/funds-subgraph
git fetch origin && git switch -c feat/redemption-queue --no-track origin/main
python3 -c "import json; json.dump(json.load(open('../funds-core/out/RedemptionQueue.sol/RedemptionQueue.json'))['abi'], open('abis/RedemptionQueue.json','w'), indent=1)"
```
Expected: `abis/RedemptionQueue.json` is a bare ABI array (same shape as `abis/Shares.json`).

- [ ] **Step 2: Schema**

Add to `type Fund` (after `policies`):
```graphql
	redemptionRequests: [RedemptionRequest!]! @derivedFrom(field: "fund")
```
Append:
```graphql
"""A queued redemption (RedemptionQueue, fund v3, founder 2026-10-06). One open request per investor per fund."""
type RedemptionRequest @entity {
	id: ID! # comptroller-requestId (request ids count per fund)
	fund: Fund!
	account: Account!
	requestId: BigInt!
	mode: String! # CASH | IN_KIND
	sharesRequested: BigInt!
	sharesOpen: BigInt! # still queued: the fallback may pay part and leave the rest open
	status: String! # OPEN | SETTLED | CANCELLED | BOUNCED
	requestedAt: BigInt!
	closedAt: BigInt
	payouts: [RedemptionPayout!]! @derivedFrom(field: "request")
}

"""One payment of a queued request: the assets (the fund's tracked list) and the amount of each."""
type RedemptionPayout @entity(immutable: true) {
	id: ID! # txhash-logindex
	request: RedemptionRequest!
	fund: Fund!
	account: Account!
	shares: BigInt!
	assets: [Bytes!]!
	amounts: [BigInt!]!
	timestamp: BigInt!
}

"""The fallback closed a batch of overdue requests' share of the fund's perps."""
type RedemptionUnwind @entity(immutable: true) {
	id: ID! # txhash-logindex
	fund: Fund!
	requests: BigInt!
	fractionWad: BigInt!
	timestamp: BigInt!
}

"""The RedemptionQueue contract: its escrowed shares are never an investment."""
type Queue @entity {
	id: ID! # queue address
	factory: Bytes
}

type Unwinder @entity {
	id: ID! # unwinder address
	approved: Boolean!
	on: Boolean!
}
```

- [ ] **Step 3: Manifest data source** — in `subgraph.yaml`, insert before the `ValueInterpreter` data source:

```yaml
  # RedemptionQueue (fund v3, 2026-10-06): Base mainnet only. scripts/manifest-base-mainnet.sh fills
  # in the address and start block from funds-core deployments/base-mainnet-redemption.json; Base
  # Sepolia has no queue (the zero address never emits).
  - kind: ethereum
    name: RedemptionQueue
    network: base-sepolia
    source:
      address: '0x0000000000000000000000000000000000000000'
      abi: RedemptionQueue
      startBlock: 47182140
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities: [Queue, RedemptionRequest, RedemptionPayout, RedemptionUnwind, Unwinder]
      abis:
        - name: RedemptionQueue
          file: ./abis/RedemptionQueue.json
      eventHandlers:
        - event: FactorySet(indexed address)
          handler: handleFactorySet
        - event: RedemptionRequested(indexed address,indexed address,indexed uint256,uint256,uint8)
          handler: handleRedemptionRequested
        - event: RedemptionCancelled(indexed address,indexed address,indexed uint256)
          handler: handleRedemptionCancelled
        - event: RedemptionSettled(indexed address,indexed address,indexed uint256,uint256,address[],uint256[])
          handler: handleRedemptionSettled
        - event: RedemptionBounced(indexed address,indexed address,indexed uint256,bytes)
          handler: handleRedemptionBounced
        - event: RedemptionsUnwound(indexed address,uint256,uint256)
          handler: handleRedemptionsUnwound
        - event: UnwinderApproved(indexed address,bool)
          handler: handleUnwinderApproved
        - event: UnwinderSwitched(indexed address,bool)
          handler: handleUnwinderSwitched
      file: ./src/redemptionQueue.ts
```
In the `Shares` template's `entities:` list add `Queue`.

Run: `npm run codegen`
Expected: `generated/RedemptionQueue/RedemptionQueue.ts` and the new classes in `generated/schema.ts`.

- [ ] **Step 4: Write the failing tests** — `tests/redemption-queue.test.ts`:

```ts
import { Address, BigInt, Bytes, ethereum } from '@graphprotocol/graph-ts';
import { afterEach, assert, clearStore, describe, newMockEvent, test } from 'matchstick-as/assembly/index';
import {
	FactorySet, RedemptionBounced, RedemptionCancelled, RedemptionRequested, RedemptionSettled, RedemptionsUnwound,
	UnwinderApproved, UnwinderSwitched,
} from '../generated/RedemptionQueue/RedemptionQueue';
import { Transfer } from '../generated/templates/Shares/Shares';
import { Fund, SharesToken } from '../generated/schema';
import {
	handleFactorySet, handleRedemptionBounced, handleRedemptionCancelled, handleRedemptionRequested,
	handleRedemptionSettled, handleRedemptionsUnwound, handleUnwinderApproved, handleUnwinderSwitched,
} from '../src/redemptionQueue';
import { handleTransfer } from '../src/shares';

const QUEUE = Address.fromString('0x00000000000000000000000000000000000a0e0e');
const FUND = Address.fromString('0x833a506d761a4756af279abc24183db407823de9');
const SHARES = Address.fromString('0x00000000000000000000000000000000005ea4e5');
const FACTORY = Address.fromString('0x42f213d7e8cd8fdbe1a6b6e2f5a2b4bc4cf929a3');
const ALICE = Address.fromString('0x00000000000000000000000000000000000a11ce');
const USDC = Address.fromString('0x833589fcd6edb6e08f4c7c32d4f71b54bda02913');
const UNWINDER = Address.fromString('0x00000000000000000000000000000000000001d0');
const KEY = FUND.toHexString() + '-0';

function param(name: string, value: ethereum.Value): ethereum.EventParam {
	return new ethereum.EventParam(name, value);
}

function queueEvent(params: ethereum.EventParam[]): ethereum.Event {
	let event = newMockEvent();
	event.address = QUEUE;
	event.parameters = params;
	return event;
}

function idOf(event: ethereum.Event): string {
	return event.transaction.hash.toHexString() + '-' + event.logIndex.toString();
}

function big(n: i64): ethereum.Value {
	return ethereum.Value.fromUnsignedBigInt(BigInt.fromI64(n));
}

/** A fund the factory indexed, with every required field. */
function storeFund(): void {
	let token = new SharesToken(SHARES.toHexString());
	token.fund = FUND.toHexString();
	token.save();
	let fund = new Fund(FUND.toHexString());
	fund.name = 'Queue Fund';
	fund.symbol = 'QF';
	fund.fundOwner = ALICE;
	fund.vault = ALICE;
	fund.sharesToken = SHARES.toHexString();
	fund.createdAt = BigInt.fromI32(1);
	fund.active = true;
	fund.shutDown = false;
	fund.ownerDepositsPaused = false;
	fund.guardianDepositsPaused = false;
	fund.totalSupply = BigInt.fromI32(1000);
	fund.investorCount = 1;
	fund.trackedAssets = [];
	fund.save();
}

function requested(shares: i64, mode: i32): RedemptionRequested {
	return changetype<RedemptionRequested>(queueEvent([
		param('comptroller', ethereum.Value.fromAddress(FUND)),
		param('investor', ethereum.Value.fromAddress(ALICE)),
		param('id', big(0)),
		param('shares', big(shares)),
		param('mode', ethereum.Value.fromI32(mode)),
	]));
}

function settled(shares: i64, usdc: i64): RedemptionSettled {
	return changetype<RedemptionSettled>(queueEvent([
		param('comptroller', ethereum.Value.fromAddress(FUND)),
		param('investor', ethereum.Value.fromAddress(ALICE)),
		param('id', big(0)),
		param('shares', big(shares)),
		param('assets', ethereum.Value.fromAddressArray([USDC])),
		param('amounts', ethereum.Value.fromUnsignedBigIntArray([BigInt.fromI64(usdc)])),
	]));
}

afterEach(() => {
	clearStore();
});

describe('queued redemptions', () => {
	test('a request opens with its shares, mode and time', () => {
		storeFund();
		let event = requested(400, 1);
		handleRedemptionRequested(event);
		assert.fieldEquals('RedemptionRequest', KEY, 'status', 'OPEN');
		assert.fieldEquals('RedemptionRequest', KEY, 'mode', 'IN_KIND');
		assert.fieldEquals('RedemptionRequest', KEY, 'sharesOpen', '400');
		assert.fieldEquals('RedemptionRequest', KEY, 'requestedAt', event.block.timestamp.toString());
	});

	test('a partial payment shrinks what is open; the last payment settles it', () => {
		storeFund();
		handleRedemptionRequested(requested(400, 0));
		let part = settled(150, 150);
		handleRedemptionSettled(part);
		assert.fieldEquals('RedemptionRequest', KEY, 'status', 'OPEN');
		assert.fieldEquals('RedemptionRequest', KEY, 'sharesOpen', '250');
		assert.fieldEquals('RedemptionPayout', idOf(part), 'shares', '150');
		assert.fieldEquals('RedemptionPayout', idOf(part), 'amounts', '[150]');
		let rest = settled(250, 250);
		rest.logIndex = BigInt.fromI32(7);
		handleRedemptionSettled(rest);
		assert.fieldEquals('RedemptionRequest', KEY, 'status', 'SETTLED');
		assert.fieldEquals('RedemptionRequest', KEY, 'sharesOpen', '0');
	});

	test('cancel and bounce close the request', () => {
		storeFund();
		handleRedemptionRequested(requested(400, 0));
		handleRedemptionCancelled(changetype<RedemptionCancelled>(queueEvent([
			param('comptroller', ethereum.Value.fromAddress(FUND)),
			param('investor', ethereum.Value.fromAddress(ALICE)),
			param('id', big(0)),
		])));
		assert.fieldEquals('RedemptionRequest', KEY, 'status', 'CANCELLED');
		assert.fieldEquals('RedemptionRequest', KEY, 'sharesOpen', '0');
		clearStore();
		storeFund();
		handleRedemptionRequested(requested(400, 0));
		handleRedemptionBounced(changetype<RedemptionBounced>(queueEvent([
			param('comptroller', ethereum.Value.fromAddress(FUND)),
			param('investor', ethereum.Value.fromAddress(ALICE)),
			param('id', big(0)),
			param('reason', ethereum.Value.fromBytes(Bytes.fromHexString('0x08c379a0'))),
		])));
		assert.fieldEquals('RedemptionRequest', KEY, 'status', 'BOUNCED');
	});

	test('an unwind batch is recorded', () => {
		storeFund();
		let event = changetype<RedemptionsUnwound>(queueEvent([
			param('comptroller', ethereum.Value.fromAddress(FUND)),
			param('requests', big(2)),
			param('fractionWad', big(250000000000000000)),
		]));
		handleRedemptionsUnwound(event);
		assert.fieldEquals('RedemptionUnwind', idOf(event), 'requests', '2');
	});

	test('unwinders: approved, switched on, switched off', () => {
		handleUnwinderApproved(changetype<UnwinderApproved>(queueEvent([
			param('unwinder', ethereum.Value.fromAddress(UNWINDER)), param('approved', ethereum.Value.fromBoolean(true)),
		])));
		assert.fieldEquals('Unwinder', UNWINDER.toHexString(), 'on', 'false');
		handleUnwinderSwitched(changetype<UnwinderSwitched>(queueEvent([
			param('unwinder', ethereum.Value.fromAddress(UNWINDER)), param('on', ethereum.Value.fromBoolean(true)),
		])));
		assert.fieldEquals('Unwinder', UNWINDER.toHexString(), 'on', 'true');
	});

	test('shares escrowed in the queue never make it an investor', () => {
		storeFund();
		handleFactorySet(changetype<FactorySet>(queueEvent([param('factory', ethereum.Value.fromAddress(FACTORY))])));
		let transfer = changetype<Transfer>(newMockEvent());
		transfer.address = SHARES;
		transfer.parameters = [
			param('from', ethereum.Value.fromAddress(ALICE)),
			param('to', ethereum.Value.fromAddress(QUEUE)),
			param('value', big(400)),
		];
		handleTransfer(transfer);
		assert.notInStore('Investment', FUND.toHexString() + '-' + QUEUE.toHexString());
		assert.fieldEquals('Fund', FUND.toHexString(), 'investorCount', '1');
	});
});
```
(The escrow test only asserts the queue side: alice has no indexed investment in this store, so her debit is not the subject.)

- [ ] **Step 5: Run to verify they fail**

Run: `npm test`
Expected: compile failure — `../src/redemptionQueue` does not exist.

- [ ] **Step 6: Mappings** — `src/redemptionQueue.ts`:

```ts
import { BigInt, Bytes } from '@graphprotocol/graph-ts';
import {
	FactorySet, RedemptionBounced, RedemptionCancelled, RedemptionRequested, RedemptionSettled, RedemptionsUnwound,
	UnwinderApproved, UnwinderSwitched,
} from '../generated/RedemptionQueue/RedemptionQueue';
import { Account, Fund, Queue, RedemptionPayout, RedemptionRequest, RedemptionUnwind, Unwinder } from '../generated/schema';

/** RedemptionQueue (fund v3, founder 2026-10-06): request ids count per fund, so the key joins both. */
function requestKey(comptroller: Bytes, id: BigInt): string {
	return comptroller.toHexString() + '-' + id.toString();
}

function eventKey(hash: Bytes, logIndex: BigInt): string {
	return hash.toHexString() + '-' + logIndex.toString();
}

/** Marks the queue's address so share transfers into its escrow are never counted as an investment. */
function ensureQueue(address: Bytes): Queue {
	let queue = Queue.load(address.toHexString());
	if (queue == null) {
		queue = new Queue(address.toHexString());
		queue.save();
	}
	return queue;
}

function close(request: RedemptionRequest, status: string, timestamp: BigInt): void {
	request.status = status;
	request.sharesOpen = BigInt.zero();
	request.closedAt = timestamp;
	request.save();
}

export function handleFactorySet(event: FactorySet): void {
	let queue = ensureQueue(event.address);
	queue.factory = event.params.factory;
	queue.save();
}

export function handleRedemptionRequested(event: RedemptionRequested): void {
	ensureQueue(event.address);
	let fundId = event.params.comptroller.toHexString();
	if (Fund.load(fundId) == null) return;
	let accountId = event.params.investor.toHexString();
	if (Account.load(accountId) == null) new Account(accountId).save();
	let request = new RedemptionRequest(requestKey(event.params.comptroller, event.params.id));
	request.fund = fundId;
	request.account = accountId;
	request.requestId = event.params.id;
	request.mode = event.params.mode == 0 ? 'CASH' : 'IN_KIND';
	request.sharesRequested = event.params.shares;
	request.sharesOpen = event.params.shares;
	request.status = 'OPEN';
	request.requestedAt = event.block.timestamp;
	request.save();
}

export function handleRedemptionCancelled(event: RedemptionCancelled): void {
	let request = RedemptionRequest.load(requestKey(event.params.comptroller, event.params.id));
	if (request == null) return;
	close(request, 'CANCELLED', event.block.timestamp);
}

/** A payment: all of what is open, or (the fallback) the part the vault could cover; the rest stays open. */
export function handleRedemptionSettled(event: RedemptionSettled): void {
	let request = RedemptionRequest.load(requestKey(event.params.comptroller, event.params.id));
	if (request == null) return;
	let payout = new RedemptionPayout(eventKey(event.transaction.hash, event.logIndex));
	payout.request = request.id;
	payout.fund = request.fund;
	payout.account = request.account;
	payout.shares = event.params.shares;
	payout.assets = changetype<Bytes[]>(event.params.assets);
	payout.amounts = event.params.amounts;
	payout.timestamp = event.block.timestamp;
	payout.save();
	let open = request.sharesOpen.minus(event.params.shares);
	if (open.le(BigInt.zero())) {
		close(request, 'SETTLED', event.block.timestamp);
		return;
	}
	request.sharesOpen = open;
	request.save();
}

/** The payout reverted (a token refused the investor): the escrow went back and the request closed. */
export function handleRedemptionBounced(event: RedemptionBounced): void {
	let request = RedemptionRequest.load(requestKey(event.params.comptroller, event.params.id));
	if (request == null) return;
	close(request, 'BOUNCED', event.block.timestamp);
}

export function handleRedemptionsUnwound(event: RedemptionsUnwound): void {
	let fundId = event.params.comptroller.toHexString();
	if (Fund.load(fundId) == null) return;
	let unwind = new RedemptionUnwind(eventKey(event.transaction.hash, event.logIndex));
	unwind.fund = fundId;
	unwind.requests = event.params.requests;
	unwind.fractionWad = event.params.fractionWad;
	unwind.timestamp = event.block.timestamp;
	unwind.save();
}

function loadUnwinder(address: Bytes): Unwinder {
	let unwinder = Unwinder.load(address.toHexString());
	if (unwinder == null) {
		unwinder = new Unwinder(address.toHexString());
		unwinder.approved = false;
		unwinder.on = false;
	}
	return unwinder;
}

export function handleUnwinderApproved(event: UnwinderApproved): void {
	let unwinder = loadUnwinder(event.params.unwinder);
	unwinder.approved = event.params.approved;
	unwinder.save();
}

export function handleUnwinderSwitched(event: UnwinderSwitched): void {
	let unwinder = loadUnwinder(event.params.unwinder);
	unwinder.on = event.params.on;
	unwinder.save();
}
```

`src/shares.ts` — import `Queue` and skip the queue in `handleTransfer`:
```ts
import { Fund, SharesToken, Account, Investment, Queue } from '../generated/schema';

/** The RedemptionQueue escrows requested shares: an exit in progress, not an investor (2026-10-07). */
function isQueue(holder: Address): boolean {
	return Queue.load(holder.toHexString()) != null;
}
```
and in `handleTransfer` change the two `adjustInvestment` calls to run only when `!isQueue(event.params.from)` / `!isQueue(event.params.to)` (the mint/burn branches stay as they are).

- [ ] **Step 7: Run the tests**

Run: `npm run codegen && npm test`
Expected: the 6 new tests and the 6 existing ones pass.

- [ ] **Step 8: Manifests** — `scripts/manifest-base-mainnet.sh`:
  - After `BROADCAST_FILE=…` add `REDEMPTION_FILE=${REDEMPTION_FILE:-../funds-core/deployments/base-mainnet-redemption.json}` and document it in the header comment ("queue + its start block; absent = the queue isn't deployed yet and its data source is dropped").
  - Read it when present: `read -r QUEUE QUEUE_START < <(python3 -c "import json; d=json.load(open('$REDEMPTION_FILE')); print(d['queue'].lower(), d['startBlock'])")`, else `QUEUE=''; QUEUE_START=''`; add `$QUEUE` (when set) to the code-check loop.
  - Pass both to the python step (`python3 - "$FACTORY" "$VI" "$START_BLOCK" "$QUEUE" "$QUEUE_START"`), and in python replace the FundFactoryV2 drop with a `drop(s, name)` helper used for FundFactoryV2 and, when `queue` is empty, for RedemptionQueue:
```python
def drop(s, name):
	at = s.index(f'    name: {name}\n')
	begin = s.rindex('  - kind: ethereum\n', 0, at)
	while True:  # comment lines directly above the block
		prev = s.rfind('\n', 0, begin - 1) + 1
		if s[prev:begin].lstrip().startswith('#'):
			begin = prev
		else:
			break
	end = s.index('  - kind: ethereum\n', at)
	return s[:begin] + s[end:]
```
  - After the global `startBlock` substitution, when `queue` is set, rewrite only the queue block:
```python
if queue:
	at = s.index('    name: RedemptionQueue\n')
	end = s.index('  - kind: ethereum\n', at)
	block = s[at:end].replace("address: '0x0000000000000000000000000000000000000000'", f"address: '{queue}'", 1)
	block = re.sub(r'startBlock: \d+', f'startBlock: {queue_start}', block, count=1)
	s = s[:at] + block + s[end:]
```
  - Extend the stale-value grep with `0x0000000000000000000000000000000000000000` and print the queue in the final echo.
- `scripts/manifest-veranta-testnet.sh`: in its python step, drop the RedemptionQueue block with the same `drop` helper (no queue on the Veranta testnet), and add the zero address to its stale grep.

- [ ] **Step 9: Verify every manifest builds**

Run:
```bash
npm run codegen && npm run build
CHECK_CODE=0 START_BLOCK=51969168 ./scripts/manifest-base-mainnet.sh && grep -c RedemptionQueue subgraph.base.yaml
npx graph codegen subgraph.base.yaml && npx graph build subgraph.base.yaml
./scripts/manifest-veranta-testnet.sh && ! grep -q RedemptionQueue subgraph.veranta-testnet.yaml && echo dropped
npm run codegen   # leave generated/ matching subgraph.yaml again
```
Expected: before the founder's deploy the base manifest has no queue (`grep -c` prints 0) and builds; with a test file (`REDEMPTION_FILE=/tmp/claude-1000/…/redemption.json` holding `{"queue":"0x…","startBlock":52300000}`) it carries the queue at that block; the Veranta manifest prints `dropped`. `subgraph.base.yaml` and `subgraph.veranta-testnet.yaml` are committed outputs: leave them regenerated only from the real deployments file (re-run the base script without `REDEMPTION_FILE` at the end).

- [ ] **Step 10: Leave the diff for the founder** — `git status` shows only the files listed above (plus the two regenerated manifests if they changed).

---

### Task 2: funds-keeper — settle and the fallback unwind

**Files:**
- Create: `funds-keeper/src/protect/redemption-settler.ts`
- Modify: `funds-keeper/src/protect/index.ts` (wiring, after the deposit executor)
- Modify: `funds-keeper/compose.production.yml` (protect service env), `funds-keeper/.env.example`
- Test: `funds-keeper/test/redemption-settler.test.ts`

**Interfaces:**
- Consumes: subgraph `redemptionRequests(where: { status: "OPEN" }) { fund { id } requestedAt }` (Task 1); `pushHeldPrices`, `pushStorePrices`, `VerantaFeed` (`src/veranta/price-store.ts`); `heldAggregators`, `verifiedFunds` (`src/pricing/held.ts`); `discoverFleet` (`src/veranta/fleet.ts`); `orderPairs` (`src/veranta/held-orders.ts`); `multicallAbi` (`src/veranta/contracts.ts`).
- Produces: `redemptionPass(deps: RedemptionDeps, tried: Map<string, number>): Promise<void>`; pure `fundsWithOpenRequests`, `overdue`, `due`, `retryWithPrices`, `pairsToStore`.

- [ ] **Step 1: Branch** — `cd /home/dude/FrostyFunds/funds-keeper && git fetch origin && git switch -c feat/redemption-queue --no-track origin/main`

- [ ] **Step 2: Write the failing tests** — `test/redemption-settler.test.ts`:

```ts
import { describe, expect, it, vi } from 'vitest';
import { encodeErrorResult, encodeFunctionResult, type PublicClient } from 'viem';
import {
	due, fundsWithOpenRequests, overdue, pairsToStore, redemptionPass, redemptionQueueAbi, retryWithPrices,
	type RedemptionDeps,
} from '../src/protect/redemption-settler';
import type { KeeperWallet } from '../src/signer/index';

const QUEUE = '0x5a5dEf86b5EBb469E190344E2f7A9664E02c0a8E' as const;
const FUND_A = '0x00000000000000000000000000000000000000aa' as const;
const FUND_B = '0x00000000000000000000000000000000000000bb' as const;
const DEADLINE = 345_600;

describe('fundsWithOpenRequests — each fund with an open request, and its oldest', () => {
	it('groups by fund and keeps the oldest requestedAt', () => {
		const funds = fundsWithOpenRequests([
			{ fund: { id: FUND_A }, requestedAt: '200' },
			{ fund: { id: FUND_B }, requestedAt: '150' },
			{ fund: { id: FUND_A }, requestedAt: '100' },
		]);
		expect([...funds.entries()]).toEqual([[FUND_A, 100], [FUND_B, 150]]);
	});
});

describe('overdue — as RedemptionQueue.isOverdue reads it, strictly past the deadline', () => {
	it('is not overdue at exactly 4 days, overdue one second later', () => {
		expect(overdue(1_000, DEADLINE, 1_000 + DEADLINE)).toBe(false);
		expect(overdue(1_000, DEADLINE, 1_000 + DEADLINE + 1)).toBe(true);
	});
});

describe('due — a fund is tried at most once per interval', () => {
	it('tries a fund never tried, then waits the interval', () => {
		expect(due(undefined, 1_000, 300)).toBe(true);
		expect(due(1_000, 1_299, 300)).toBe(false);
		expect(due(1_000, 1_300, 300)).toBe(true);
	});
});

describe('retryWithPrices — store prices only when that can change the answer', () => {
	it('never for "nothing payable" or "fills pending"; yes for a stale price', () => {
		expect(retryWithPrices('NothingSettled')).toBe(false);
		expect(retryWithPrices('UnwindPending')).toBe(false);
		expect(retryWithPrices('NotOurFund')).toBe(false);
		expect(retryWithPrices('StalePush')).toBe(true);
		expect(retryWithPrices('NeverPushed')).toBe(true);
	});
});

describe('pairsToStore — the fallback needs a stored price for EVERY held pair (Chainlink-priced ones too)', () => {
	it('lists each pair once across the fund perp accounts, ETH (pair 0) included', () => {
		const books = [
			{ book: [[{ trade: { pairIndex: 0n } }, { trade: { pairIndex: 129n } }], []] as const, pending: [] as const },
			{ book: [[{ trade: { pairIndex: 129n } }], []] as const, pending: [{ orderInfo: { trade: { pairIndex: 1n } } }] as const },
		];
		expect(pairsToStore(books).sort((a, b) => Number(a - b))).toEqual([0n, 1n, 129n]);
	});
});

describe('redemptionPass — simulate first, store prices only on a stale-price revert, send only what succeeds', () => {
	function harness(settleOutcomes: ('ok' | 'NothingSettled' | 'StalePush')[], opts: { dryRun?: boolean } = {}) {
		const sent: unknown[] = [];
		const stored: string[] = [];
		let call = 0;
		const client = {
			getBlock: async () => ({ timestamp: 2_000_000n }),
			readContract: async ({ functionName }: { functionName: string }) => {
				if (functionName === 'deadline') return BigInt(DEADLINE);
				if (functionName === 'unwinders') return [];
				throw new Error(`unexpected read ${functionName}`);
			},
			simulateContract: async (req: { functionName: string; args: unknown[] }) => {
				const outcome = settleOutcomes[call++] ?? 'NothingSettled';
				if (outcome !== 'ok') {
					const data = encodeErrorResult({ abi: [...redemptionQueueAbi, { type: 'error', name: 'StalePush', inputs: [] }], errorName: outcome });
					const { ContractFunctionRevertedError, ContractFunctionExecutionError } = await import('viem');
					throw new ContractFunctionExecutionError(
						new ContractFunctionRevertedError({ abi: [...redemptionQueueAbi, { type: 'error', name: 'StalePush', inputs: [] }], data, functionName: req.functionName }),
						{ abi: redemptionQueueAbi, functionName: req.functionName, args: req.args, contractAddress: QUEUE },
					);
				}
				return { result: 1n, request: { address: QUEUE, abi: redemptionQueueAbi, functionName: req.functionName, args: req.args } };
			},
			waitForTransactionReceipt: async () => ({ status: 'success' }),
		} as unknown as PublicClient;
		const wallet = { account: { address: '0x000000000000000000000000000000000000beef' }, writeContract: async (r: unknown) => { sent.push(r); return '0xhash'; } } as unknown as KeeperWallet;
		const fetchFn = vi.fn(async () => ({ ok: true, status: 200, json: async () => ({ data: { redemptionRequests: [{ fund: { id: FUND_A }, requestedAt: '1999000' }] } }) }));
		const deps: RedemptionDeps = {
			client, wallet, queue: QUEUE, subgraphUrl: 'http://subgraph', dryRun: opts.dryRun ?? false, log: () => {},
			everySec: 300, fetchFn, verified: async (funds) => funds,
			storeSettlePrices: async (fund) => { stored.push(fund); },
			storeUnwindPrices: async () => {},
		};
		return { deps, sent, stored };
	}

	it('settles when the simulation passes, without storing prices', async () => {
		const { deps, sent, stored } = harness(['ok']);
		await redemptionPass(deps, new Map());
		expect(stored).toEqual([]);
		expect(sent).toHaveLength(1);
	});

	it('sends nothing and stores nothing while the vault can\'t pay', async () => {
		const { deps, sent, stored } = harness(['NothingSettled']);
		await redemptionPass(deps, new Map());
		expect(stored).toEqual([]);
		expect(sent).toHaveLength(0);
	});

	it('stores the fund\'s prices after a stale-price revert, then settles', async () => {
		const { deps, sent, stored } = harness(['StalePush', 'ok']);
		await redemptionPass(deps, new Map());
		expect(stored).toEqual([FUND_A]);
		expect(sent).toHaveLength(1);
	});

	it('DRY_RUN simulates and sends nothing', async () => {
		const { deps, sent } = harness(['ok'], { dryRun: true });
		await redemptionPass(deps, new Map());
		expect(sent).toHaveLength(0);
	});

	it('tries a fund once per interval', async () => {
		const { deps, sent } = harness(['ok', 'ok']);
		const tried = new Map<string, number>();
		await redemptionPass(deps, tried);
		await redemptionPass(deps, tried);
		expect(sent).toHaveLength(1);
	});
});
```
If constructing viem's error classes this way doesn't type-check, keep the harness but build the thrown error with `new BaseError('reverted', { cause: Object.assign(new ContractFunctionRevertedError({ abi, data, functionName }), {}) })` — the code under test only needs `err.walk()` to find a `ContractFunctionRevertedError` whose `data.errorName` is set. Ledger the change as a ruling.

- [ ] **Step 3: Run to verify they fail**

Run: `npx vitest run test/redemption-settler.test.ts`
Expected: FAIL — cannot find module `../src/protect/redemption-settler`.

- [ ] **Step 4: Implement** — `src/protect/redemption-settler.ts`:

```ts
/**
 * RedemptionQueue settler (fund v3, founder 2026-10-06; spec 2026-10-06 §7). Every pass, for each
 * fund with an open queued redemption: simulate `settle` at the prices already stored; only when
 * that reverts on a price (not on "nothing payable yet" or "fills pending") store the fund's perp
 * prices and simulate again; send only a simulation that passes. While governance or the guardian
 * has switched an unwinder on, an overdue fund is unwound first: every pair its perp accounts hold
 * gets a fresh Veranta price in the unwinder's store (Chainlink-priced pairs too — PerpUnwinder reads
 * the store for every pair), then `unwindOverdue`.
 *
 * Convenience, never a point of failure: `settle` and `unwindOverdue` stay anyone-callable. A fund
 * is tried at most once per `everySec`. DRY_RUN simulates and sends nothing.
 */
import { BaseError, ContractFunctionRevertedError, parseAbi, type PublicClient } from 'viem';
import type { FetchLike } from '../fetch.js';
import type { KeeperWallet } from '../signer/index.js';
import { orderPairs } from '../veranta/held-orders.js';

export const redemptionQueueAbi = parseAbi([
	'function settle(address comptroller, uint256 maxRequests) returns (uint256 settled)',
	'function unwindOverdue(address comptroller, uint256 maxRequests)',
	'function deadline() view returns (uint256)',
	'function unwinders() view returns (address[])',
	'function isUnwinderOn(address unwinder) view returns (bool)',
	'error NothingSettled()',
	'error UnwindPending()',
	'error NotOverdue()',
	'error UnwinderOff()',
	'error NotOurFund(address comptroller)',
	'error CallStarved()',
]);

/** Requests per settle: ~100k gas each on top of one fund valuation (~2.24M per perp account). */
export const SETTLE_MAX_REQUESTS = 20n;
/** Overdue requests per unwind batch (the queue caps the batch; ~10k gas each to mark). */
export const UNWIND_MAX_REQUESTS = 50n;
/** settle values the fund: its perp prices at most this old (the deposit executor's freshness). */
export const FRESH_BEFORE_SETTLE_SEC = 120;
/** PerpUnwinder refuses a stored price older than 120 s at the unwind's block. */
export const FRESH_BEFORE_UNWIND_SEC = 60;

/** Reverts that a fresh price can't change: nothing to store for them. */
const NOT_A_PRICE = new Set(['NothingSettled', 'UnwindPending', 'NotOverdue', 'UnwinderOff', 'NotOurFund', 'CallStarved']);

export interface OpenRequestRow { fund: { id: string }; requestedAt: string }

export interface RedemptionDeps {
	client: PublicClient;
	wallet: KeeperWallet;
	queue: `0x${string}`;
	subgraphUrl: string;
	dryRun: boolean;
	log: (msg: string) => void;
	everySec: number;
	fetchFn?: FetchLike;
	/** M-4: only funds our factories created get prices pushed for them. */
	verified: (funds: `0x${string}`[]) => Promise<`0x${string}`[]>;
	/** Stores the fund's held perp prices (the deposit executor's push), at most `FRESH_BEFORE_SETTLE_SEC` old. */
	storeSettlePrices?: (fund: `0x${string}`) => Promise<void>;
	/** Stores a price for every pair the fund's perp accounts hold, into the switched-on unwinder's store. */
	storeUnwindPrices?: (fund: `0x${string}`) => Promise<void>;
}

const OPEN_QUERY = `{
	redemptionRequests(where: { status: "OPEN" }, first: 1000, orderBy: requestedAt) {
		fund { id }
		requestedAt
	}
}`;

/** Pure: each fund with an open request → its oldest request's time (what isOverdue reads). */
export function fundsWithOpenRequests(rows: OpenRequestRow[]): Map<`0x${string}`, number> {
	const out = new Map<`0x${string}`, number>();
	for (const row of rows) {
		const fund = row.fund.id.toLowerCase() as `0x${string}`;
		const at = Number(row.requestedAt);
		const seen = out.get(fund);
		if (seen === undefined || at < seen) out.set(fund, at);
	}
	return out;
}

/** Pure: strictly past the deadline, as RedemptionQueue.isOverdue (block time, never wall clock). */
export function overdue(oldestRequestedAt: number, deadlineSec: number, chainNowSec: number): boolean {
	return chainNowSec > oldestRequestedAt + deadlineSec;
}

/** Pure: a fund is tried at most once per `everySec`. */
export function due(lastTriedAt: number | undefined, nowSec: number, everySec: number): boolean {
	return lastTriedAt === undefined || nowSec - lastTriedAt >= everySec;
}

/** Pure: whether a revert is one a freshly stored price could turn into a pass. */
export function retryWithPrices(errorName: string): boolean {
	return !NOT_A_PRICE.has(errorName);
}

/** Pure: every pair the fund's perp accounts hold — trades, resting limits, pending opens — once. */
export function pairsToStore(
	accounts: { book: Parameters<typeof orderPairs>[0]; pending: Parameters<typeof orderPairs>[1] }[],
): bigint[] {
	return [...new Set(accounts.flatMap((a) => orderPairs(a.book, a.pending)))];
}

function revertName(err: unknown): string {
	if (err instanceof BaseError) {
		const reverted = err.walk((e) => e instanceof ContractFunctionRevertedError);
		if (reverted instanceof ContractFunctionRevertedError) return reverted.data?.errorName ?? reverted.signature ?? 'reverted';
	}
	return (err as Error).message.slice(0, 120);
}

type Simulated = { ok: true; result: unknown; request: Parameters<KeeperWallet['writeContract']>[0] } | { ok: false; error: string };

async function simulate(deps: RedemptionDeps, functionName: 'settle' | 'unwindOverdue', fund: `0x${string}`, max: bigint): Promise<Simulated> {
	try {
		const { result, request } = await deps.client.simulateContract({
			account: deps.wallet.account, address: deps.queue, abi: redemptionQueueAbi, functionName, args: [fund, max],
		});
		return { ok: true, result, request: request as Parameters<KeeperWallet['writeContract']>[0] };
	} catch (err) {
		return { ok: false, error: revertName(err) };
	}
}

async function send(deps: RedemptionDeps, what: string, fund: `0x${string}`, sim: Extract<Simulated, { ok: true }>): Promise<void> {
	if (deps.dryRun) return deps.log(`redemption-settler DRY RUN — would ${what} ${fund}`);
	const hash = await deps.wallet.writeContract(sim.request);
	const receipt = await deps.client.waitForTransactionReceipt({ hash });
	deps.log(`redemption-settler ${what.toUpperCase()} ${fund}${what === 'settle' ? ` (${String(sim.result)} request(s))` : ''} → tx ${hash} (${receipt.status})`);
}

async function trySettle(deps: RedemptionDeps, fund: `0x${string}`): Promise<void> {
	let sim = await simulate(deps, 'settle', fund, SETTLE_MAX_REQUESTS);
	if (!sim.ok && retryWithPrices(sim.error) && deps.storeSettlePrices) {
		await deps.storeSettlePrices(fund);
		sim = await simulate(deps, 'settle', fund, SETTLE_MAX_REQUESTS);
	}
	if (!sim.ok) return deps.log(`redemption-settler · ${fund} waits: ${sim.error}`);
	await send(deps, 'settle', fund, sim);
}

async function tryUnwind(deps: RedemptionDeps, fund: `0x${string}`): Promise<void> {
	if (deps.storeUnwindPrices) await deps.storeUnwindPrices(fund);
	const sim = await simulate(deps, 'unwindOverdue', fund, UNWIND_MAX_REQUESTS);
	if (!sim.ok) return deps.log(`redemption-settler · ${fund} not unwound: ${sim.error}`);
	await send(deps, 'unwind', fund, sim);
}

async function openRequests(deps: RedemptionDeps): Promise<OpenRequestRow[]> {
	const res = await (deps.fetchFn ?? fetch)(deps.subgraphUrl, {
		method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ query: OPEN_QUERY }),
		signal: AbortSignal.timeout(10_000),
	});
	if (!res.ok) throw new Error(`subgraph ${res.status}`);
	const body = (await res.json()) as { data?: { redemptionRequests?: OpenRequestRow[] }; errors?: unknown };
	if (body.errors) throw new Error(`subgraph: ${JSON.stringify(body.errors).slice(0, 200)}`);
	return body.data?.redemptionRequests ?? [];
}

/** One unwinder switched on, or none (the fallback is off). */
export async function switchedOnUnwinder(client: PublicClient, queue: `0x${string}`): Promise<`0x${string}` | null> {
	const list = await client.readContract({ address: queue, abi: redemptionQueueAbi, functionName: 'unwinders' });
	for (const unwinder of list) {
		if (await client.readContract({ address: queue, abi: redemptionQueueAbi, functionName: 'isUnwinderOn', args: [unwinder] })) return unwinder;
	}
	return null;
}

export async function redemptionPass(deps: RedemptionDeps, tried: Map<string, number>): Promise<void> {
	const open = fundsWithOpenRequests(await openRequests(deps));
	if (!open.size) return;
	const funds = new Set(await deps.verified([...open.keys()]));
	const now = Number((await deps.client.getBlock()).timestamp);
	const deadline = Number(await deps.client.readContract({ address: deps.queue, abi: redemptionQueueAbi, functionName: 'deadline' }));
	const unwinder = await switchedOnUnwinder(deps.client, deps.queue);
	for (const [fund, oldest] of open) {
		if (!funds.has(fund) || !due(tried.get(fund), now, deps.everySec)) continue;
		tried.set(fund, now);
		try {
			if (unwinder && overdue(oldest, deadline, now)) await tryUnwind(deps, fund);
			await trySettle(deps, fund);
		} catch (err) {
			deps.log(`redemption-settler SKIP ${fund}: ${(err as Error).message.slice(0, 200)}`);
		}
	}
}
```
The test harness's `readContract` answers `unwinders` with `[]` so `switchedOnUnwinder` returns null.

- [ ] **Step 5: Run the tests**

Run: `npx vitest run test/redemption-settler.test.ts && npm run typecheck`
Expected: 10 tests pass; typecheck clean.

- [ ] **Step 6: Wire into protect** — `src/protect/index.ts`, after the `depositExecutorOn` block of declarations:

```ts
// Redemption queue (fund v3, founder 2026-10-06; spec §7): settle every fund whose queued
// redemptions the vault can pay — prices stored only when the simulation says they are stale — and,
// once governance or the guardian switches an unwinder on, unwind overdue ones first. Off without
// REDEMPTION_QUEUE (no queue on the testnets).
const redemptionQueue = process.env.REDEMPTION_QUEUE as `0x${string}` | undefined;
const redemptionOn = Boolean(subgraphUrl && redemptionQueue) && fundFactories.length > 0 && process.env.REDEMPTION_SETTLER !== '0';
const redemptionEverySec = Number(process.env.REDEMPTION_SETTLE_EVERY_SECONDS ?? 300);
const redemptionTried = new Map<string, number>();
console.log(`redemption settler · ${redemptionOn ? `ON (queue ${redemptionQueue}, each fund every ${redemptionEverySec}s)` : 'off (needs SUBGRAPH_URL + REDEMPTION_QUEUE + FUND_FACTORIES; REDEMPTION_SETTLER=0 disables)'}`);
```
(`fundFactories` is declared a few lines lower today — move this block below it.) At the end of `fullPass()`:

```ts
	if (redemptionOn) {
		const log = (msg: string) => console.log(`[${new Date().toISOString()}] ${msg}`);
		try {
			await redemptionPass({
				client, wallet, queue: redemptionQueue as `0x${string}`, subgraphUrl: subgraphUrl as string,
				dryRun: config.dryRun, log, everySec: redemptionEverySec,
				verified: (funds) => verifiedFunds(client, funds, fundFactories),
				storeSettlePrices: verantaPusherOn
					? async (fund) => pushHeldPrices(await heldAggregators(client, [fund]), client, wallet, verantaStores, {
						feedUrl: verantaFeedUrl, minAgeSec: FRESH_BEFORE_SETTLE_SEC, dryRun: config.dryRun, log,
					})
					: undefined,
				storeUnwindPrices: (fund) => storeEveryHeldPair(fund, log),
			}, redemptionTried);
		} catch (err) {
			console.error(`redemption pass failed: ${(err as Error).message}`);
		}
	}
```
and, beside it, the unwind price helper (reads the switched-on unwinder's `store()`, the fund's perp accounts from the subgraph fleet, each account's book via its `verantaMulticall()`):

```ts
const unwinderStoreAbi = parseAbi(['function store() view returns (address)']);
const perpAccountAbi = parseAbi(['function verantaMulticall() view returns (address)']);
/** Every pair the fund's perp accounts hold, freshly stored where PerpUnwinder reads it. */
async function storeEveryHeldPair(fund: `0x${string}`, log: (msg: string) => void): Promise<void> {
	const unwinder = await switchedOnUnwinder(client, redemptionQueue as `0x${string}`);
	if (!unwinder) return;
	const store = await client.readContract({ address: unwinder, abi: unwinderStoreAbi, functionName: 'store' });
	const accounts = (await discoverFleet(subgraphUrl as string)).filter((p) => p.comptroller.toLowerCase() === fund);
	const books = await Promise.all(accounts.map(async ({ position }) => {
		const multicall = await client.readContract({ address: position, abi: perpAccountAbi, functionName: 'verantaMulticall' });
		const [book, pending] = await Promise.all([
			client.readContract({ address: multicall, abi: multicallAbi, functionName: 'getPositions', args: [position] }),
			client.readContract({ address: multicall, abi: multicallAbi, functionName: 'getPendingOrder', args: [position] }),
		]);
		return { book, pending } as unknown as Parameters<typeof pairsToStore>[0][number];
	}));
	const feeds = pairsToStore(books).map((pairIndex) => ({ store, pairIndex, maxPushAge: 600 }));
	if (feeds.length) await pushStorePrices(client, wallet, store, feeds, { feedUrl: verantaFeedUrl, minAgeSec: FRESH_BEFORE_UNWIND_SEC, dryRun: config.dryRun, log });
}
```
Imports to add: `redemptionPass, switchedOnUnwinder, pairsToStore, FRESH_BEFORE_SETTLE_SEC, FRESH_BEFORE_UNWIND_SEC` from `./redemption-settler.js`; `pushStorePrices` from `../veranta/price-store.js`; `discoverFleet` from `../veranta/fleet.js`; `multicallAbi` from `../veranta/contracts.js`; `parseAbi` from `viem` (check what index.ts already imports; keep the `.js` suffix style index.ts uses).

- [ ] **Step 7: Env** — `compose.production.yml`, protect service, after `DEPOSIT_EXECUTOR`:
```yaml
      # RedemptionQueue (fund v3, 2026-10-06): from funds-core deployments/base-mainnet-redemption.json
      # ("queue"). Empty = the settler is off. Each fund with a queued request is tried every
      # REDEMPTION_SETTLE_EVERY_SECONDS (default 300); REDEMPTION_SETTLER=0 disables.
      REDEMPTION_QUEUE: ${REDEMPTION_QUEUE:-}
      REDEMPTION_SETTLER: ${REDEMPTION_SETTLER:-1}
```
`.env.example`: add the three vars with one-line comments. Root `/home/dude/FrostyFunds/compose.yml`: no change (no queue on the testnets; the job stays off).

- [ ] **Step 8: Run the whole suite and a dry pass**

Run: `npm test && npm run typecheck`
Expected: every suite passes (report any failure by name, including ones you didn't cause).
Then, once the queue is deployed (Task 7), a read-only live check: `DRY_RUN=1 REDEMPTION_QUEUE=<queue> … npm run protect:once` against Base logs `redemption settler · ON` and either nothing (no open requests) or `waits: NothingSettled` / `DRY RUN — would settle`.

- [ ] **Step 9: Leave the diff for the founder.**

---

### Task 3: frosty-terminal — plumbing (ABIs, deployments, fund version, queue reads, error copy)

**Files:**
- Create: `frosty-terminal/src/abi/RedemptionQueue.json`, `frosty-terminal/src/abi/ComptrollerV3.json`
- Modify: `frosty-terminal/indexer/mainnet-deployments.ts`, `frosty-terminal/src/lib/mainnetDeployments.ts`, `frosty-terminal/src/lib/tokens.ts`
- Create: `frosty-terminal/src/lib/fundVersion.ts`, `frosty-terminal/src/lib/useRedemptionRequests.ts`
- Modify: `frosty-terminal/src/lib/callErrors.ts`
- Test: `frosty-terminal/test/mainnet-deployments.test.ts` (extend), `frosty-terminal/test/fund-version.test.ts`, `frosty-terminal/test/presign-checks.test.ts` (extend if it asserts the two reworded explanations)

**Interfaces:**
- Produces: `INFRA.redemptionQueue: Addr` (ZERO until synced; ZERO on the testnets); `fundVersionFrom(queueRead, registrarRead): 1 | 2 | 3 | undefined`; `useFundVersion(comptroller): { version, queue }`; `useRedemptionRequests(fundId): { open: QueueRequest[]; recent: QueueRequest[] }` with `QueueRequest = { id: string; requestId: string; account: { id: string }; mode: 'CASH' | 'IN_KIND'; sharesRequested: string; sharesOpen: string; status: string; requestedAt: string; closedAt: string | null }`.

- [ ] **Step 1: Branch and ABIs**

```bash
cd /home/dude/FrostyFunds/frosty-terminal
git fetch origin && git switch -c feat/redemption-queue --no-track origin/main
for c in RedemptionQueue ComptrollerV3; do python3 -c "import json,sys; json.dump(json.load(open('../funds-core/out/$c.sol/$c.json'))['abi'], open('src/abi/$c.json','w'), indent=1)"; done
```

- [ ] **Step 2: Failing tests**

Extend `test/mainnet-deployments.test.ts`:
```ts
	it('the redemption queue defaults to ZERO until its book is synced, then is taken', () => {
		expect(parseGenesis(FORK).redemptionQueue).toBe(ZERO);
		const g = parseGenesis({ ...FORK, redemptionQueue: '0x5a5def86b5ebb469e190344e2f7a9664e02c0a8e', fundV3Deployer: '0x1b832ebd104bccfa05222c1d581cfae019071498' });
		expect(g.redemptionQueue).toBe('0x5a5dEf86b5EBb469E190344E2f7A9664E02c0a8E');
		expect(g.fundV3Deployer).toBe('0x1b832ebD104BccfA05222C1D581cFAE019071498');
	});
```
Create `test/fund-version.test.ts`:
```ts
import { describe, expect, it } from 'vitest';
import { fundVersionFrom } from '../src/lib/fundVersion';

describe('fundVersionFrom — v3 answers redemptionQueue(); v2 only registrar(); v1 neither', () => {
	it('reads v3 first: a v3 fund also answers registrar()', () => {
		expect(fundVersionFrom({ status: 'success', result: '0x5a5dEf86b5EBb469E190344E2f7A9664E02c0a8E' }, { status: 'success', result: '0x34AcBA229Aeaf7F1c0f442633F35E26Bc94b4e2A' })).toBe(3);
	});
	it('a reverting redemptionQueue() with a registrar is v2; both reverting is v1', () => {
		expect(fundVersionFrom({ status: 'failure' }, { status: 'success', result: '0x34AcBA229Aeaf7F1c0f442633F35E26Bc94b4e2A' })).toBe(2);
		expect(fundVersionFrom({ status: 'failure' }, { status: 'failure' })).toBe(1);
	});
	it('is undefined while either read is still loading', () => {
		expect(fundVersionFrom(undefined, { status: 'failure' })).toBeUndefined();
		expect(fundVersionFrom({ status: 'failure' }, undefined)).toBeUndefined();
	});
});
```
Run: `npx vitest run test/mainnet-deployments.test.ts test/fund-version.test.ts`
Expected: FAIL (no `redemptionQueue` key; no `fundVersion` module).

- [ ] **Step 3: Implement deployments + version**
  - `src/lib/mainnetDeployments.ts`: append `'redemptionQueue', 'perpUnwinder', 'fundV3Deployer'` to `LATER_KEYS` and extend its doc comment ("redemptionQueue / perpUnwinder / fundV3Deployer: DeployRedemptionQueue (base-mainnet-redemption.json)").
  - `indexer/mainnet-deployments.ts`: `const redemption = book('base-mainnet-redemption.json');` and add `['redemptionQueue', redemption.queue], ['perpUnwinder', redemption.perpUnwinder], ['fundV3Deployer', redemption.fundV3Deployer]` to the mapped list.
  - `src/lib/tokens.ts`: `Infra` gains `// RedemptionQueue (fund v3); ZERO = not deployed — every queue surface hides\n\tredemptionQueue: Addr;`, `mainnetInfra` maps `redemptionQueue: g.redemptionQueue`, the Sepolia and Veranta infra objects set `redemptionQueue: ZERO`.
  - `src/lib/fundVersion.ts`:
```ts
'use client';
import { useReadContracts } from 'wagmi';
import ComptrollerV3 from '@/abi/ComptrollerV3.json';

type Read = { status: 'success'; result: unknown } | { status: 'failure' } | undefined;

/** Pure: v3 (fund with the redemption queue, 2026-10-06) answers redemptionQueue(); v2 answers
 *  registrar() only; v1 neither. A v3 fund answers registrar() too, so v3 is read first. */
export function fundVersionFrom(queue: Read, registrar: Read): 1 | 2 | 3 | undefined {
	if (queue === undefined || registrar === undefined) return undefined;
	if (queue.status === 'success') return 3;
	return registrar.status === 'success' ? 2 : 1;
}

/** The fund's comptroller version and, for v3, its queue. The reverts ARE the answer: no retries. */
export function useFundVersion(comptroller: `0x${string}` | undefined) {
	const { data } = useReadContracts({
		allowFailure: true,
		contracts: comptroller ? [
			{ address: comptroller, abi: ComptrollerV3 as never, functionName: 'redemptionQueue' },
			{ address: comptroller, abi: ComptrollerV3 as never, functionName: 'registrar' },
		] : [],
		query: { enabled: Boolean(comptroller), retry: false, staleTime: Infinity },
	});
	const version = fundVersionFrom(data?.[0] as Read, data?.[1] as Read);
	const queue = version === 3 ? (data?.[0]?.result as `0x${string}`) : undefined;
	return { version, queue };
}
```
  - `src/lib/useRedemptionRequests.ts` (own query, so the fund page never depends on a subgraph version that has the new entities; off until the queue is deployed):
```ts
'use client';
import { useQuery } from '@tanstack/react-query';
import { subgraph } from './subgraph';
import { INFRA } from './tokens';

const ZERO = '0x0000000000000000000000000000000000000000';

export interface QueueRequest {
	id: string; requestId: string; account: { id: string }; mode: 'CASH' | 'IN_KIND';
	sharesRequested: string; sharesOpen: string; status: string; requestedAt: string; closedAt: string | null;
}

const QUEUE_QUERY = `query Queue($fund: String!) {
	open: redemptionRequests(where: { fund: $fund, status: "OPEN" }, orderBy: requestedAt, orderDirection: asc, first: 200) {
		id requestId account { id } mode sharesRequested sharesOpen status requestedAt closedAt
	}
	recent: redemptionRequests(where: { fund: $fund }, orderBy: requestedAt, orderDirection: desc, first: 50) {
		id requestId account { id } mode sharesRequested sharesOpen status requestedAt closedAt
	}
}`;

/** Queued redemptions of one fund (RedemptionQueue, fund v3). Its own query: a subgraph version
 *  without these entities can't break the fund page, and nothing is asked before the queue exists. */
export function useRedemptionRequests(fundId: string | undefined) {
	const enabled = Boolean(fundId) && INFRA.redemptionQueue !== ZERO;
	const { data } = useQuery({
		queryKey: ['fund', (fundId ?? '').toLowerCase(), 'queue'],
		queryFn: () => subgraph<{ open: QueueRequest[]; recent: QueueRequest[] }>(QUEUE_QUERY, { fund: (fundId ?? '').toLowerCase() }),
		enabled,
		refetchInterval: 15_000,
	});
	return { open: data?.open ?? [], recent: data?.recent ?? [], enabled };
}
```
(The query key starts with `'fund'`, so `indexWatcher`'s existing `fund` invalidation refreshes it after a receipt.)

Run: `npx vitest run test/mainnet-deployments.test.ts test/fund-version.test.ts`
Expected: PASS.

- [ ] **Step 4: Error copy** — `src/lib/callErrors.ts`:
  - `CALL_ERRORS`: add `...(RedemptionQueue as Abi), ...(ComptrollerV3 as Abi)` (imports at the top, same style as `ComptrollerV2`).
  - The queue reuses `RequestExists()` / `NoRequest()` (same signatures as the deposit errors, de-duplicated by signature), so reword both explanations to fit either request: `[/^RequestExists/, 'you already have an open request in this fund — finish or cancel it first']`, `[/^NoRequest/, 'there is no open request to act on']`. If `test/presign-checks.test.ts` pins the old wording, update those two expectations in the same step.
  - Add, under the investors comment: `[/^UseRedemptionQueue/, 'this fund holds perps or LPs: request a redemption instead — it is paid once the manager raises the cash']`, `[/^NoExternalPositions/, 'this fund holds no perps or LPs right now — redeem instantly instead']`, `[/^ZeroShares/, 'enter how many shares to redeem']`, `[/^Unwound/, 'the fallback already closed your share of the perps: this request is paid at the next settlement and can no longer be cancelled']`, `[/^NotOurFund/, 'this fund is not served by the redemption queue']`.

Run: `npm test`
Expected: all suites pass.

- [ ] **Step 5: Leave the diff for the founder** (Tasks 4 and 5 continue on this branch).

---

### Task 4: frosty-terminal — investor queue UI

**Files:**
- Create: `frosty-terminal/src/lib/redemptionQueue.ts`
- Create: `frosty-terminal/src/components/QueuedRedeem.tsx`
- Modify: `frosty-terminal/src/components/InvestPanel.tsx` (version via `useFundVersion`; the redeem block branches)
- Modify: `frosty-terminal/src/app/fund/[id]/layout.tsx` (alerts strip: overdue)
- Modify: `frosty-terminal/src/app/fund/[id]/invest/page.tsx` (queued redemptions table)
- Test: `frosty-terminal/test/redemption-queue.test.ts`

**Interfaces:**
- Consumes: `useFundVersion`, `useRedemptionRequests`, `QueueRequest`, `INFRA.redemptionQueue` (Task 3); `lockRemaining`, `fmtTime`, `fmtUnits`; `useCheckedWriteContract`; `useFundNav`.
- Produces: pure `QUEUE_DEADLINE_SEC`, `deadlineAt(requestedAt)`, `fundOverdue(open, nowSec)`, `placeInLine(open, account)`, `deadlineIn(at, nowSec)`, `redeemPath(version, holdsPositions)`.

- [ ] **Step 1: Failing tests** — `test/redemption-queue.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { QUEUE_DEADLINE_SEC, deadlineAt, deadlineIn, fundOverdue, placeInLine, redeemPath } from '../src/lib/redemptionQueue';

const row = (account: string, requestedAt: number, sharesOpen: string) =>
	({ id: `f-${requestedAt}`, requestId: '0', account: { id: account }, mode: 'CASH' as const, sharesRequested: sharesOpen, sharesOpen, status: 'OPEN', requestedAt: String(requestedAt), closedAt: null });

describe('the 4-day deadline (RedemptionQueue.DEADLINE, strictly after)', () => {
	it('is the request time + 4 days', () => {
		expect(QUEUE_DEADLINE_SEC).toBe(345_600);
		expect(deadlineAt(1_000)).toBe(346_600);
	});
	it('the fund is overdue only once its OLDEST open request is strictly past it', () => {
		const open = [row('0xb0b', 2_000, '5'), row('0xa11ce', 1_000, '5')];
		expect(fundOverdue(open, 1_000 + QUEUE_DEADLINE_SEC)).toBe(false);
		expect(fundOverdue(open, 1_001 + QUEUE_DEADLINE_SEC)).toBe(true);
		expect(fundOverdue([], 10 ** 12)).toBe(false);
	});
});

describe('placeInLine — what is still OPEN ahead of you (a partial payment shrinks it)', () => {
	it('counts places and the shares ahead, oldest first', () => {
		const open = [row('0xa11ce', 1_000, '250'), row('0xb0b', 2_000, '100'), row('0xca401', 3_000, '7')];
		expect(placeInLine(open, '0xCA401')).toEqual({ place: 3, of: 3, sharesAhead: 350n });
		expect(placeInLine(open, '0xd00d')).toBeNull();
	});
});

describe('deadlineIn — the countdown', () => {
	it('days and hours above a day, the shares-lock format below', () => {
		expect(deadlineIn(100 + 2 * 86_400 + 4 * 3_600, 100)).toBe('in 2d 04h');
		expect(deadlineIn(100 + 3_600 + 300, 100)).toBe('in 1h 05m');
	});
});

describe('redeemPath — which exit the investor gets', () => {
	it('a v3 fund holding a perp or an LP queues; any fund without positions redeems instantly', () => {
		expect(redeemPath(3, true)).toBe('queue');
		expect(redeemPath(3, false)).toBe('instant');
		expect(redeemPath(2, true)).toBe('instant');
		expect(redeemPath(1, true)).toBe('instant');
		expect(redeemPath(undefined, true)).toBe('loading');
	});
});
```
Run: `npx vitest run test/redemption-queue.test.ts` — Expected: FAIL (module missing).

- [ ] **Step 2: Implement the pure lib** — `src/lib/redemptionQueue.ts`:

```ts
import type { QueueRequest } from './useRedemptionRequests';
import { lockRemaining } from './sharesLock';

/** RedemptionQueue.DEADLINE (founder 2026-10-06): past it the fund is overdue and its manager's fees stop. */
export const QUEUE_DEADLINE_SEC = 4 * 86_400;

export function deadlineAt(requestedAt: number): number {
	return requestedAt + QUEUE_DEADLINE_SEC;
}

/** As RedemptionQueue.isOverdue: the oldest open request, strictly past its deadline. */
export function fundOverdue(open: QueueRequest[], nowSec: number): boolean {
	if (!open.length) return false;
	const oldest = Math.min(...open.map((r) => Number(r.requestedAt)));
	return nowSec > deadlineAt(oldest);
}

/** 1-based place among the open requests (oldest first) and the shares still open ahead. */
export function placeInLine(open: QueueRequest[], account: string): { place: number; of: number; sharesAhead: bigint } | null {
	const sorted = [...open].sort((a, b) => Number(a.requestedAt) - Number(b.requestedAt));
	const at = sorted.findIndex((r) => r.account.id.toLowerCase() === account.toLowerCase());
	if (at < 0) return null;
	const sharesAhead = sorted.slice(0, at).reduce((acc, r) => acc + BigInt(r.sharesOpen), 0n);
	return { place: at + 1, of: sorted.length, sharesAhead };
}

/** "in 2d 04h" above a day; the shares-lock countdown below. */
export function deadlineIn(at: number, nowSec: number): string {
	const left = Math.max(0, at - nowSec);
	if (left < 86_400) return lockRemaining(at, nowSec);
	return `in ${Math.floor(left / 86_400)}d ${String(Math.floor((left % 86_400) / 3_600)).padStart(2, '0')}h`;
}

/** v3 funds holding a perp or an LP redeem through the queue; everything else instantly. */
export function redeemPath(version: 1 | 2 | 3 | undefined, holdsPositions: boolean): 'queue' | 'instant' | 'loading' {
	if (version === undefined) return 'loading';
	return version === 3 && holdsPositions ? 'queue' : 'instant';
}
```
Run the test — Expected: PASS.

- [ ] **Step 3: `QueuedRedeem` component** — `src/components/QueuedRedeem.tsx`. Props: `{ comptroller, sharesToken, queue, locked, lockNote }` (the parent already computes the shares lock). It renders, all lowercase copy, the repo's panel classes:
  - Reads (wagmi, `refetchInterval: 15_000`): `requestOf(comptroller, address)` on the queue (RedemptionQueue ABI); the shares `allowance(address, queue)` and `balanceOf(address)` (viem `erc20Abi` — the trimmed ERC20.json has no `totalSupply`, use `erc20Abi` for all three); `useFundNav(comptroller)` for the estimate; `useRedemptionRequests(comptroller).open` for the line.
  - Writes: `useCheckedWriteContract(comptroller)` (the same hook InvestPanel uses; queue calls value nothing, so no price push).
  - No open request: shares input; mode toggle `cash | in kind`; estimate `≈ {shares × sharePrice} {DENOM_SYMBOL} at today's NAV` (cash) or `your share of every token, plus the positions' share in {DENOM_SYMBOL}` (in kind); `1 · approve shares` (when allowance < shares: `approve(queue, shares)` on the shares token) then `2 · request redemption` (`requestRedeem(comptroller, shares, mode === 'cash' ? 0 : 1)`); disabled while `locked` (show `lockNote`). Helper copy: `this fund holds perps or LPs: redemptions queue until the manager raises the cash, oldest first, at the NAV of settlement · 4 days late and the manager's fees stop`.
  - Open request: `#{place} of {of} in line · {fmtUnits(shares, 18, 2)} shares · {cash|in kind} · requested {fmtTime(requestedAt)}`; deadline line `deadline {deadlineIn(deadlineAt(requestedAt), now)}` or, overdue, an amber box `overdue since {fmtTime(deadline)} — the manager's fees have stopped`; if `request.unwound`: `the fallback closed your share of the perps: you are paid at the next settlement; it can't be cancelled now`; `cancel request` (`btn btn-danger`, `cancel(comptroller)` on the queue; disabled while unwound).
  - Always, at the bottom: `exit in kind now` (`redeemSharesInKind(shares)` on the comptroller) under a red box: `pays a slice of every token now and forfeits your share of the fund's perps and LPs — it can also break the fund's hedge` (spec §8).
  - `<SimVerdict verdict={refusal} pending={checking} pricing={pricing} />`, `<TxPending … />` and the error line, as InvestPanel does.

- [ ] **Step 4: InvestPanel** — replace the inline `registrar` probe with `const { version, queue } = useFundVersion(comptroller); const isV2 = version !== undefined && version >= 2; const versionPending = version === undefined;` (keep `registrar` for `RedemptionPreview`: read it only when `isV2`, from the same `useReadContract` call it has today). Read `getExternalPositions()` (`ComptrollerV2` ABI, `refetchInterval: 30_000`) → `holdsPositions = (positions?.length ?? 0) > 0`. In the redeem block: `redeemPath(version, holdsPositions) === 'queue' && queue ? <QueuedRedeem … /> : <the existing inputs and buttons>`. For a v2 fund holding positions, add under the buttons the same red in-kind warning sentence (spec §8: "V2 and V3 funds").

- [ ] **Step 5: Alerts strip and table**
  - `layout.tsx`: `const { open: queued } = useRedemptionRequests(fund?.id);` and, inside the alerts builder, `if (fundOverdue(queued, nowSec)) alerts.push({ key: 'overdue', text: 'redemption overdue — manager fees stopped', href: `${base}/invest` });` plus, when not overdue but `queued.length > 0`, `{ key: 'queued', text: `${queued.length} redemption${queued.length === 1 ? '' : 's'} queued` }`.
  - `invest/page.tsx`: under the redemptions table, a `queued redemptions` table from `useRedemptionRequests(id).recent` (account, shares requested / still open, cash | in kind, status lowercase, requested, closed) — hidden when `enabled` is false.

- [ ] **Step 6: Verify**

Run: `npm test && npm run build`
Expected: all suites pass; the production build passes (no `useSearchParams` added, so no Suspense boundary needed). With `NEXT_PUBLIC_NETWORK=base-sepolia npm run dev` the invest tab is unchanged (queue hidden: `INFRA.redemptionQueue` is ZERO).

- [ ] **Step 7: Leave the diff for the founder.**

---

### Task 5: frosty-terminal — the manager's "Redemptions due" panel

**Files:**
- Create: `frosty-terminal/src/lib/proRataUnwind.ts`
- Create: `frosty-terminal/src/components/manage/RedemptionsDue.tsx`
- Modify: `frosty-terminal/src/components/manage/SlipstreamExitControls.tsx` (optional `fractionWad`)
- Modify: `frosty-terminal/src/components/manage/FundTokenTicket.tsx`, `FundStockTicket.tsx` (optional `initialAmount`)
- Modify: `frosty-terminal/src/app/fund/[id]/desk/page.tsx` (render the panel; `sellHolding(row, amount?)`)
- Test: `frosty-terminal/test/pro-rata-unwind.test.ts`

**Interfaces:**
- Consumes: `useRedemptionRequests` (Task 3), `fundOverdue`, `deadlineAt`, `deadlineIn` (Task 4); `useFundBook` (`SpotRow`, `PerpRow`, `LpRow`, `navUsd`); `usePerpBooks` (per-account `[trades, limits]` with `trade.{pairIndex, index, initialPosToken, leverage, buy}`); `useVerantaCatalog` (per-pair `minPosUsdc`, `lazerFeedId`); `useLivePrices`.
- Produces: pure `WAD`, `fractionWad(shares, supply)`, `usdcNeeded({ cashShares, inKindShares, supply, cashValue, vaultUsdc, positionsValue })`, `tradeClose(collateral, leverage, fWad, minPosUsdc)`, `liquidityToRemove(liquidity, fWad)`, `spotToSell(balance, fWad)`.

- [ ] **Step 1: Failing tests** — `test/pro-rata-unwind.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { WAD, fractionWad, liquidityToRemove, spotToSell, tradeClose, usdcNeeded } from '../src/lib/proRataUnwind';

describe('fractionWad — the queued share of the fund, rounded UP (the manager raises at least it)', () => {
	it('is shares / supply in WAD, never under', () => {
		expect(fractionWad(1n, 3n)).toBe(333_333_333_333_333_334n);
		expect(fractionWad(0n, 3n)).toBe(0n);
		expect(fractionWad(5n, 0n)).toBe(0n);
	});
});

describe('usdcNeeded — what settlement takes from the vault (RedemptionMath)', () => {
	it('cash: the share of the cash-able value; in kind: the share of vault USDC + positions', () => {
		const need = usdcNeeded({ cashShares: 100n, inKindShares: 50n, supply: 1_000n, cashValue: 10_000n, vaultUsdc: 2_000n, positionsValue: 6_000n });
		expect(need).toBe(1_000n + 400n); // 10% of 10,000 + 5% of (2,000 + 6,000)
	});
});

describe('tradeClose — PerpUnwinder\'s rule: close F of the collateral, or all when the rest is under the pair minimum', () => {
	it('closes F (rounded up)', () => {
		expect(tradeClose(1_000_000_000n, 50_000_000_000n, WAD / 4n, 100_000_000n)).toEqual({ amount: 250_000_000n, whole: false });
	});
	it('closes the whole trade when the remainder\'s size is under the minimum', () => {
		// 200 USDC × 5x = 1,000 size; closing 90% leaves 20 × 5 = 100 < 150
		expect(tradeClose(200_000_000n, 50_000_000_000n, (WAD * 9n) / 10n, 150_000_000n)).toEqual({ amount: 200_000_000n, whole: true });
	});
	it('nothing to close for a zero fraction', () => {
		expect(tradeClose(1_000_000_000n, 50_000_000_000n, 0n, 100_000_000n)).toBeNull();
	});
});

describe('liquidityToRemove / spotToSell — pro rata, up for liquidity, down for a sale', () => {
	it('rounds the LP removal up and the spot sale down', () => {
		expect(liquidityToRemove(1_000n, WAD / 3n)).toBe(334n);
		expect(spotToSell(1_000n, WAD / 3n)).toBe(333n);
	});
});
```
Run: `npx vitest run test/pro-rata-unwind.test.ts` — Expected: FAIL (module missing).

- [ ] **Step 2: Implement** — `src/lib/proRataUnwind.ts`:

```ts
/** The manager's pro-rata unwind for queued redemptions (spec 2026-10-06 §8): close F of every perp
 *  trade and LP, return the USDC to the vault, and for cash requests sell F_cash of the spot, where
 *  F is the queued share of the fund. Mirrors RedemptionMath and PerpUnwinder so what the manager
 *  raises is what settlement takes. */
export const WAD = 10n ** 18n;
const LEVERAGE_PRECISION = 10n ** 10n; // Veranta leverage scale (5x = 5e10)

const ceilDiv = (a: bigint, b: bigint) => (a + b - 1n) / b;

export function fractionWad(shares: bigint, supply: bigint): bigint {
	if (supply === 0n || shares === 0n) return 0n;
	return ceilDiv(shares * WAD, supply);
}

/** USDC settlement takes: cash requests get their share of the cash-able value (every readable,
 *  non-pool-priced holding plus the positions); in-kind requests their share of vault USDC + positions. */
export function usdcNeeded(q: { cashShares: bigint; inKindShares: bigint; supply: bigint; cashValue: bigint; vaultUsdc: bigint; positionsValue: bigint }): bigint {
	if (q.supply === 0n) return 0n;
	return (q.cashValue * q.cashShares) / q.supply + ((q.vaultUsdc + q.positionsValue) * q.inKindShares) / q.supply;
}

/** F of a trade's collateral (rounded up), or the whole trade when what would remain is under the
 *  pair's minimum leveraged size — PerpUnwinder._closeAmount's rule. */
export function tradeClose(collateral: bigint, leverage: bigint, fWad: bigint, minPosUsdc: bigint): { amount: bigint; whole: boolean } | null {
	if (fWad === 0n || collateral === 0n) return null;
	const amount = ceilDiv(collateral * fWad, WAD);
	if (amount >= collateral) return { amount: collateral, whole: true };
	const rest = collateral - amount;
	if ((rest * leverage) / LEVERAGE_PRECISION < minPosUsdc) return { amount: collateral, whole: true };
	return { amount, whole: false };
}

export function liquidityToRemove(liquidity: bigint, fWad: bigint): bigint {
	return ceilDiv(liquidity * fWad, WAD);
}

export function spotToSell(balance: bigint, fWad: bigint): bigint {
	return (balance * fWad) / WAD;
}
```
Run the test — Expected: PASS.

- [ ] **Step 3: Partial LP exit** — `SlipstreamExitControls`: add `fractionWad?: bigint` to the props. When set: the withdraw step decreases `liquidityToRemove(pos[7], fractionWad)` (mins from `lpWithdrawMins(thatLiquidity, pos[5], pos[6], priceRaw)`), its label is `withdraw {pct}% of liquidity` (pct = `Number(fractionWad * 10000n / WAD) / 100`), the burn step is never offered, and the trailing hint reads `pro-rata: withdraw → collect to the vault`. Without the prop it behaves exactly as today.

- [ ] **Step 4: Prefilled spot sale** — `FundStockTicket` and `FundTokenTicket` take `initialAmount?: string` and seed their amount state with it (`useState(initialAmount ?? '')`; `FundTokenTicket` passes it on to `FundPoolTicket` / `PoolPricedTicket`). Comment: `// prefilled only from the manager's "Redemptions due" panel (spec 2026-10-06 §8) — otherwise empty (TASKS §W)`. On the desk: `const [spotAmount, setSpotAmount] = useState<string | undefined>()`; `sellHolding(row: SpotRow, amount?: string)` sets it (and clears it when `selectMarket` is called by the picker); both tickets get `initialAmount={spotAmount}` and their `key` includes it so they remount with the amount.

- [ ] **Step 5: `RedemptionsDue` panel** — `src/components/manage/RedemptionsDue.tsx`, rendered on the desk page above the side tabs when `canTrade && open.length > 0`. Props: `{ comptroller, book, positions, supply, onSell }`.
  - Header: `redemptions due · {n} request{s} · {pct}% of the fund · deadline {deadlineIn(deadlineAt(oldest), now)}`, or red `OVERDUE — your fees have stopped until it is paid`.
  - Cash line: `{DENOM_SYMBOL} needed ≈ {usdcNeeded(...)} · in the vault {vault} · to raise {max(0, need − vault)}`. Inputs: `cashShares` / `inKindShares` summed from `open` by mode (sharesOpen); `supply` from the shares token's `totalSupply`; `vaultUsdc` = the denomination row of `book.spot`; `positionsValue` = `navUsd − Σ book.spot.valueUsdc` (in denomination units); `cashValue` = `navUsd − Σ value of pool-priced spot rows` (read `poolPricedAdapter(asset)` per spot asset from `INFRA.poolPriceRegistrar`, as `RedemptionPreview` does).
  - Perps: for each Veranta account (`positions` type 6) and each trade in `usePerpBooks([account]).books[0][0]`: `close {pct}% of {pairLabel} {long|short} #{index}: {fmtUnits(amount, 6, 2)} USDC collateral{whole ? ' (whole trade: the rest would be under the pair minimum)' : ''}` → `callOnExternalPosition(account, [], [], [], abi.encode(uint8 1, abi.encode(uint256 pairIndex, uint256 index, uint256 amount, uint256 wantedPrice)))`, `wantedPrice` = the pair's live Lazer price (`useLivePrices` over the catalog's `lazerFeedId`) × 1e10, button disabled while it is unknown. Then, per account with idle USDC (`balanceOf(account)` > 0): `return {idle} USDC to the vault` → action 6 `ReturnToVault(idle)` with `[USDC]` received (VerantaPanel's "return"). Copy: `closes fill in ~20 s; the USDC then shows here to return`.
  - LPs: Slipstream positions (types 4 and 7) → `<SlipstreamExitControls fund={comptroller} position={p} fractionWad={f} />`; other LP types → `remove {pct}% of its liquidity from its yield page`.
  - Spot (only when `cashShares > 0`): each non-denomination spot row that is not pool-priced → `sell {fmtUnits(spotToSell(balance, fCash), decimals, 6)} {symbol} (≈ {value})` button → `onSell(row, amountString)`.
  - Footer: `the keeper settles the queue on its own once the vault can pay`.
  - Writes through `useCheckedWriteContract(comptroller)` with the `SimVerdict` / `TxPending` / error lines.

- [ ] **Step 6: Verify**

Run: `npm test && npm run build`
Expected: all suites pass; production build passes. With `NEXT_PUBLIC_NETWORK=base-sepolia npm run dev` the desk is unchanged (no queue).

- [ ] **Step 7: Leave the diff for the founder.**

---

### Task 6: frostyflow — the health report's queued-redemptions line

**Files:**
- Modify: `/home/dude/FrostyLabs/frostyflow/scripts/workflows/health/build-health-monitor.ts`
- Create: `/home/dude/FrostyFunds/.ops-scratch/health-redemptions-2026-10-07.js` (prod console patch; outside every repo)

**Interfaces:**
- Consumes: subgraph `redemptionRequests(where: { status: "OPEN" }) { requestedAt mode fund { id name } }` (Task 1, published).

- [ ] **Step 1: Prerequisite and branch** — the founder has committed `feat/health-perp-on-demand`. Then `git switch -c feat/health-redemptions --no-track feat/health-perp-on-demand`.

- [ ] **Step 2: Builder** — in `reads()`, the `Pending Deposits` node's body query becomes
`"{ depositRequests(where: { status: PENDING }, first: 20, orderBy: requestedAt) { requestedAt assets fund { id name } } redemptionRequests(where: { status: \"OPEN\" }, first: 20, orderBy: requestedAt) { requestedAt mode fund { id name } } }"` (comment: one subgraph read for both queues, so no new node or edge). Add
```ts
// Line 7 (redemption queue, 2026-10-07). The prod patch copies this text verbatim.
const RULE_REDEMPTIONS = `7) Queued redemptions (funds holding perps or LPs): you get the open requests with requestedAt (unix seconds) and the fund. A request's deadline is requestedAt + 345600 (4 days). NEEDS ATTENTION if any request's deadline is less than 86400 seconds (24 h) after the check time: name the fund and say its manager must raise the cash before the deadline (desk, "redemptions due"). NEEDS ATTENTION, urgent, if any request is past its deadline: name the fund, say the manager's fees have stopped, and that governance or the guardian can switch on the fallback unwind if the manager stays absent. Otherwise fine; open requests far from their deadline are normal.`;
```
to the rules list after `RULE_KEEPER_GAS`, a user-message paragraph `7) Queued redemptions: ` + `mention(r.deposits.id, ["body", "data", "redemptionRequests"])`, and to the hourly gate `{ source: bind(r.deposits.id, ["body", "data", "redemptionRequests"]), operator: "is_not_empty" }` (comment: any open request wakes the report; the model applies the 24 h rule, as line 5 does for deposits).

Run: `pnpm biome check scripts/workflows/health/build-health-monitor.ts && pnpm tsc --noEmit -p .` (or the repo's own lint/typecheck scripts — read `package.json` first and use those).
Expected: clean.

- [ ] **Step 3: Prod patch script** — `.ops-scratch/health-redemptions-2026-10-07.js`, built on `health-perp-on-demand-2026-10-05.js` (same `HO.prod` ids, `hoRead` / `hoWrite` / `hoDeploy`, dry run by default, `{ send: true }` to apply, an undo, no secrets printed):
  - Both workflows: the `Pending Deposits` node's body → the new query; the `Health Report` system message gains the line-7 rule paragraph (verbatim `RULE_REDEMPTIONS`); the user message gains the line-7 paragraph after line 6.
  - Hourly only: one gate rule `is_not_empty` on `Pending Deposits` `body.data.redemptionRequests`.
  - Guards: exactly one node of each name; line 7 absent before apply (present before undo); node and edge counts unchanged after the write; re-read and compare before redeploying.
  - Header: `ORDER: apply AFTER the subgraph version with redemptionRequests is published on The Graph — before that the query errors and line 5 (deposits) breaks too.`

- [ ] **Step 4: Leave the builder diff for the founder; the patch script stays in `.ops-scratch/` for the founder to run.**

---

### Task 7: The rollout runbook

**Files:**
- Modify: `/home/dude/FrostyFunds/MAINNET_RUNBOOK_FUNDS.md` (new section "Redemption queue rollout (fund v3, 2026-10-07)"; internal, never committed)

- [ ] **Step 1: Write the section**, in this order (each step names who runs it):
  1. **Founder:** merge funds-core `feat/redemption-queue`; from `main`: `forge script script/mainnet/DeployRedemptionQueue.s.sol --rpc-url <base> --account frosty-main --sender 0xaE51f2EfE70e57b994BE8F7f97C4dC824c51802a --broadcast --slow --verify`; commit `deployments/base-mainnet-redemption.json`. Dry run 2026-10-07: 7 transactions, ~18.9M gas total, the largest 8.3M, ~0.0002 ETH. The unwinder lands approved and OFF; no fund changes yet.
  2. **Subgraph:** merge; `SUBGRAPH_SLUG=frosty-funds VERSION_LABEL=<next> npm run deploy-base`; publish the version in Studio (re-indexes from genesis 51,969,168).
  3. **Keeper:** merge; Coolify env `REDEMPTION_QUEUE=<queue>`; if the Engine vault access token restricts target contracts, allow the queue; Deploy (manual — merging ships nothing). Check the log line `redemption settler · ON (queue …)`.
  4. **Terminal:** merge; `npx tsx indexer/mainnet-deployments.ts`; commit `src/lib/deployments/base-mainnet.json`; Deploy in Coolify.
  5. **Health:** in the prod FrostyFlow tab console: `healthRedemptions()` (dry run), then `healthRedemptions({ send: true })` — only after step 2's version is published.
  6. **Founder:** `factory.setComptrollerDeployer(<fundV3Deployer>)` (deployer key today; after the governance handoff a Safe → timelock proposal). From then on new funds are v3; existing funds stay v2.
  7. **Smoke test:** a small v3 fund with a tiny perp: request a redemption from a second wallet; the "Redemptions due" panel shows it; close + return; the keeper settles within ~5 min; the subgraph shows SETTLED.
- Ops notes in the same section: switching the fallback on is one transaction (`setUnwinderOn(perpUnwinder, true)`, guardian or governance); only governance switches it off; a fund keeps ≤ 5 perp accounts (runbook "Perp accounts: known gaps").

- [ ] **Step 2: Done** — nothing to commit (root docs are internal).
