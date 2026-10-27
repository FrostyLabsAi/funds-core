#!/usr/bin/env bash
# LIST THE VERANTA-PRICED STOCKS (Base mainnet, founder 2026-10-25): the seven Coinbase stocks with no Chainlink feed
# that funds can buy on Aero — MUc PLTRc NFLXc AMDc AVGOc MRVLc LLYc — each becomes a VI primitive on its
# B20VerantaPriceAdapter (Veranta's Pyth-signed price × the token's multiplier()) with a 10-minute heartbeat.
# MUc and PLTRc are pool-priced today; this re-points them (no fund held either, 2026-10-25).
# Each also gets a VI answer band, ⅓× to 3× its price at listing (review 2026-10-25): the price is Pyth's share price
# × Coinbase's multiplier, two sources that update apart — a split re-confirmed at the old close while the multiplier
# already moved (or the reverse) is a 2–4× error, which then reverts instead of pricing. A stock that really triples
# (or falls to a third) needs its band widened: the same setAnswerBounds call, with SEND=1 BANDS_ONLY=1.
# Deploy first: script/mainnet/DeployVerantaStocks.s.sol (writes deployments/base-mainnet-veranta-stocks.json).
# cast, NOT forge: addPrimitive reads the B20 token's decimals(), a Base precompile Foundry can't run.
# The VI's owner is today's registrar, owned by registrar V2 (2026-10-09), owned by the deployer — or by registrar V3
# once the Aero venue's owner steps ran (2026-10-25), whose callOldRegistrar is V2's one hop further: each listing is
# callOldRegistrar(execute(addPrimitive(stock, adapter, 600))) on whichever of the two the deployer owns.
# Checks before anything is sent, per stock: the token is the one Coinbase names (symbol, 8 decimals, multiplier > 0);
# the adapter reads that token, that Veranta pair and the deployed store; Veranta's pair is that ticker; the store
# accepts Veranta's current packet for the pair (simulated); Veranta's price × multiplier is within 3% of the stock's
# Aero USDC pool (a $100 quote from Aero's Metaquoter) — catches a wrong pair or token; the listing simulates from the
# deployer.
#   Checks only (default): ./script/mainnet/list-veranta-stocks.sh
#   Send:                  SEND=1 ./script/mainnet/list-veranta-stocks.sh   (signs with --account frosty-main)
# Reads BASE_RPC_URL from .env (or the environment). Never prints it.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1

RPC=${BASE_RPC_URL:-$(grep -E '^BASE_RPC_URL=' .env 2>/dev/null | cut -d= -f2- | tr -d '"')}
[ -n "$RPC" ] || { echo "✗ FAIL: set BASE_RPC_URL"; exit 1; }
BOOK=${VERANTA_STOCKS_FILE:-deployments/base-mainnet-veranta-stocks.json}
DEPLOYER=0xaE51f2EfE70e57b994BE8F7f97C4dC824c51802a
HEARTBEAT=120 # = the adapters' maxPushAge (DeployVerantaStocks.MAX_PUSH_AGE)
MAX_FEED_AGE=432000
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
AERO_FACTORY=0x9CB220581b91b0C83223012FE69688b92aD07a76
METAQUOTER=0x1dDfeC5058180C207F55BB77D95AcDd0d8227868
VERANTA_FEED=https://feed-v3.veranta.xyz
VERANTA_DATA=https://data.veranta.xyz/v2/trading

# SYM TOKEN VERANTA_PAIR AERO_USDC_POOL (deepest USDC pool of each, $198k–$463k on 2026-10-25)
STOCKS=(
	"MUc 0xb200000000000000000000Fd2f87532B90095211 100 0x41e21950362B1014bC629252ecFFF8fcA5F1646C"
	"PLTRc 0xb2000000000000000000007d16372840dF4dAbbe 110 0xA0473ceD0cd1bfB857e3E04B5FA4b6aF18C5e44d"
	"NFLXc 0xb20000000000000000000058B8c947e44011dFE6 112 0x67Ba8dBeDC6D7f93f0F5967Aa2420715f1edC756"
	"AMDc 0xB2000000000000000000000d8Ce462E99ee7A47B 98 0x138Cb591C4A7D854D796E1906af8228d84CB7642"
	"AVGOc 0xB200000000000000000000Fc737aeA6196aB5a4c 111 0x086A1447D0851F0aeA9D09D6c547fEC8E97be413"
	"MRVLc 0xB200000000000000000000eC3c4c7395Cc609813 107 0x611ab290422d534D9595b01e648911fefA963137"
	"LLYc 0xB200000000000000000000f1a0F91e34892E4718 120 0x2b7ee4623ec6AfbC1e587b2668c0ED8F3ff44949"
)

