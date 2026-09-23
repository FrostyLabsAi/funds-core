#!/usr/bin/env bash
# PROTECT MODE E2E — full retail lifecycle on a fresh local anvil, driving the REAL
# protect keeper (funds-keeper npm run protect:once). No broadcasts, no fork.
#
#   HEDGE (Trailing Protect — the "ipod token" acceptance story):
#     user holds 2 tETH · enables 8% trailing protect · price 2500 → keeper tracks
#     → price 2200 (−12%) → keeper OPENS the short via delegatedAction (user's USDC)
#     → operator fill → price recovers 2510 → keeper RELEASES the hedge
#   STOP (trailing stop):
#     user opens a 2x LONG · price runs 2500→2800 (trail arms at the high)
#     → price 2600 (−7.1% > 5%) → keeper MARKET-CLOSES the position
set -uo pipefail

CORE=/home/dude/FrostyFunds/funds-core
KEEPER_DIR=/home/dude/FrostyFunds/funds-keeper
PORT=8549
RPC="http://127.0.0.1:${PORT}"
KEY0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 # keeper (anvil dev 0)
KEY1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d # user   (anvil dev 1)
KEEPER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
USER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8

step() { echo "STEP $(date +%H:%M:%S) $*"; }
fail() { echo "✗ FAIL: $*"; kill "${ANVIL_PID:-0}" 2>/dev/null; exit 1; }
deploy() { # contract path:name [constructor args…] → address
	local TARGET=$1; shift
	local OUT
	if [ $# -gt 0 ]; then
		OUT=$(forge create "$TARGET" --rpc-url "$RPC" --private-key "$KEY0" --broadcast --constructor-args "$@" 2>&1)
	else
		OUT=$(forge create "$TARGET" --rpc-url "$RPC" --private-key "$KEY0" --broadcast 2>&1)
	fi
	echo "$OUT" | grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | awk '{print $3}'
}
run_protect() {
	(cd "$KEEPER_DIR" && \
	VERANTA_PAIRS="0:${TETH}:${FEED}:18" \
	VERANTA_ROUTER=$VENUE VERANTA_MULTICALL=$VENUE VERANTA_STORAGE=$VENUE VERANTA_USDC=$TUSDC VERANTA_PYTH=$VENUE \
	PROTECT_REGISTRY=$REGISTRY PROTECT_START_BLOCK=0 PROTECT_STATE_FILE="$STATE_FILE" \
	VERANTA_KEEPER_KEY=$KEY0 VERANTA_RPC_URL=$RPC VERANTA_CHAIN_ID=84532 \
	timeout 120 npm run --silent protect:once 2>&1)
}

step "starting fresh anvil on :${PORT}"
pkill -f "anvil.*--port ${PORT}" 2>/dev/null
anvil --port "$PORT" --chain-id 84532 --silent &
ANVIL_PID=$!
for i in $(seq 1 30); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 || fail "anvil not answering"

step "deploying the world (venue, tokens, feed, registry)"
cd "$CORE" || fail cd
TUSDC=$(deploy 'test/utils/Mocks.sol:MockERC20' 'Test USDC' tUSDC 6);         [ -n "$TUSDC" ] || fail "tUSDC deploy"
TETH=$(deploy 'test/utils/Mocks.sol:MockERC20' 'Test ETH' tETH 18);           [ -n "$TETH" ] || fail "tETH deploy"
FEED=$(deploy 'test/utils/Mocks.sol:MockAggregator' 8 250000000000);          [ -n "$FEED" ] || fail "feed deploy"
VENUE=$(deploy 'test/utils/MockVeranta.sol:MockVeranta' "$TUSDC");            [ -n "$VENUE" ] || fail "venue deploy"
REGISTRY=$(deploy 'src/protect/ProtectRegistry.sol:ProtectRegistry');         [ -n "$REGISTRY" ] || fail "registry deploy"
STATE_FILE=$(mktemp -u /tmp/protect-e2e-state-XXXX.json)
step "venue $VENUE · registry $REGISTRY"

step "user setup: 2 tETH spot · 5,000 tUSDC · venue approval · keeper delegation"
cast send --rpc-url "$RPC" --private-key "$KEY0" "$TETH" 'mint(address,uint256)' "$USER" 2000000000000000000 >/dev/null
cast send --rpc-url "$RPC" --private-key "$KEY0" "$TUSDC" 'mint(address,uint256)' "$USER" 5000000000 >/dev/null
cast send --rpc-url "$RPC" --private-key "$KEY1" "$TUSDC" 'approve(address,uint256)' "$VENUE" 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff >/dev/null
EXPIRY=$(( $(date +%s) + 7776000 ))
cast send --rpc-url "$RPC" --private-key "$KEY1" "$VENUE" 'setDelegate(address,uint256)' "$KEEPER" "$EXPIRY" >/dev/null

step "═══ SCENARIO 1: TRAILING PROTECT (hedge) — 8% trail"
cast send --rpc-url "$RPC" --private-key "$KEY1" "$REGISTRY" \
	'configure(uint8,uint256,address,uint16,uint16)' 0 0 "$TETH" 800 2 >/dev/null || fail "configure HEDGE"

P1=$(run_protect); echo "$P1"
echo "$P1" | grep -q 'tracking high' || fail "pass 1: not tracking"

step "price 2500 → 2200 (−12%, through the 8% trail)"
cast send --rpc-url "$RPC" --private-key "$KEY0" "$FEED" 'setAnswer(int256)' 220000000000 >/dev/null
P2=$(run_protect); echo "$P2"
echo "$P2" | grep -q 'PROTECTED: short 2.0000' || fail "pass 2: hedge did not open"

step "in-flight gate check (order pending), then operator fill @ 2200"
P3=$(run_protect); echo "$P3"
echo "$P3" | grep -q 'in flight' || fail "pass 3: pending gate missed"
cast send --rpc-url "$RPC" --private-key "$KEY0" "$VENUE" 'fillPending(uint256)' 22000000000000 >/dev/null

P4=$(run_protect); echo "$P4"
echo "$P4" | grep -qE 'hedged since .*protected high \$2500' || fail "pass 4: not holding the hedge"

step "price recovers to 2510 (above the protected high) — expect RELEASE"
cast send --rpc-url "$RPC" --private-key "$KEY0" "$FEED" 'setAnswer(int256)' 251000000000 >/dev/null
P5=$(run_protect); echo "$P5"
echo "$P5" | grep -q 'RELEASED' || fail "pass 5: hedge not released"
echo "✓ SCENARIO 1 PASS — hedge armed on the drawdown, held through the dip, released on recovery"

step "═══ SCENARIO 2: TRAILING STOP — 5% trail on a 2x long"
cast send --rpc-url "$RPC" --private-key "$KEY1" "$REGISTRY" \
	'configure(uint8,uint256,address,uint16,uint16)' 1 0 0x0000000000000000000000000000000000000000 500 0 >/dev/null || fail "configure STOP"
# user opens a 1,000 USDC 2x LONG at 2510 and the operator fills it
cast send --rpc-url "$RPC" --private-key "$KEY1" "$VENUE" \
	'openTrade((address,uint256,uint256,uint256,uint256,uint256,bool,uint256,uint256,uint256,uint256),uint8,uint256)' \
	"(${USER},0,0,0,1000000000,25100000000000,true,20000000000,0,0,0)" 0 10000000000 >/dev/null || fail "user openTrade"
cast send --rpc-url "$RPC" --private-key "$KEY0" "$VENUE" 'fillPending(uint256)' 25100000000000 >/dev/null

P6=$(run_protect); echo "$P6"
echo "$P6" | grep -q 'long trailing' || fail "pass 6: stop not tracking the long"

step "price runs to 2800 (trail follows the high)"
cast send --rpc-url "$RPC" --private-key "$KEY0" "$FEED" 'setAnswer(int256)' 280000000000 >/dev/null
P7=$(run_protect); echo "$P7"
echo "$P7" | grep -q 'trailing \$2800' || fail "pass 7: extreme did not ratchet to 2800"

step "price falls to 2600 (−7.1% from 2800, through the 5% trail) — expect CLOSE"
cast send --rpc-url "$RPC" --private-key "$KEY0" "$FEED" 'setAnswer(int256)' 260000000000 >/dev/null
P8=$(run_protect); echo "$P8"
echo "$P8" | grep -q 'STOPPED OUT' || fail "pass 8: trailing stop did not close"

P9=$(run_protect); echo "$P9" | grep -E "HEDGE|STOP|tracking" | head -2
echo "✓ SCENARIO 2 PASS — stop trailed the run-up and closed on the retrace"

rm -f "$STATE_FILE"
echo "✓✓✓ PROTECT E2E COMPLETE — both products lifecycle-proven against the demo venue"
kill "$ANVIL_PID" 2>/dev/null
exit 0
