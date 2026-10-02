# TWAP Exposure Policy V3 (no fund buys a delisted token) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** degen funds (`allowRiskyAssets`) can no longer buy a delisted TWAP token. Today they can, because `TwapExposurePolicyV2._checkBuy` returns early for them (`TwapExposurePolicyV2.sol:85`).

**Architecture:**
- New side-by-side `TwapExposurePolicyV3`: V2 copied verbatim, with one change. Degen funds still skip the caps, but they get the delisted rule on every buy path: adapter swaps, the newest live limit order, and LP creation. Every non-degen path, every error signature and every hook stays V2's.
- A deploy library (`script/mainnet/TwapPolicyV3.sol`) holds the wiring. The broadcast script and the fork test both run it, so what's tested is what ships. It swaps the factory's mandatory list from V2 to V3 and approves V3 as the replacement for V1 and V2.
- The founder broadcasts through an `.ops-scratch` wrapper. ALPHA moves only by reconfiguring.

**Tech Stack:** Foundry 1.5.0 (forge, anvil, cast), solc 0.8.24, OpenZeppelin, Base mainnet fork pinned at block 52,066,028.

**Spec:** founder decision 2026-10-02, verbatim: "yes close that gap, degen funds shouldnt buy delisted tokens". The side pocket (zero-priced assets) is dropped: the mainnet VI has none, so there's nothing to do for it. The research below backs every task: cast calls at block 52,066,028 plus file:line references.

## Findings (read-only research, 2026-10-02)

**What each part of the system runs today** (cast, block 52,066,028):
- **New funds.** `FundFactory 0x42F213d7f6018BF293bF0ecB727C59A25b5029a3`.`getMandatoryPolicies()` = TwapExposurePolicyV2 `0xd8C7417F6Da77D534586715Cb1187935043C5A8F` on hooks 4, 0, 5, 6, in that order.
  - V2 reads TwapListingRegistryV2 `0x055501158140a240AD9180c1f54De7cdd8f8B48e`, which has **0 listings**.
- **ALPHA** `0x833A506d761A4756AF279ABC24183Db407823dE9` is the only fund (`fundsCount()` = 1). It's degen (`allowRiskyAssets()` = true), and its fundOwner is the deployer `0xaE51…802a`.
  - Hooks 0/4/5/6 run **TwapExposurePolicy V1** `0xB2be6B954c4b141cF3EB6de7D4f2b093A068E2Df`. Also attached: the factory's unrestricted mandate `0xA3e0…BA57` on hook 4, and `0x7c74…Aa34` on hook 5.
  - V1 reads the **v1 registry** `0x4888D9AAB01AD30c37098A37388Fdb568A381CF6`. It has 0 listings and will never get any, because listings now go through the PriceListingModule into the v2 registry.
  - Result: **ALPHA has no TWAP rule for v2 listings.** No delisted-buy block and no delisted-holding deposit pause (as a degen fund it skips the caps anyway).
- **V1 has the same degen gap:** `TwapExposurePolicy.sol:83` has the same early return as `TwapExposurePolicyV2.sol:85`.
- `policyReplacements(V1)` = `policyReplacements(V2)` = 0, and ALPHA has no reconfiguration request.
- **Factory ownership.** Owner = deployer. `pendingOwner()` = timelock `0xd50AF6A924f23AC6944fB8eBc981E006B07D83Ba`, left over from the cancelled 2026-09-29 Start. Its accept op `0xaa22…888a` is cancelled (`isOperation` = false), and minDelay is 172,800. The owner can make calls now.
- **ALPHA has 3 external positions:**
  - LP `0x3Fbd…d674`: 25.58 USDC + 15.54 B20 `0xb200…883d`;
  - LP `0x236E…fe2c`: 24.96 USDC + 3.43 B20 `0xb200…707C`;
  - an empty Veranta perp account `0x33C7…844d`.
- **The module has no keeper.** `keepers(deployer)` = false, and the twap-v2 book's `keeper` is 0.

**How a policy reaches funds** (`src/core/FundFactory.sol`):
- **New funds.** `_attachMandatoryPolicies` (:358-374) adds each mandatory entry unless the fund already carries it or its approved replacement (:367).
  - `setPolicyReplacement(V2, V3)` alone would give new funds V3. But a manager who names V2 in its own `createFund` ruleset (:316-333) would keep V2, because V2 counts as "present".
  - Swapping the list itself with `setMandatoryPolicies` (:343-350) closes that hole: V2 never satisfies a V3 entry.
  - So the owner's calls are: `setMandatoryPolicies(V3 ×4)`, `setPolicyReplacement(V1, V3)` and `setPolicyReplacement(V2, V3)`. They take effect at once with no delay while the deployer owns the factory. After the handoff, the same calls need a timelock proposal (2 days).
- **Existing funds move only by reconfiguring:**
  1. The owner approves the swap with `setPolicyReplacement(old, new)` (:256-272; `new` must implement every hook `old` does).
  2. The fund owner calls `createReconfigurationRequest(fund, sameConfig, [oldPolicy])` (:443-449). The window is the larger of 2 days and the fund's sharesActionTimelock (:472-474); for ALPHA that's 2 days.
  3. After the window, the fund owner calls `executeReconfiguration`. It reverts **while any external position is open** (:533) and settles fees (:536).
  4. The result is a **new Comptroller address** with the same Vault, Shares, holders, HWM and tracked assets. Every policy carries over with the swap applied (:546, :570-582), and missing mandatory policies are added (:547).
  - The guardian can `revokePolicyReplacement` instantly (:275-279).
- **ALPHA therefore can't switch without a migration.** Its options:
  - A. Unwind its 3 positions, then request, wait 2 days, execute. Its comptroller address changes; vault, shares, holders and HWM carry over.
  - B. Stay on V1 and never buy a TWAP-listed token in ALPHA.
  - C. Retire it and open a new fund. The name "ALPHA" is reserved forever (:380).

**Exit paths.** In `PostCallOnIntegration`, policies run on the PARSED `incomingAssets`, whatever was actually received (`Comptroller.sol:437-474`):
- **Swaps:** `UniswapV3SwapAdapter.sol:33-43`, `AerodromeSlipstreamSwapAdapter.sol:33-43`, `UniswapV2SwapAdapter.sol:35-45` and `AerodromeBasicSwapAdapter.sol:39-49` have incoming = `tokenOut` only. Selling X puts X in spendAssets, so **a sale is never blocked**.
- **`ERC4626Adapter.sol:46-52` REDEEM and `CompounderAdapter.sol:50-60` WITHDRAW:** incoming = the underlying(s).
  - A delisted TWAP underlying would block the unwind. Normal funds already have this trap TODAY (`BuyingDelistedAsset`, or the caps while listed); V3 gives degen funds the same one.
  - It's unreachable today:
    - `listCompounder` refuses TWAP-priced pool tokens (`PriceListingModule.sol:152-153`).
    - A VI-priced token can never be TWAP-listed afterwards (`TwapListingRegistryV2.sol:244`).
    - 4626 vaults enter the VI only through governance `module.execute` (`PriceListingModule.sol:168`). `YieldListing.sol:62` only requires that the underlying is priced.
  - So: no V3 code; normal funds are the reference. A runbook rule is added instead: never list a 4626 vault whose underlying is TWAP-priced.
- **LP removals.** No integration adapter handles LPs: the 8 registered adapters are 6 swap adapters, ERC4626 and Compounder, all checked `isAdapterRegistered` = true. LPs are external positions, whose hook carries only `(position, loss)` (`Comptroller.sol:680`), so a removal never shows incoming assets.
- **External-position hooks in V3:**
  - `CreateExternalPosition` runs at creation only, which is never an exit.
  - `PostCallOnExternalPosition` checks only the newest limit order; LP and perp positions have no `orderCount()` and pass.
  - New for degen funds: while the NEWEST order is live and buys a delisted token, other calls on that limit-order position revert until the order is cancelled.
  - Cancel always passes: it is risk-reducing and unpriced (`LimitOrderPosition.sol:87-90, 100-107`; `Comptroller.sol:664`) and leaves `sellRemaining = 0`. Normal funds can't hold such an order at all. Not a trap.
- **Redemptions are unaffected.** In-kind redemption runs no policies (`Comptroller.sol:317-363`). Cash redemption runs only `RedeemSharesForSpecificAssets` (:307), which V3 doesn't implement.
- **Off-chain:** nothing changes. The terminal decodes the TWAP-policy errors by signature (`frosty-terminal/src/lib/simulate.ts:25-31`, `SimVerdict.tsx:15`). V3 keeps V2's exact error set.

**Item 4, open choice:** also refuse degen buys while the clock runs (`belowFloorSince != 0`, under 72 h)?
- In code it's one line.
- Anyone can START a clock (`TwapListingRegistryV2.sol:295-305`); only a lister can clear one (:306), and no keeper is set yet. So a dip, or a griefer pushing a pool under the floor once, would freeze degen buys instantly.
- **Recommendation: not now.** Revisit once the Plan B keeper clears clocks within minutes. The scope stays delisted-only, pinned by `test_fork_clockRunningIsNotDelisted`.

**Gas (estimate; Task 2 measures it):**
- V2's CREATE used 1,850,174 gas in the 2026-10-01 broadcast (`broadcast/DeployTwapListingV2.s.sol/8453/run-latest.json`), and `setMandatoryPolicies` used 63,090.
- V3 is V2 plus ~100 bytes. Estimate:
  - ≈ 1.9M for the CREATE;
  - ≈ 63k for `setMandatoryPolicies`;
  - ≈ 2 × 50k for `setPolicyReplacement`;
  - total **≈ 2.1M gas**: about 0.000012 ETH of L2 execution at the 0.0056 gwei paid on 2026-10-01, plus Base's L1 data fee.
- Runtime: a degen fund's trade pays one more cold registry read (≈ 5–7k gas). The normal path is unchanged.

## Global Constraints
- **Side-by-side only.** New files:
  - `src/policies/TwapExposurePolicyV3.sol`
  - `script/mainnet/TwapPolicyV3.sol`
  - `script/mainnet/DeployTwapPolicyV3.s.sol`
  - `test/fork/TwapPolicyV3Fork.t.sol`
- **NEVER edit** `TwapExposurePolicy.sol`, `TwapExposurePolicyV2.sol`, `FundFactory.sol`, `Comptroller.sol`, `TwapListingRegistryV2.sol` or `PriceListingModule.sol`; they're all deployed.
- **Only two existing files change, both scripts:** the `_loadV2` loader in `script/mainnet/TransferFundsGovernance.s.sol`, and one comment in `script/mainnet/FundsGovernance.sol`. Without the loader change, the handoff's verify (`FundsGovernance.sol:213-216`, which requires every mandatory entry to be `v2.policy`) would revert after V3.
- **V3 keeps V2's six errors** with byte-identical signatures. Add no new error.
- **No admin surface.** V3 has no owner and no setters. The deploy uses only existing owner calls: `setMandatoryPolicies` and `setPolicyReplacement` ×2.
- **Scope = delisted** (`isDelisted && isTwapPriced`). Below the floor with the clock still running stays buyable (open choice, item 4).
- **Code style:** solc 0.8.24, OZ imports as in V2, tabs, single quotes. Don't run `forge fmt` on existing files.
- **Tests and RPC:**
  - No mocks: fork tests only, on a fork pinned at `BASE_FORK_BLOCK=52066028`, run with `-j 1`.
  - Keep forge/anvil's default rate limit (330 CUPS ≈ ≤ 20 req/s; never pass `--no-rpc-rate-limit`). cast loops sleep 0.1 s between calls.
  - Read the RPC URL from `funds-core/.env` silently. Never print `.env` values.
