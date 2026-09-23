#!/usr/bin/env bash
# updateMargin fork probe — the gate for keeper-v2 auto top-up (README: "deferred until
# its oracle-fee semantics are fork-tested"). Runs against the REAL Veranta v2 contracts
# on an anvil fork of Base mainnet, using a real trader's live ETH short and a REAL
# wormhole-signed Pyth payload replayed from an on-chain update tx (no mocks; Hermes
# itself is API-key-gated since 2026-08-26, so the probe replays instead of fetching).
#
# Ground truth from the verified sources (TradingRouter impl 0x18d580…, PositionUpdates-
# Module 0x092b7d…, DelegateModule 0xe6D7dF…, PriceAggregator impl 0x5c7349…):
#   updateMargin(pair, index, updateType{0=DEPOSIT,1=WITHDRAW}, amount1e6,
#                priceUpdateData[], PriceSourcing{0=PYTH_CORE,1=PYTH_LAZER,2=AVANTIS}) payable
#   — SINGLE-TX: aggregator.fulfill{value: msg.value} runs inline — no operator round-trip.
#   — UPDATE_MARGIN is NOT in _ifParseUpdateData → the PYTH_CORE path is
#     pyth.updatePriceFeeds(payload) + getPriceNoOlderThan(feedId, 30): a payload is only
#     needed when the stored on-chain Pyth price is older than 30s (always send one).
#   — msg.value must cover pyth.getUpdateFee(payload) — ZERO wei on Base today
#     (singleUpdateFeeInWei = 0, transactionFeeInWei = 0); keeper reads it at runtime.
#   — Delegatable: module reads __msgSender() (senderOverride), delegatedAction forwards
#     msg.value, no selector restrictions. DEPOSIT pulls USDC from the TRADER (our position
#     contract, already max-approved to TradingStorage); WITHDRAW pays the trader only.
#   — AVANTIS sourcing needs their whitelisted publisher's signature — not usable by us.
#   — Gated by whenMarketNotPaused(pair): equity-pair top-ups revert while paused (weekends).
#
# TESTS:
#   1  trader DEPOSIT 50 USDC w/ replayed real payload, msg.value = getUpdateFee
#      → collateral up, USDC pulled from trader, leverage down, liq px further away
#   2  delegate DEPOSIT via delegatedAction w/ EMPTY payload (stored price < 30s)
#      → same effect; USDC from trader, keeper pays nothing but gas — the keeper-v2 path
set -uo pipefail

PORT=8548
RPC="http://127.0.0.1:${PORT}"
KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 # anvil dev key 0 (public)
KEEPER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
ROUTER=0x44914408af82bC9983bbb330e3578E1105e11d4e
STORAGE=0x8a311D7048c35985aa31C131B9A13e03a5f7422d
MULTICALL=0xA7cFc43872F4D7B0E6141ee8c36f1F7FEe5d099e
PYTH=0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a
ETH_USD_PYTH_ID=ff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace

# A real trader with a live ETH/USD short (found via router logs; override when they
# close it: TRADER=0x… PAIR=n INDEX=n ./run-margin-probe.sh)
TRADER=${TRADER:-0xE624C6089641C922b769f804BC5c8F1590378893}
PAIR=${PAIR:-0}
INDEX=${INDEX:-0}
DEPOSIT=50000000 # 50 USDC per test

