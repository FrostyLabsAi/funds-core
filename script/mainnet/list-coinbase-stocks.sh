#!/usr/bin/env bash
# LIST COINBASE TOKENIZED STOCKS (Base mainnet) — while the deployer owns the ValueInterpreter's
# owner (the PoolPriceRegistrar after the pool-pricing switch-over, the PriceListingModule before
# it): each Coinbase B20 stock (from Coinbase's API, by address) with a Chainlink "Coinbase <TICKER>"
# feed becomes a VI primitive on it, for SPOT trading
# (the feed prices ONE token = share price × the token's multiplier, per Chainlink's docs),
# with a 5-day staleness limit so weekends/holidays (feeds are 24/5) never block trading.
# Stock PERPS are no longer mapped onto the tokens (founder 2026-10-06): they are valued at Veranta's
# own price (script/mainnet/RepointStockPerps.s.sol). Until then this script also re-pointed each
# stock perp to its token; running that step again would undo the re-point. The token ↔ perp hedge
# link is deployments/base-mainnet-stock-hedges.json — add a new stock with a Veranta perp there.
# addPrimitive goes through the VI's owner's `execute`: the registrar named in
# deployments/base-mainnet-pool-pricing.json (POOL_PRICING_FILE) or, before the switch-over, the
# module named in deployments/base-mainnet-twap-v2.json (TWAP_V2_FILE). Anything else is refused.
# Since registrar V2 (deployments/base-mainnet-v4.json `registrar`, or V4_FILE) took over that registrar
# (2026-10-09), the call goes through registrar V2's callOldRegistrar; its owner, the deployer, sends it.
# cast, NOT forge: B20 tokens are a Base node precompile that Foundry's EVM does not implement
# (a local call to decimals() fails with OpcodeNotFound), so a forge script dies simulating
# addPrimitive. cast sends to the real chain, where B20 works.
# Every token symbol/decimals, feed description and Veranta pair symbol is asserted on-chain
# before anything is sent.
#   Checks only (default): BASE_RPC_URL=<rpc> ./script/mainnet/list-coinbase-stocks.sh
#   Send:                  SEND=1 DEPLOYER_KEY=<key> BASE_RPC_URL=<rpc> ./script/mainnet/list-coinbase-stocks.sh
# Reads the VI from deployments/base-mainnet.json (DeployFundsMainnet writes it)
# and the VI's owner from the pool-pricing or TWAP v2 book (see above).
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1

RPC=${BASE_RPC_URL:?set BASE_RPC_URL}
DEPLOYMENTS=${DEPLOYMENTS_FILE:-deployments/base-mainnet.json}
TWAP_V2=${TWAP_V2_FILE:-deployments/base-mainnet-twap-v2.json}
POOL_PRICING=${POOL_PRICING_FILE:-deployments/base-mainnet-pool-pricing.json}
V4_BOOK=${V4_FILE:-deployments/base-mainnet-v4.json}
STALENESS=432000 # 5 days — outlives weekend + holiday closures (longest seen ≈ 92.5h); VI max is 7 days