- **Git:**
  - The founder runs `git fetch origin`. The agent then runs `git checkout -b feat/twap-policy-v3 --no-track origin/main`.
  - Local `origin/main` (161ce72) already contains 78dbda0; fetch anyway.
  - No worktrees. Agents never `git add`, `commit` or `push`.
- **Broadcasts:**
  - Agents broadcast only to a local anvil fork.
  - Mainnet is founder-only, through the wrapper, with keystore `frosty-main` and sender `0xaE51f2EfE70e57b994BE8F7f97C4dC824c51802a`.
  - The governance handoff is NEVER run on mainnet in this plan (only rehearsed on anvil).
- **Opus writes all Solidity.** The controller does the final review.
- **Internal docs stay internal.** `MAINNET_RUNBOOK_FUNDS.md` and `.ops-scratch/` live outside the repo and are never committed.

## Review Focus
1. **Normal funds must behave exactly as under V2.** Pinned by:
   - `test_fork_normalFundRulesUnchanged` (byte-identical revert from the same state);
   - the normal-fund lines in `test_fork_degenCannotBuyADelistedToken` and `test_fork_degenCannotOpenAnLpOnADelistedToken`;
   - ±300 gas parity in `test_fork_gasOfTheNewCheck`.
2. **A degen fund holding a delisted token can always get out:** sell, in-kind redemption, and cancelling a resting buy. Pinned by `test_fork_degenExitsADelistedHolding` and `test_fork_degenRestingBuyOrderMustBeCancelledFirst`.
3. **The refusal starts at exactly 72 h.** With the clock running and under 72 h, a degen fund still buys (founder scope). Pinned by `test_fork_clockRunningIsNotDelisted`.
4. **No dodging V3, and no double deploy.** A manager naming V2 in its own ruleset still runs V3, and a second deploy run stops before sending anything. Pinned by `test_fork_wiring`.
5. **Existing funds have a working opt-in path with an explicit prerequisite.** V2→V3 works end to end; ALPHA's V1→V3 request is accepted, but execution is refused while its positions are open. Pinned by `test_fork_reconfigurationSwapsV2ForV3` and `test_fork_alphaOptInNeedsItsPositionsWoundDown`.

Known residuals, documented in the runbook and not fixed:
- A resting limit order placed BEFORE a delisting stays fillable by takers until it's cancelled. Policies only see the newest order, so placing a newer order masks an older live buy.
- An LP opened while the token was listed can keep adding liquidity.
- 4626/compounder unwinds of a TWAP underlying are covered by the listing guards above, not by V3.

---

### Task 0: Branch (no code)
- [ ] **Step 1 (founder):** `cd ~/FrostyFunds/funds-core && git fetch origin`
- [ ] **Step 2 (agent):** `cd /home/dude/FrostyFunds/funds-core && git status --short && git checkout -b feat/twap-policy-v3 --no-track origin/main`
  - Expected: status prints nothing first (the tree is clean, HEAD 78dbda0), then `Switched to a new branch 'feat/twap-policy-v3'`.
  - If the status isn't empty, STOP and ask the founder.

### Task 1: `TwapExposurePolicyV3` + deploy library + fork tests (red → green)

**Files:**
- Create: `src/policies/TwapExposurePolicyV3.sol`
- Create: `script/mainnet/TwapPolicyV3.sol`
- Test: `test/fork/TwapPolicyV3Fork.t.sol`

**Interfaces:**
- Consumes (live, unchanged):
  - `TwapListingRegistryV2.isDelisted(address) returns (bool)`, `isTwapPriced(address) returns (bool)`, `pokeFloor(address) returns (bool)`, `DELIST_GRACE()`;
  - `PriceListingModule.setKeeper(address,bool)` and `list(address,address,Venue,int24) returns (address)`;
  - `FundFactory.getMandatoryPolicies()`, `setMandatoryPolicies(PolicyReg[])`, `setPolicyReplacement(address,address)`, `policyReplacements(address)`, `createFund(...)`, `createReconfigurationRequest(address,FundConfig,address[])`, `executeReconfiguration(address)`, `getRequestedPolicySwaps(address)`;
  - `FundsMainnet.LIMIT_ORDER_TYPE` (2) and `UNI_LP_TYPE` (3).
- Produces:
  - `contract TwapExposurePolicyV3 is IPolicy` with `constructor(TwapListingRegistryV2)`, `registry()`, V2's six errors and V2's four hooks;
  - `library TwapPolicyV3` with:
    - `struct Config { address deployer; FundFactory factory; TwapListingRegistryV2 registry; address policyV1; address policyV2; }`;
    - `deploy(Config) internal returns (TwapExposurePolicyV3)` and `verify(Config, TwapExposurePolicyV3) internal view`;
    - errors `BadConfig()`, `WrongOwner(address)`, `WrongRegistry(address)`, `MandatoryPoliciesMismatch(uint256)`, `MandatoryPolicyMismatch(uint256,uint8,address)` and `ReplacementMismatch(address,address)`.

- [ ] **Step 1: Pre-flight. Confirm the pinned block still shows what the tests assume** (read-only, throttled)
```bash
cd /home/dude/FrostyFunds/funds-core
RPC=$(grep -E '^BASE_RPC_URL=' .env | cut -d= -f2- | tr -d '"'); B=52066028
c() { sleep 0.1; cast call "$@" --block "$B" --rpc-url "$RPC"; }
c 0x42F213d7f6018BF293bF0ecB727C59A25b5029a3 'getMandatoryPolicies()((uint8,address)[])'
c 0x3CDbaBE5Bf4E6cfE10A2A326E0ad31b2d16398D4 'isSupportedAsset(address)(bool)' 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf
c 0x055501158140a240AD9180c1f54De7cdd8f8B48e 'getListedAssets()(address[])'
c 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 'balanceOf(address)(uint256)' 0x67A11022B7B6ed66f81233F6C8Ed6e48F7826530
c 0x833A506d761A4756AF279ABC24183Db407823dE9 'getExternalPositions()(address[])'
```
Expected:
- the mandatory list is `(4|0|5|6, 0xd8C7…5A8F)`;
- `isSupportedAsset(VVV)` = `false`;
- the listed assets are `[]`;
- the VVV pool holds ≈ `332130…` (≈ $332k USDC);
- ALPHA has 3 positions.

- [ ] **Step 2: Red baseline. V3 starts as an exact copy of V2**
```bash
cd /home/dude/FrostyFunds/funds-core
cp src/policies/TwapExposurePolicyV2.sol src/policies/TwapExposurePolicyV3.sol
sed -i 's/^\/\/\/ @title TwapExposurePolicyV2$/\/\/\/ @title TwapExposurePolicyV3/; s/^contract TwapExposurePolicyV2 is IPolicy {$/contract TwapExposurePolicyV3 is IPolicy {/' src/policies/TwapExposurePolicyV3.sol
grep -n 'TwapExposurePolicyV' src/policies/TwapExposurePolicyV3.sol
```
Expected: exactly two hits, both `TwapExposurePolicyV3` (the title and the contract line).

- [ ] **Step 3: Write the deploy library** `script/mainnet/TwapPolicyV3.sol`
```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {FundFactory} from '../../src/core/FundFactory.sol';
import {IPolicy} from '../../src/interfaces/IPolicy.sol';
import {TwapListingRegistryV2} from '../../src/pricing/TwapListingRegistryV2.sol';
import {TwapExposurePolicyV2} from '../../src/policies/TwapExposurePolicyV2.sol';
import {TwapExposurePolicyV3} from '../../src/policies/TwapExposurePolicyV3.sol';

/// @title TwapPolicyV3
/// @notice TwapExposurePolicyV3 wired into the LIVE Base factory as code — one library the broadcast
///         script (DeployTwapPolicyV3) and the fork test (test/fork/TwapPolicyV3Fork) both run, so
///         what is tested is exactly what ships. The caller is the genesis deployer, which still
///         owns the FundFactory:
///           1. TwapExposurePolicyV3 over the live TwapListingRegistryV2;
///           2. the mandatory list: every TwapExposurePolicyV2 entry becomes V3, hooks kept — new
///              funds run V3 even when a manager names V2 in its own ruleset (a replacement alone
///              would let V2 count as present, FundFactory.sol:367);
///           3. V3 approved as the replacement of V1 and of V2 — an existing fund opts in by
///              reconfiguring (2-day window; its external positions closed first).
///         {verify} proves the end state or reverts. V3 has no owner: nothing joins the handoff.
library TwapPolicyV3 {
	/// @notice Mainnet's mandatory list: TwapExposurePolicyV2 on hooks 4, 0, 5, 6 (cast, block 52066028).
	uint256 internal constant MANDATORY_TWAP_ENTRIES = 4;

	struct Config {
		address deployer; // owns the FundFactory until the governance handoff
		FundFactory factory;
		TwapListingRegistryV2 registry; // deployments/base-mainnet-twap-v2.json `registry`
		address policyV1; // genesis TwapExposurePolicy (deployments/base-mainnet.json `twapPolicy`)
		address policyV2; // TwapExposurePolicyV2 (deployments/base-mainnet-twap-v2.json `policy`)
	}

	error BadConfig();
	error WrongOwner(address owner);
	error WrongRegistry(address registry);
	error MandatoryPoliciesMismatch(uint256 count);
	error MandatoryPolicyMismatch(uint256 index, uint8 hook, address policy);
	error ReplacementMismatch(address policy, address replacement);

	/// @notice Deploy and wire (steps 1–3), then {verify}.
	function deploy(Config memory cfg) internal returns (TwapExposurePolicyV3 policy) {
		_checkConfig(cfg);
		// a second run finds V3 here and stops before sending anything
		_requireAll(cfg.factory.getMandatoryPolicies(), cfg.policyV2);

		policy = new TwapExposurePolicyV3(cfg.registry);
		FundFactory.PolicyReg[] memory next = new FundFactory.PolicyReg[](MANDATORY_TWAP_ENTRIES);
		for (uint256 i; i < MANDATORY_TWAP_ENTRIES; ++i) {
			next[i] = FundFactory.PolicyReg({hook: _hook(i), policy: address(policy)});
		}
		cfg.factory.setMandatoryPolicies(next);
		cfg.factory.setPolicyReplacement(cfg.policyV1, address(policy));
		cfg.factory.setPolicyReplacement(cfg.policyV2, address(policy));
		verify(cfg, policy);
	}

	/// @notice Revert unless `policy` reads the v2 registry, is every mandatory entry on the genesis
	///         hooks, and is the approved replacement of V1 and of V2.
	function verify(Config memory cfg, TwapExposurePolicyV3 policy) internal view {
		if (address(policy.registry()) != address(cfg.registry)) revert WrongRegistry(address(policy.registry()));
		_requireAll(cfg.factory.getMandatoryPolicies(), address(policy));
		_requireReplacement(cfg.factory, cfg.policyV1, address(policy));
		_requireReplacement(cfg.factory, cfg.policyV2, address(policy));
	}

	function _checkConfig(Config memory cfg) private view {
		if (
			cfg.deployer == address(0) || address(cfg.factory) == address(0) || address(cfg.registry) == address(0)
				|| cfg.policyV1 == address(0) || cfg.policyV2 == address(0)
		) revert BadConfig();
		address owner = cfg.factory.owner();
		if (owner != cfg.deployer) revert WrongOwner(owner);
		address v2Registry = address(TwapExposurePolicyV2(cfg.policyV2).registry());
		if (v2Registry != address(cfg.registry)) revert WrongRegistry(v2Registry);
	}

	/// @dev Exactly MANDATORY_TWAP_ENTRIES entries, each `policy` on the genesis hook order.
	function _requireAll(FundFactory.PolicyReg[] memory regs, address policy) private pure {
		if (regs.length != MANDATORY_TWAP_ENTRIES) revert MandatoryPoliciesMismatch(regs.length);
		for (uint256 i; i < regs.length; ++i) {
			if (regs[i].policy != policy || regs[i].hook != _hook(i)) {
				revert MandatoryPolicyMismatch(i, uint8(regs[i].hook), regs[i].policy);
			}
		}
	}

	/// @dev The genesis order (FundsMainnet.sol:214-217; cast at block 52066028: 4, 0, 5, 6).
	function _hook(uint256 i) private pure returns (IPolicy.PolicyHook) {
		if (i == 0) return IPolicy.PolicyHook.PostCallOnIntegration;
		if (i == 1) return IPolicy.PolicyHook.PostDepositRequest;
		if (i == 2) return IPolicy.PolicyHook.CreateExternalPosition;
		return IPolicy.PolicyHook.PostCallOnExternalPosition;
	}

	function _requireReplacement(FundFactory factory, address policy, address expected) private view {
		address stored = factory.policyReplacements(policy);
		if (stored != expected) revert ReplacementMismatch(policy, stored);
	}
}
```