CID=$(grep -m1 '^NEXT_PUBLIC_THIRDWEB_CLIENT_ID=' /home/dude/FrostyLabs/frostyflow/.env.local 2>/dev/null || grep -m1 '^NEXT_PUBLIC_THIRDWEB_CLIENT_ID=' /home/dude/FrostyLabs/frostyflow/.env)
CID=${CID#*=}; CID=$(echo "$CID" | tr -d '"\r ')
UPSTREAM="https://8453.rpc.thirdweb.com/${CID}"

step() { echo "STEP $(date +%H:%M:%S) $*"; }
fail() { echo "FAIL $(date +%H:%M:%S) $*"; kill "${ANVIL_PID:-0}" 2>/dev/null; exit 1; }

trade_state() { # → "collateral1e6 leverage1e10 liqPx1e10"
	# Stored-trade collateral is initialPosToken (field 4) — the verified source marks
	# positionSizeUSDC "//dummy" for OPEN trades (it is collateral only on SUBMISSION).
	local LIQ POS
	LIQ=$(cast call --rpc-url "$RPC" "$MULTICALL" \
		'getDynamicDataForPosition(address,uint256,uint256)(uint256,uint256,int256)' "$TRADER" "$PAIR" "$INDEX" \
		| sed -n 1p | awk '{print $1}') || return 1
	POS=$(cast call --rpc-url "$RPC" "$STORAGE" \
		'openTrades(address,uint256,uint256)((address,uint256,uint256,uint256,uint256,uint256,bool,uint256,uint256,uint256,uint256))' \
		"$TRADER" "$PAIR" "$INDEX")
	echo "$(echo "$POS" | tr -d '()' | cut -d',' -f4 | awk '{print $1}') $(echo "$POS" | tr -d '()' | cut -d',' -f8 | awk '{print $1}') $LIQ"
}

step "finding the newest on-chain Pyth tx carrying an ETH/USD update (payload replay source)"
PYTH_TX=$(curl -s -m 40 "https://base.blockscout.com/api/v2/addresses/${PYTH}/transactions?filter=to" \
	| python3 -c "
import json,sys
d=json.load(sys.stdin)
for it in d.get('items',[]):
	if it.get('result','') in ('success','') and '${ETH_USD_PYTH_ID}' in it.get('raw_input',''):
		print(it['block_number'], it['hash']); break
")
[ -n "${PYTH_TX:-}" ] || fail "no recent ETH/USD Pyth update tx found on Base"
read BLOCK TXHASH <<<"$PYTH_TX"
step "replaying payload from tx ${TXHASH} (block ${BLOCK}) — forking AT that block so the payload is in-window"

INPUT=$(cast tx "$TXHASH" input --rpc-url "$UPSTREAM")
VAA=$(cast decode-calldata 'updatePriceFeedsIfNecessary(bytes[],bytes32[],uint64[])' "$INPUT" \
	| sed -n 1p | tr -d '[] ' | cut -d',' -f1)
echo "$VAA" | grep -q '^0x' || fail "could not extract priceUpdateData from ${TXHASH}"
step "payload extracted ($(( (${#VAA} - 2) / 2 )) bytes, real wormhole signatures)"

step "starting anvil fork of Base @ ${BLOCK}"
pkill -f "anvil --fork-url.*${PORT}" 2>/dev/null
anvil --fork-url "$UPSTREAM" --fork-block-number "$BLOCK" --port "$PORT" --chain-id 84530 --silent &
ANVIL_PID=$!
for i in $(seq 1 60); do
	cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break
	kill -0 "$ANVIL_PID" 2>/dev/null || fail "anvil died on startup"
	sleep 2
done
cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 || fail "anvil not answering after 120s"
T0=$(cast block latest --rpc-url "$RPC" -f timestamp)
step "anvil up (pid ${ANVIL_PID}) · fork timestamp ${T0}"

FEE=$(cast call --rpc-url "$RPC" "$PYTH" 'getUpdateFee(bytes[])(uint256)' "[${VAA}]" | awk '{print $1}')
step "pyth.getUpdateFee(payload) = ${FEE} wei (keeper reads this at runtime, never hardcodes)"

step "impersonating trader ${TRADER} (live short on pair ${PAIR})"
cast rpc --rpc-url "$RPC" anvil_impersonateAccount "$TRADER" >/dev/null || fail "impersonate"
cast rpc --rpc-url "$RPC" anvil_setBalance "$TRADER" 0xDE0B6B3A7640000 >/dev/null # 1 ETH gas
SLOT=$(cast index address "$TRADER" 9)
cast rpc --rpc-url "$RPC" anvil_setStorageAt "$USDC" "$SLOT" \
	0x000000000000000000000000000000000000000000000000000000003b9aca00 >/dev/null || fail "USDC balance write"
cast send --rpc-url "$RPC" --unlocked --from "$TRADER" "$USDC" \
	'approve(address,uint256)' "$STORAGE" \
	0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff >/dev/null || fail "USDC approve"

read C0 L0 LIQ0 <<<"$(trade_state)" || fail "reading trade state"
step "BEFORE: collateral $((C0 / 1000000)) USDC · leverage $(echo "$L0" | awk '{printf "%.1f", $1/1e10}')x · liq \$$(echo "$LIQ0" | awk '{printf "%.2f", $1/1e10}')"
[ "${C0:-0}" -gt 0 ] || fail "trader has no open trade at pair ${PAIR}/${INDEX} — pick another (see router logs)"

step "TEST 1: trader DEPOSIT 50 USDC (replayed payload, msg.value=${FEE})"
cast rpc --rpc-url "$RPC" evm_setNextBlockTimestamp $((T0 + 5)) >/dev/null
BAL0=$(cast call --rpc-url "$RPC" "$USDC" 'balanceOf(address)(uint256)' "$TRADER" | awk '{print $1}')
cast send --rpc-url "$RPC" --unlocked --from "$TRADER" "$ROUTER" \
	"$(cast calldata 'updateMargin(uint256,uint256,uint8,uint256,bytes[],uint8)' \
		"$PAIR" "$INDEX" 0 "$DEPOSIT" "[${VAA}]" 0)" --value "$FEE" >/dev/null \
	|| fail "TEST 1: updateMargin DEPOSIT reverted"
read C1 L1 LIQ1 <<<"$(trade_state)"
BAL1=$(cast call --rpc-url "$RPC" "$USDC" 'balanceOf(address)(uint256)' "$TRADER" | awk '{print $1}')
# The full amount is pulled from the trader; collateral credits amount MINUS a small
# venue processing fee (observed ~0.03%) — keeper top-up sizing must overshoot slightly.
DELTA1=$((C1 - C0)); FEE1=$((DEPOSIT - DELTA1))
[ "$DELTA1" -gt $((DEPOSIT - 1000000)) ] && [ "$DELTA1" -le "$DEPOSIT" ] \
	|| fail "TEST 1: collateral ${C0} → ${C1} (Δ${DELTA1}), expected ≈+${DEPOSIT}"
[ $((BAL0 - BAL1)) -eq "$DEPOSIT" ] || fail "TEST 1: trader USDC moved $((BAL0 - BAL1)), expected ${DEPOSIT}"
[ "$L1" -lt "$L0" ] || fail "TEST 1: leverage did not drop (${L0} → ${L1})"
echo "PASS $(date +%H:%M:%S) TEST 1: DEPOSIT applied — collateral +$(echo "$DELTA1" | awk '{printf "%.6f", $1/1e6}') USDC (venue fee $(echo "$FEE1" | awk '{printf "%.6f", $1/1e6}')), leverage $(echo "$L0 $L1" | awk '{printf "%.1fx → %.1fx", $1/1e10, $2/1e10}'), liq \$$(echo "$LIQ0 $LIQ1" | awk '{printf "%.2f → %.2f", $1/1e10, $2/1e10}')"

step "TEST 2: same DEPOSIT via delegatedAction, EMPTY payload (stored Pyth price < 30s)"
EXPIRY=$((T0 + 7776000))
cast send --rpc-url "$RPC" --unlocked --from "$TRADER" "$ROUTER" \
	'setDelegate(address,uint256)' "$KEEPER" "$EXPIRY" >/dev/null || fail "setDelegate"
INNER=$(cast calldata 'updateMargin(uint256,uint256,uint8,uint256,bytes[],uint8)' \
	"$PAIR" "$INDEX" 0 "$DEPOSIT" '[]' 0)
cast rpc --rpc-url "$RPC" evm_setNextBlockTimestamp $((T0 + 12)) >/dev/null
KEEPER_BAL0=$(cast call --rpc-url "$RPC" "$USDC" 'balanceOf(address)(uint256)' "$KEEPER" | awk '{print $1}')
cast send --rpc-url "$RPC" --private-key "$KEY" "$ROUTER" \
	'delegatedAction(address,bytes)' "$TRADER" "$INNER" --value 0 >/dev/null \
	|| fail "TEST 2: delegatedAction(updateMargin) reverted"
read C2 L2 LIQ2 <<<"$(trade_state)"
BAL2=$(cast call --rpc-url "$RPC" "$USDC" 'balanceOf(address)(uint256)' "$TRADER" | awk '{print $1}')
KEEPER_BAL1=$(cast call --rpc-url "$RPC" "$USDC" 'balanceOf(address)(uint256)' "$KEEPER" | awk '{print $1}')
DELTA2=$((C2 - C1))
[ "$DELTA2" -gt $((DEPOSIT - 1000000)) ] && [ "$DELTA2" -le "$DEPOSIT" ] \
	|| fail "TEST 2: collateral ${C1} → ${C2} (Δ${DELTA2}), expected ≈+${DEPOSIT}"
[ $((BAL1 - BAL2)) -eq "$DEPOSIT" ] || fail "TEST 2: USDC did not come from the TRADER"
[ "$KEEPER_BAL0" -eq "$KEEPER_BAL1" ] || fail "TEST 2: keeper USDC moved — custody violation"
echo "PASS $(date +%H:%M:%S) TEST 2: delegate DEPOSIT applied — USDC from trader, keeper paid gas only · leverage $(echo "$L1 $L2" | awk '{printf "%.1fx → %.1fx", $1/1e10, $2/1e10}') · liq \$$(echo "$LIQ1 $LIQ2" | awk '{printf "%.2f → %.2f", $1/1e10, $2/1e10}')"

if [ "${KEEP_ANVIL:-0}" = 1 ]; then
	echo "DONE $(date +%H:%M:%S) margin probe complete — anvil left running on :${PORT} (pid ${ANVIL_PID}) for the keeper margin-e2e"
else
	echo "DONE $(date +%H:%M:%S) margin probe complete — killing anvil"
	kill "$ANVIL_PID" 2>/dev/null
fi
exit 0