# The stock list is no longer hard-coded (2026-10-05). Base's DeFi guide
# (docs.base.org/build-on-base/integrate-defi/list-tokenized-stocks) says to discover Coinbase stocks from
# the Coinbase API and identify them by ADDRESS. So: every token in https://api.coinbase.com/v1/tokenized-stocks
# whose Chainlink "Coinbase <TICKER>" feed exists in Chainlink's Base directory (the STANDARD proxyAddress,
# never the SVR secondaryProxyAddress) is listed. Stocks without a feed yet are reported and skipped.
# COINc/INTCc (listed 2026-10-01) are no longer in Coinbase's list (zero supply), so they are no longer
# touched (their perps moved to Veranta-priced markers with the rest, 2026-10-06).
CB_API=${CB_STOCKS_API:-https://api.coinbase.com/v1/tokenized-stocks}
CL_DIRECTORY=${CL_DIRECTORY:-https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-base-1.json}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# the API pages 100 tokens at a time (2026-10-25: 211 stocks over three pages; reading one page missed 111)
python3 - "$CB_API" "$WORK/coinbase.json" <<'EOF' || { echo "✗ FAIL: can't read $CB_API"; exit 1; }
import json, sys, urllib.parse, urllib.request
api, out = sys.argv[1], sys.argv[2]
tokens, page = [], None
while True:
	url = api + (f'?page_token={urllib.parse.quote(page)}' if page else '')
	body = json.load(urllib.request.urlopen(urllib.request.Request(url, headers={'user-agent': 'curl/8.5.0'}), timeout=60))
	tokens += body['tokens']
	page = body.get('next_page_token')
	if not page:
		break
json.dump({'tokens': tokens}, open(out, 'w'))
EOF
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
if [ -f "$DEPLOYMENTS" ]; then
	VI=$(python3 -c "import json; print(json.load(open('$DEPLOYMENTS'))['valueInterpreter'])")
	echo "VI $VI"
	OWNER=$(call "$VI" 'owner()(address)' | tr '[:upper:]' '[:lower:]')
	ADMIN=""
	# today's chain, PRICING-POOL-01 (2026-11-01): the VI's owner is the windowed registrar, under the new V2, under the new V3
	WINDOWED=${WINDOWED_PRICING_FILE:-deployments/base-mainnet-windowed-pricing.json}
	for BOOK_KEY in "$WINDOWED:base" "$POOL_PRICING:registrar" "$TWAP_V2:module"; do
		BOOK=${BOOK_KEY%:*}
		[ -f "$BOOK" ] || continue
		NAMED=$(python3 -c "import json; print(json.load(open('$BOOK')).get('${BOOK_KEY##*:}', ''))" | tr '[:upper:]' '[:lower:]')
		[ "$NAMED" = "$OWNER" ] && ADMIN=$OWNER
	done
	[ -n "$ADMIN" ] || fail "the VI's owner $OWNER is neither the pool-pricing registrar nor the TWAP v2 module"
	echo "$ADMIN owns the VI"
	VIA_V2=""
	if [ -f "$WINDOWED" ] && [ "$(python3 -c "import json; print(json.load(open('$WINDOWED')).get('base', ''))" | tr '[:upper:]' '[:lower:]')" = "$OWNER" ]; then
		VIA_V2=$(python3 -c "import json; print(json.load(open('$WINDOWED'))['registrar'])" | tr '[:upper:]' '[:lower:]')
	elif [ -f "$V4_BOOK" ]; then
		REGISTRAR_V2=$(python3 -c "import json; print(json.load(open('$V4_BOOK')).get('registrar', ''))" | tr '[:upper:]' '[:lower:]')
		ADMIN_OWNER=$(call "$ADMIN" 'owner()(address)' | tr '[:upper:]' '[:lower:]')
		[ -n "$REGISTRAR_V2" ] && [ "$ADMIN_OWNER" = "$REGISTRAR_V2" ] && VIA_V2=$REGISTRAR_V2
	fi
	# once registrar V3 owns V2 (the Aero venue, 2026-10-25) the deployer sends the same callOldRegistrar to V3
	AERO_BOOK=${AERO_REGISTRAR_FILE:-deployments/base-mainnet-aero-registrar.json}
	if [ -n "$VIA_V2" ] && [ -f "$AERO_BOOK" ]; then
		V3=$(python3 -c "import json; print(json.load(open('$AERO_BOOK')).get('registrar', ''))" | tr '[:upper:]' '[:lower:]')
		[ -n "$V3" ] && [ "$(call "$VIA_V2" 'owner()(address)' | tr '[:upper:]' '[:lower:]')" = "$V3" ] && VIA_V2=$V3
	fi
	[ -z "$VIA_V2" ] || echo "listings go through $VIA_V2's callOldRegistrar"
else
	echo "no $DEPLOYMENTS yet — checking tokens and feeds only"
fi

echo "── on-chain checks"
ROWS=()
for row in "${STOCKS[@]}"; do
	read -r SYM TOKEN FEED NAV <<<"$row"
	TICKER=${SYM%c}
	[ "$(call "$TOKEN" 'symbol()(string)' | unquote)" = "$SYM" ] || fail "$TOKEN is not $SYM"
	[ "$(call "$TOKEN" 'decimals()(uint8)')" = "8" ] || fail "$SYM decimals"
	DESC=$(call "$FEED" 'description()(string)' | unquote)
	[ "$DESC" = "Coinbase $TICKER" ] || fail "$FEED is '$DESC', not Coinbase $TICKER"
	ANSWER=$(call "$FEED" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' | sed -n 2p | awk '{print $1}')
	[ "${ANSWER:0:1}" != "-" ] && [ "$ANSWER" != "0" ] || fail "$SYM feed answer $ANSWER"
	# the feed must agree with the NAV Coinbase publishes for the same token (catches a wrong feed)
	python3 -c "import sys; a, n = $ANSWER / 1e8, float('$NAV'); sys.exit(0 if n == 0 or abs(a - n) / n < 0.02 else 1)" \
		|| fail "$SYM feed $ANSWER is more than 2% off Coinbase's NAV $NAV"
	printf '✓ %-7s token ok · %s = %s\n' "$SYM" "$DESC" "$ANSWER"
	ROWS+=("$SYM $TOKEN $FEED")
done

if [ "${SEND:-0}" != "1" ]; then
	echo "checks passed — nothing sent (SEND=1 to list)"
	exit 0
fi
[ -n "$VI" ] || fail "SEND needs $DEPLOYMENTS (run DeployFundsMainnet first)"
KEY=${DEPLOYER_KEY:?set DEPLOYER_KEY}

echo "── listing"
for row in "${ROWS[@]}"; do
	read -r SYM TOKEN FEED <<<"$row"
	if [ "$(call "$VI" 'isSupportedAsset(address)(bool)' "$TOKEN")" != "true" ]; then
		ADD=$(cast calldata 'addPrimitive(address,address,uint32)' "$TOKEN" "$FEED" "$STALENESS")
		if [ -n "$VIA_V2" ]; then
			cast send "$VIA_V2" 'callOldRegistrar(bytes)' "$(cast calldata 'execute(bytes)' "$ADD")" \
				--rpc-url "$RPC" --private-key "$KEY" >/dev/null || fail "addPrimitive $SYM"
		else
			cast send "$ADMIN" 'execute(bytes)' "$ADD" --rpc-url "$RPC" --private-key "$KEY" >/dev/null || fail "addPrimitive $SYM"
		fi
	fi
	RATE=$(call "$VI" 'calcUsdRate(address)(uint256)' "$TOKEN" | awk '{print $1}')
	printf '✓ %-7s listed · VI rate %s\n' "$SYM" "$RATE"
done
echo "done — every Coinbase stock with a Chainlink feed is priced by the VI for spot trading"