- [ ] **Step 4: Write the fork test** `test/fork/TwapPolicyV3Fork.t.sol`
```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {IPolicy} from '../../src/interfaces/IPolicy.sol';
import {IUniswapV3SwapRouter} from '../../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {TickMath} from '../../src/libraries/TickMath.sol';
import {TwapListingRegistry} from '../../src/pricing/TwapListingRegistry.sol';
import {TwapListingRegistryV2} from '../../src/pricing/TwapListingRegistryV2.sol';
import {PriceListingModule} from '../../src/pricing/PriceListingModule.sol';
import {TwapExposurePolicy} from '../../src/policies/TwapExposurePolicy.sol';
import {TwapExposurePolicyV3} from '../../src/policies/TwapExposurePolicyV3.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {TwapPolicyV3} from '../../script/mainnet/TwapPolicyV3.sol';

/// @notice TWAP EXPOSURE POLICY V3 on a pinned Base fork against the LIVE contracts: the factory,
///         TwapListingRegistryV2 + PriceListingModule, TwapExposurePolicyV2, the Uniswap v3 swap
///         adapter, the limit-order and Uniswap LP position types, and ALPHA. setUp runs
///         TwapPolicyV3.deploy — the exact wiring DeployTwapPolicyV3 broadcasts — as the real
///         deployer. A test keeper lists VVV on its real USDC 0.3% pool; real sells drain it under
///         the floor; a stranger's poke starts the clock; 72 h pass. No mocks; `deal` only funds
///         balances.
///         Chainlink USDC/USD (25 h heartbeat in the TWAP adapter) is stale after the 72 h warp, so
///         every check after it uses paths that read no price: the buy/sell policy check, in-kind
///         redemption, deposit requests and risk-reducing limit-order calls.
///         Run: BASE_MAINNET_RPC=<url> [BASE_FORK_BLOCK=52066028] forge test --match-path test/fork/TwapPolicyV3Fork.t.sol -j 1 -vv
contract TwapPolicyV3ForkTest is Test {
	string internal constant GENESIS_FILE = 'deployments/base-mainnet.json';
	string internal constant TWAP_V2_FILE = 'deployments/base-mainnet-twap-v2.json';
	/// @dev TWAP v2 and the fee compounders live, nothing TWAP-listed yet, mandatory = V2 on hooks
	///      4/0/5/6, one fund (ALPHA), no module keeper (cast 2026-10-02).
	uint256 internal constant PINNED_BLOCK = 52_066_028;

	address internal constant USDC = FundsMainnet.USDC;
	address internal constant WETH = FundsMainnet.WETH;
	address internal constant UNI_ROUTER = FundsMainnet.UNI_SWAP_ROUTER02;
	/// @dev "VVV" (Venice Token, 18 dp), unpriced in the live VI (isSupportedAsset = false, cast).
	address internal constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;
	/// @dev Uniswap getPool(VVV, USDC, 3000), USDC token0: 332,130 USDC, observation cardinality 360 (cast).
	address internal constant VVV_USDC_3000 = 0x67A11022B7B6ed66f81233F6C8Ed6e48F7826530;
	/// @dev The live degen fund: fundOwner = the deployer; TwapExposurePolicy V1 on hooks 0/4/5/6.
	address internal constant ALPHA = 0x833A506d761A4756AF279ABC24183Db407823dE9;
	/// @dev Real sells moving VVV's spot this many ticks drain its pool's USDC far under the $25k
	///      floor (TwapListingV2Fork: $285,310 → $2,601 at block 52014634).
	int24 internal constant UNDER_FLOOR_TICKS = 20_000;
	uint256 internal constant DEPOSIT = 10_000e6;
	uint256 internal constant BUY = 1_000e6;

	bool internal forked;
	address internal deployer;
	FundFactory internal factory;
	ValueInterpreter internal vi;
	TwapListingRegistryV2 internal registry;
	PriceListingModule internal module;
	address internal uniAdapter;
	address internal policyV1;
	address internal policyV2;
	TwapExposurePolicyV3 internal policyV3;
	Comptroller internal degenV2;
	Comptroller internal normalV2;
	Comptroller internal degenV3;
	Comptroller internal normalV3;
	address internal keeper = makeAddr('twapKeeper');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');
	address internal stranger = makeAddr('stranger');

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, vm.envOr('BASE_FORK_BLOCK', PINNED_BLOCK));
		forked = true;

		string memory genesis = vm.readFile(GENESIS_FILE);
		string memory twapV2 = vm.readFile(TWAP_V2_FILE);
		deployer = vm.parseJsonAddress(genesis, '.deployer');
		factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		vi = ValueInterpreter(vm.parseJsonAddress(genesis, '.valueInterpreter'));
		uniAdapter = vm.parseJsonAddress(genesis, '.uniAdapter');
		policyV1 = vm.parseJsonAddress(genesis, '.twapPolicy');
		registry = TwapListingRegistryV2(vm.parseJsonAddress(twapV2, '.registry'));
		module = PriceListingModule(vm.parseJsonAddress(twapV2, '.module'));
		policyV2 = vm.parseJsonAddress(twapV2, '.policy');

		// the keeper role Plan B will hold (no keeper is set on mainnet yet)
		vm.prank(deployer);
		module.setKeeper(keeper, true);

		// controls: funds created before the switch keep V2
		degenV2 = _fund('V3 Rehearsal Degen Control', 'v2DGN', true);
		normalV2 = _fund('V3 Rehearsal Normal Control', 'v2NRM', false);

		// the switch, exactly as DeployTwapPolicyV3 broadcasts it
		vm.startPrank(deployer);
		policyV3 = TwapPolicyV3.deploy(_v3Config());
		vm.stopPrank();

		degenV3 = _fund('V3 Rehearsal Degen', 'v3DGN', true);
		normalV3 = _fund('V3 Rehearsal Normal', 'v3NRM', false);
	}

	// ─── wiring ──────────────────────────────────────────────────────────────────

	/// New funds run V3 (never V2) on the four hooks, even when a manager names V2 itself; V1 and V2
	/// funds may opt into V3; V3 has no owner; a second deploy run stops before sending anything.
	function test_fork_wiring() public {
		vm.skip(!forked);
		FundFactory.PolicyReg[] memory mandatory = factory.getMandatoryPolicies();
		uint8[4] memory hooks = [uint8(4), 0, 5, 6];
		assertEq(mandatory.length, 4);
		for (uint256 i; i < 4; ++i) {
			assertEq(uint8(mandatory[i].hook), hooks[i], 'hooks kept in genesis order');
			assertEq(mandatory[i].policy, address(policyV3));
		}
		assertEq(factory.policyReplacements(policyV1), address(policyV3), 'V1 funds may opt in');
		assertEq(factory.policyReplacements(policyV2), address(policyV3), 'V2 funds may opt in');
		assertEq(address(policyV3.registry()), address(registry));
		(bool hasOwner,) = address(policyV3).staticcall(abi.encodeWithSignature('owner()'));
		assertFalse(hasOwner, 'no admin surface');

		_assertRuns(degenV3, address(policyV3), policyV2);
		_assertRuns(normalV3, address(policyV3), policyV2);
		_assertRuns(degenV2, policyV2, address(policyV3));

		// naming V2 in its own ruleset doesn't keep a fund off V3
		FundFactory.PolicyReg[] memory own = new FundFactory.PolicyReg[](1);
		own[0] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnIntegration, policy: policyV2});
		Comptroller dodger = Comptroller(factory.createFund(_config('V3 Rehearsal Dodger', 'v3DDG', true), own));
		assertEq(
			_count(dodger.getPolicies(IPolicy.PolicyHook.PostCallOnIntegration), address(policyV3)), 1, 'V3 attached anyway'
		);

		vm.expectRevert(
			abi.encodeWithSelector(TwapPolicyV3.MandatoryPolicyMismatch.selector, uint256(0), uint8(4), address(policyV3))
		);
		this.deployAgain();
	}

	// ─── the gap ─────────────────────────────────────────────────────────────────

	/// THE RED CASE. Listed and healthy: degen and normal funds buy. Drained under the floor for
	/// 72 h: a V2 degen fund still buys (the gap); a V3 degen fund can't; normal funds can't (as before).
	function test_fork_degenCannotBuyADelistedToken() public {
		vm.skip(!forked);
		_listVvv();
		_buyOk(degenV3);
		_buyOk(normalV3);
		_delistVvv();

		_buyOk(degenV2); // the gap V3 closes
		bytes memory delisted = abi.encodeWithSelector(TwapExposurePolicyV3.BuyingDelistedAsset.selector, VVV);
		_buyRefused(degenV3, delisted);
		_buyRefused(normalV3, delisted);
		_buyRefused(normalV2, delisted);
	}

	/// Scope (founder 2026-10-02): delisted only. Under the floor with the clock running, a degen
	/// fund still buys; the refusal starts at exactly DELIST_GRACE.
	function test_fork_clockRunningIsNotDelisted() public {
		vm.skip(!forked);
		_listVvv();
		_drain();
		vm.prank(stranger);
		assertTrue(registry.pokeFloor(VVV), 'the clock starts');
		_warpRoll(registry.DELIST_GRACE() - 1);
		assertFalse(registry.isDelisted(VVV));
		_buyOk(degenV3);
		_warpRoll(1);
		assertTrue(registry.isDelisted(VVV));
		_buyRefused(degenV3, abi.encodeWithSelector(TwapExposurePolicyV3.BuyingDelistedAsset.selector, VVV));
	}

	// ─── exits ───────────────────────────────────────────────────────────────────

	/// A degen fund holding a delisted token can always get out: deposits pause (as in V2), an
	/// investor redeems in kind (no policy runs), the manager sells the rest, deposits reopen.
	function test_fork_degenExitsADelistedHolding() public {
		vm.skip(!forked);
		_listVvv();
		_buyOk(degenV3);
		_delistVvv();
		address vault = address(degenV3.vault());

		deal(USDC, alice, 100e6);
		vm.startPrank(alice);
		IERC20(USDC).approve(address(degenV3), 100e6);
		vm.expectRevert(abi.encodeWithSelector(TwapExposurePolicyV3.DepositsPausedDelistedHolding.selector, VVV));
		degenV3.requestDeposit(100e6);
		degenV3.redeemSharesInKind(degenV3.shares().balanceOf(alice) / 2);
		vm.stopPrank();
		assertGt(IERC20(VVV).balanceOf(alice), 0, 'in kind pays out the delisted token');

		uint256 rest = IERC20(VVV).balanceOf(vault);
		uint256 usdcBefore = IERC20(USDC).balanceOf(vault);
		vm.prank(manager);
		degenV3.callOnIntegration(uniAdapter, abi.encode(VVV, USDC, uint24(3000), rest, uint256(0)));
		assertEq(IERC20(VVV).balanceOf(vault), 0, 'sold out');
		assertGt(IERC20(USDC).balanceOf(vault), usdcBefore, 'for USDC');

		vm.prank(alice);
		degenV3.requestDeposit(100e6); // nothing delisted held any more: deposits reopen
	}

	/// A degen fund's resting buy of VVV placed while listed: once VVV is delisted, other calls on
	/// that limit-order position are refused until the order is cancelled; cancelling always passes.
	function test_fork_degenRestingBuyOrderMustBeCancelledFirst() public {
		vm.skip(!forked);
		_listVvv();
		vm.prank(manager);
		address position = degenV3.createExternalPosition(FundsMainnet.LIMIT_ORDER_TYPE, '');
		// at the oracle rate (the position refuses anything worse than 1% under it)
		uint128 minVvv = uint128(vi.calcCanonicalAssetValue(USDC, BUY, VVV));
		bytes memory place = abi.encode(
			uint8(0), abi.encode(USDC, VVV, uint128(BUY), minVvv, uint64(block.timestamp + 7 days))
		);
		_onPosition(degenV3, position, _one(USDC), _oneAmount(BUY + 100e6), new address[](0), place);
		_delistVvv();

		bytes memory returnFree = abi.encode(uint8(2), abi.encode(USDC, uint256(100e6)));
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(TwapExposurePolicyV3.BuyingDelistedAsset.selector, VVV));
		degenV3.callOnExternalPosition(position, new address[](0), new uint256[](0), _one(USDC), returnFree);

		bytes memory cancel = abi.encode(uint8(1), abi.encode(uint256(1)));
		_onPosition(degenV3, position, new address[](0), new uint256[](0), new address[](0), cancel);
		uint256 before = IERC20(USDC).balanceOf(address(degenV3.vault()));
		bytes memory returnAll = abi.encode(uint8(2), abi.encode(USDC, BUY + 100e6));
		_onPosition(degenV3, position, new address[](0), new uint256[](0), _one(USDC), returnAll);
		assertEq(IERC20(USDC).balanceOf(address(degenV3.vault())), before + BUY + 100e6, 'every USDC back in the vault');
	}

	/// Listed: a degen fund may open an LP on VVV (V2's rule for degen funds, kept); a normal fund
	/// never may (unchanged). Delisted: the degen fund can't open one either.
	function test_fork_degenCannotOpenAnLpOnADelistedToken() public {
		vm.skip(!forked);
		_listVvv();
		bytes memory pair = abi.encode(USDC, VVV, uint24(3000));
		vm.prank(manager);
		degenV3.createExternalPosition(FundsMainnet.UNI_LP_TYPE, pair);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(TwapExposurePolicyV3.TwapAssetInExternalPosition.selector, VVV));
		normalV3.createExternalPosition(FundsMainnet.UNI_LP_TYPE, pair);

		_delistVvv();
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(TwapExposurePolicyV3.BuyingDelistedAsset.selector, VVV));
		degenV3.createExternalPosition(FundsMainnet.UNI_LP_TYPE, pair);
	}

	// ─── normal funds: V2's rules ────────────────────────────────────────────────

	/// Non-degen paths are V2's: the same refusal, byte for byte, from the same state.
	function test_fork_normalFundRulesUnchanged() public {
		vm.skip(!forked);
		_listVvv();
		// 30% of GAV into one TWAP token: over the 20% line (or the pool cap, if the band is thin) for both
		bytes memory v2Err = _buyErr(normalV2, 3_000e6);
		bytes memory v3Err = _buyErr(normalV3, 3_000e6);
		bytes4 sel = bytes4(v3Err);
		assertTrue(
			sel == TwapExposurePolicyV3.TwapShareOfGavExceeded.selector || sel == TwapExposurePolicyV3.PoolShareExceeded.selector,
			'a cap refused it'
		);
		assertEq(v3Err, v2Err, 'same rule, same numbers');
	}

	// ─── existing funds: the opt-in path ─────────────────────────────────────────

	/// ALPHA (the only existing fund; degen) runs V1, which reads the empty v1 registry. Its owner
	/// can opt into V3 (V1 → V3 approved) behind the 2-day window, but execution is refused until
	/// its external positions are wound down: positions hold the old Comptroller immutably.
	function test_fork_alphaOptInNeedsItsPositionsWoundDown() public {
		vm.skip(!forked);
		Comptroller alpha = Comptroller(ALPHA);
		assertTrue(alpha.allowRiskyAssets(), 'a degen fund');
		assertEq(_count(alpha.getPolicies(IPolicy.PolicyHook.PostCallOnIntegration), policyV1), 1, 'runs V1');
		TwapListingRegistry v1Registry = TwapExposurePolicy(policyV1).registry();
		assertEq(v1Registry.getListedAssets().length, 0, 'V1 reads the empty v1 registry');
		uint256 positions = alpha.getExternalPositions().length;
		assertGt(positions, 0, 'live positions');
		emit log_named_uint('ALPHA external positions', positions);

		vm.prank(deployer);
		address fresh = factory.createReconfigurationRequest(ALPHA, _configOf(alpha), _one(policyV1));
		(address requested, uint64 executableAt) = factory.reconfigurationRequests(ALPHA);
		assertEq(requested, fresh);
		assertEq(uint256(executableAt), block.timestamp + 2 days, 'max(2 days, its 1-day shares timelock)');
		FundFactory.PolicySwap[] memory swaps = factory.getRequestedPolicySwaps(ALPHA);
		assertEq(swaps.length, 1);
		assertEq(swaps[0].from, policyV1);
		assertEq(swaps[0].to, address(policyV3));

		skip(2 days);
		vm.prank(deployer);
		vm.expectRevert(FundFactory.ExternalPositionsStillActive.selector);
		factory.executeReconfiguration(ALPHA);
	}

	/// A fund created before the switch (V2) opts in: after the window its new Comptroller runs V3
	/// exactly once on every hook and V2 nowhere; its mandate carries over.
	function test_fork_reconfigurationSwapsV2ForV3() public {
		vm.skip(!forked);
		vm.prank(manager);
		address fresh = factory.createReconfigurationRequest(address(normalV2), _configOf(normalV2), _one(policyV2));
		skip(2 days);
		vm.prank(manager);
		factory.executeReconfiguration(address(normalV2));
		_assertRuns(Comptroller(fresh), address(policyV3), policyV2);
		assertEq(
			_count(Comptroller(fresh).getPolicies(IPolicy.PolicyHook.PostCallOnIntegration), factory.unrestrictedMandate()),
			1,
			'the mandate carries over'
		);
	}

	// ─── gas ─────────────────────────────────────────────────────────────────────

	/// What the new check costs, every touched account cold (a fresh transaction's view): a degen
	/// fund's buy pays one registry read more than under V2; a normal fund's path costs the same.
	function test_fork_gasOfTheNewCheck() public {
		vm.skip(!forked);
		_listVvv();
		uint256 degenV2Gas = _validateGas(policyV2, degenV2, VVV);
		uint256 degenV3Gas = _validateGas(address(policyV3), degenV3, VVV);
		uint256 normalV2Gas = _validateGas(policyV2, normalV2, WETH);
		uint256 normalV3Gas = _validateGas(address(policyV3), normalV3, WETH);
		emit log_named_uint('degen buy of a listed TWAP token, V2 (gas)', degenV2Gas);
		emit log_named_uint('degen buy of a listed TWAP token, V3 (gas)', degenV3Gas);
		emit log_named_uint('normal buy of a non-TWAP token, V2 (gas)  ', normalV2Gas);
		emit log_named_uint('normal buy of a non-TWAP token, V3 (gas)  ', normalV3Gas);
		assertGt(degenV3Gas, degenV2Gas, 'V3 reads what V2 skipped for degen funds');
		assertLt(degenV3Gas - degenV2Gas, 10_000, 'one cold registry read');
		assertApproxEqAbs(normalV3Gas, normalV2Gas, 300, 'the normal path is V2s');
	}

	// ─── external wrapper (a library revert needs a call frame) ──────────────────

	function deployAgain() external {
		TwapPolicyV3.deploy(_v3Config());
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	function _v3Config() internal view returns (TwapPolicyV3.Config memory) {
		return TwapPolicyV3.Config({
			deployer: deployer, factory: factory, registry: registry, policyV1: policyV1, policyV2: policyV2
		});
	}

	function _config(string memory name, string memory symbol, bool degen)
		internal
		view
		returns (FundFactory.FundConfig memory)
	{
		return FundFactory.FundConfig({
			name: name,
			symbol: symbol,
			denominationAsset: IERC20(USDC),
			fundOwner: manager,
			mgmtScaledPerSecondRate: 0,
			perfFeeBps: 0,
			sharesActionTimelock: 0,
			minRequestDuration: 1 minutes,
			executionWindow: 1 days,
			allowRiskyAssets: degen
		});
	}

	/// @dev A fresh fund (manager-owned) holding DEPOSIT USDC of alice's.
	function _fund(string memory name, string memory symbol, bool degen) internal returns (Comptroller fund) {
		fund = Comptroller(factory.createFund(_config(name, symbol, degen)));
		deal(USDC, alice, DEPOSIT);
		vm.startPrank(alice);
		IERC20(USDC).approve(address(fund), DEPOSIT);
		fund.requestDeposit(DEPOSIT);
		vm.stopPrank();
		skip(1 minutes);
		fund.executeDepositRequest(alice);
	}

	/// @dev A fund's own terms, read back (a reconfiguration keeps owner and denomination).
	function _configOf(Comptroller fund) internal view returns (FundFactory.FundConfig memory) {
		(uint128 mgmt, uint16 perf) = fund.feeConfig();
		return FundFactory.FundConfig({
			name: fund.shares().name(),
			symbol: fund.shares().symbol(),
			denominationAsset: fund.denominationAsset(),
			fundOwner: fund.fundOwner(),
			mgmtScaledPerSecondRate: mgmt,
			perfFeeBps: perf,
			sharesActionTimelock: uint64(fund.sharesActionTimelock()),
			minRequestDuration: uint64(fund.minRequestDuration()),
			executionWindow: uint64(fund.executionWindow()),
			allowRiskyAssets: fund.allowRiskyAssets()
		});
	}

	function _listVvv() internal {
		vm.prank(keeper);
		module.list(VVV, USDC, TwapListingRegistryV2.Venue.UniswapV3, 3000);
		assertTrue(registry.isTwapPriced(VVV), 'listed: the VI prices VVV through the registry');
	}

	/// @dev Real sells of VVV into its USDC 0.3% pool until spot has moved UNDER_FLOOR_TICKS against
	///      it (USDC is token0, so selling VVV raises the tick), paid out of the pool's USDC.
	function _drain() internal {
		(, int24 spot) = _slot0(VVV_USDC_3000);
		uint160 limit = TickMath.getSqrtRatioAtTick(spot + UNDER_FLOOR_TICKS);
		uint256 amount = 100_000_000e18;
		deal(VVV, address(this), amount);
		IERC20(VVV).approve(UNI_ROUTER, amount);
		IUniswapV3SwapRouter(UNI_ROUTER).exactInputSingle(
			IUniswapV3SwapRouter.ExactInputSingleParams({
				tokenIn: VVV,
				tokenOut: USDC,
				fee: 3000,
				recipient: address(this),
				amountIn: amount,
				amountOutMinimum: 0,
				sqrtPriceLimitX96: limit
			})
		);
		(uint160 sqrtAfter,) = _slot0(VVV_USDC_3000);
		assertEq(sqrtAfter, limit, 'the sells reached the limit');
	}

	function _delistVvv() internal {
		_drain();
		vm.prank(stranger);
		assertTrue(registry.pokeFloor(VVV), 'the drained pool reads under the floor: a stranger starts the clock');
		_warpRoll(registry.DELIST_GRACE());
		assertTrue(registry.isDelisted(VVV), '72 hours under the floor: delisted');
	}

	/// @dev UniswapV3SwapAdapter data: `usdcIn` USDC → VVV through its USDC 0.3% pool.
	function _buy(uint256 usdcIn) internal pure returns (bytes memory) {
		return abi.encode(USDC, VVV, uint24(3000), usdcIn, uint256(0));
	}

	function _buyOk(Comptroller fund) internal {
		address vault = address(fund.vault());
		uint256 before = IERC20(VVV).balanceOf(vault);
		vm.prank(manager);
		fund.callOnIntegration(uniAdapter, _buy(BUY));
		assertGt(IERC20(VVV).balanceOf(vault), before, 'bought');
	}

	function _buyRefused(Comptroller fund, bytes memory expected) internal {
		vm.prank(manager);
		vm.expectRevert(expected);
		fund.callOnIntegration(uniAdapter, _buy(BUY));
	}

	/// @dev The revert data of a buy that must fail (state is unchanged after it).
	function _buyErr(Comptroller fund, uint256 usdcIn) internal returns (bytes memory) {
		vm.prank(manager);
		(bool ok, bytes memory ret) =
			address(fund).call(abi.encodeCall(Comptroller.callOnIntegration, (uniAdapter, _buy(usdcIn))));
		assertFalse(ok, 'expected a revert');
		return ret;
	}

	function _onPosition(
		Comptroller fund,
		address position,
		address[] memory send,
		uint256[] memory amounts,
		address[] memory back,
		bytes memory action
	) internal {
		vm.prank(manager);
		fund.callOnExternalPosition(position, send, amounts, back, action);
	}

	/// @dev Gas of one PostCallOnIntegration validate with every account it can touch cold.
	function _validateGas(address policy, Comptroller fund, address incoming) internal returns (uint256 used) {
		bytes memory data =
			abi.encode(uniAdapter, new address[](0), new uint256[](0), _one(incoming), new uint256[](1));
		vm.cool(policy);
		vm.cool(address(fund));
		vm.cool(address(registry));
		vm.cool(address(vi));
		vm.prank(address(fund));
		uint256 before = gasleft();
		IPolicy(policy).validate(IPolicy.PolicyHook.PostCallOnIntegration, data);
		used = before - gasleft();
	}

	/// @dev On each of the four TWAP hooks: `expected` exactly once, `absent` never.
	function _assertRuns(Comptroller fund, address expected, address absent) internal view {
		IPolicy.PolicyHook[4] memory hooks = [
			IPolicy.PolicyHook.PostCallOnIntegration,
			IPolicy.PolicyHook.PostDepositRequest,
			IPolicy.PolicyHook.CreateExternalPosition,
			IPolicy.PolicyHook.PostCallOnExternalPosition
		];
		for (uint256 h; h < 4; ++h) {
			address[] memory policies = fund.getPolicies(hooks[h]);
			assertEq(_count(policies, expected), 1, 'runs exactly once');
			assertEq(_count(policies, absent), 0, 'never the other version');
		}
	}

	function _count(address[] memory list, address a) internal pure returns (uint256 n) {
		for (uint256 i; i < list.length; ++i) {
			if (list[i] == a) ++n;
		}
	}

	function _one(address a) internal pure returns (address[] memory list) {
		list = new address[](1);
		list[0] = a;
	}

	function _oneAmount(uint256 a) internal pure returns (uint256[] memory list) {
		list = new uint256[](1);
		list[0] = a;
	}

	function _slot0(address pool) internal view returns (uint160 sqrtPriceX96, int24 tick) {
		(bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature('slot0()'));
		assertTrue(ok);
		(sqrtPriceX96, tick) = abi.decode(data, (uint160, int24));
	}

	/// @dev Time passes on Base: ~2-second blocks.
	function _warpRoll(uint256 secs) internal {
		vm.warp(block.timestamp + secs);
		vm.roll(block.number + secs / 2);
	}
}
```

