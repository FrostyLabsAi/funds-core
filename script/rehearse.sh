#!/usr/bin/env bash
# FLAGSHIP-ON-VERANTA-RAILS REHEARSAL — one command, whole loop (Base Sepolia):
#   A: fund born w/ venue mandate → deposit request (1-min cooldown)
#   B: execute deposit → LP long leg (real Uniswap NPM) → Veranta position + autopilot ON
#   keeper pass 1: detects under-hedge, opens the short via delegatedAction
#   operator fill (demo venue, public fillPending) → keeper pass 2: within band
#   C: de-risk (halve LP) → keeper pass 3: REDUCES the short → final report
# Run from funds-core: ./script/rehearse.sh   (uses PRIVATE_KEY etc. from .env)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
set -a; source .env; set +a

FACTORY_W6=0x27c620d184513295B605e90e74D745D9c79f721A
VENUE=0x8fA15B90985863f73e7B62e1dFA3D7740c75a4D4 # wave 6.2 (fork-proven collateral layout + updateMargin)
TETH=0xB949122bF2991edA2d660A2E99f2393ffE74Ae01
TETH_FEED=0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1
RPC=${BASE_SEPOLIA_RPC_URL:-https://base-sepolia-rpc.publicnode.com}
KEEPER_DIR=../funds-keeper
SUBGRAPH=http://localhost:8000/subgraphs/name/frostyfunds/funds

step() { echo; echo "═══ $(date +%H:%M:%S) $*"; }
fail() { echo "✗ FAIL: $*"; exit 1; }

# RESUME MODE: pass RIG_COMPTROLLER + RIG_LP + RIG_VPOS (+RIG_GAV0) to skip phases A/B
if [ -n "${RIG_COMPTROLLER:-}" ] && [ -n "${RIG_LP:-}" ] && [ -n "${RIG_VPOS:-}" ]; then
	COMPTROLLER=$RIG_COMPTROLLER; LP=$RIG_LP; VPOS=$RIG_VPOS; GAV0=${RIG_GAV0:-?}
	echo "═══ RESUMING with existing fund $COMPTROLLER"
else

step "PHASE A — create mandated fund + deposit request"
OUT=$(FACTORY=$FACTORY_W6 TETH=$TETH forge script script/RehearseFlagship.s.sol:RehearseFlagship \
	--rpc-url "$RPC" --private-key "$PRIVATE_KEY" --broadcast --slow 2>&1)
COMPTROLLER=$(echo "$OUT" | grep -oE 'RIG_COMPTROLLER 0x[0-9a-fA-F]{40}' | awk '{print $2}')
[ -n "${COMPTROLLER:-}" ] || fail "phase A: $(echo "$OUT" | tail -4)"
echo "✓ fund: $COMPTROLLER (venue mandate: LP + veranta perps, set once)"

step "waiting out the 1-minute deposit cooldown…"
sleep 70

step "PHASE B — execute deposit → LP long leg → veranta hedge + autopilot"
OUT=$(RIG_COMPTROLLER=$COMPTROLLER TUSDC=$TUSDC TETH=$TETH forge script script/RehearseFlagship.s.sol:RehearseFlagshipB \
	--rpc-url "$RPC" --private-key "$PRIVATE_KEY" --broadcast --slow 2>&1)
LP=$(echo "$OUT" | grep -oE 'RIG_LP_POSITION 0x[0-9a-fA-F]{40}' | awk '{print $2}')
VPOS=$(echo "$OUT" | grep -oE 'RIG_VERANTA_POSITION 0x[0-9a-fA-F]{40}' | awk '{print $2}')
GAV0=$(echo "$OUT" | grep -oE 'RIG_GAV [0-9]+' | awk '{print $2}')
[ -n "${VPOS:-}" ] || fail "phase B: $(echo "$OUT" | tail -4)"
echo "✓ LP position: $LP · veranta position: $VPOS · GAV: $GAV0 (1e6)"
fi

step "waiting for the subgraph to index the LP position (keeper discovers it there)…"
for i in $(seq 1 100); do
	N=$(curl -s -m 5 "$SUBGRAPH" -X POST -H 'content-type: application/json' \
		-d "{\"query\":\"{ externalPositions(where:{fund:\\\"${COMPTROLLER,,}\\\", typeId:\\\"3\\\"}) { id } }\"}" | grep -c "${LP,,}" || true)
	[ "$N" -ge 1 ] && break
	sleep 6
done
[ "$N" -ge 1 ] || fail "subgraph never indexed the LP position"
echo "✓ LP position indexed"

run_keeper() {
	(cd "$KEEPER_DIR" && \
	VERANTA_COMPTROLLER=$COMPTROLLER VERANTA_POSITION=$VPOS VERANTA_ASSET=$TETH \
	VERANTA_ASSET_DECIMALS=18 VERANTA_FEED=$TETH_FEED VERANTA_PAIR_INDEX=0 \
	VERANTA_ROUTER=$VENUE VERANTA_MULTICALL=$VENUE VERANTA_STORAGE=$VENUE VERANTA_USDC=$TUSDC VERANTA_PYTH=$VENUE \
	VERANTA_KEEPER_KEY=$PRIVATE_KEY VERANTA_RPC_URL=$RPC VERANTA_CHAIN_ID=84532 SUBGRAPH_URL=$SUBGRAPH \
	timeout 240 npm run --silent veranta:once 2>&1)
}

step "KEEPER PASS 1 — expect increase_short ≈ LP's tETH share"
P1=$(run_keeper); echo "$P1"
if echo "$P1" | grep -q 'SKIP: market order in flight'; then
	echo "✓ short already opened in a previous run — order pending the operator"
elif echo "$P1" | grep -qE 'within .*band'; then
	echo "✓ hedge already filled and within band from a previous run — skipping to phase C"
	SKIP_FILL=1
else
	echo "$P1" | grep -q 'increase_short' || fail "keeper pass 1 did not open the hedge"
	echo "$P1" | grep -qE 'rebalance: .*success' || fail "keeper pass 1 tx failed"
fi

if [ "${SKIP_FILL:-0}" = 1 ]; then
step "OPERATOR FILL — skipped (already filled in a previous run)"
else
step "OPERATOR FILL — demo venue, at the live Chainlink price"
PX8=$(cast call --rpc-url "$RPC" "$TETH_FEED" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' | sed -n 2p | awk '{print $1}')
FILLED=0
for i in 1 2 3 4; do
	sleep 4 # let the previous tx settle into the RPC's nonce view
	if cast send --rpc-url "$RPC" --private-key "$PRIVATE_KEY" "$VENUE" 'fillPending(uint256)' $((PX8 * 100)) >/dev/null 2>&1; then FILLED=1; break; fi
done
[ "$FILLED" = 1 ] || fail "fillPending (after 4 attempts)"
echo "✓ filled at feed price $((PX8 / 100000000)) USD"

fi
step "KEEPER PASS 2 — expect drift within band (delta-neutral confirmed)"
P2=$(run_keeper); echo "$P2"
echo "$P2" | grep -qE 'within .*band|none' || fail "keeper pass 2 not within band"
GAV1=$(cast call --rpc-url "$RPC" "$COMPTROLLER" 'calcGav()(uint256)' | awk '{print $1}')
echo "✓ GAV after hedge: $GAV1 (was $GAV0)"

step "PHASE C — de-risk: halve the LP long leg"
OUT=$(RIG_COMPTROLLER=$COMPTROLLER RIG_LP=$LP UNI_ADAPTER=0xB7d0C0Fc11DC4EB792833E83952713B0b7d2Fc56 TETH=$TETH forge script script/RehearseFlagshipC.s.sol:RehearseFlagshipC \
	--rpc-url "$RPC" --private-key "$PRIVATE_KEY" --broadcast --slow 2>&1)
echo "$OUT" | grep -E 'RIG_GAV_AFTER_DERISK' || fail "phase C: $(echo "$OUT" | tail -4)"

step "KEEPER PASS 3 — expect reduce_short (over-hedged after de-risk)"
P3=$(run_keeper); echo "$P3"
echo "$P3" | grep -q 'reduce_short' || fail "keeper pass 3 did not reduce the hedge"
echo "$P3" | grep -qE 'rebalance: .*success' || fail "keeper pass 3 tx failed"

step "FINAL STATE"
GAV2=$(cast call --rpc-url "$RPC" "$COMPTROLLER" 'calcGav()(uint256)' | awk '{print $1}')
P4=$(run_keeper); echo "$P4" | grep -E 'veranta pair|liq distance' || true
echo
echo "✓✓✓ REHEARSAL COMPLETE"
echo "  fund $COMPTROLLER · LP $LP · hedge $VPOS"
echo "  GAV: open $GAV0 → hedged $GAV1 → after de-risk+rebalance $GAV2 (1e6 units)"
echo "  watch it in the terminal: https://frostyfunds.localhost:1355/fund/$COMPTROLLER"
