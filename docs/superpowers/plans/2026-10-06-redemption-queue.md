# Redemption queue (funds-core) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build ComptrollerV3, the shared RedemptionQueue and the switched-off PerpUnwinder in funds-core, fully tested (unit, fuzz, Base fork), ready for a reviewed deploy.

**Architecture:** One `RedemptionQueue` contract serves every V3 fund: it escrows shares, values the fund from public reads, computes every payout and drives the fallback unwind. `ComptrollerV3` is ComptrollerV2 plus five small hooks that trust only the queue address fixed at construction. `PerpUnwinder` is a stateless helper that lists pro-rata close actions for a Veranta perp account; the queue forwards them through the comptroller, which refuses anything not risk-reducing.

**Tech Stack:** Solidity 0.8.24, Foundry (forge 1.5.0), OpenZeppelin 5.x, Base mainnet fork tests (`BASE_MAINNET_RPC`).

**Spec:** `docs/superpowers/specs/2026-10-06-redemption-queue-design.md` (approved 2026-10-06).

**Scope of this plan:** funds-core only (spec §3–6, §10 contract tests, §11 deploy script and rehearsal, README rules). The keeper settle and fallback jobs, terminal panels and subgraph data source (spec §7–9) get their own plan once these ABIs are final.

## Global Constraints

- Never `git add`, `git commit` or `git push`; the founder commits. Checkpoints below replace commit steps.
- No mainnet broadcast. Scripts are dry-run or fork-rehearsed only.
- Tabs, single quotes, comments carry the why with dates (`// founder 2026-10-06`).
- Versioned contracts sit side by side: ComptrollerV2 is not modified; V3 is a new file.
- `ComptrollerV3` runtime size must stay under 24,576 bytes (EIP-170); a test asserts it.
- Deadline 4 days. Unwind fill timeout 1 hour. Unwind price freshness 120 seconds.
- The protocol never swaps. Forwarded actions must satisfy the position's own `isRiskReducing`.
- Payout amounts always round down (a redeemer is never paid more than their share).
- Fork tests `return` from `setUp` without `BASE_MAINNET_RPC`.

## Deviations from the spec (confirm in review)

1. **Performance fee while overdue:** the spec says the high-water mark is "unchanged". That lets the manager collect the overdue period's gains later, so the fee stop would bite only on the management fee. This plan raises the high-water mark to the current fee price while overdue instead, so gains made while overdue are never charged. Management fee time is forfeited as specified.
2. **`unwindOverdue` takes no price updates:** the caller stores fresh prices in the same transaction through Multicall3 (`store.submit`, then `unwindOverdue`), exactly as the keeper already does before deposits. The unwinder refuses a stored price older than 120 seconds. Same effect, no payable function.
3. **Coverage tokens:** the fallback's "extra vault tokens" exclude pool-priced and unreadable tokens (a pumped long-tail price must not pull extra value out), matching how cash redemption already treats them.
4. **Fee-stop scope:** if fees were last settled before the deadline, the whole interval since then is forfeited at the first settlement while overdue (the comptroller keeps one clock). Deposits and redemptions settle fees, so the gap is normally short.

## Review Focus