- [ ] **Step 5: Run it and watch the right tests fail (RED)**
```bash
cd /home/dude/FrostyFunds/funds-core
BASE_MAINNET_RPC=$(grep -E '^BASE_RPC_URL=' .env | cut -d= -f2- | tr -d '"') BASE_FORK_BLOCK=52066028 \
	forge test --match-path test/fork/TwapPolicyV3Fork.t.sol -j 1 -vv
```
Expected: **5 failed, 5 passed.**
- FAIL with "call did not revert as expected": `test_fork_degenCannotBuyADelistedToken`, `test_fork_clockRunningIsNotDelisted`, `test_fork_degenRestingBuyOrderMustBeCancelledFirst`, `test_fork_degenCannotOpenAnLpOnADelistedToken`.
- FAIL with "V3 reads what V2 skipped for degen funds": `test_fork_gasOfTheNewCheck`.
- PASS: `test_fork_wiring`, `test_fork_degenExitsADelistedHolding`, `test_fork_normalFundRulesUnchanged`, `test_fork_alphaOptInNeedsItsPositionsWoundDown`, `test_fork_reconfigurationSwapsV2ForV3`.

If `_delistVvv` fails on "reads under the floor" at the pinned block, raise `UNDER_FLOOR_TICKS` to `40_000` and record the measured reserve in its `@dev`. Any other failure means a wrong assumption: stop and report it.

