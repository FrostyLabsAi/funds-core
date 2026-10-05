#!/usr/bin/env bash
# LIST COINBASE TOKENIZED STOCKS (Base mainnet) — while the deployer owns the ValueInterpreter's
# owner (the PoolPriceRegistrar after the pool-pricing switch-over, the PriceListingModule before
# it) and the Veranta perp factory:
#   1. each Coinbase B20 stock (from Coinbase's API, by address) with a Chainlink "Coinbase <TICKER>" feed
#      becomes a VI primitive on it
#      (the feed prices ONE token = share price × the token's multiplier, per Chainlink's docs),
#      with a 5-day staleness limit so weekends/holidays (feeds are 24/5) never block trading;
#   2. each stock perp on Veranta is mapped onto the same token (setPairAsset), re-pointing a pair
#      ListVerantaPairs had mapped to its Veranta-priced marker (COIN/CRCL/INTC, listed 2026-10-01).
# addPrimitive goes through the VI's owner's `execute`: the registrar named in
# deployments/base-mainnet-pool-pricing.json (POOL_PRICING_FILE) or, before the switch-over, the
# module named in deployments/base-mainnet-twap-v2.json (TWAP_V2_FILE). Anything else is refused.
# cast, NOT forge: B20 tokens are a Base node precompile that Foundry's EVM does not implement
# (a local call to decimals() fails with OpcodeNotFound), so a forge script dies simulating
# addPrimitive. cast sends to the real chain, where B20 works.
# Every token symbol/decimals, feed description and Veranta pair symbol is asserted on-chain
# before anything is sent.
#   Checks only (default): BASE_RPC_URL=<rpc> ./script/mainnet/list-coinbase-stocks.sh
#   Send:                  SEND=1 DEPLOYER_KEY=<key> BASE_RPC_URL=<rpc> ./script/mainnet/list-coinbase-stocks.sh
# Reads the VI + perp factory from deployments/base-mainnet.json (DeployFundsMainnet writes it)
# and the VI's owner from the pool-pricing or TWAP v2 book (see above).
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1

RPC=${BASE_RPC_URL:?set BASE_RPC_URL}
DEPLOYMENTS=${DEPLOYMENTS_FILE:-deployments/base-mainnet.json}
TWAP_V2=${TWAP_V2_FILE:-deployments/base-mainnet-twap-v2.json}
POOL_PRICING=${POOL_PRICING_FILE:-deployments/base-mainnet-pool-pricing.json}
VERANTA_PAIR_STORAGE=0x5db3772136e5557EFE028Db05EE95C84D76faEC4
STALENESS=432000 # 5 days — outlives weekend + holiday closures (longest seen ≈ 92.5h); VI max is 7 days

