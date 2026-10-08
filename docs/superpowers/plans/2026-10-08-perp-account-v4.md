# Perp account V4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `VerantaPerpPositionV4` (held-pairs valuation, close costs in NAV, manager AddMargin, unmapped held pair reverts), its type factory, deploy script, fork proofs, and the terminal's add-margin + held-pairs reads.

**Architecture:** V4 is a standalone copy of V3 (versioned contracts sit side by side because deployed instances are immutable) bound to the same shared config (the deployed V2 factory). A `EnumerableSet.UintSet` of held pairs drives valuation while no keeper is delegated; a full walk runs while one is, and RemoveAutopilot re-syncs the list. Close costs are read live from Veranta's PairStorage. The terminal detects V4 by `heldPairs()`.

**Tech Stack:** Solidity 0.8.24, OpenZeppelin 5.x, Foundry (unit + Base fork tests); Next.js 16 / wagmi / viem / vitest (terminal).

**Spec:** `funds-core/docs/superpowers/specs/2026-10-08-perp-account-v4-design.md`

## Global Constraints

- Action ordinals 0–7 unchanged; `CloseTrade = 1`, `ReturnToVault = 6` stay risk-reducing; `AddMargin = 8` is NOT risk-reducing.
- `positionFactory()` returns the deployed V2 factory (`deployments/base-mainnet.json .verantaFactory`, `0x6B15…D8a9`).
- Hard rule 4: every Veranta state of the account is valued or valuation reverts.
- Tabs, single quotes, explicit types; comments carry the why with dates (`// spec 2026-10-08 §3.3`).
- No `git add`/`commit`/`push`, no mainnet broadcast (founder does both). Branches: funds-core `feat/perp-account-v4` (exists), frosty-terminal `feat/perp-account-v4` via `git checkout --no-track -b feat/perp-account-v4 origin/main`.
- Fork tests `return`/`skip` without `BASE_MAINNET_RPC`; the archive RPC is `BASE_RPC_URL` from `funds-core/.env`.
- `VerantaPerpPositionV4Factory` runtime < 24,576 bytes (`forge build --sizes`).
- No untracked artifacts left in either repo except the intended new files.

## Review Focus

1. Keeper rotation: SetAutopilot with a different keeper while one is delegated must remove the old delegation on Veranta, or a rotated-out keeper could open trades list mode never sees (Task 2 test `test_setAutopilot_rotationRemovesTheOldKeeper`).
2. RemoveAutopilot while a keeper-opened market order is still PENDING: the sync must list that pair so the fill is valued (Task 2 test `test_removeAutopilot_syncListsAPendingKeeperOrder`).
3. Pruning must keep a pair whose trade is being market-closed (still counted by `openTradesCount`) and a pair with only a resting limit order (Task 2 tests `test_prune_keepsAPairWithALimitOrderOnly`, `test_prune_dropsAnEmptyPairAfterCancel`).
4. An unmapped pair the account holds nothing on must not revert valuation (full-walk mode reads every pair) (Task 2 test `test_unmappedPair_withNothingHeld_doesNotRevert`).
5. Close cost on a trade past liquidation: signed math must not underflow; the comptroller's per-position zero floor still applies (Task 3 test `test_closeCost_deepLoser_floorsAtZero`).

---

### Task 1: Veranta cost interface + mock support

**Files:**
- Modify: `src/interfaces/external/IVeranta.sol` (append `IVerantaPairCosts`)
- Modify: `test/utils/MockVeranta.sol` (close fee, spread, `pairs`, margin fee record)

**Interfaces:**
- Produces: `IVerantaPairCosts.pairCloseFeeP(uint256 pairIndex, uint256 positionSizeCoinOi, bool buy) view returns (uint256)`; `IVerantaPairCosts.pairs(uint256) view returns (uint256 maxOpenDeviationP, uint256 maxCloseDeviationP, bytes32 feedId, uint256 backupMaxDeviationP, address backupFeed, uint256 spreadP)`; mock `setCloseFeeP(uint256 pairIndex, uint256 p)`, `setSpreadP(uint256 pairIndex, uint256 p)`, `marginFeesPaid() returns (uint256)`.

- [ ] **Step 1: Append the interface**

```solidity
/// @notice Veranta PairStorage cost reads (impl 0x2511…cad0, verified source, read 2026-10-08). 1e10 = 1%.
interface IVerantaPairCosts {
	/// @dev Non-view in Veranta's own interface (it delegatecalls an extension) but it writes nothing:
	///      it runs inside a static call (fork probe 2026-10-08, ≈10k gas).
	function pairCloseFeeP(uint256 pairIndex, uint256 positionSizeCoinOi, bool buy) external view returns (uint256);

	/// @dev The public `pairs` getter's leading static fields (Feed{maxOpenDeviationP, maxCloseDeviationP,
	///      feedId}, BackupFeed{maxDeviationP, feedId}, spreadP); the fields after spreadP are ignored.
	function pairs(uint256 pairIndex)
		external
		view
		returns (
			uint256 maxOpenDeviationP,
			uint256 maxCloseDeviationP,
			bytes32 feedId,
			uint256 backupMaxDeviationP,
			address backupFeed,
			uint256 spreadP
		);
}
```

