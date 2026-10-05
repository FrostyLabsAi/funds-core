#!/usr/bin/env bash
# MIGRATE THE B20 TWAP LISTINGS (Base mainnet) — the last step of the pool-pricing switch-over, after
# MigratePoolPricing. Every Coinbase B20 token the old TWAP registry still prices (PLTRc, MUc,
# cbHYPE, cbZEC, Basecat on 2026-10-04) moves onto a pool adapter on its same pool through
# registrar.setPool, so the registry's delisting and deposit-pause rules stop applying to it too.
# cast, NOT forge: B20 tokens are a Base node precompile that Foundry's EVM does not implement, so a
# forge script dies simulating setPool (it reads decimals()). cast sends to the real chain.
#   Checks only (default): BASE_RPC_URL=<rpc> ./script/mainnet/migrate-b20-listings.sh
#   Send:                  SEND=1 DEPLOYER_KEY=<key> BASE_RPC_URL=<rpc> ./script/mainnet/migrate-b20-listings.sh
#   (the key, decrypted from the frosty-main keystore only for this command — see the runbook)
# Reads the VI from deployments/base-mainnet.json, the registry from deployments/base-mainnet-twap-v2.json
# and the registrar from deployments/base-mainnet-pool-pricing.json.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1

RPC=${BASE_RPC_URL:?set BASE_RPC_URL}
GENESIS=deployments/base-mainnet.json
TWAP_V2=${TWAP_V2_FILE:-deployments/base-mainnet-twap-v2.json}
POOL_PRICING=${POOL_PRICING_FILE:-deployments/base-mainnet-pool-pricing.json}

fail() { echo "✗ FAIL: $*"; exit 1; }
call() { sleep "${THROTTLE:-0}"; cast call "$@" --rpc-url "$RPC"; } # THROTTLE=0.5 on a public RPC
lower() { tr '[:upper:]' '[:lower:]'; }
# a load-balanced RPC (thirdweb) can answer a read right after a send from a node a block behind — the
# 2026-10-04 run failed "PLTRc still TWAP-priced" on a setPool that had landed — so wait for the state
off_twap() { for _ in $(seq 15); do [ "$(call "$REGISTRY" 'isTwapPriced(address)(bool)' "$1")" = "false" ] && return 0; sleep 2; done; return 1; }
json() { python3 -c "import json; print(json.load(open('$1'))['$2'])"; }

[ "$(cast chain-id --rpc-url "$RPC")" = "8453" ] || fail "not Base mainnet (8453)"
for f in "$GENESIS" "$TWAP_V2" "$POOL_PRICING"; do [ -f "$f" ] || fail "no $f"; done
VI=$(json "$GENESIS" valueInterpreter)
REGISTRY=$(json "$TWAP_V2" registry)
REGISTRAR=$(json "$POOL_PRICING" registrar)
[ "$(call "$VI" 'owner()(address)' | lower)" = "$(echo "$REGISTRAR" | lower)" ] \
	|| fail "the registrar $REGISTRAR does not own the VI yet — run MigratePoolPricing first"
echo "VI $VI · registry $REGISTRY · registrar $REGISTRAR"

# B20 layout (base-std docs/architecture.md): byte 0 = 0xB2, bytes 1..8 zero
PENDING=()
for ASSET in $(call "$REGISTRY" 'getListedAssets()(address[])' | tr -d '[] ' | tr ',' ' '); do
	[[ "$(echo "$ASSET" | lower)" == 0xb2000000000000000000* ]] || continue
	[ "$(call "$REGISTRY" 'isTwapPriced(address)(bool)' "$ASSET")" = "true" ] || continue
	POOL=$(call "$REGISTRY" 'listings(address)(address,address,address,uint64,uint64)' "$ASSET" | sed -n 2p)
	SYM=$(call "$ASSET" 'symbol()(string)' | tr -d '"')
	printf '• %-8s %s  pool %s\n' "$SYM" "$ASSET" "$POOL"
	PENDING+=("$ASSET $POOL $SYM")
done
[ ${#PENDING[@]} -gt 0 ] || { echo "nothing to migrate: no B20 token is TWAP-priced"; exit 0; }

if [ "${SEND:-0}" != "1" ]; then
	echo "${#PENDING[@]} to migrate — nothing sent (SEND=1 to send)"
	exit 0
fi
KEY=${DEPLOYER_KEY:?set DEPLOYER_KEY}

echo "── migrating"
for row in "${PENDING[@]}"; do
	read -r ASSET POOL SYM <<<"$row"
	cast send "$REGISTRAR" 'setPool(address,address)' "$ASSET" "$POOL" --rpc-url "$RPC" --private-key "$KEY" >/dev/null \
		|| fail "setPool $SYM"
	off_twap "$ASSET" || fail "$SYM still TWAP-priced 30s after setPool"
	echo "✓ $SYM on its pool adapter · \$$(call "$VI" 'calcUsdRate(address)(uint256)' "$ASSET" | awk '{print $1}') (18 dp)"
done
echo "done"