# The stock list is no longer hard-coded (2026-10-05). Base's DeFi guide
# (docs.base.org/build-on-base/integrate-defi/list-tokenized-stocks) says to discover Coinbase stocks from
# the Coinbase API and identify them by ADDRESS. So: every token in https://api.coinbase.com/v1/tokenized-stocks
# whose Chainlink "Coinbase <TICKER>" feed exists in Chainlink's Base directory (the STANDARD proxyAddress,
# never the SVR secondaryProxyAddress) is listed. Stocks without a feed yet are reported and skipped.
# COINc/INTCc (listed 2026-10-01) are no longer in Coinbase's list (zero supply), so they are no longer
# touched; their perps stay mapped.
CB_API=${CB_STOCKS_API:-https://api.coinbase.com/v1/tokenized-stocks}
CL_DIRECTORY=${CL_DIRECTORY:-https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-base-1.json}
# Coinbase ticker → Veranta perp symbol where they differ: the GOOGL token ↔ Veranta's GOOG perp
# (class C vs class A trade within ~1% — accepted 2026-10-01)
declare -A PERP_SYMBOL=([GOOGL]=GOOG)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
curl -sf -m 60 "$CB_API" -o "$WORK/coinbase.json" || { echo "✗ FAIL: can't read $CB_API"; exit 1; }
curl -sf -m 60 "$CL_DIRECTORY" -o "$WORK/chainlink.json" || { echo "✗ FAIL: can't read $CL_DIRECTORY"; exit 1; }
# rows: SYM TOKEN FEED NAV — one per Coinbase stock with a Chainlink feed
python3 - "$WORK" <<'EOF'
import json, sys
work = sys.argv[1]
tokens = json.load(open(f'{work}/coinbase.json'))['tokens']
feeds = {f['name']: f['proxyAddress'] for f in json.load(open(f'{work}/chainlink.json'))
         if (f.get('name') or '').startswith('Coinbase ') and f.get('proxyAddress')}
with open(f'{work}/rows.txt', 'w') as rows, open(f'{work}/nofeed.txt', 'w') as nofeed:
    for t in sorted(tokens, key=lambda t: t['symbol']):
        sym, ticker = t['symbol'], t['symbol'][:-1] if t['symbol'].endswith('c') else t['symbol']
        feed = feeds.get(f'Coinbase {ticker}')
        if feed:
            rows.write(f"{sym} {t['contract_address']} {feed} {t.get('nav_price') or 0}\n")
        else:
            nofeed.write(f"{sym}\n")
EOF
mapfile -t STOCKS < "$WORK/rows.txt"
echo "Coinbase lists $(python3 -c "import json; print(len(json.load(open('$WORK/coinbase.json'))['tokens']))") stocks · ${#STOCKS[@]} have a Chainlink feed on Base"
[ -s "$WORK/nofeed.txt" ] && echo "no Chainlink feed yet (skipped): $(tr '\n' ' ' < "$WORK/nofeed.txt")"

fail() { echo "✗ FAIL: $*"; exit 1; }
call() { sleep "${THROTTLE:-0}"; cast call "$@" --rpc-url "$RPC"; } # THROTTLE=0.5 on a public RPC
unquote() { tr -d '"'; }

[ "$(cast chain-id --rpc-url "$RPC")" = "8453" ] || fail "not Base mainnet (8453)"

VI=""
PERPS=""
if [ -f "$DEPLOYMENTS" ]; then
	VI=$(python3 -c "import json; print(json.load(open('$DEPLOYMENTS'))['valueInterpreter'])")
	PERPS=$(python3 -c "import json; print(json.load(open('$DEPLOYMENTS'))['verantaFactory'])")
	echo "VI $VI · perp factory $PERPS"
	OWNER=$(call "$VI" 'owner()(address)' | tr '[:upper:]' '[:lower:]')
	ADMIN=""
	for BOOK_KEY in "$POOL_PRICING:registrar" "$TWAP_V2:module"; do
		BOOK=${BOOK_KEY%:*}
		[ -f "$BOOK" ] || continue
		NAMED=$(python3 -c "import json; print(json.load(open('$BOOK')).get('${BOOK_KEY##*:}', ''))" | tr '[:upper:]' '[:lower:]')
		[ "$NAMED" = "$OWNER" ] && ADMIN=$OWNER
	done
	[ -n "$ADMIN" ] || fail "the VI's owner $OWNER is neither the pool-pricing registrar nor the TWAP v2 module"
	echo "$ADMIN owns the VI"
else
	echo "no $DEPLOYMENTS yet — checking tokens, feeds and pairs only"
fi

# Veranta's pair catalog once: perp symbol → pair index (a stock perp is mapped onto its token)
declare -A PAIR_OF
N=$(call "$VERANTA_PAIR_STORAGE" 'pairsCount()(uint256)' | awk '{print $1}')
for ((i = 0; i < N; i++)); do
	FROM=$(call "$VERANTA_PAIR_STORAGE" 'pairData(uint256)(string,string,uint256)' "$i" | head -1 | unquote)
	[ -n "$FROM" ] || continue
	[ -n "${PAIR_OF[$FROM]:-}" ] || PAIR_OF[$FROM]=$i
done

echo "── on-chain checks"
ROWS=()
for row in "${STOCKS[@]}"; do
	read -r SYM TOKEN FEED NAV <<<"$row"
	TICKER=${SYM%c}
	PAIR_SYM=${PERP_SYMBOL[$TICKER]:-$TICKER}
	PAIR=${PAIR_OF[$PAIR_SYM]:--}
	[ "$(call "$TOKEN" 'symbol()(string)' | unquote)" = "$SYM" ] || fail "$TOKEN is not $SYM"
	[ "$(call "$TOKEN" 'decimals()(uint8)')" = "8" ] || fail "$SYM decimals"
	DESC=$(call "$FEED" 'description()(string)' | unquote)
	[ "$DESC" = "Coinbase $TICKER" ] || fail "$FEED is '$DESC', not Coinbase $TICKER"
	ANSWER=$(call "$FEED" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' | sed -n 2p | awk '{print $1}')
	[ "${ANSWER:0:1}" != "-" ] && [ "$ANSWER" != "0" ] || fail "$SYM feed answer $ANSWER"
	# the feed must agree with the NAV Coinbase publishes for the same token (catches a wrong feed)
	python3 -c "import sys; a, n = $ANSWER / 1e8, float('$NAV'); sys.exit(0 if n == 0 or abs(a - n) / n < 0.02 else 1)" \
		|| fail "$SYM feed $ANSWER is more than 2% off Coinbase's NAV $NAV"
	printf '✓ %-7s token ok · %s = %s · perp %s\n' "$SYM" "$DESC" "$ANSWER" "$([ "$PAIR" = - ] && echo none || echo "pair $PAIR = $PAIR_SYM")"
	ROWS+=("$SYM $TOKEN $FEED $PAIR")
done

if [ "${SEND:-0}" != "1" ]; then
	echo "checks passed — nothing sent (SEND=1 to list)"
	exit 0
fi
[ -n "$VI" ] || fail "SEND needs $DEPLOYMENTS (run DeployFundsMainnet first)"
KEY=${DEPLOYER_KEY:?set DEPLOYER_KEY}

echo "── listing"
for row in "${ROWS[@]}"; do
	read -r SYM TOKEN FEED PAIR <<<"$row"
	if [ "$(call "$VI" 'isSupportedAsset(address)(bool)' "$TOKEN")" != "true" ]; then
		cast send "$ADMIN" 'execute(bytes)' "$(cast calldata 'addPrimitive(address,address,uint32)' "$TOKEN" "$FEED" "$STALENESS")" \
			--rpc-url "$RPC" --private-key "$KEY" >/dev/null || fail "addPrimitive $SYM"
	fi
	if [ "$PAIR" != - ] && [ "$(call "$PERPS" 'pairAsset(uint256)(address)' "$PAIR" | tr '[:upper:]' '[:lower:]')" != "$(echo "$TOKEN" | tr '[:upper:]' '[:lower:]')" ]; then
		cast send "$PERPS" 'setPairAsset(uint256,address)' "$PAIR" "$TOKEN" \
			--rpc-url "$RPC" --private-key "$KEY" >/dev/null || fail "setPairAsset $SYM"
	fi
	RATE=$(call "$VI" 'calcUsdRate(address)(uint256)' "$TOKEN" | awk '{print $1}')
	printf '✓ %-7s listed · VI rate %s · perp %s\n' "$SYM" "$RATE" "$([ "$PAIR" = - ] && echo none || echo "pair $PAIR mapped")"
done
echo "done — every Coinbase stock with a Chainlink feed is priced by the VI, and its perp (if Veranta lists one) is tradeable by funds"