- [ ] **Step 2: Extend MockVeranta** (inside the contract, after `setFundingFee`; defaults 0 keep every V2/V3 test unchanged)

```solidity
	/// @dev Veranta PairStorage cost reads (IVerantaPairCosts): per-pair close fee and base spread, 1e10 = 1%
	mapping(uint256 => uint256) public closeFeeOf;
	mapping(uint256 => uint256) public spreadOf;
	/// @dev msg.value the margin path received (the Lazer verification fee)
	uint256 public marginFeesPaid;

	function setCloseFeeP(uint256 pairIndex, uint256 p) external {
		closeFeeOf[pairIndex] = p;
	}

	function setSpreadP(uint256 pairIndex, uint256 p) external {
		spreadOf[pairIndex] = p;
	}

	function pairCloseFeeP(uint256 pairIndex, uint256, bool) external view returns (uint256) {
		return closeFeeOf[pairIndex];
	}

	function pairs(uint256 pairIndex) external view returns (uint256, uint256, bytes32, uint256, address, uint256) {
		return (0, 0, bytes32(0), 0, address(0), spreadOf[pairIndex]);
	}
```

and in `updateMargin`, first line of the body: `marginFeesPaid += msg.value;`

- [ ] **Step 3: Build and run the V2 suite (must stay green)**

Run: `forge build && forge test --match-contract VerantaPerpV2Test`
Expected: PASS (all existing tests).

### Task 2: VerantaPerpPositionV4 — held pairs, modes, unmapped revert, order type

**Files:**
- Create: `src/positions/VerantaPerpPositionV4.sol`
- Test: `test/VerantaPerpV4.t.sol`

**Interfaces:**
- Consumes: Task 1 `IVerantaPairCosts`, mock setters.
- Produces: `VerantaPerpPositionV4(address comptroller_, VerantaPerpPositionV2Factory config)`, `VerantaPerpPositionV4.Action` (…`LinkReferral = 7`, `AddMargin = 8`), `heldPairs() returns (uint256[])`, errors `PairUnmapped(uint256)`, `UnsupportedOrderType(uint8)`, `FeeBalanceTooLow(uint256,uint256)`, events `HeldPairAdded(uint256 indexed)`, `HeldPairRemoved(uint256 indexed)`, `SyncedHeldPairs(uint256)`, `MarginAdded(uint256 indexed,uint256,uint256)`; `VerantaPerpPositionV4Factory(VerantaPerpPositionV2Factory config_)` with `config()` and `deployPosition(address, bytes)`.