- [ ] **Step 6: Implement V3. Replace `src/policies/TwapExposurePolicyV3.sol` in full**
```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IPolicy} from '../interfaces/IPolicy.sol';
import {IExternalPosition} from '../interfaces/IExternalPosition.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {Comptroller} from '../core/Comptroller.sol';
import {TwapListingRegistryV2} from '../pricing/TwapListingRegistryV2.sol';
import {ITwapPriceAdapter} from '../interfaces/ITwapPriceAdapter.sol';

/// @title TwapExposurePolicyV3
/// @notice Limits for funds holding TWAP-priced assets:
///         - at most 20% of GAV across all TWAP-priced holdings;
///         - per asset, at most 10% of its pool's ±10% QUOTE-side depth — the lower of the live
///           read and the keeper-recorded depth, so liquidity added in the same transaction never
///           lifts a cap (50% once ≥ $250k);
///         - no fund buys a delisted asset, degen funds included: not through an adapter, not with
///           a resting limit order, not by opening an LP on it;
///         - a delisted asset pauses NEW deposits into funds still holding it until sold.
/// @dev TwapExposurePolicyV2 (deployed, never edited) with one change, founder 2026-10-02 ("degen
///      funds shouldnt buy delisted tokens"): degen funds (`allowRiskyAssets`) still skip the caps,
///      no longer the delisted rule. Every non-degen path, every error (same selectors) and the
///      hooks are V2's. Sales are never blocked. A degen fund's newest live limit order buying a
///      delisted asset blocks other calls on that position until cancelled (the cancel passes).
///      Non-degen funds can't LP a TWAP-priced token or place a limit order buying one; TWAP units
///      inside positions count toward the caps. No owner, no settings.
contract TwapExposurePolicyV3 is IPolicy {
	uint256 public constant BPS = 10_000;
	uint256 public constant MAX_GAV_BPS = 2_000;
	uint256 public constant LARGE_POOL_USD = 250_000;
	uint256 public constant SMALL_POOL_CAP_BPS = 1_000;
	uint256 public constant LARGE_POOL_CAP_BPS = 5_000;

	TwapListingRegistryV2 public immutable registry;

	error TwapShareOfGavExceeded(uint256 shareBps);
	error PoolShareExceeded(address asset, uint256 holdingUsd18, uint256 capUsd18);
	error BuyingDelistedAsset(address asset);
	error DepositsPausedDelistedHolding(address asset);
	error TwapAssetInExternalPosition(address asset);
	error UnsupportedHook(PolicyHook hook);

	constructor(TwapListingRegistryV2 registry_) {
		registry = registry_;
	}

	/// @inheritdoc IPolicy
	function implementedHooks() external pure returns (PolicyHook[] memory hooks) {
		hooks = new PolicyHook[](4);
		hooks[0] = PolicyHook.PostCallOnIntegration;
		hooks[1] = PolicyHook.PostDepositRequest;
		hooks[2] = PolicyHook.CreateExternalPosition;
		hooks[3] = PolicyHook.PostCallOnExternalPosition;
	}

	/// @inheritdoc IPolicy
	function validate(PolicyHook hook, bytes calldata validationData) external {
		Comptroller comptroller = Comptroller(msg.sender);
		if (hook == PolicyHook.PostDepositRequest) {
			_checkNoDelistedHolding(comptroller);
		} else if (hook == PolicyHook.PostCallOnIntegration) {
			(,,, address[] memory incomingAssets,) =
				abi.decode(validationData, (address, address[], uint256[], address[], uint256[]));
			_checkBuy(comptroller, incomingAssets);
		} else if (hook == PolicyHook.CreateExternalPosition) {
			(, address position) = abi.decode(validationData, (uint256, address));
			_checkLpPair(position, comptroller.allowRiskyAssets());
		} else if (hook == PolicyHook.PostCallOnExternalPosition) {
			(address position,) = abi.decode(validationData, (address, uint256));
			_checkNewestOrder(position, comptroller.allowRiskyAssets());
		} else {
			revert UnsupportedHook(hook);
		}
	}

	function _checkNoDelistedHolding(Comptroller comptroller) internal view {
		address[] memory held = comptroller.getTrackedAssets();
		address vault = address(comptroller.vault());
		for (uint256 i; i < held.length; ++i) {
			address asset = held[i];
			if (registry.isDelisted(asset) && registry.isTwapPriced(asset) && IERC20(asset).balanceOf(vault) > 0) {
				revert DepositsPausedDelistedHolding(asset);
			}
		}
	}

	function _checkBuy(Comptroller comptroller, address[] memory incomingAssets) internal {
		if (comptroller.allowRiskyAssets()) {
			_refuseDelisted(incomingAssets);
			return;
		}

		bool boughtTwap;
		for (uint256 i; i < incomingAssets.length; ++i) {
			address asset = incomingAssets[i];
			if (!registry.isTwapPriced(asset)) continue;
			if (registry.isDelisted(asset)) revert BuyingDelistedAsset(asset);
			boughtTwap = true;
			_checkPoolShare(comptroller, asset);
		}
		if (boughtTwap) _checkShareOfGav(comptroller);
	}

	/// @dev Degen funds skip the caps, never the delisted rule. Delisted is read first: one storage
	///      read, false for every asset the registry never listed.
	function _refuseDelisted(address[] memory incomingAssets) internal view {
		for (uint256 i; i < incomingAssets.length; ++i) {
			address asset = incomingAssets[i];
			if (registry.isDelisted(asset) && registry.isTwapPriced(asset)) revert BuyingDelistedAsset(asset);
		}
	}

	/// @dev The fund's holding (vault + external positions), in USD, against its pool's ±10%
	///      quote-side depth: the lower of the live read and the keeper-recorded depth.
	function _checkPoolShare(Comptroller comptroller, address asset) internal {
		IValueInterpreter vi = comptroller.valueInterpreter();
		uint256 units = IERC20(asset).balanceOf(address(comptroller.vault())) + _unitsInPositions(comptroller, asset);
		uint256 holdingUsd18 = Math.mulDiv(vi.calcUsdRate(asset), units, 10 ** IERC20Metadata(asset).decimals());
		uint256 depthUsd18 = Math.min(
			ITwapPriceAdapter(registry.adapterOf(asset)).poolDepthUsd(), registry.recordedDepthUsd18(asset)
		);
		uint256 capBps = depthUsd18 < LARGE_POOL_USD * 1e18 ? SMALL_POOL_CAP_BPS : LARGE_POOL_CAP_BPS;
		uint256 capUsd18 = Math.mulDiv(depthUsd18, capBps, BPS);
		if (holdingUsd18 > capUsd18) revert PoolShareExceeded(asset, holdingUsd18, capUsd18);
	}

	function _checkShareOfGav(Comptroller comptroller) internal {
		uint256 gav = comptroller.calcGav();
		if (gav == 0) return;
		address[] memory held = comptroller.getTrackedAssets();
		uint256 twapValue;
		for (uint256 i; i < held.length; ++i) {
			if (registry.isTwapPriced(held[i])) twapValue += comptroller.calcAssetGav(held[i]);
		}
		// TWAP legs inside external positions count too
		IValueInterpreter vi = comptroller.valueInterpreter();
		address denomination = address(comptroller.denominationAsset());
		address[] memory positions = comptroller.getExternalPositions();
		for (uint256 p; p < positions.length; ++p) {
			(address[] memory assets, uint256[] memory amounts) = IExternalPosition(positions[p]).getManagedAssets();
			for (uint256 i; i < assets.length; ++i) {
				if (amounts[i] > 0 && registry.isTwapPriced(assets[i])) {
					twapValue += vi.calcCanonicalAssetValue(assets[i], amounts[i], denomination);
				}
			}
		}
		uint256 shareBps = Math.mulDiv(twapValue, BPS, gav);
		if (shareBps > MAX_GAV_BPS) revert TwapShareOfGavExceeded(shareBps);
	}

	/// @dev Units of `asset` the fund's external positions manage.
	function _unitsInPositions(Comptroller comptroller, address asset) internal returns (uint256 units) {
		address[] memory positions = comptroller.getExternalPositions();
		for (uint256 p; p < positions.length; ++p) {
			(address[] memory assets, uint256[] memory amounts) = IExternalPosition(positions[p]).getManagedAssets();
			for (uint256 i; i < assets.length; ++i) {
				if (assets[i] == asset) units += amounts[i];
			}
		}
	}

	/// @dev An LP's pair is fixed at creation: refuse a TWAP-priced side (non-degen) or a delisted
	///      one (degen). Positions without a pair pass.
	function _checkLpPair(address position, bool degen) internal view {
		_refuseTwap(_addressView(position, 'token0()'), degen);
		_refuseTwap(_addressView(position, 'token1()'), degen);
	}

	/// @dev The newest limit order must not buy a TWAP-priced asset (non-degen) or a delisted one
	///      (degen); selling is allowed, and an order with nothing left to sell passes, so cancelling
	///      it always clears the position. Positions without orders pass.
	function _checkNewestOrder(address position, bool degen) internal view {
		(bool ok, bytes memory ret) = position.staticcall(abi.encodeWithSignature('orderCount()'));
		if (!ok || ret.length != 32) return;
		uint256 newest = abi.decode(ret, (uint256));
		if (newest == 0) return;
		(ok, ret) = position.staticcall(abi.encodeWithSignature('orders(uint256)', newest));
		if (!ok || ret.length < 64) return;
		(, address buyToken, uint128 sellRemaining) = abi.decode(ret, (address, address, uint128));
		if (sellRemaining > 0) _refuseTwap(buyToken, degen);
	}

	/// @dev Non-degen: no TWAP-priced asset at all (V2's rule). Degen: no delisted one.
	function _refuseTwap(address asset, bool degen) internal view {
		if (asset == address(0) || !registry.isTwapPriced(asset)) return;
		if (!degen) revert TwapAssetInExternalPosition(asset);
		if (registry.isDelisted(asset)) revert BuyingDelistedAsset(asset);
	}

	function _addressView(address target, string memory signature) internal view returns (address) {
		(bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(signature));
		return ok && ret.length == 32 ? abi.decode(ret, (address)) : address(0);
	}
}
```
Review aid: `diff src/policies/TwapExposurePolicyV2.sol src/policies/TwapExposurePolicyV3.sol` must show ONLY:
- the natspec;
- the two `validate` branches;
- `_checkBuy`'s first block and the new `_refuseDelisted`;
- the `degen` parameter on `_checkLpPair`, `_checkNewestOrder` and `_refuseTwap`;
- `_refuseTwap`'s body.