1. A request whose fund holds a pool-priced token pumped between request and settlement: cash mode must pay that token in kind, never in cash.
2. Cancel after the investor's shares were moved by an allow-list policy fund: returning shares from the queue must not be blocked by `PreTransferShares` policies.
3. Several requests settled in one call: the second must be paid exactly as if settled alone (no drift from the first payout's burn).
4. A fee settlement while overdue then a settlement that clears it: the next fee settlement charges only time after the clear.
5. An unwind whose close reverts for one trade: the other trades still close and the redeemer is covered from the vault.

---

### Task 1: ComptrollerV3 as a copy of V2, wired to a queue address

**Files:**
- Create: `src/core/ComptrollerV3.sol` (copy of `src/core/ComptrollerV2.sol`)
- Create: `src/interfaces/IRedemptionQueue.sol`
- Create: `test/ComptrollerV3.t.sol` (copy of `test/ComptrollerV2.t.sol`, retargeted)
- Create: `test/utils/MockRedemptionQueue.sol`

**Interfaces:**
- Produces: `interface IRedemptionQueue { function isOverdue(address comptroller) external view returns (bool); }`
- Produces: `ComptrollerV3` with constructor `(...V2 args..., PoolPriceRegistrar registrar_, IRedemptionQueue redemptionQueue_)` and `IRedemptionQueue public immutable redemptionQueue`.
- Produces: `MockRedemptionQueue` with `setOverdue(address, bool)` and passthrough callers for the hooks (Task 2).

- [ ] **Step 1: Copy V2 to V3 and the V2 tests to V3 tests**

```bash
cp src/core/ComptrollerV2.sol src/core/ComptrollerV3.sol
sed -i 's/contract ComptrollerV2 is/contract ComptrollerV3 is/' src/core/ComptrollerV3.sol
cp test/ComptrollerV2.t.sol test/ComptrollerV3.t.sol
sed -i 's/ComptrollerV2/ComptrollerV3/g' test/ComptrollerV3.t.sol
```

- [ ] **Step 2: Add the queue interface**

```solidity
// src/interfaces/IRedemptionQueue.sol
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice What a V3 comptroller reads from its redemption queue (founder 2026-10-06).
interface IRedemptionQueue {
	/// @notice True while the fund's oldest open request is past its deadline (fees stop).
	function isOverdue(address comptroller) external view returns (bool);
}
```

- [ ] **Step 3: Add the constructor argument and immutable**

In `ComptrollerV3.sol`: import `IRedemptionQueue`; add `IRedemptionQueue public immutable redemptionQueue;` after `registrar`; append `IRedemptionQueue redemptionQueue_` as the last constructor parameter; assign it; revert `ZeroAddressConfig()` when it is zero. Update the contract NatSpec header to say redemptions of funds with external positions go through the queue.

- [ ] **Step 4: Mock queue for tests**

```solidity
// test/utils/MockRedemptionQueue.sol
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IRedemptionQueue} from '../../src/interfaces/IRedemptionQueue.sol';
import {ComptrollerV3} from '../../src/core/ComptrollerV3.sol';

/// @dev Stands in for RedemptionQueue in ComptrollerV3 unit tests: a settable overdue flag and
///      direct calls into the queue-only hooks.
contract MockRedemptionQueue is IRedemptionQueue {
	mapping(address => bool) public overdue;

	function setOverdue(address comptroller, bool value) external {
		overdue[comptroller] = value;
	}

	function isOverdue(address comptroller) external view returns (bool) {
		return overdue[comptroller];
	}

	function payOut(ComptrollerV3 fund, address to, uint256 shares, address[] calldata assets, uint256[] calldata amounts)
		external
	{
		fund.payOutRedemption(to, shares, assets, amounts);
	}

	function forward(ComptrollerV3 fund, address position, bytes calldata actionData) external {
		fund.forwardUnwind(position, actionData);
	}
}
```

(`payOut` and `forward` compile only after Task 2; until then leave them out and add them in Task 2 Step 1.)

- [ ] **Step 5: Retarget the copied tests' factory**

In `test/ComptrollerV3.t.sol` `setUp`, deploy `MockRedemptionQueue queue = new MockRedemptionQueue();` before the factory and pass `abi.encode(registrar, queue)` as the blueprint's extra args. Rename the contract to `ComptrollerV3Test`.

- [ ] **Step 6: Size test**

Add to `test/ComptrollerV3.t.sol`:

```solidity
	/// EIP-170: the V3 comptroller's runtime must fit (V2 had 603 bytes to spare).
	function test_runtimeSizeFitsEip170() public {
		ComptrollerV3 fund = _fund(0);
		assertLt(address(fund).code.length, 24_577);
	}
```

- [ ] **Step 7: Run V3's copied suite**

Run: `forge test --match-contract ComptrollerV3Test`
Expected: every V2 test passes on V3 (behavioral parity), size test passes.

- [ ] **Step 8: Checkpoint** — `git status` shows only the new files; no commit.

---

### Task 2: ComptrollerV3 hooks

**Files:**
- Modify: `src/core/ComptrollerV3.sol`
- Modify: `test/utils/MockRedemptionQueue.sol` (add `payOut`, `forward`)
- Create: `test/utils/MockUnwindPosition.sol`
- Test: `test/ComptrollerV3Hooks.t.sol` (inherits the fixture of `ComptrollerV3Test`)

**Interfaces:**
- Consumes: `IRedemptionQueue.isOverdue` (Task 1).
- Produces on `ComptrollerV3`:
  - `function payOutRedemption(address to, uint256 sharesToBurn, address[] calldata assets, uint256[] calldata amounts) external` (queue only; nonReentrant; burns from the queue; reduces cost basis; withdraws from the vault; emits `RedemptionPaidOut(address indexed to, uint256 sharesBurned, address[] assets, uint256[] amounts)`).
  - `function forwardUnwind(address position, bytes calldata actionData) external` (queue only; nonReentrant; requires an active position and `isRiskReducing`; emits `UnwindForwarded(address indexed position, bytes actionData)`).
  - Errors `OnlyRedemptionQueue()`, `UseRedemptionQueue()`, `NotRiskReducing(address position)`.
- Produces `MockUnwindPosition` (test util): an external position worth `locked + idle` USDC; action 1 `Close(amount)` moves `amount` from locked to idle (risk-reducing); action 6 `ReturnToVault(amount)` sends idle USDC to the vault (risk-reducing); action 0 `Lock(amount)` (not risk-reducing).

- [ ] **Step 1: Write the failing tests** (`test/ComptrollerV3Hooks.t.sol`)

```solidity
	function test_payOutRedemption_onlyQueue() public {
		ComptrollerV3 fund = _fund(0);
		vm.expectRevert(ComptrollerV3.OnlyRedemptionQueue.selector);
		fund.payOutRedemption(alice, 1, new address[](0), new uint256[](0));
	}

	function test_payOutRedemption_burnsQueueSharesAndPays() public {
		ComptrollerV3 fund = _fund(0);
		uint256 half = fund.shares().balanceOf(alice) / 2;
		vm.prank(alice);
		fund.shares().transfer(address(queue), half);
		address[] memory assets = new address[](1);
		assets[0] = address(usdc);
		uint256[] memory amounts = new uint256[](1);
		amounts[0] = 5_000e6;
		queue.payOut(fund, alice, half, assets, amounts);
		assertEq(fund.shares().balanceOf(address(queue)), 0);
		assertEq(usdc.balanceOf(alice), 5_000e6);
	}

	function test_forwardUnwind_refusesNonRiskReducingAndForeignPositions() public {
		ComptrollerV3 fund = _fundWithUnwindPosition(); // creates a MockUnwindPosition, locks 4,000 USDC in it
		address position = fund.getExternalPositions()[0];
		vm.expectRevert(abi.encodeWithSelector(ComptrollerV3.NotRiskReducing.selector, position));
		queue.forward(fund, position, abi.encode(uint8(0), abi.encode(uint256(1))));
		vm.expectRevert(abi.encodeWithSelector(ComptrollerV3.NotActiveExternalPosition.selector, address(0xbeef)));
		queue.forward(fund, address(0xbeef), abi.encode(uint8(1), abi.encode(uint256(1))));
	}

	function test_forwardUnwind_closesAndReturnsToVault() public {
		ComptrollerV3 fund = _fundWithUnwindPosition();
		address position = fund.getExternalPositions()[0];
		uint256 vaultBefore = usdc.balanceOf(address(fund.vault()));
		queue.forward(fund, position, abi.encode(uint8(1), abi.encode(uint256(400e6))));
		queue.forward(fund, position, abi.encode(uint8(6), abi.encode(uint256(400e6))));
		assertEq(usdc.balanceOf(address(fund.vault())), vaultBefore + 400e6);
	}

	function test_instantCashRedemption_refusedWhileAPositionIsHeld() public {
		ComptrollerV3 fund = _fundWithUnwindPosition();
		vm.prank(alice);
		vm.expectRevert(ComptrollerV3.UseRedemptionQueue.selector);
		fund.redeemShares(1e18);
	}

	function test_instantCashRedemption_unchangedForPureSpotFund() public {
		ComptrollerV3 fund = _fund(0);
		vm.prank(alice);
		fund.redeemShares(1e18);
		assertGt(usdc.balanceOf(alice), 0);
	}

	function test_inKindExit_alwaysOpen_evenWithPositions() public {
		ComptrollerV3 fund = _fundWithUnwindPosition();
		vm.prank(alice);
		fund.redeemSharesInKind(1e18);
		assertGt(usdc.balanceOf(alice), 0);
	}

	function test_transferToAndFromQueue_skipsShareTransferPolicies() public {
		ComptrollerV3 fund = _fundWithRecipientAllowList(); // AllowedSharesTransferRecipientsPolicy listing nobody
		vm.prank(alice);
		fund.shares().transfer(address(queue), 1e18); // to the queue: policies skipped
		vm.prank(address(queue));
		fund.shares().transfer(alice, 1e18); // back to the investor (cancel): policies skipped
		vm.prank(alice);
		vm.expectRevert(); // to anyone else: the allow list still applies
		fund.shares().transfer(bob, 1e18);
	}

	function test_feeStop_managementTimeForfeitedWhileOverdue() public {
		ComptrollerV3 fund = _fundWithMgmtFee(); // 2%/yr management fee
		skip(30 days);
		queue.setOverdue(address(fund), true);
		uint256 supply = fund.shares().totalSupply();
		fund.settleFees();
		assertEq(fund.shares().totalSupply(), supply, 'no management fee while overdue');
		queue.setOverdue(address(fund), false);
		skip(1 days);
		fund.settleFees();
		uint256 minted = fund.shares().totalSupply() - supply;
		assertApproxEqRel(minted, supply * 2 / 100 / 365, 0.01e18, 'only the day after the clear is charged');
	}

	function test_feeStop_noPerformanceFeeOnGainsMadeWhileOverdue() public {
		ComptrollerV3 fund = _fundHoldingWeth(2_000); // perf fee 20%, half the fund in WETH
		queue.setOverdue(address(fund), true);
		wethFeed.setAnswer(3_000e8); // gains while overdue
		uint256 supply = fund.shares().totalSupply();
		fund.settleFees();
		assertEq(fund.shares().totalSupply(), supply);
		queue.setOverdue(address(fund), false);
		fund.settleFees();
		assertEq(fund.shares().totalSupply(), supply, 'overdue gains are never charged');
	}
```

- [ ] **Step 2: Run to verify they fail**

Run: `forge test --match-contract ComptrollerV3HooksTest`
Expected: compile errors for the missing hooks, then failures.

- [ ] **Step 3: Implement the hooks in `ComptrollerV3.sol`**

```solidity
	modifier onlyRedemptionQueue() {
		if (msg.sender != address(redemptionQueue)) revert OnlyRedemptionQueue();
		_;
	}

	/// @notice The queue pays a settled request: it computed the amounts (RedemptionQueue), the
	///         comptroller only burns the escrowed shares and pays them out (founder 2026-10-06).
	function payOutRedemption(address to, uint256 sharesToBurn, address[] calldata assets, uint256[] calldata amounts)
		external
		onlyRedemptionQueue
		nonReentrant
	{
		if (assets.length != amounts.length) revert ArrayLengthMismatch();
		shares.burn(address(redemptionQueue), sharesToBurn);
		for (uint256 i; i < assets.length; ++i) {
			if (amounts[i] == 0) continue;
			FundValuation.reduceCostBasis(costBasis, assets[i], amounts[i], IERC20(assets[i]).balanceOf(address(vault)));
			vault.withdraw(assets[i], to, amounts[i]);
		}
		emit RedemptionPaidOut(to, sharesToBurn, assets, amounts);
	}

	/// @notice The fallback unwind (switched off until governance and the guardian turn it on):
	///         only an action the position itself reports as risk-reducing gets through, so it
	///         can close or return value to the vault, never open risk or move value elsewhere.
	function forwardUnwind(address position, bytes calldata actionData) external onlyRedemptionQueue nonReentrant {
		if (!externalPositions.contains(position)) revert NotActiveExternalPosition(position);
		if (!IExternalPosition(position).isRiskReducing(actionData)) revert NotRiskReducing(position);
		IExternalPosition(position).receiveCallFromFund(actionData);
		emit UnwindForwarded(position, actionData);
	}
```

In `redeemShares`, first line: `if (externalPositions.length() != 0) revert UseRedemptionQueue();` with a comment that positions can't be paid from the vault on demand (founder 2026-10-06).

In `validateSharesTransfer`: keep the timelock check; wrap the policy run:

```solidity
		// a request or a cancel moves shares to or from the queue: an exit, not a transfer to a third party
		if (from != address(redemptionQueue) && to != address(redemptionQueue)) {
			_runPolicies(IPolicy.PolicyHook.PreTransferShares, abi.encode(from, to, amount));
		}
```

In `_settleManagementFee`, after advancing `lastMgmtFeeSettled`: `if (redemptionQueue.isOverdue(address(this))) return; // fee stop, time forfeited`.

In `_settlePerformanceFee`, after computing `grossSharePrice` and before the `<= hwm` check:

```solidity
		// fee stop: gains made while a redemption is overdue are never charged
		if (redemptionQueue.isOverdue(address(this))) {
			if (grossSharePrice > highWaterMark) highWaterMark = grossSharePrice;
			return;
		}
```

Add the events and errors listed in Interfaces.

- [ ] **Step 4: Write `MockUnwindPosition`** (`test/utils/MockUnwindPosition.sol`): `IExternalPosition` holding USDC; `getManagedAssets` returns `[usdc]`, `[locked + idle]`; `isRiskReducing` true for actions 1 and 6; `receiveCallFromFund` onlyComptroller: action 0 `Lock(amount)` pulls nothing (amount must already be at the position, moved by `callOnExternalPosition`'s transfer) and adds to `locked`; action 1 `Close(amount)` moves `min(amount, locked)` from locked to idle; action 6 `ReturnToVault(amount)` transfers `min(amount, idle)` to `comptroller.vault()`. Plus a factory registered as a position type in the fixture.

- [ ] **Step 5: Run the hook tests and the parity suite**

Run: `forge test --match-contract 'ComptrollerV3(Hooks)?Test'`
Expected: all pass, including `test_runtimeSizeFitsEip170`.

- [ ] **Step 6: If the size test fails, make room without dropping a hook**

Measure: `forge build --sizes | grep ComptrollerV3`. Move, in this order until it fits, each to a new external library `src/core/ComptrollerV3Lib.sol` (`using` pattern as `FundValuation`): (a) the `addPolicy` hook-matching loop; (b) `_receivedValue` and `_vaultBalances` (pass `trackedAssets` storage and context); (c) `initializeForMigration`'s tracked-asset copy. Re-run Step 5 after each move.

- [ ] **Step 7: Checkpoint** — all ComptrollerV3 suites green; `forge build --sizes` shows margin ≥ 0.

---

### Task 3: RedemptionQueue — requests, cancel, deadline, unwinder registry

**Files:**
- Create: `src/redemption/RedemptionQueue.sol`
- Test: `test/RedemptionQueue.t.sol`

**Interfaces:**
- Consumes: `ComptrollerV3.redemptionQueue()`, `shares()`, `getExternalPositions()`, `FundFactory.funds(address)`, `FundFactory.guardian()`.
- Produces:
  - `enum Mode { Cash, InKind }`
  - `struct Request { address investor; uint64 requestedAt; Mode mode; bool open; bool unwound; uint256 shares; }`
  - `function requestRedeem(address comptroller, uint256 shares, Mode mode) external returns (uint256 id)`
  - `function cancel(address comptroller) external`
  - `function isOverdue(address comptroller) external view returns (bool)`
  - `function requestOf(address comptroller, address investor) external view returns (uint256 id, Request memory)`
  - `function requestAt(address comptroller, uint256 id) external view returns (Request memory)`
  - `function queueBounds(address comptroller) external view returns (uint256 head, uint256 length)`
  - `function setFactory(address factory) external` (owner, once; the factory must exist before the queue is used, and the V3 blueprint needs the queue's address first)
  - `function approveUnwinder(address unwinder, bool approved) external` (owner)
  - `function setUnwinderOn(address unwinder, bool on) external` (on: owner or `factory.guardian()`, approved only; off: owner only)
  - `function unwinders() external view returns (address[] memory)`, `isUnwinderOn(address) returns (bool)`
  - Constants `DEADLINE = 4 days`, `UNWIND_FILL_TIMEOUT = 1 hours`.
  - Events `RedemptionRequested(address indexed comptroller, address indexed investor, uint256 indexed id, uint256 shares, Mode mode)`, `RedemptionCancelled(address indexed comptroller, address indexed investor, uint256 indexed id)`, `UnwinderApproved(address indexed unwinder, bool approved)`, `UnwinderSwitched(address indexed unwinder, bool on)`.

- [ ] **Step 1: Write the failing tests** (fixture: `ComptrollerV3Test`'s setUp, but the factory's blueprint gets a real `RedemptionQueue(factory)`; deploy the queue with the factory address computed first, or give the queue a one-time `setFactory` callable by its owner before use — pick the one-time setter, `factory` then immutable in storage via a `factorySet` guard)

```solidity
	function test_request_escrowsShares_andRecordsOldestFirst() public { /* alice then bob request; ids 0,1; queue holds both escrows; queueBounds = (0, 2) */ }
	function test_request_refusedForPureSpotFund() public { /* expectRevert NoExternalPositions */ }
	function test_request_oneOpenPerInvestor() public { /* second request reverts RequestExists */ }
	function test_request_refusedForForeignComptroller() public { /* a ComptrollerV3 bound to another queue → NotOurFund */ }
	function test_cancel_returnsShares_andAdvancesHead() public { /* alice cancels; shares back; bob is head */ }
	function test_cancel_refusedOnceUnwound() public { /* set unwound via Task 6 path; here: expectRevert after a forced unwind in Task 6 suite */ }
	function test_isOverdue_afterFourDays_only() public { /* false at 4 days, true at 4 days + 1 s; false after head cancels */ }
	function test_unwinder_guardianCanSwitchOnApprovedOnly() public { /* guardian on for unapproved → NotApproved; owner approves; guardian on ok; guardian off → OnlyOwner; owner off ok; withdraw approval switches off */ }
```

Write each test fully (assert balances, ids, events) — no empty bodies in the file.

- [ ] **Step 2: Run to verify they fail** — `forge test --match-contract RedemptionQueueTest` → compile errors.

- [ ] **Step 3: Implement** `RedemptionQueue` storage and these functions:

```solidity
	struct Book {
		Request[] requests;
		uint256 head; // oldest request that may still be open
		mapping(address investor => uint256) openIdPlusOne;
		uint64 unwoundAt; // last fallback unwind of this fund (0 = none pending)
		uint256 unwoundThrough; // requests [head, unwoundThrough) were unwound
	}
	mapping(address comptroller => Book) internal books;

	function _advanceHead(Book storage b) internal {
		uint256 h = b.head;
		while (h < b.requests.length && !b.requests[h].open) ++h;
		b.head = h;
	}

	function isOverdue(address comptroller) public view returns (bool) {
		Book storage b = books[comptroller];
		uint256 h = b.head;
		while (h < b.requests.length && !b.requests[h].open) ++h;
		return h < b.requests.length && block.timestamp > b.requests[h].requestedAt + DEADLINE;
	}
```

`requestRedeem`: check the fund (`factory.funds(comptroller)` non-zero and `ComptrollerV3(comptroller).redemptionQueue() == this`), `getExternalPositions().length > 0`, no open request, `shares > 0`; push the request; `shares().transferFrom(msg.sender, address(this), shares)` (the comptroller still applies the shares-action timelock); emit. `cancel`: open, not unwound; mark closed; clear `openIdPlusOne`; `_advanceHead`; transfer shares back; emit. Registry per the Interfaces block; `Ownable2Step` owner.

- [ ] **Step 4: Run tests** — all pass.

- [ ] **Step 5: Checkpoint.**

---

### Task 4: RedemptionQueue — valuation and `settle` (cash and in kind)

**Files:**
- Create: `src/redemption/RedemptionMath.sol` (pure payout math, library)
- Modify: `src/redemption/RedemptionQueue.sol`
- Test: `test/RedemptionMath.t.sol`, `test/RedemptionQueueSettle.t.sol`

**Interfaces:**
- Produces:
  - `struct Snapshot { address denom; uint256 supply; address[] assets; uint256[] balances; uint256[] values; bool[] inKind; uint256 positionsValue; }` (`inKind` = pool-priced or unreadable)
  - `function RedemptionMath.cashPayout(Snapshot memory s, uint256 shares) internal pure returns (uint256 usdc, uint256[] memory inKindAmounts)`
  - `function RedemptionMath.inKindPayout(Snapshot memory s, uint256 shares) internal pure returns (uint256 usdc, uint256[] memory amounts)`
  - `function settle(address comptroller, uint256 maxRequests) external returns (uint256 settled)`
  - Event `RedemptionSettled(address indexed comptroller, address indexed investor, uint256 indexed id, uint256 shares, uint256 usdcPaid, address[] assets, uint256[] amounts, uint256 forfeitedValue)`

Math (all `Math.mulDiv`, rounding down), `f = shares / supply`:
- Cash: `usdc = f × (Σ values[i] where !inKind[i] + positionsValue)`; `inKindAmounts[i] = f × balances[i]` where `inKind[i]`.
- In kind: `usdc = f × (balance(denom) + positionsValue)`; `amounts[i] = f × balances[i]` for every asset except `denom`.

- [ ] **Step 1: Failing math tests** (`test/RedemptionMath.t.sol`)

```solidity
	function test_cash_paysValueInUsdc_andLongTailInKind() public pure {
		// vault: 1,000 USDC (value 1,000), 1 WETH (value 2,000), 500 TKN pool-priced (value 500); positions 3,000
		RedemptionMath.Snapshot memory s = _snap(1_000e6, 2_000e6, 500e6, 3_000e6, 100e18);
		(uint256 usdc, uint256[] memory k) = RedemptionMath.cashPayout(s, 10e18); // 10%
		assertEq(usdc, 600e6); // 10% of (1,000 + 2,000 + 3,000)
		assertEq(k[2], 50e6); // 10% of 500 TKN, in kind
		assertEq(k[1], 0); // WETH is paid in cash
	}

	function test_inKind_paysTokensPlusPositionShareInUsdc() public pure {
		RedemptionMath.Snapshot memory s = _snap(1_000e6, 2_000e6, 500e6, 3_000e6, 100e18);
		(uint256 usdc, uint256[] memory a) = RedemptionMath.inKindPayout(s, 10e18);
		assertEq(usdc, 400e6); // 10% of (1,000 vault USDC + 3,000 positions)
		assertEq(a[1], 0.1e18); // 10% of 1 WETH
		assertEq(a[2], 50e6); // 10% of 500 TKN
	}

	function testFuzz_neverPaysMoreThanTheShare(uint256 shares, uint256 supply) public pure {
		supply = bound(supply, 1e18, 1e30);
		shares = bound(shares, 1, supply);
		RedemptionMath.Snapshot memory s = _snap(1_000e6, 2_000e6, 500e6, 3_000e6, supply);
		(uint256 usdc,) = RedemptionMath.cashPayout(s, shares);
		assertLe(usdc, Math.mulDiv(6_000e6, shares, supply));
	}
```

- [ ] **Step 2: Run, verify fail; Step 3: implement `RedemptionMath`; Step 4: run, pass.**

- [ ] **Step 5: Failing settle tests** (`test/RedemptionQueueSettle.t.sol`, V3 funds holding a `MockUnwindPosition`)

```solidity
	function test_settle_waitsUntilTheVaultCanPay_thenPaysAtSettlementNav() public {
		// fund 10,000: vault 2,000 USDC, position 8,000 locked; alice requests 50% in kind, needing
		// 50% × (2,000 + 8,000) = 5,000 USDC → settle reverts NothingSettled
		// manager closes 3,000 and returns it (callOnExternalPosition) → vault 5,000 → settle pays alice 5,000 USDC
	}
	function test_settle_oldestFirst_stopsAtFirstUnpayable() public { /* alice cash (big) then bob in kind (small): vault covers bob only → settles 0 */ }
	function test_settle_twoRequests_eachPaidAsIfAlone() public { /* Review Focus 3: compare to two separate settles */ }
	function test_settle_cashPaysPumpedPoolPricedTokenInKind() public { /* Review Focus 1 */ }
	function test_settle_feesSettledFirst_escrowBearsFees() public { /* mgmt fee fund; escrowed shares diluted like alice's */ }
	function test_settle_isPermissionless() public { /* attacker calls settle; alice receives */ }
	function test_settle_clearsOverdue_andFeesResume() public { /* Review Focus 4 with the real queue */ }
```

Write each body fully with exact numbers before implementing.

- [ ] **Step 6: Implement `settle`** in `RedemptionQueue`:
  1. `_advanceHead`; if the head request is unwound, run Task 6's `_settleUnwound` first (stub that reverts `UnwindPending()` until Task 6).
  2. `ComptrollerV3(comptroller).settleFees()`.
  3. Build the snapshot: `getTrackedAssets()`, vault balances, `valueInterpreter().calcCanonicalAssetValue` in try/catch (unreadable → `inKind`), `registrar().poolPricedAdapter(asset) != 0` → `inKind`, positions via `FundValuation.positionValue(position, ctx)`; `supply = shares().totalSupply()`.
  4. Loop from head up to `maxRequests`: compute the payout from the snapshot (same `supply` for all: pro-rata payouts leave per-share value unchanged), track `usdcLeft`; stop at the first request needing more USDC than left; else `payOutRedemption(investor, shares, assets, amounts)` with the USDC amount added at the denom's index; mark closed; emit.
  5. Revert `NothingSettled()` when zero requests were paid (keeps the keeper's simulation honest).

- [ ] **Step 7: Run all queue tests; Step 8: Checkpoint.**

---

### Task 5: Invariant test for settle

**Files:**
- Test: `test/invariant/RedemptionQueueInvariant.t.sol`

**Interfaces:**
- Consumes: Tasks 2–4.

- [ ] **Step 1: Write the handler and invariants**

Handler actions: `request(actor, shares, mode)`, `cancel(actor)`, `managerReturns(amount)` (manager closes and returns USDC from the mock position), `settle()`, `warp(dt)`. Invariants:
- `invariant_noRedeemerOverpaid`: for every settled request, `usdcPaid + Σ value(in-kind amounts) ≤ shares × NAV_at_settlement / supply + 1` (tracked by the handler from the event).
- `invariant_fifo`: a request is never settled while an older one is open.
- `invariant_escrowMatches`: queue share balance == Σ open requests' shares.

- [ ] **Step 2: Run** `forge test --match-path test/invariant/RedemptionQueueInvariant.t.sol` → pass (fix code, not invariants, on failure).
- [ ] **Step 3: Checkpoint.**

---

### Task 6: Fallback unwind in the queue

**Files:**
- Create: `src/interfaces/IRedemptionUnwinder.sol`
- Modify: `src/redemption/RedemptionQueue.sol`, `src/redemption/RedemptionMath.sol`
- Create: `test/utils/MockUnwinder.sol`
- Test: `test/RedemptionQueueUnwind.t.sol`

**Interfaces:**
- Produces:

```solidity
interface IRedemptionUnwinder {
	/// @notice True for a position this unwinder knows how to unwind.
	function supports(address position) external view returns (bool);
	/// @notice Actions that close `fractionWad` (1e18 = all) of the position, pro rata.
	function closeActions(address position, uint256 fractionWad) external view returns (bytes[] memory);
	/// @notice The action that returns the position's idle value to the fund's vault (empty = none).
	function collectAction(address position) external view returns (bytes memory);
	/// @notice True while a close sent to the venue is still waiting for its fill.
	function hasPending(address position) external view returns (bool);
}
```

- `function unwindOverdue(address comptroller) external` — requires an unwinder switched on; marks every overdue open request from the head as `unwound` (`unwoundThrough`), records `unwoundAt`; `F = Σ unwound shares / supply`; for each fund position and each switched-on unwinder that `supports` it, forwards each `closeActions(position, F)` via `forwardUnwind` inside try/catch (a failing close emits `UnwindCloseFailed(position, reason)` and is covered at settle). Emits `RedemptionsUnwound(address indexed comptroller, uint256 throughId, uint256 fractionWad)`.
- `RedemptionMath.fallbackPayout(Snapshot memory s, uint256 shares, uint256 usdcLeft, uint256[] memory remaining) internal pure returns (uint256 usdc, uint256[] memory amounts, uint256 forfeitedValue)`: in kind `f × balances[i]` (non-denom); USDC `min(f × (balance(denom) + positionsValue), usdcLeft)`; shortfall covered from `remaining` non-denom tokens that are not `inKind` (Deviation 3), pro rata by value, capped by what remains; the rest is `forfeitedValue`.

- [ ] **Step 1: Failing tests**

```solidity
	function test_unwind_refusedWhileSwitchedOff() public { /* overdue; expectRevert UnwinderOff */ }
	function test_unwind_refusedBeforeDeadline() public { /* switched on; expectRevert NotOverdue */ }
	function test_unwind_closesTheOverdueFraction_only() public {
		// fund 10,000: vault 2,000, position 8,000 locked; alice 50% overdue, bob 10% not overdue
		// unwind → position closes 50% × 8,000 = 4,000 (MockUnwinder asks for fraction × locked)
		// bob's request untouched; alice can no longer cancel (expectRevert Unwound)
	}
	function test_settleUnwound_waitsForFillsOrTimeout() public { /* MockUnwinder.hasPending true → UnwindPending; after 1 hour proceeds */ }
	function test_settleUnwound_collects_thenPaysFullValue() public {
		// after unwind: collect returns 4,000 to the vault; alice (50%, cash request) gets
		// 50% of vault tokens in kind + USDC up to 50% × (vault USDC + positions) = 5,000
	}
	function test_settleUnwound_closeThatFailed_coveredFromVaultTokens() public {
		// MockUnwinder returns a close the position rejects (Review Focus 5): alice still paid full value,
		// shortfall covered with WETH from the vault at VI price; forfeited 0
	}
	function test_settleUnwound_lpShare_coveredAtFullValue_restForfeited() public {
		// a second position the unwinder doesn't support (an LP stand-in) worth 3,000; vault tokens cover part;
		// event reports the exact forfeited value
	}
	function test_unwind_neverMovesValueOutsideTheFund() public {
		// a malicious MockUnwinder returning a non-risk-reducing action: forwardUnwind reverts NotRiskReducing,
		// caught → UnwindCloseFailed; vault + position totals unchanged
	}
```

Write all bodies with exact numbers.

- [ ] **Step 2: Run, fail; Step 3: implement `unwindOverdue`, `_settleUnwound` (collect via `collectAction` per supported position through `forwardUnwind`, then `fallbackPayout` for each unwound request, then continue normal settlement), `fallbackPayout`; Step 4: run, pass.**
- [ ] **Step 5: Checkpoint.**

---

### Task 7: PerpUnwinder (real Veranta, fork-tested)

**Files:**
- Create: `src/redemption/PerpUnwinder.sol`
- Test: `test/fork/PerpUnwinderFork.t.sol`

**Interfaces:**
- Consumes: `IRedemptionUnwinder` (Task 6); `IVerantaTradingStorage`, `IVerantaMulticall`, `IVerantaPairStorage` (`src/interfaces/external/IVeranta.sol`); `VerantaPriceStore.latest(pair)`.
- Produces: `PerpUnwinder(address perpConfig, VerantaPriceStore store, IVerantaTradingStorage tradingStorage, IVerantaMulticall multicall, address pairStorage, IERC20 usdc)` implementing `IRedemptionUnwinder`:
  - `supports(p)`: `staticcall positionFactory()` returns `perpConfig`.
  - `closeActions(p, F)`: for each pair `< pairsCount`, if `openTradesCount(p, pair) > 0`, read slots `< maxTradesPerPair` until counted; per trade `amount = initialPosToken × F / 1e18`; if `(initialPosToken − amount) × leverage / 1e10 < pairMinLevPosUSDC(pair)` then `amount = initialPosToken`; `wantedPrice` = stored price in 1e10, refusing one older than 120 s (`StalePrice(pair)`); action `abi.encode(uint8(1), abi.encode(pair, index, amount, wantedPrice))`.
  - `collectAction(p)`: `abi.encode(uint8(6), abi.encode(usdc.balanceOf(p)))`, empty when zero.
  - `hasPending(p)`: `multicall.getPendingOrder(p).length > 0`.
- `pairMinLevPosUSDC(uint256)` is read with a low-level call on PairStorage (selector verified on Base 2026-10-06: returns 100e6 for pair 81); add it to `IVerantaPairStorage`.

- [ ] **Step 1: Fork tests** (pinned `FORK_BLOCK = 52_014_634`, the ETH packet and operator fill helpers from `VerantaPerpPositionV3Fork.t.sol` copied in):
  - `test_fork_supports_perpAccount_notOthers` (V3 account true; a `MockUnwindPosition` false).
  - `test_fork_closeActions_halfOfEveryTrade` (5× ETH long 199.5725 USDC; F = 0.5 → amount 99,786,250).
  - `test_fork_closeActions_closesAllUnderTheMinimum` (30 USDC 5×; F = 0.5 leaves 75 < 100 → whole trade).
  - `test_fork_closeActions_refusesStalePrice` (warp 121 s past the stored price → `StalePrice`).
  - `test_fork_fullFallback_realFill` (V3 fund on the fork with the real queue and unwinder switched on: alice requests 50% in kind, deadline passes, Multicall store.submit + unwindOverdue, operator fills, settle → alice paid within 1% of half the fund's value, the trade halved).
  - `test_fork_managerProRataUnwind_keepsHedgeRatio` (fund holds WETH and a short of equal size; manager closes F of the short and returns USDC; settle in kind; remaining WETH : short ratio unchanged within rounding).
- [ ] **Step 2: Implement; Step 3: run with `BASE_MAINNET_RPC` and `BASE_FORK_BLOCK=52014634`; Step 4: checkpoint.**

---

### Task 8: Deploy script and fork rehearsal

**Files:**
- Create: `script/mainnet/DeployRedemptionQueue.s.sol`
- Test: `test/fork/RedemptionQueueDeployFork.t.sol`

**Interfaces:**
- Produces: script `run()` deploying `RedemptionQueue(owner = deployer)`, setting its factory, `PerpUnwinder` (addresses from `FundsMainnet` and `deployments/base-mainnet-veranta.json`), `approveUnwinder(unwinder, true)` (left **off**), `ComptrollerBlueprintDeployer(type(ComptrollerV3).creationCode, abi.encode(registrar, queue))`; writes `deployments/base-mainnet-redemption.json` (`queue`, `perpUnwinder`, `fundV3Deployer`). It does **not** call `setComptrollerDeployer` (a separate reviewed step).
- [ ] **Step 1: Fork rehearsal test:** run the script's body as the deployer on live state, then `factory.setComptrollerDeployer(fundV3Deployer)` as the owner, create a V3 fund, open a perp account, request, settle after the manager returns cash; assert the unwinder is approved but off.
- [ ] **Step 2: Dry-run the script against mainnet** (`forge script ... --sender <deployer>`, no `--broadcast`) and record the addresses it would deploy.
- [ ] **Step 3: Checkpoint.**

---

### Task 9: Governance handoff and docs

**Files:**
- Modify: `script/mainnet/FundsGovernance.sol` (queue `transferOwnership` to the timelock; `acceptOwnership` scheduled like the factory's)
- Modify: `test/fork/GovernanceHandoffFork.t.sol` (queue owned by the timelock after the rehearsal)
- Modify: `README.md` hard rules #2 and #6

- [ ] **Step 1:** Rule #2 → "Deposits are async (request → execute). Funds holding external positions redeem through the RedemptionQueue (request → settle once the vault can pay); pure-spot funds redeem instantly." Rule #6 → "Funds with external positions redeem through the RedemptionQueue (cash or in kind at settlement NAV); the in-kind exit stays open always and forfeits external positions. Exits are never gated by the protocol, a pause or the guardian."
- [ ] **Step 2:** Handoff script and rehearsal; run `BASE_MAINNET_RPC=… forge test --match-path test/fork/GovernanceHandoffFork.t.sol`.
- [ ] **Step 3: Full suite** `forge test` and `forge build --sizes`; checkpoint.
