#!/usr/bin/env bash
# PRICING-POOL-01 ROLLOUT, THE B20 STEP (Base mainnet), between the two runs of WindowedPricingOwnerSteps.s.sol: every
# token whose asset or quote is a Coinbase B20 moves onto a fixed clone of its same pool through the new registrar V2's
# setPool, sent by the new V3's callRegistrarV2.
# cast, NOT forge: B20 tokens are a Base node precompile that Foundry's EVM does not implement, so a forge script dies
# simulating setPool (it reads decimals()). cast sends to the real chain.
#   Checks only (default): BASE_RPC_URL=<rpc> ./script/mainnet/migrate-windowed-b20.sh
#   Send:                  SEND=1 BASE_RPC_URL=<rpc> ./script/mainnet/migrate-windowed-b20.sh
#                          (signs with the frosty-main keystore; it asks for the password on each send)
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1

RPC=${BASE_RPC_URL:?set BASE_RPC_URL}
BOOK=deployments/base-mainnet-windowed-pricing.json
OLD_V3=0xF867a01419d805A76A4637304f13d486EcB5749c
ZERO=0x0000000000000000000000000000000000000000

fail() { echo "✗ FAIL: $*"; exit 1; }
call() { sleep "${THROTTLE:-0}"; cast call "$@" --rpc-url "$RPC"; } # THROTTLE=0.5 on a public RPC
json() { python3 -c "import json; print(json.load(open('$1'))['$2'])"; }
# on Base a B20 token's account code is the single byte 0xef
is_b20() { [ "$(cast code "$1" --rpc-url "$RPC")" = "0xef" ]; }

[ "$(cast chain-id --rpc-url "$RPC")" = "8453" ] || fail "not Base mainnet (8453)"
[ -f "$BOOK" ] || fail "no $BOOK: run DeployWindowedPricing first"
V3=$(json "$BOOK" registrar)
V2=$(json "$BOOK" registrarV2)
[ "$(call "$V2" 'owner()(address)')" = "$V3" ] || fail "new V2 isn't under new V3: run WindowedPricingOwnerSteps first"

# Every move is simulated before the first is sent: a listing setPool can't move (a B20 on v4 or Aero, none today) stops the
# script here, with nothing half done (review 2026-11-01).
OWNER=$(call "$V3" 'owner()(address)')
moves=()
for asset in $(call "$OLD_V3" 'getRegisteredAssets()(address[])' | tr -d '[] ' | tr ',' ' '); do
	adapter=$(call "$OLD_V3" 'poolPricedAdapter(address)(address)' "$asset")
	[ "$adapter" = "$ZERO" ] && continue
	config=$(call "$adapter" 'config()((address,address,address,address,bool,uint8,uint8))' | tr -d '() ')
	pool=$(echo "$config" | cut -d, -f2)
	quote=$(echo "$config" | cut -d, -f4)
	is_b20 "$asset" || is_b20 "$quote" || continue
	data=$(cast calldata 'setPool(address,address)' "$asset" "$pool")
	call "$V3" 'callRegistrarV2(bytes)' "$data" --from "$OWNER" >/dev/null 2>&1 \
		|| fail "$asset on pool $pool (quote $quote): setPool would revert. A B20 on v4 or Aero needs its own step."
	echo "· $asset on pool $pool (quote $quote)"
	moves+=("$asset $data")
done

moved=0
for move in "${moves[@]+"${moves[@]}"}"; do
	asset=${move%% *}
	data=${move#* }
	if [ "${SEND:-0}" = "1" ]; then
		cast send "$V3" 'callRegistrarV2(bytes)' "$data" --account frosty-main --rpc-url "$RPC" >/dev/null
		# a load-balanced RPC can answer from a node a block behind (2026-10-04): wait for the state
		for _ in $(seq 15); do [ "$(call "$OLD_V3" 'poolPricedAdapter(address)(address)' "$asset")" = "$ZERO" ] && break; sleep 2; done
		[ "$(call "$OLD_V3" 'poolPricedAdapter(address)(address)' "$asset")" = "$ZERO" ] || fail "$asset still on its old clone"
		[ "$(call "$V3" 'poolPricedAdapter(address)(address)' "$asset")" != "$ZERO" ] || fail "$asset not on the new chain"
	fi
	moved=$((moved + 1))
done
echo "✓ ${moved} B20 listing(s) $([ "${SEND:-0}" = "1" ] && echo moved || echo 'would move (SEND=1 to send)')"