Any other difference is a defect.

- [ ] **Step 7: Run it (GREEN), then size and the whole suite**
```bash
cd /home/dude/FrostyFunds/funds-core
BASE_MAINNET_RPC=$(grep -E '^BASE_RPC_URL=' .env | cut -d= -f2- | tr -d '"') BASE_FORK_BLOCK=52066028 \
	forge test --match-path test/fork/TwapPolicyV3Fork.t.sol -j 1 -vv
forge build --sizes 2>/dev/null | grep -E 'TwapExposurePolicyV[23] '
forge test 2>&1 | tail -5
```
Expected:
- 10 passed, 0 failed. The gas logs show a degen overhead of ≈ 5–7k, and normal V2 ≈ V3 (±300).
- V3's runtime size is within ~150 bytes of V2's 8,312 (both far under 24,576).
- The full suite reports 0 failed; fork tests skip without `BASE_MAINNET_RPC`.
- Copy the four gas numbers into the Task 2 runbook line.

- [ ] **Step 8: Founder commits** (agents never commit). Suggested message: `feat: TwapExposurePolicyV3 — degen funds can't buy delisted tokens`. Files: `src/policies/TwapExposurePolicyV3.sol`, `script/mainnet/TwapPolicyV3.sol` and `test/fork/TwapPolicyV3Fork.t.sol`.

### Task 2: Broadcast script + handoff loader + anvil rehearsal + founder wrapper + runbook

**Files:**
- Create: `script/mainnet/DeployTwapPolicyV3.s.sol`
- Modify: `script/mainnet/TransferFundsGovernance.s.sol:24-27` (a constant) and `:57-61` (`_loadV2`)
- Modify: `script/mainnet/FundsGovernance.sol:42` (comment only)
- Create (outside the repo): `/home/dude/FrostyFunds/.ops-scratch/deploy-twap-policy-v3.sh`
- Modify (outside the repo, never committed): `/home/dude/FrostyFunds/MAINNET_RUNBOOK_FUNDS.md`

**Interfaces:**
- Consumes: `TwapPolicyV3.Config`, `TwapPolicyV3.deploy` and `TwapExposurePolicyV3` from Task 1.
- Produces:
  - the address book `deployments/base-mainnet-twap-policy-v3.json`, with keys `policy` (V3), `replaces` (V2) and `startBlock`;
  - env `TWAP_POLICY_V3_FILE` (overrides that path in the governance scripts);
  - wrapper subcommands `rehearse | deploy | resume`.

