#!/usr/bin/env bash
# Veranta contract-trader probe on a local anvil fork of Base mainnet.
# Emits one STEP/PASS/FAIL line per stage — designed to be watched, never silent.
set -uo pipefail

CORE=/home/dude/FrostyFunds/funds-core
PORT=8547
RPC="http://127.0.0.1:${PORT}"
BLOCK=51321503
KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 # anvil dev key 0 (public)
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
ROUTER=0x44914408af82bC9983bbb330e3578E1105e11d4e
STORAGE=0x8a311D7048c35985aa31C131B9A13e03a5f7422d
MULTICALL=0xA7cFc43872F4D7B0E6141ee8c36f1F7FEe5d099e
FEED_ETH=0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70
KEEPER=0x00000000000000000000000000000000000AB0DE

CID=$(grep -m1 '^NEXT_PUBLIC_THIRDWEB_CLIENT_ID=' /home/dude/FrostyLabs/frostyflow/.env.local 2>/dev/null || grep -m1 '^NEXT_PUBLIC_THIRDWEB_CLIENT_ID=' /home/dude/FrostyLabs/frostyflow/.env)
CID=${CID#*=}; CID=$(echo "$CID" | tr -d '"\r ')
UPSTREAM="https://8453.rpc.thirdweb.com/${CID}"

step() { echo "STEP $(date +%H:%M:%S) $*"; }
fail() { echo "FAIL $(date +%H:%M:%S) $*"; kill "${ANVIL_PID:-0}" 2>/dev/null; exit 1; }

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
step "anvil up (pid ${ANVIL_PID})"

step "deploying probe"
cd "$CORE" || fail "cd funds-core"
OUT=$(timeout 300 forge create script/probe/VerantaProbe.sol:VerantaProbe \
	--rpc-url "$RPC" --private-key "$KEY" --broadcast \
	--constructor-args "$ROUTER" "$USDC" "$STORAGE" 2>&1)
PROBE=$(echo "$OUT" | grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | awk '{print $3}')
[ -n "${PROBE:-}" ] || fail "deploy failed: $(echo "$OUT" | tail -3)"
step "probe deployed at ${PROBE} (constructor USDC approval to TradingStorage SUCCEEDED)"

step "funding probe with 1,000 USDC via slot-9 write"
SLOT=$(cast index address "$PROBE" 9)
cast rpc --rpc-url "$RPC" anvil_setStorageAt "$USDC" "$SLOT" \
	0x000000000000000000000000000000000000000000000000000000003b9aca00 >/dev/null || fail "setStorageAt"
BAL=$(cast call --rpc-url "$RPC" "$USDC" 'balanceOf(address)(uint256)' "$PROBE")
echo "$BAL" | grep -q '^1000000000' || fail "USDC balance write did not stick: $BAL"
step "probe holds $BAL raw USDC"

step "TEST 1: setDelegate from a contract trader"
EXPIRY=$(( $(date +%s) + 7776000 ))
timeout 300 cast send --rpc-url "$RPC" --private-key "$KEY" "$PROBE" \
	'probeSetDelegate(address,uint256)' "$KEEPER" "$EXPIRY" >/dev/null 2>&1 || fail "setDelegate tx REVERTED"
DELEG=$(cast call --rpc-url "$RPC" "$ROUTER" 'multipleDelegations(address,address)(bool,uint256)' "$PROBE" "$KEEPER")
echo "$DELEG" | grep -q 'true' || fail "delegation not stored: $DELEG"
echo "PASS $(date +%H:%M:%S) TEST 1: router stored delegation for contract trader -> $DELEG"

step "TEST 2: openTrade (market short ETH/USD, 200 USDC x2) from a contract trader"
RAW=$(cast call --rpc-url "$RPC" "$FEED_ETH" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' | sed -n 2p | awk '{print $1}')
REF=$(( RAW * 100 )) # 8dp feed -> 1e10 price scale
step "chainlink ETH ref price (1e10): ${REF}"
OPEN_OUT=$(timeout 300 cast send --rpc-url "$RPC" --private-key "$KEY" "$PROBE" \
	'probeOpenShort(uint256,uint256,uint256,uint256,uint256)' 0 200000000 20000000000 "$REF" 50000000000 2>&1)
if echo "$OPEN_OUT" | grep -q 'status.*1\|success'; then
	echo "PASS $(date +%H:%M:%S) TEST 2: openTrade tx mined successfully"
else
	echo "FAILINFO $(date +%H:%M:%S) openTrade output tail: $(echo "$OPEN_OUT" | tail -5)"
	fail "openTrade tx REVERTED"
fi

PENDING=$(cast call --rpc-url "$RPC" "$MULTICALL" 'getPendingOrder(address)((uint256,((address,uint256,uint256,uint256,uint256,uint256,bool,uint256,uint256,uint256,uint256),uint256,uint256,uint256))[])' "$PROBE" 2>&1)
ESCROW=$(cast call --rpc-url "$RPC" "$USDC" 'balanceOf(address)(uint256)' "$PROBE")
echo "RESULT pendingOrders: $(echo "$PENDING" | head -c 400)"
echo "RESULT probe USDC after open: $ESCROW (was 1000000000 — 200000000 escrowed if it dropped to 800000000)"
echo "$PENDING" | grep -q "$(echo "$PROBE" | tr 'A-F' 'a-f')\|${PROBE}" && echo "PASS $(date +%H:%M:%S) TEST 2: pending order visible in Multicall for contract trader"

echo "DONE $(date +%H:%M:%S) probe complete — killing anvil"
kill "$ANVIL_PID" 2>/dev/null
exit 0