fail() { echo "✗ FAIL: $*"; exit 1; }
call() { sleep "${THROTTLE:-0}"; cast call "$@" --rpc-url "$RPC"; } # THROTTLE=0.5 on a public RPC
lower() { tr '[:upper:]' '[:lower:]'; }
num() { awk '{print $1}'; } # cast prints a large number with its scientific form: "432000 [4.32e5]"
json() { python3 -c "import json,sys; print(json.load(open('$1'))$2)"; }

[ "$(cast chain-id --rpc-url "$RPC")" = "8453" ] || [ -n "${REHEARSAL:-}" ] || fail "not Base mainnet (8453)"
[ -f "$BOOK" ] || fail "no $BOOK — run DeployVerantaStocks first"
STORE=$(json "$BOOK" "['store']")
VI=$(json deployments/base-mainnet.json "['valueInterpreter']")
REGISTRAR_V2=$(json deployments/base-mainnet-v4.json "['registrar']")
OLD_REGISTRAR=$(call "$VI" 'owner()(address)')
[ "$(call "$OLD_REGISTRAR" 'owner()(address)' | lower)" = "$(echo "$REGISTRAR_V2" | lower)" ] || fail "registrar V2 doesn't own the VI's owner"
VIA=$REGISTRAR_V2
V2_OWNER=$(call "$REGISTRAR_V2" 'owner()(address)' | lower)
if [ "$V2_OWNER" != "$(echo "$DEPLOYER" | lower)" ]; then
	AERO_BOOK=deployments/base-mainnet-aero-registrar.json
	[ -f "$AERO_BOOK" ] && [ "$V2_OWNER" = "$(json "$AERO_BOOK" "['registrar']" | lower)" ] \
		|| fail "registrar V2 is owned by $V2_OWNER: neither the deployer nor the registrar V3 in $AERO_BOOK"
	[ "$(call "$V2_OWNER" 'owner()(address)' | lower)" = "$(echo "$DEPLOYER" | lower)" ] || fail "the deployer doesn't own registrar V3"
	VIA=$V2_OWNER
fi
FEE=$(call "$(call "$STORE" 'lazer()(address)')" 'verification_fee()(uint256)' | awk '{print $1}')
curl -sf -m 60 -A curl/8.5.0 "$VERANTA_DATA" -o "${TMPDIR:-/tmp}/veranta-trading.json" || fail "can't read $VERANTA_DATA"
echo "store $STORE · VI $VI · listings through $VIA"