- [ ] **Step 1: Write** `script/mainnet/DeployTwapPolicyV3.s.sol`
```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {TwapListingRegistryV2} from '../../src/pricing/TwapListingRegistryV2.sol';
import {TwapExposurePolicyV3} from '../../src/policies/TwapExposurePolicyV3.sol';
import {TwapPolicyV3} from './TwapPolicyV3.sol';

/// @notice TwapExposurePolicyV3 on the LIVE Base factory — what test/fork/TwapPolicyV3Fork rehearses.
///         Run by the genesis deployer while it still owns the FundFactory (TwapPolicyV3 lists the
///         three steps: 4 transactions). Reads deployments/base-mainnet.json (factory, twapPolicy,
///         deployer) and deployments/base-mainnet-twap-v2.json (registry, policy). Writes
///         deployments/base-mainnet-twap-policy-v3.json: policy, replaces (V2), startBlock (a lower
///         bound of the deploy block). StartFundsGovernance / Finish / Verify read it.
///         A second run reverts before sending anything (the mandatory list no longer names V2).
///         Run: forge script script/mainnet/DeployTwapPolicyV3.s.sol --rpc-url <base> --account <keystore> \
///              --sender <deployer> --broadcast --slow [--verify]
///         Env: [DEPLOYMENTS_FILE] (default deployments/base-mainnet-twap-policy-v3.json)
contract DeployTwapPolicyV3 is Script {
	string internal constant GENESIS_FILE = 'deployments/base-mainnet.json';
	string internal constant TWAP_V2_FILE = 'deployments/base-mainnet-twap-v2.json';

	function run() external {
		require(block.chainid == 8453, 'Base (8453) only');
		string memory file = vm.envOr('DEPLOYMENTS_FILE', string('deployments/base-mainnet-twap-policy-v3.json'));
		// DEPLOYMENTS_FILE must never name another address book
		if (vm.exists(file)) {
			string memory existing = vm.readFile(file);
			require(
				!vm.keyExistsJson(existing, '.valueInterpreter') && !vm.keyExistsJson(existing, '.registry'),
				'DEPLOYMENTS_FILE is another address book'
			);
		}

		string memory genesis = vm.readFile(GENESIS_FILE);
		string memory twapV2 = vm.readFile(TWAP_V2_FILE);
		TwapPolicyV3.Config memory cfg = TwapPolicyV3.Config({
			deployer: vm.parseJsonAddress(genesis, '.deployer'),
			factory: FundFactory(vm.parseJsonAddress(genesis, '.factory')),
			registry: TwapListingRegistryV2(vm.parseJsonAddress(twapV2, '.registry')),
			policyV1: vm.parseJsonAddress(genesis, '.twapPolicy'),
			policyV2: vm.parseJsonAddress(twapV2, '.policy')
		});
		require(msg.sender == cfg.deployer, 'run as the genesis deployer (it owns the factory)');
		// the head before broadcasting: the deploy lands at or after it
		uint256 startBlock = block.number;

		vm.startBroadcast();
		TwapExposurePolicyV3 policy = TwapPolicyV3.deploy(cfg);
		vm.stopBroadcast();

		string memory k = 'twapPolicyV3';
		vm.serializeAddress(k, 'policy', address(policy));
		vm.serializeAddress(k, 'replaces', cfg.policyV2);
		string memory out = vm.serializeUint(k, 'startBlock', startBlock);
		vm.writeJson(out, file);

		console2.log('TwapExposurePolicyV3', address(policy));
		console2.log('mandatory on hooks 4, 0, 5, 6; approved replacement of V1', cfg.policyV1);
		console2.log('                                                and of V2', cfg.policyV2);
		console2.log('written to', file);
	}
}
```
Then run `forge build` and expect it to compile.

- [ ] **Step 2: Write the founder wrapper** `/home/dude/FrostyFunds/.ops-scratch/deploy-twap-policy-v3.sh`, then `chmod +x` it and check it with `bash -n`
```bash
#!/usr/bin/env bash
# TwapExposurePolicyV3 on Base mainnet: no fund buys a delisted token, degen funds included.
# Runbook section "TWAP exposure policy V3". Nothing reaches mainnet unless you type yes.
#   rehearse  pinned anvil fork (block 52066028): deploy, end state, a refused second run, then the
#             governance handoff scripts (Start → Safe schedule → +2 days → Finish → Verify) must
#             still verify with V3. Restores every file it touches. Sends nothing to Base.
#   deploy    checks the live state, simulates, asks yes, broadcasts 4 txs, prints the end state.
#   resume    finishes a broadcast that died midway (sends only what is missing) and verifies.
set -euo pipefail
cd "$(dirname "$0")/../funds-core"
RPC=$(grep -E '^BASE_RPC_URL=' .env | cut -d= -f2- | tr -d '"')
[ -n "$RPC" ] || { echo 'BASE_RPC_URL not set in funds-core/.env'; exit 1; }
DEPLOYER=0xaE51f2EfE70e57b994BE8F7f97C4dC824c51802a
SAFE=0xB0f37bE90a8BD82D991Bf694F960C67198778B8B
TIMELOCK=0xd50AF6A924f23AC6944fB8eBc981E006B07D83Ba
ANVIL_SENDER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
PINNED=52066028
SCRIPT=script/mainnet/DeployTwapPolicyV3.s.sol
GOV=script/mainnet/TransferFundsGovernance.s.sol
BOOK=deployments/base-mainnet-twap-policy-v3.json
FACTORY=$(jq -r .factory deployments/base-mainnet.json)
V1=$(jq -r .twapPolicy deployments/base-mainnet.json)
V2=$(jq -r .policy deployments/base-mainnet-twap-v2.json)
[ -f "$SCRIPT" ] || { echo "$SCRIPT missing: check out the branch with V3"; exit 1; }

state() { # $1 = rpc url; one call at a time
	echo "factory owner:   $(cast call "$FACTORY" 'owner()(address)' --rpc-url "$1")"; sleep 0.1
	echo "mandatory:       $(cast call "$FACTORY" 'getMandatoryPolicies()((uint8,address)[])' --rpc-url "$1")"; sleep 0.1
	echo "replacement[V1]: $(cast call "$FACTORY" 'policyReplacements(address)(address)' "$V1" --rpc-url "$1")"; sleep 0.1
	echo "replacement[V2]: $(cast call "$FACTORY" 'policyReplacements(address)(address)' "$V2" --rpc-url "$1")"; sleep 0.1
	echo "funds:           $(cast call "$FACTORY" 'fundsCount()(uint256)' --rpc-url "$1")"
}

case "${1:-}" in
	rehearse)
		[ -f "$BOOK" ] && { echo "$BOOK exists: V3 is deployed, nothing to rehearse"; exit 1; }
		[ -e broadcast/DeployTwapPolicyV3.s.sol ] && { echo 'broadcast/DeployTwapPolicyV3.s.sol exists (a real run?): not rehearsing over it'; exit 1; }
		A=http://127.0.0.1:8549
		RBOOK=deployments/rehearsal-twap-policy-v3.json
		SAVE=$(mktemp -d)
		cp -a broadcast/TransferFundsGovernance.s.sol "$SAVE/broadcast-gov"
		if [ -d cache/TransferFundsGovernance.s.sol ]; then cp -a cache/TransferFundsGovernance.s.sol "$SAVE/cache-gov"; fi
		cp deployments/safe-schedule-frostyfunds-handoff.json "$SAVE/"
		anvil --port 8549 --chain-id 8453 --fork-url "$RPC" --fork-block-number "$PINNED" --silent > /dev/null 2>&1 &
		ANVIL=$!
		restore() {
			kill "$ANVIL" 2> /dev/null || true
			rm -rf broadcast/DeployTwapPolicyV3.s.sol cache/DeployTwapPolicyV3.s.sol \
				broadcast/TransferFundsGovernance.s.sol cache/TransferFundsGovernance.s.sol "$RBOOK"
			cp -a "$SAVE/broadcast-gov" broadcast/TransferFundsGovernance.s.sol
			if [ -d "$SAVE/cache-gov" ]; then cp -a "$SAVE/cache-gov" cache/TransferFundsGovernance.s.sol; fi
			cp "$SAVE/safe-schedule-frostyfunds-handoff.json" deployments/
			rm -rf "$SAVE"
			echo 'restored: broadcast/cache governance records and the Safe schedule file'
		}
		trap restore EXIT
		until cast block-number --rpc-url "$A" > /dev/null 2>&1; do sleep 1; done
		cast rpc anvil_impersonateAccount "$DEPLOYER" --rpc-url "$A" > /dev/null
		forge build
		echo '== deploy (anvil) =='
		DEPLOYMENTS_FILE="$RBOOK" forge script "$SCRIPT" --rpc-url "$A" --sender "$DEPLOYER" --unlocked --broadcast --slow
		echo 'gas per tx:'
		jq -r '.receipts[].gasUsed' broadcast/DeployTwapPolicyV3.s.sol/8453/run-latest.json | xargs -n1 cast to-dec
		state "$A"
		echo '== a second run must refuse =='
		if DEPLOYMENTS_FILE="$RBOOK" forge script "$SCRIPT" --rpc-url "$A" --sender "$DEPLOYER" > /dev/null 2>&1; then
			echo 'FAIL: the second run did not refuse'; exit 1
		fi
		echo 'refused, as it must'
		echo '== governance handoff scripts with V3 (anvil only) =='
		TIMELOCK="$TIMELOCK" forge script "$GOV:StartFundsGovernance" --rpc-url "$A" --sender "$DEPLOYER" --unlocked --broadcast --slow
		cast rpc anvil_impersonateAccount "$SAFE" --rpc-url "$A" > /dev/null
		cast rpc anvil_setBalance "$SAFE" 0x8AC7230489E80000 --rpc-url "$A" > /dev/null
		DATA=$(jq -r '.transactions[0].data' deployments/safe-schedule-frostyfunds-handoff.json)
		cast rpc eth_sendTransaction "{\"from\":\"$SAFE\",\"to\":\"$TIMELOCK\",\"data\":\"$DATA\"}" --rpc-url "$A" > /dev/null
		cast rpc evm_increaseTime 172801 --rpc-url "$A" > /dev/null
		cast rpc evm_mine --rpc-url "$A" > /dev/null
		TIMELOCK="$TIMELOCK" TWAP_POLICY_V3_FILE="$RBOOK" forge script "$GOV:FinishFundsGovernance" \
			--rpc-url "$A" --sender "$ANVIL_SENDER" --unlocked --broadcast --slow
		TIMELOCK="$TIMELOCK" TWAP_POLICY_V3_FILE="$RBOOK" forge script "$GOV:VerifyFundsGovernance" --rpc-url "$A"
		echo 'REHEARSAL PASSED: nothing was sent to Base'
		;;
	deploy)
		[ -f "$BOOK" ] && { echo "$BOOK exists: V3 is already deployed"; exit 1; }
		state "$RPC"
		OWNER=$(cast call "$FACTORY" 'owner()(address)' --rpc-url "$RPC")
		[ "${OWNER,,}" = "${DEPLOYER,,}" ] || { echo 'the factory is not the deployer'"'"'s any more: after the handoff this is a timelock proposal'; exit 1; }
		sleep 0.1
		N=$(cast call "$FACTORY" 'getMandatoryPolicies()((uint8,address)[])' --rpc-url "$RPC" | grep -oi "$V2" | wc -l)
		[ "$N" -eq 4 ] || { echo "the mandatory list names V2 $N times, not 4: stopping"; exit 1; }
		DRY=deployments/dry-run-twap-policy-v3.json
		trap 'rm -f "$DRY"' EXIT
		echo 'Building (a stale artifact once broke a simulation)...'
		forge build
		echo "Simulating $SCRIPT against Base mainnet (no transactions sent)..."
		DEPLOYMENTS_FILE="$DRY" forge script "$SCRIPT" --rpc-url "$RPC" --sender "$DEPLOYER" --slow
		rm -f "$DRY"
		echo
		read -rp "Broadcast these 4 transactions to Base MAINNET from $DEPLOYER? Type yes: " ok
		[ "$ok" = yes ] || { echo 'Stopped. Nothing sent.'; exit 0; }
		forge script "$SCRIPT" --rpc-url "$RPC" --sender "$DEPLOYER" --account frosty-main --broadcast --slow --verify
		state "$RPC"
		echo "V3: $(jq -r .policy "$BOOK"). Commit $BOOK."
		echo 'If verification failed partway: deploy-twap-policy-v3.sh resume'
		;;
	resume)
		forge script "$SCRIPT" --rpc-url "$RPC" --sender "$DEPLOYER" --account frosty-main --resume --verify
		state "$RPC"
		;;
	*)
		echo 'Usage: deploy-twap-policy-v3.sh rehearse | deploy | resume'; exit 1 ;;
esac
```
Run: `chmod +x /home/dude/FrostyFunds/.ops-scratch/deploy-twap-policy-v3.sh && bash -n /home/dude/FrostyFunds/.ops-scratch/deploy-twap-policy-v3.sh`. Expected: no output.

