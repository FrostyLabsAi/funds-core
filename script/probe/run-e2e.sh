#!/usr/bin/env bash
# Veranta keeper fork e2e: deploy the full funds-core stack on an anvil fork of Base,
# opt the fund into autopilot, then let the REAL TypeScript keeper rebalance through
# Veranta's delegatedAction. STEP/PASS/FAIL lines throughout — never silent.
set -uo pipefail

CORE=/home/dude/FrostyFunds/funds-core
KEEPER_DIR=/home/dude/FrostyFunds/funds-keeper
PORT=8548
RPC="http://127.0.0.1:${PORT}"
BLOCK=51321503

# anvil dev keys (public): 0 = deployer/manager, 1 = keeper delegate
KEY0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
KEY1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
KEEPER_ADDR=0x70997970C51812dc3A010C7d01b50e0d17dc79C8

USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
WETH=0x4200000000000000000000000000000000000006
FEED_ETH=0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70
ROUTER=0x44914408af82bC9983bbb330e3578E1105e11d4e
MULTICALL=0xA7cFc43872F4D7B0E6141ee8c36f1F7FEe5d099e

CID=$(grep -m1 '^NEXT_PUBLIC_THIRDWEB_CLIENT_ID=' /home/dude/FrostyLabs/frostyflow/.env.local 2>/dev/null || grep -m1 '^NEXT_PUBLIC_THIRDWEB_CLIENT_ID=' /home/dude/FrostyLabs/frostyflow/.env)
CID=${CID#*=}; CID=$(echo "$CID" | tr -d '"\r ')
UPSTREAM="https://8453.rpc.thirdweb.com/${CID}"

step() { echo "STEP $(date +%H:%M:%S) $*"; }
fail() { echo "FAIL $(date +%H:%M:%S) $*"; kill "${ANVIL_PID:-0}" 2>/dev/null; exit 1; }

step "starting anvil fork of Base @ ${BLOCK} (native chain id — keeper signs for 8453)"
pkill -f "anvil.*--port ${PORT}" 2>/dev/null
anvil --fork-url "$UPSTREAM" --fork-block-number "$BLOCK" --port "$PORT" --silent &
ANVIL_PID=$!
for i in $(seq 1 60); do
	cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break
	kill -0 "$ANVIL_PID" 2>/dev/null || fail "anvil died on startup"
	sleep 2
done
step "anvil up (pid ${ANVIL_PID})"

step "deploying funds-core stack + fund + VerantaPerpPositionV2"
cd "$CORE" || fail "cd funds-core"
OUT=$(E2E_KEEPER=$KEEPER_ADDR timeout 600 forge script script/probe/DeployVerantaE2E.s.sol:DeployVerantaE2E \
	--rpc-url "$RPC" --private-key "$KEY0" --broadcast --skip-simulation --slow 2>&1)
COMPTROLLER=$(echo "$OUT" | grep -oE 'E2E_COMPTROLLER 0x[0-9a-fA-F]{40}' | awk '{print $2}')
VAULT=$(echo "$OUT" | grep -oE 'E2E_VAULT 0x[0-9a-fA-F]{40}' | awk '{print $2}')
POSITION=$(echo "$OUT" | grep -oE 'E2E_POSITION 0x[0-9a-fA-F]{40}' | awk '{print $2}')
[ -n "${COMPTROLLER:-}" ] && [ -n "${VAULT:-}" ] && [ -n "${POSITION:-}" ] || fail "deploy failed: $(echo "$OUT" | tail -5)"
step "fund ${COMPTROLLER} · vault ${VAULT} · position ${POSITION}"

step "long leg: wrapping 0.8 ETH -> WETH into the vault"
cast send --rpc-url "$RPC" --private-key "$KEY0" "$WETH" 'deposit()' --value 0.8ether >/dev/null || fail "WETH deposit"
cast send --rpc-url "$RPC" --private-key "$KEY0" "$WETH" 'transfer(address,uint256)' "$VAULT" 800000000000000000 >/dev/null || fail "WETH transfer"

step "hedge budget: 2,000 USDC to the vault via slot-9 write"
SLOT=$(cast index address "$VAULT" 9)
cast rpc --rpc-url "$RPC" anvil_setStorageAt "$USDC" "$SLOT" \
	0x0000000000000000000000000000000000000000000000000000000077359400 >/dev/null || fail "setStorageAt"

step "manager opt-in: move 1,500 USDC vault -> position + SetAutopilot (one comptroller call)"
EXPIRY=$(( $(date +%s) + 7776000 ))
INNER=$(cast abi-encode 'f(uint256)' "$EXPIRY")
ACTION=$(cast abi-encode 'f(uint8,bytes)' 4 "$INNER")
cast send --rpc-url "$RPC" --private-key "$KEY0" "$COMPTROLLER" \
	'callOnExternalPosition(address,address[],uint256[],address[],bytes)' \
	"$POSITION" "[$USDC]" "[1500000000]" "[]" "$ACTION" >/dev/null || fail "callOnExternalPosition SetAutopilot"
DELEG=$(cast call --rpc-url "$RPC" "$ROUTER" 'multipleDelegations(address,address)(bool,uint256)' "$POSITION" "$KEEPER_ADDR")
echo "$DELEG" | grep -q 'true' || fail "delegation not live: $DELEG"
echo "PASS $(date +%H:%M:%S) manager opted in — keeper delegated on the real router ($DELEG)"

run_keeper() {
	cd "$KEEPER_DIR" && \
	VERANTA_COMPTROLLER="$COMPTROLLER" VERANTA_POSITION="$POSITION" VERANTA_ASSET="$WETH" \
	VERANTA_ASSET_DECIMALS=18 VERANTA_FEED="$FEED_ETH" VERANTA_PAIR_INDEX=0 \
	VERANTA_KEEPER_KEY="$KEY1" VERANTA_RPC_URL="$RPC" \
	SUBGRAPH_URL="http://localhost:8000/subgraphs/name/frostyfunds/funds" \
	timeout 300 npm run --silent veranta:once 2>&1
}

step "KEEPER PASS 1 (live): expect increase_short ~0.8 via delegatedAction"
P1=$(run_keeper)
echo "$P1" | sed 's/^/KEEPER1| /'
echo "$P1" | grep -q 'increase_short' || fail "keeper did not decide increase_short"
echo "$P1" | grep -qE 'rebalance: increase_short.*success' || fail "keeper rebalance tx did not succeed"
echo "PASS $(date +%H:%M:%S) keeper opened the hedge through delegatedAction"

PENDING=$(cast call --rpc-url "$RPC" "$MULTICALL" 'getPendingOrder(address)((uint256,((address,uint256,uint256,uint256,uint256,uint256,bool,uint256,uint256,uint256,uint256),uint256,uint256,uint256))[])' "$POSITION")
POSBAL=$(cast call --rpc-url "$RPC" "$USDC" 'balanceOf(address)(uint256)' "$POSITION")
echo "RESULT pending order: $(echo "$PENDING" | head -c 300)"
echo "RESULT position USDC after open: $POSBAL (funded 1500000000 — collateral escrowed with Veranta)"
echo "$PENDING" | grep -qi "${POSITION#0x}" || fail "no pending order for the position"
echo "PASS $(date +%H:%M:%S) collateral escrowed, order pending the Veranta operator"

step "KEEPER PASS 2 (live): expect SKIP — in-flight order gate"
P2=$(run_keeper)
echo "$P2" | sed 's/^/KEEPER2| /'
echo "$P2" | grep -q 'SKIP: market order in flight' || fail "in-flight gate did not trigger"
echo "PASS $(date +%H:%M:%S) in-flight gate held — no double-trade"

echo "DONE $(date +%H:%M:%S) e2e complete — killing anvil"
kill "$ANVIL_PID" 2>/dev/null
exit 0