declare -A BAND
echo "── checks"
for row in "${STOCKS[@]}"; do
	read -r SYM TOKEN PAIR POOL <<<"$row"
	TICKER=${SYM%c}
	ADAPTER=$(json "$BOOK" "['$SYM']")
	[ "$(call "$TOKEN" 'symbol()(string)' | tr -d '"')" = "$SYM" ] || fail "$TOKEN is not $SYM"
	[ "$(call "$TOKEN" 'decimals()(uint8)' | num)" = "8" ] || fail "$SYM decimals"
	MULT=$(call "$TOKEN" 'multiplier()(uint256)' | awk '{print $1}')
	[ "$MULT" != "0" ] || fail "$SYM multiplier is 0"
	[ "$(call "$ADAPTER" 'token()(address)' | lower)" = "$(echo "$TOKEN" | lower)" ] || fail "$SYM adapter token"
	[ "$(call "$ADAPTER" 'pairIndex()(uint256)' | num)" = "$PAIR" ] || fail "$SYM adapter pair"
	[ "$(call "$ADAPTER" 'store()(address)' | lower)" = "$(echo "$STORE" | lower)" ] || fail "$SYM adapter store"
	[ "$(call "$ADAPTER" 'maxPushAge()(uint32)' | num)" = "$HEARTBEAT" ] || fail "$SYM adapter maxPushAge"
	[ "$(call "$ADAPTER" 'maxFeedAge()(uint32)' | num)" = "$MAX_FEED_AGE" ] || fail "$SYM adapter maxFeedAge"
	FROM=$(python3 -c "
import json; p = json.load(open('${TMPDIR:-/tmp}/veranta-trading.json'))['pairInfos']
p = p.values() if isinstance(p, dict) else p
print(next(x['from'] for x in p if x['index'] == $PAIR))")
	[ "$FROM" = "$TICKER" ] || fail "Veranta pair $PAIR is $FROM, not $TICKER"
	[ "$(call "$POOL" 'factory()(address)' | lower)" = "$(echo "$AERO_FACTORY" | lower)" ] || fail "$SYM pool isn't Aero's"
	FEED=$(curl -sf -m 30 -A curl/8.5.0 "$VERANTA_FEED/v2/pairs/$PAIR/price-update-data") || fail "Veranta's feed for $PAIR"
	PACKET=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['pro']['priceUpdateData'])" "$FEED")
	PRICE=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['pro']['price'])" "$FEED")
	# a packet can be a block ahead of the chain (FeedFromFuture): retry once after the next block
	cast call "$STORE" 'submit(uint256,bytes)(bool)' "$PAIR" "$PACKET" --value "$FEE" --rpc-url "$RPC" >/dev/null 2>&1 \
		|| { sleep 3; cast call "$STORE" 'submit(uint256,bytes)(bool)' "$PAIR" "$PACKET" --value "$FEE" --rpc-url "$RPC" >/dev/null; } \
		|| fail "the store refuses Veranta's packet for $SYM"
	OUT=$(call "$METAQUOTER" 'quoteExactInputSingleV3(address,address,uint256,uint160)(uint256,uint160,uint32)' "$POOL" "$USDC" 100000000 0 | head -1 | awk '{print $1}')
	read -r TOKEN_PX POOL_PX <<<"$(python3 -c "print($PRICE * $MULT / 1e18, 100 / ($OUT / 1e8))")"
	python3 -c "import sys; sys.exit(0 if abs($TOKEN_PX / $POOL_PX - 1) < 0.03 else 1)" \
		|| fail "$SYM: Veranta × multiplier \$$TOKEN_PX is more than 3% off its Aero pool \$$POOL_PX"
	ADD=$(cast calldata 'addPrimitive(address,address,uint32)' "$TOKEN" "$ADAPTER" "$HEARTBEAT")
	CALL=$(cast calldata 'execute(bytes)' "$ADD")
	cast call "$VIA" 'callOldRegistrar(bytes)' "$CALL" --from "$DEPLOYER" --rpc-url "$RPC" >/dev/null \
		|| fail "$SYM: the listing doesn't simulate from the deployer"
	# the answer band in the adapter's 8 decimals
	read -r LO HI <<<"$(python3 -c "import math; p = $TOKEN_PX * 1e8; print(math.floor(p / 3), math.ceil(p * 3))")"
	BAND[$SYM]="$LO $HI"
	BOUNDS=$(cast calldata 'execute(bytes)' "$(cast calldata 'setAnswerBounds(address,int256,int256)' "$TOKEN" "$LO" "$HI")")
	cast call "$VIA" 'callOldRegistrar(bytes)' "$BOUNDS" --from "$DEPLOYER" --rpc-url "$RPC" >/dev/null \
		|| fail "$SYM: the answer band doesn't simulate from the deployer"
	printf '✓ %-6s pair %-3s · Veranta × multiplier $%.2f · Aero pool $%.2f · band $%.2f–$%.2f · listing simulates\n' \
		"$SYM" "$PAIR" "$TOKEN_PX" "$POOL_PX" "$(python3 -c "print($LO / 1e8)")" "$(python3 -c "print($HI / 1e8)")"
done

if [ "${SEND:-0}" != "1" ]; then
	echo "checks passed — nothing sent (SEND=1 to list)"
	exit 0
fi

echo "── listing (frosty-main signs each)"
# an anvil rehearsal (REHEARSAL=1) sends from the unlocked deployer instead
SIGN=(--account frosty-main)
[ -z "${REHEARSAL:-}" ] || SIGN=(--unlocked --from "$DEPLOYER")
for row in "${STOCKS[@]}"; do
	read -r SYM TOKEN PAIR POOL <<<"$row"
	ADAPTER=$(json "$BOOK" "['$SYM']")
	read -r LO HI <<<"${BAND[$SYM]}"
	# the band first: the price is never readable without it
	BOUNDS=$(cast calldata 'execute(bytes)' "$(cast calldata 'setAnswerBounds(address,int256,int256)' "$TOKEN" "$LO" "$HI")")
	cast send "$VIA" 'callOldRegistrar(bytes)' "$BOUNDS" "${SIGN[@]}" --rpc-url "$RPC" >/dev/null || fail "band for $SYM"
	echo "✓ $SYM band $LO–$HI (8 decimals)"
	[ -z "${BANDS_ONLY:-}" ] || continue
	CURRENT=$(call "$VI" 'getAssetInfo(address)(address,uint32,uint8,uint8)' "$TOKEN" | head -1)
	if [ "$(echo "$CURRENT" | lower)" = "$(echo "$ADAPTER" | lower)" ]; then
		echo "✓ $SYM already on its adapter"
		continue
	fi
	CALL=$(cast calldata 'execute(bytes)' "$(cast calldata 'addPrimitive(address,address,uint32)' "$TOKEN" "$ADAPTER" "$HEARTBEAT")")
	cast send "$VIA" 'callOldRegistrar(bytes)' "$CALL" "${SIGN[@]}" --rpc-url "$RPC" >/dev/null || fail "listing $SYM"
	echo "✓ $SYM listed on $ADAPTER"
done
echo "done — the keeper's VERANTA_PRICE_STORES needs $STORE appended; the terminal pushes these prices before trades"