- [ ] **Step 1: Write the test file** — setUp copied from `test/VerantaPerpV2.t.sol` (same mock, same V1 `Comptroller` fund), registering `new VerantaPerpPositionV4Factory(positionFactory)` as type 6; helpers `_createPosition`, `_none`, `_call`, `_openStandardTrade(position, buy)` (1,000 USDC, ETH pair 1, 2×, $2,500) and `_keeperOpen(position, pairIndex, buy)` (SetAutopilot funded with 1,000 USDC, then `veranta.delegatedAction` openTrade as in V2's `test_v2_keeperOpenedTradeOnUntouchedPair_isValued`). Port V2's valuation/custody/referral cases with V4 types: `test_openTrade_pendingOrderValuedAtCollateral`, `test_cancelPendingMarketOrder_refundsPosition`, `test_openTrade_rejectsUnmappedPair`, `test_openTrade_rejectsUnsupportedUnderlying`, `test_shortHedge_gavFlatAtEntry_thenTracksPriceInverse`, `test_longTrade_gavTracksPrice`, `test_accruedFeesReduceValue_fundingCreditIncreasesIt`, `test_closeTrade_refundsAndGavHolds`, `test_setAutopilot_delegatesPinnedKeeper`, `test_removeAutopilot_revertsWhenInactive`, `test_returnToVault_onlyDestinationIsVault`, `test_receiveCallFromFund_onlyComptroller`, `test_linkReferral_linksTheProtocolCodeAsThePosition`, `test_unknownAction_reverts`, `test_restingLimitOrder_valuedAtEscrow`, `test_twoTradesOnOnePair_bothValued`, `test_isRiskReducing_sameSetAsV3`. New cases:

```solidity
	function test_openTrade_listsThePairBeforeTheFill() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		uint256[] memory held = position.heldPairs();
		assertEq(held.length, 1);
		assertEq(held[0], ETH_PAIR);
		assertEq(comptroller.calcGav(), 10_000e6, 'pending escrow valued');
		veranta.fillPending(2_500e10);
		assertEq(position.heldPairs().length, 1);
		assertEq(comptroller.calcGav(), 10_000e6);
	}

	function test_listMode_readsOnlyListedPairs() public {
		veranta.setPairsCount(135);
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		vm.expectCall(address(veranta), abi.encodeWithSelector(veranta.openTradesCount.selector), 1);
		position.getManagedAssets();
	}

	function test_fullWalkMode_whileAKeeperIsDelegated() public {
		veranta.setPairsCount(135);
		VerantaPerpPositionV4 position = _createPosition();
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.SetAutopilot), abi.encode(block.timestamp + 30 days)));
		vm.expectCall(address(veranta), abi.encodeWithSelector(veranta.openTradesCount.selector), 135);
		position.getManagedAssets();
	}

	function test_keeperOpenedTrade_valuedInFullWalk_thenSyncedOnRemove() public {
		uint256 otherPair = 3;
		positionFactory.setPairAsset(otherPair, address(teth));
		VerantaPerpPositionV4 position = _createPosition();
		_keeperOpen(position, otherPair, false);
		veranta.fillPending(2_500e10);
		assertEq(position.heldPairs().length, 0, 'the account never saw it');
		assertEq(comptroller.calcGav(), 10_000e6, 'full walk values it');

		vm.expectEmit(address(position));
		emit VerantaPerpPositionV4.SyncedHeldPairs(1);
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.RemoveAutopilot), ''));
		assertEq(position.activeDelegate(), address(0));
		assertEq(position.heldPairs()[0], otherPair, 'synced into the list');
		tethFeed.setAnswer(3_000e8);
		assertEq(comptroller.calcGav(), 9_600e6, 'list mode still values it');
	}

	function test_removeAutopilot_syncListsAPendingKeeperOrder() public {
		uint256 otherPair = 3;
		positionFactory.setPairAsset(otherPair, address(teth));
		VerantaPerpPositionV4 position = _createPosition();
		_keeperOpen(position, otherPair, false); // still pending
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.RemoveAutopilot), ''));
		assertEq(position.heldPairs()[0], otherPair, 'a pending order lists its pair');
		veranta.fillPending(2_500e10);
		tethFeed.setAnswer(3_000e8);
		assertEq(comptroller.calcGav(), 9_600e6, 'the fill is valued in list mode');
	}

	function test_setAutopilot_rotationRemovesTheOldKeeper() public {
		VerantaPerpPositionV4 position = _createPosition();
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.SetAutopilot), abi.encode(block.timestamp + 30 days)));
		address keeper2 = makeAddr('keeper2');
		positionFactory.setAutopilotKeeper(keeper2);
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.SetAutopilot), abi.encode(block.timestamp + 30 days)));
		(bool oldEnabled,) = veranta.multipleDelegations(address(position), keeper);
		(bool newEnabled,) = veranta.multipleDelegations(address(position), keeper2);
		assertFalse(oldEnabled, 'one keeper at most');
		assertTrue(newEnabled);
		assertEq(position.activeDelegate(), keeper2);
	}

	function test_prune_dropsAnEmptyPairAfterCancel() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		vm.expectEmit(address(position));
		emit VerantaPerpPositionV4.HeldPairRemoved(ETH_PAIR);
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.CancelPendingMarketOrder), abi.encode(uint256(1))));
		assertEq(position.heldPairs().length, 0);
	}

	function test_prune_keepsAPairWithALimitOrderOnly() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.CancelPendingMarketOrder), abi.encode(uint256(1))));
		// list it again through an open, then leave only a resting limit order on it
		_openStandardTrade(position, false);
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.CancelPendingMarketOrder), abi.encode(uint256(2))));
		assertEq(position.heldPairs().length, 0);
		_openStandardTrade(position, false);
		vm.prank(address(position));
		usdc.approve(address(veranta), 1_000e6);
		// the refund of order 3 funds a limit order on the same pair
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.CancelPendingMarketOrder), abi.encode(uint256(3))));
		assertEq(position.heldPairs().length, 0);
		_openStandardTrade(position, false);
		veranta.pushLimitOrder(address(position), ETH_PAIR, 0, 0); // a zero-escrow resting order on the pair
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.CancelPendingMarketOrder), abi.encode(uint256(4))));
		assertEq(position.heldPairs().length, 1, 'kept: a limit order rests on it');
	}

	function test_unmappedHeldPair_revertsValuation() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		positionFactory.setPairAsset(ETH_PAIR, address(0));
		vm.expectRevert(abi.encodeWithSelector(VerantaPerpPositionV4.PairUnmapped.selector, ETH_PAIR));
		position.getManagedAssets();
		// closing still works (unpriced, risk-reducing)
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.CloseTrade), abi.encode(ETH_PAIR, uint256(0), uint256(1_000e6), uint256(2_500e10))));
		assertEq(usdc.balanceOf(address(position)), 1_000e6);
	}

	function test_unmappedPair_withNothingHeld_doesNotRevert() public {
		VerantaPerpPositionV4 position = _createPosition();
		_call(position, abi.encode(uint8(VerantaPerpPositionV4.Action.SetAutopilot), abi.encode(block.timestamp + 30 days)));
		positionFactory.setPairAsset(ETH_PAIR, address(0)); // full walk reads pair 1, which holds nothing
		position.getManagedAssets();
		assertEq(comptroller.calcGav(), 10_000e6);
	}

	function test_openTrade_refusesTheZeroFeePnlOrderType() public {
		VerantaPerpPositionV4 position = _createPosition();
		address[] memory transferAssets = new address[](1);
		transferAssets[0] = address(usdc);
		uint256[] memory transferAmounts = new uint256[](1);
		transferAmounts[0] = 1_000e6;
		(address[] memory noAssets,) = _none();
		bytes memory open = abi.encode(
			uint8(VerantaPerpPositionV4.Action.OpenTrade),
			abi.encode(ETH_PAIR, uint256(1_000e6), uint256(2e10), false, uint256(2_500e10), uint256(1e10), uint8(3), uint256(0), uint256(0))
		);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(VerantaPerpPositionV4.UnsupportedOrderType.selector, 3));
		comptroller.callOnExternalPosition(address(position), transferAssets, transferAmounts, noAssets, open);
	}

	function test_factory_deploysV4BoundToTheSharedConfig() public {
		VerantaPerpPositionV4 position = _createPosition();
		assertEq(address(position.positionFactory()), address(positionFactory));
		assertEq(address(v4Factory.config()), address(positionFactory));
	}
```

(`test_prune_keepsAPairWithALimitOrderOnly` is written in the execution as the shortest sequence that leaves only a limit order on a listed pair: open (lists ETH), `pushLimitOrder` from the account's idle USDC, cancel the pending market order → the pair stays listed.)

- [ ] **Step 2: Run to see it fail**

Run: `forge test --match-contract VerantaPerpV4Test`
Expected: compile error, `VerantaPerpPositionV4` not found.

- [ ] **Step 3: Write `src/positions/VerantaPerpPositionV4.sol`** — V3's body (constructor, referral link, `isRiskReducing`, `_openTrade`, `getManagedAssets`/`getDebtAssets`, `_side`) carried over unchanged, plus:

```solidity
	using EnumerableSet for EnumerableSet.UintSet;

	/// @dev 0 market, 1 stop-limit, 2 limit. 3 = MARKET_PNL (zero-fee trades that pay a profit share
	///      on close) is refused: valuation doesn't model the profit share (spec 2026-10-08 §3.4)
	uint8 internal constant MAX_ORDER_TYPE = 2;

	/// @notice The keeper currently delegated on Veranta (0 = autopilot off). Non-zero switches
	///         valuation to a walk over every Veranta pair (spec §3.1).
	address public activeDelegate;
	/// @dev Pairs the manager opened or ordered on, plus every held pair found when a keeper
	///      delegation ends; read alone while no keeper is delegated (spec §3.1).
	EnumerableSet.UintSet internal _heldPairs;

	/// @notice The listed pairs (list mode reads only these); the terminal uses it to tell V4 apart.
	function heldPairs() external view returns (uint256[] memory) {
		return _heldPairs.values();
	}
```

`receiveCallFromFund`: V3's branches, with SetAutopilot / RemoveAutopilot replaced by

```solidity
		} else if (rawAction == uint8(Action.SetAutopilot)) {
			uint256 expiry = abi.decode(args, (uint256));
			address keeper = positionFactory.autopilotKeeper();
			address previous = activeDelegate;
			// one keeper at most (spec §3.1): a rotated-out keeper keeps no delegation that list
			// mode, entered only through RemoveAutopilot's sync, could miss trades from
			if (previous != address(0) && previous != keeper) {
				router.removeDelegate(previous);
				emit AutopilotRemoved(previous);
			}
			router.setDelegate(keeper, expiry);
			activeDelegate = keeper;
			emit AutopilotSet(keeper, expiry);
		} else if (rawAction == uint8(Action.RemoveAutopilot)) {
			address delegate = activeDelegate;
			if (delegate == address(0)) revert AutopilotNotActive();
			router.removeDelegate(delegate);
			activeDelegate = address(0);
			emit AutopilotRemoved(delegate);
			// the keeper may have opened trades the account never saw: list every held pair
			_syncHeldPairs();
```

and `_pruneHeldPairs();` after the if/else chain. `_openTrade` starts with
`if (a.orderType > MAX_ORDER_TYPE) revert UnsupportedOrderType(a.orderType);` and calls `_addHeldPair(a.pairIndex)` right before `router.openTrade`. Helpers:

```solidity
	function _addHeldPair(uint256 pairIndex) internal {
		if (_heldPairs.add(pairIndex)) emit HeldPairAdded(pairIndex);
	}

	/// @dev Drop listed pairs with no trade, no limit order and no pending market order.
	///      Backwards: EnumerableSet.remove moves the last element into the freed slot.
	function _pruneHeldPairs() internal {
		uint256 n = _heldPairs.length();
		if (n == 0) return;
		IVerantaMulticall.PendingOrder[] memory pending = verantaMulticall.getPendingOrder(address(this));
		for (uint256 i = n; i > 0; --i) {
			uint256 pairIndex = _heldPairs.at(i - 1);
			if (_holds(pairIndex, pending)) continue;
			_heldPairs.remove(pairIndex);
			emit HeldPairRemoved(pairIndex);
		}
	}

	/// @dev One walk over every Veranta pair: list each one holding anything (spec §3.1).
	function _syncHeldPairs() internal {
		IVerantaMulticall.PendingOrder[] memory pending = verantaMulticall.getPendingOrder(address(this));
		uint256 pairs = pairStorage.pairsCount();
		for (uint256 pairIndex; pairIndex < pairs; ++pairIndex) {
			if (_holds(pairIndex, pending)) _addHeldPair(pairIndex);
		}
		emit SyncedHeldPairs(_heldPairs.length());
	}

	function _holds(uint256 pairIndex, IVerantaMulticall.PendingOrder[] memory pending) internal view returns (bool) {
		if (tradingStorage.openTradesCount(address(this), pairIndex) > 0) return true;
		if (tradingStorage.openLimitOrdersCount(address(this), pairIndex) > 0) return true;
		for (uint256 i; i < pending.length; ++i) {
			if (pending[i].orderInfo.trade.pairIndex == pairIndex) return true;
		}
		return false;
	}
```

Valuation:

```solidity
	function _valuation() internal view returns (int256 usdcNet, address[] memory tokens, int256[] memory tokenAmts) {
		usdcNet = int256(usdc.balanceOf(address(this)));
		// escrowed collateral of in-flight market opens (a cheap per-trader list, every pair)
		IVerantaMulticall.PendingOrder[] memory pending = verantaMulticall.getPendingOrder(address(this));
		for (uint256 i; i < pending.length; ++i) {
			usdcNet += int256(pending[i].orderInfo.trade.positionSizeUSDC);
		}

		uint256[] memory pairs = _pairsToValue();
		uint256 maxSlots = tradingStorage.maxTradesPerPair();
		tokens = new address[](pairs.length);
		tokenAmts = new int256[](pairs.length);
		for (uint256 i; i < pairs.length; ++i) {
			(int256 usdcDelta, int256 units, address asset) = _valuePair(pairs[i], maxSlots);
			usdcNet += usdcDelta;
			if (units == 0) continue;
			// Merge same-underlying legs (pairs sharing an asset)
			bool merged;
			for (uint256 j; j < i; ++j) {
				if (tokens[j] == asset) {
					tokenAmts[j] += units;
					merged = true;
					break;
				}
			}
			if (!merged) {
				tokens[i] = asset;
				tokenAmts[i] = units;
			}
		}
	}

	/// @dev List mode while no keeper is delegated; every pair while one is (it can open trades
	///      through Veranta's delegatedAction that the account never sees) — spec §3.1, option A.
	function _pairsToValue() internal view returns (uint256[] memory pairs) {
		if (activeDelegate == address(0)) return _heldPairs.values();
		pairs = new uint256[](pairStorage.pairsCount());
		for (uint256 i; i < pairs.length; ++i) {
			pairs[i] = i;
		}
	}
```

`_valuePair(uint256 pairIndex, uint256 maxSlots) returns (int256 usdcDelta, int256 units, address asset)`: V3's two count reads and early `return (0, 0, address(0))`; then `asset = positionFactory.pairAsset(pairIndex); if (asset == address(0)) revert PairUnmapped(pairIndex);` (spec §3.2 comment) and `uint8 decimals = IERC20Metadata(asset).decimals();`, then V3's slot loop calling `_valueTrade(t, pairIndex, slot, decimals)` and the `ValuationIncomplete` check. `_valueTrade` is V3's with `asset` replaced by the passed `decimals` (units always computed).

Factory:

```solidity
/// @title VerantaPerpPositionV4Factory
/// @notice Stateless, ownerless type factory for V4 perp accounts, bound to `config` (the deployed
///         VerantaPerpPositionV2Factory: pair map, autopilot keeper, referral).
contract VerantaPerpPositionV4Factory is IExternalPositionTypeFactory {
	VerantaPerpPositionV2Factory public immutable config;

	error ZeroAddress();

	constructor(VerantaPerpPositionV2Factory config_) {
		if (address(config_) == address(0)) revert ZeroAddress();
		config = config_;
	}

	/// @inheritdoc IExternalPositionTypeFactory
	function deployPosition(address comptroller, bytes calldata) external returns (address position) {
		position = address(new VerantaPerpPositionV4(comptroller, config));
	}
}
```

- [ ] **Step 4: Run the suite**

Run: `forge test --match-contract VerantaPerpV4Test -vv`
Expected: PASS (every case above + the ported V2 cases).

### Task 3: Close costs in valuation

**Files:**
- Modify: `src/positions/VerantaPerpPositionV4.sol` (`_valuePair`, `_valueTrade`)
- Test: `test/VerantaPerpV4.t.sol`

**Interfaces:**
- Consumes: Task 1 `IVerantaPairCosts`, mock `setCloseFeeP`/`setSpreadP`.

- [ ] **Step 1: Failing tests**

```solidity
	/// 2× short of 1,000 USDC = 2,000 size; close fee 0.01% (1e8) + spread 0.05% (5e8) = 0.06% → 1.2 USDC
	function test_closeCost_feePlusSpreadOffEachTrade() public {
		veranta.setCloseFeeP(ETH_PAIR, 1e8);
		veranta.setSpreadP(ETH_PAIR, 5e8);
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		assertEq(comptroller.calcGav(), 10_000e6 - 1.2e6);
	}

	function test_closeCost_longsPayItToo() public {
		veranta.setCloseFeeP(ETH_PAIR, 1e8);
		veranta.setSpreadP(ETH_PAIR, 1e8);
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, true);
		veranta.fillPending(2_500e10);
		assertEq(comptroller.calcGav(), 10_000e6 - 0.4e6);
	}

	function test_closeCost_pendingOrderPaysNone() public {
		veranta.setCloseFeeP(ETH_PAIR, 1e8);
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		assertEq(comptroller.calcGav(), 10_000e6, 'escrow at face value until the fill');
	}

	function test_closeCost_deepLoser_floorsAtZero() public {
		veranta.setCloseFeeP(ETH_PAIR, 1e8);
		veranta.setSpreadP(ETH_PAIR, 1e8);
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		tethFeed.setAnswer(5_000e8); // the 2× short lost 2,000 on 1,000 collateral
		assertEq(comptroller.calcGav(), 9_000e6, 'position floors at zero, nothing reverts');
	}
```

- [ ] **Step 2: Run** — `forge test --match-test closeCost` → FAIL (GAV 10,000e6, no deduction).

- [ ] **Step 3: Implement.** In `_valuePair`, after `decimals`: `(,,,,, uint256 spreadP) = IVerantaPairCosts(address(pairStorage)).pairs(pairIndex);` and pass `spreadP` to `_valueTrade`. In `_valueTrade`, compute the close cost in a helper to stay under the stack limit:

```solidity
	/// @dev What closing this trade costs (spec 2026-10-08 §3.3): Veranta's close fee for this size
	///      and side plus the pair's base spread, on the leveraged size. The referral discount and
	///      the operator's dynamic spread above the base are not modelled.
	function _closeCost(uint256 pairIndex, uint256 leveragedSize, uint256 coinExposure, bool buy, uint256 spreadP)
		internal
		view
		returns (uint256)
	{
		uint256 closeFeeP = IVerantaPairCosts(address(pairStorage)).pairCloseFeeP(pairIndex, coinExposure, buy);
		return (leveragedSize * (closeFeeP + spreadP)) / PERCENT_SCALE;
	}
```

with `uint256 internal constant PERCENT_SCALE = 100 * 1e10; // Veranta's percentages: 1e10 = 1%`, and `fees = int256(rolloverFee) + fundingFee + int256(_closeCost(...))`.

- [ ] **Step 4: Run** — `forge test --match-contract VerantaPerpV4Test` → PASS.

### Task 4: AddMargin

**Files:**
- Modify: `src/positions/VerantaPerpPositionV4.sol`
- Test: `test/VerantaPerpV4.t.sol`

- [ ] **Step 1: Failing tests**

```solidity
	function _addMargin(VerantaPerpPositionV4 position, uint256 amount, uint256 fee) internal {
		address[] memory transferAssets = new address[](1);
		transferAssets[0] = address(usdc);
		uint256[] memory transferAmounts = new uint256[](1);
		transferAmounts[0] = amount;
		(address[] memory noAssets,) = _none();
		bytes memory data = abi.encode(
			uint8(VerantaPerpPositionV4.Action.AddMargin),
			abi.encode(ETH_PAIR, uint256(0), amount, new bytes[](0), uint8(1), fee)
		);
		vm.prank(manager);
		comptroller.callOnExternalPosition(address(position), transferAssets, transferAmounts, noAssets, data);
	}

	function test_addMargin_movesVaultUsdcIntoTheTrade_andPaysTheFee() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		vm.deal(address(position), 10);
		vm.expectEmit(address(position));
		emit VerantaPerpPositionV4.MarginAdded(ETH_PAIR, 0, 100e6);
		_addMargin(position, 100e6, 1);
		uint256 venueFee = (uint256(100e6) * 3) / 10_000; // the mock's deposit fee
		assertEq(veranta.openTrades(address(position), ETH_PAIR, 0).initialPosToken, 1_100e6 - venueFee);
		assertEq(veranta.marginFeesPaid(), 1);
		assertEq(address(position).balance, 9);
		assertEq(comptroller.calcGav(), 10_000e6 - venueFee);
	}

	function test_addMargin_withoutEthForTheFee_reverts() public {
		VerantaPerpPositionV4 position = _createPosition();
		_openStandardTrade(position, false);
		veranta.fillPending(2_500e10);
		vm.expectRevert(abi.encodeWithSelector(VerantaPerpPositionV4.FeeBalanceTooLow.selector, 1, 0));
		_addMargin(position, 100e6, 1);
	}

	function test_addMargin_isNotRiskReducing() public {
		VerantaPerpPositionV4 position = _createPosition();
		assertFalse(position.isRiskReducing(abi.encode(uint8(VerantaPerpPositionV4.Action.AddMargin), '')));
	}

	function test_receive_acceptsEth_andItStaysOutOfNav() public {
		VerantaPerpPositionV4 position = _createPosition();
		(bool ok,) = address(position).call{value: 1 ether}('');
		assertTrue(ok);
		assertEq(comptroller.calcGav(), 10_000e6);
	}
```

- [ ] **Step 2: Run** — `forge test --match-test 'addMargin|receive'` → FAIL (UnknownAction / no receive).

- [ ] **Step 3: Implement**

```solidity
		} else if (rawAction == uint8(Action.AddMargin)) {
			_addMargin(args);
```

```solidity
	/// @dev Spec §4: deposit margin into one open trade against a signed price Veranta verifies
	///      (Lazer: under 30 s old, not ahead of the chain clock). The verification fee is paid in
	///      ETH from this account's own balance (receive()); its few wei stay out of NAV.
	function _addMargin(bytes memory args) internal {
		(uint256 pairIndex, uint256 index, uint256 amount, bytes[] memory priceUpdateData, uint8 priceSourcing, uint256 fee) =
			abi.decode(args, (uint256, uint256, uint256, bytes[], uint8, uint256));
		uint256 balance = address(this).balance;
		if (balance < fee) revert FeeBalanceTooLow(fee, balance);
		router.updateMargin{value: fee}(pairIndex, index, MARGIN_DEPOSIT, amount, priceUpdateData, priceSourcing);
		emit MarginAdded(pairIndex, index, amount);
	}

	/// @notice ETH for Veranta's price-verification fee (AddMargin); not part of NAV.
	receive() external payable {}
```

with `uint8 internal constant MARGIN_DEPOSIT = 0; // Veranta updateType.DEPOSIT`.

- [ ] **Step 4: Run** — `forge test --match-contract VerantaPerpV4Test` → PASS; `forge build --sizes | grep VerantaPerpPositionV4` → factory runtime under 24,576.

### Task 5: Fork proofs on live Veranta (pinned block 52014634)

**Files:**
- Create: `test/fork/VerantaPerpPositionV4Fork.t.sol`

Uses `VerantaPerpPositionV3Fork`'s pinned block, real ETH Lazer packet (`ETH_LAZER_PACKET`, ts 1790818690, $2,685.28631153), operator `0xe8f6…BC92`, and its `_fund` / `_openTrade` / `_fill` / `_close` / `_valueAt` / `_collateral` helpers (copied), with type 6 re-pointed to a fresh `VerantaPerpPositionV4Factory(v2Factory)`.

- [ ] **Step 1: Tests**
  - `test_fork_closeCostReadsWorkInAStaticCall`: `IVerantaPairCosts(PAIR_STORAGE).pairs(0)` spreadP = 1e8 and `pairCloseFeeP(0, …, true)` = 1e8 via a view helper contract.
  - `test_fork_navAfterCloseCostsVsRealClosePayout`: 200 USDC 5× ETH long, filled with the real packet; `_valueAt(p, ETH_PACKET_PRICE)` vs the real close payout; assert the gap is ≤ the referral discount's share of the close fee (≈ 0.005 USDC) and log it. (V3 gap was 0.194573.)
  - `test_fork_addMarginWithTheRealPacket`: filled long, `vm.deal(p, 1)`, AddMargin 50 USDC with `[ETH_LAZER_PACKET]`, sourcing 1, fee 1 at `ETH_PACKET_TS + 29` → collateral + 50e6, account ETH 0; at `+30` reverts.
  - `test_fork_listModeGasVsFullWalk`: one filled trade; gas of `getManagedAssets()` in list mode vs after SetAutopilot (full walk); assert list < 10% of full and log both.
  - `test_fork_keeperOpenCountedThenSynced`: SetAutopilot; keeper `delegatedAction` openTrade (ETH short 100 USDC 5×); fill; value present while delegated; RemoveAutopilot → `heldPairs()` = [0] and the value is unchanged.

- [ ] **Step 2: Run**

Run: `set -a; source .env; set +a; BASE_MAINNET_RPC=$BASE_RPC_URL BASE_FORK_BLOCK=52014634 forge test --match-path test/fork/VerantaPerpPositionV4Fork.t.sol -vv`
Expected: PASS, logs of the close-cost gap and both gas numbers.

### Task 6: Redemption fallback on a V4 account (block 52230324)

**Files:**
- Create: `test/fork/PerpUnwinderV4Fork.t.sol` — `PerpUnwinderForkTest`'s setUp (short-deadline queue, V3 blueprint, PerpUnwinder) plus `factory.registerPositionType(PERP_TYPE, address(new VerantaPerpPositionV4Factory(VerantaPerpPositionV2Factory(perpConfig))))`, and its full unwind test (request, overdue, unwind with a fresh push, operator fill, settle) against a V4 account; assert `canUnwind(account)` and that the account is a V4 (`heldPairs()` = [129]).

- [ ] **Step 1: Write, Step 2: Run** `BASE_MAINNET_RPC=$BASE_RPC_URL forge test --match-path test/fork/PerpUnwinderV4Fork.t.sol -vv` → PASS.

### Task 7: Deploy script + rollout rehearsal

**Files:**
- Create: `script/mainnet/DeployPerpAccountV4.s.sol`
- Create: `test/fork/PerpAccountV4RolloutFork.t.sol`

- [ ] **Step 1: Script** (pattern of `DeployRedemptionQueue.s.sol`): Base only, `--sender` = genesis deployer, deploys `VerantaPerpPositionV4Factory(verantaFactory)`; on a real broadcast writes `deployments/base-mainnet-perp-v4.json` `{ perpV4Factory, startBlock }`; prints the founder's next step `cast send <factory> 'registerPositionType(uint256,address)' 6 <perpV4Factory>`.
- [ ] **Step 2: Rehearsal test at the latest block:** run the script's deploy (`new DeployPerpAccountV4().deploy(config)` library-style helper or the same constructor call), re-point type 6 as the factory owner, create a fresh V3 fund through the live factory + V3 deployer, create a perp account: it is V4 (`heldPairs()` empty), `positionFactory()` = the V2 config, `PerpUnwinder(<live>).canUnwind(account)` true, `getManagedAssets()` cheap; TestFund4's V3 account `0xEb85…c2d4` still values (its `getManagedAssets` unchanged before/after the re-point).
- [ ] **Step 3: Run** `BASE_MAINNET_RPC=$BASE_RPC_URL forge test --match-path test/fork/PerpAccountV4RolloutFork.t.sol -vv` → PASS. Then `forge test` (whole unit suite) → PASS.

### Task 8: Terminal — V4 helpers (pure) + held-pairs book reads

**Files:**
- Create: `frosty-terminal/src/lib/perpAccountV4.ts`, `frosty-terminal/test/perp-account-v4.test.ts`
- Modify: `frosty-terminal/src/lib/usePerpBooks.ts`

**Interfaces:**
- Produces: `PERP_ACTION_ADD_MARGIN = 8`; `addMarginArgs(pairIndex: bigint, tradeIndex: bigint, amount: bigint, packets: Hex[], fee: bigint): Hex` (flat `(uint256,uint256,uint256,bytes[],uint8,uint256)`, sourcing 1 = PYTH_LAZER); `ethTopUp(balance: bigint, fee: bigint): bigint` (0 when enough, else `fee * 100n - balance` so later adds don't need another top-up); `bookPairs(mapped: number[], held: readonly bigint[] | undefined, delegated: boolean): number[]` (held pairs ∩ anything when V4 in list mode; `mapped` otherwise); `PERP_V4_ABI` (`heldPairs`, `activeDelegate`).

- [ ] Steps: tests first (encoding round-trips through `decodeAbiParameters`; `ethTopUp` cases; `bookPairs`: V3 (held undefined) → mapped, V4 delegated → mapped, V4 list mode → held as numbers even when not in `mapped`), run `npx vitest run test/perp-account-v4.test.ts` → FAIL, implement, → PASS. Then `usePerpBooks`: one extra `useReadContracts` reading `heldPairs` + `activeDelegate` per account (`allowFailure`; a V3 account's `heldPairs` fails → undefined), per-account pair lists from `bookPairs`, calls and the `books` assembly indexed by per-account offsets. `npm run typecheck` (or `npx tsc --noEmit`) → clean.

### Task 9: Terminal — add margin on V4 trade rows

**Files:**
- Create: `frosty-terminal/src/components/manage/AddMargin.tsx`
- Modify: `frosty-terminal/src/components/manage/VerantaPanel.tsx` (row button "add margin" when the account is V4), `frosty-terminal/src/lib/usePerpPrices.ts` (export `fetchPacket`), `frosty-terminal/src/lib/verantaPrices.ts` (`VERANTA_LAZER` = `0xACeA761c27A909d4D3895128EBe6370FDE2dF481`, the keeper's constant).

- [ ] Steps: AddMargin takes `account`, `comptroller`, `trade` (pair, index), shows an amount input + vault-available pick; on submit: read `verification_fee` from `VERANTA_LAZER` and the account's ETH balance; if `ethTopUp > 0` send that ETH to the account and wait; fetch the pair's packet (`fetchPacket`), wait for the chain clock to reach its publish time (same loop as `usePushPerpPrices`), then `writeContract(callOnExternalPosition(account, [USDC], [amount], [], encode(8, addMarginArgs(...))))`. Copy: "adds USDC from the vault to this trade's margin · Veranta needs a fresh signed price: sign within ~20 s". Shown only when `heldPairs()` reads (V4) and `FEATURES` has perps on mainnet. `npm test`, `npx tsc --noEmit`, `npm run build` (move a stale `.next-veranta` out first if it breaks the build, restore after) → green.

### Task 10: Docs

- [ ] `MAINNET_RUNBOOK_FUNDS.md`: new section "Perp account V4: BUILT 2026-10-08, NOT DEPLOYED" (what it fixes, fork results, the two founder steps, terminal deploy), and the known-gaps list marked "fixed in V4 for new accounts" per item.
- [ ] Spec status line updated with the fork numbers.
- [ ] `git status --short` in both repos: only the intended files.