- [ ] **Step 3: RED. Rehearse before the loader change.** The handoff verify must reject V3.
```bash
/home/dude/FrostyFunds/.ops-scratch/deploy-twap-policy-v3.sh rehearse
```
Expected:
- The deploy part prints 4 txs and the gas per tx (≈ 1.9M, ≈ 63k, ≈ 50k, ≈ 50k).
- The state shows the mandatory list as V3 ×4 and both replacements = V3. The second run is refused.
- Start succeeds. `FinishFundsGovernance` FAILS with `MandatoryPolicyNotV2(0, <V3 address>)`. This is the bug: without the loader change, the real handoff would be blocked.
- The exit trap prints `restored: …`.
- Then `git -C /home/dude/FrostyFunds/funds-core diff --stat deployments/` prints nothing.

- [ ] **Step 4: The loader change.** In `script/mainnet/TransferFundsGovernance.s.sol`:

After line 27 (`string internal constant COMPOUNDERS_FILE = …;`), add:
```solidity
	/// @dev What DeployTwapPolicyV3 writes; present = every mandatory entry must name its policy.
	///      TWAP_POLICY_V3_FILE (env) overrides the path, for the anvil rehearsal.
	string internal constant TWAP_POLICY_V3_FILE = 'deployments/base-mainnet-twap-policy-v3.json';
```
In `_loadV2`, replace the line `		console2.log('  TwapExposurePolicyV2', v2.policy);` with:
```solidity
		string memory v3File = vm.envOr('TWAP_POLICY_V3_FILE', string(TWAP_POLICY_V3_FILE));
		if (vm.exists(v3File)) {
			v2.policy = vm.parseJsonAddress(vm.readFile(v3File), '.policy');
			console2.log('  TwapExposurePolicyV3 (every mandatory entry)', v2.policy);
		} else {
			console2.log('  TwapExposurePolicyV2', v2.policy);
		}
```
In `script/mainnet/FundsGovernance.sol:42`, replace `		address policy; // TwapExposurePolicyV2 — every mandatory entry` with:
```solidity
		address policy; // the TWAP exposure policy every mandatory entry names: V2, or V3 once DeployTwapPolicyV3 ran
```
Run `forge build` and expect it to compile.

- [ ] **Step 5: GREEN. Rehearse again**
```bash
/home/dude/FrostyFunds/.ops-scratch/deploy-twap-policy-v3.sh rehearse
```
Expected:
- the same deploy output;
- Finish prints `handoff complete and verified: the deployer holds nothing`;
- Verify prints `verified: …`;
- then `REHEARSAL PASSED: nothing was sent to Base` and `restored: …`.

Record the 4 gas numbers.

- [ ] **Step 6: Only the intended paths changed**
```bash
cd /home/dude/FrostyFunds/funds-core && git status --short && git diff --stat deployments/
```
Expected:
- `?? src/policies/TwapExposurePolicyV3.sol`, `?? script/mainnet/TwapPolicyV3.sol`, `?? script/mainnet/DeployTwapPolicyV3.s.sol`, `?? test/fork/TwapPolicyV3Fork.t.sol` and `?? docs/superpowers/plans/2026-10-02-twap-policy-v3.md`;
- ` M script/mainnet/TransferFundsGovernance.s.sol` and ` M script/mainnet/FundsGovernance.sol`;
- empty output for `deployments/`.

(Task 1's three files appear as committed instead if the founder already committed them.)

- [ ] **Step 7: Runbook** `/home/dude/FrostyFunds/MAINNET_RUNBOOK_FUNDS.md` (internal; never committed)

(a) Under "TWAP listing v2 + v2b", in the **Known limit** bullet (line 277: `- To move a fund to V2: …`), append this sub-bullet:
```
  - Superseded 2026-10-02: approve V1 → V3, not V2 (section "TWAP exposure policy V3").
```
(b) Insert this section right before `## Turning the protocol fee on (after FROST launches)`, filling in the measured gas numbers:
````
## TWAP exposure policy V3 (no fund buys a delisted token): BUILT 2026-10-0X, NOT DEPLOYED
Branch `feat/twap-policy-v3` in funds-core. Plan: `docs/superpowers/plans/2026-10-02-twap-policy-v3.md`.
- **What changes (founder 2026-10-02: "degen funds shouldnt buy delisted tokens").** `TwapExposurePolicyV3` is V2 plus one rule: degen funds can't buy a delisted token. Not by swap, not with a resting limit order, not by opening an LP on it.
  - Degen funds still skip the caps.
  - Normal funds: unchanged (same rules, same errors).
  - Sales and in-kind exits are never blocked.
- **"Delisted"** means the pool has been under the floor for 72 h, as of a poke. Anyone can START the clock; only the keeper (through the module) clears it. No keeper is set yet, so a griefer could get a healthy token delisted after 72 h with nobody to clear the clock. Set the Plan B keeper before relying on listings.
- **Deploy (founder, keystore), 4 txs:**
  1. Rehearse: `~/FrostyFunds/.ops-scratch/deploy-twap-policy-v3.sh rehearse`. Pinned anvil fork; it also proves the handoff scripts verify with V3. Sends nothing.
  2. Real run: `~/FrostyFunds/.ops-scratch/deploy-twap-policy-v3.sh deploy`. It checks the owner and the mandatory list, simulates, asks yes, then broadcasts:
     - CREATE V3;
     - `factory.setMandatoryPolicies(V3 on hooks 4,0,5,6)`;
     - `setPolicyReplacement(V1, V3)`;
     - `setPolicyReplacement(V2, V3)`.
     It writes `deployments/base-mainnet-twap-policy-v3.json`; commit it. If it dies midway: `… resume`.
  - Rehearsed 2026-10-0X: gas <CREATE> / <setMandatory> / <repl V1> / <repl V2>, ≈ 2.1M total.
  - No delay while the deployer owns the factory. After the handoff, the same calls are a timelock proposal (2 days).
- **V3 has no owner:** nothing joins the handoff. Start/Finish/Verify read the V3 book and require every mandatory entry to be V3.
- **Who gets V3:** every fund created after the deploy, even one whose manager names V2 in its own ruleset. Existing funds keep their policy until their owner reconfigures.
- **ALPHA (the only existing fund, degen) runs V1,** which reads the EMPTY v1 registry. For v2 listings ALPHA has no TWAP rule at all: no delisted-buy block and no delisted-holding deposit pause. Options:
  - A. **Migrate** (recommended, before ALPHA touches any TWAP listing):
    1. `createReconfigurationRequest(ALPHA, same config, [V1])`. Its 3 positions (2 LPs, 1 perp account) can stay open while the 2-day window runs.
    2. Unwind and remove all 3 positions.
    3. `executeReconfiguration(ALPHA)`.
    The result is a NEW comptroller address; vault, shares, holders and HWM are kept. Re-create the positions, and point the terminal, keeper, subgraph and workflows at the new comptroller.
  - B. Keep ALPHA on V1, and never buy a TWAP-listed token in ALPHA.
  - C. Retire ALPHA and open a new fund (the name "ALPHA" is taken forever).
- **Rule:** never list a 4626 vault whose underlying is TWAP-priced (via `module.execute`). After a delisting no fund could redeem it through the adapter; only in-kind redemption would still work.
- **Not covered:**
  - A resting limit order placed before a delisting stays fillable until it's cancelled. V3 checks only the newest order.
  - An LP opened while the token was listed can keep adding liquidity.
````
After the founder's broadcast, the agent adds a LIVE STATUS line in this form:
```
- 2026-10-0X **TwapExposurePolicyV3 DEPLOYED `<address>`** (block N): mandatory = V3 on 4/0/5/6; replacements V1 → V3, V2 → V3; book committed.
```

- [ ] **Step 8: Founder commits** (agents never commit). Suggested message: `feat: DeployTwapPolicyV3 + handoff reads the V3 book`. Files: `script/mainnet/DeployTwapPolicyV3.s.sol`, `script/mainnet/TransferFundsGovernance.s.sol`, `script/mainnet/FundsGovernance.sol` and this plan.

## Founder ops (exact order)
1. Before Task 0: `cd ~/FrostyFunds/funds-core && git fetch origin`.
2. After Tasks 1–2 and the controller's review: commit (Task 1 Step 8, Task 2 Step 8).
3. Optional: `~/FrostyFunds/.ops-scratch/deploy-twap-policy-v3.sh rehearse` (sends nothing).
4. Broadcast: `~/FrostyFunds/.ops-scratch/deploy-twap-policy-v3.sh deploy`, type `yes`, then commit `deployments/base-mainnet-twap-policy-v3.json`.
5. Decide ALPHA: A, B or C (runbook section). A needs its own small plan: the unwind of the LPs plus a request/execute script, because positions are position-type specific.
6. The governance handoff stays the LAST launch step. Start/Finish/Verify pick up the V3 book automatically.

## Follow-ups (not in this plan)
- **ALPHA migration (option A), if chosen.** Script `createReconfigurationRequest(ALPHA, sameConfig, [V1])` and the execute step, unwind the 2 LPs and the perp account, re-create the positions, and update the terminal, keeper and subgraph to the new comptroller.
- **Item 4:** block degen buys while the clock runs, once the Plan B keeper clears clocks promptly.
