#!/usr/bin/env bash
# LIST COINBASE TOKENIZED STOCKS (Base mainnet) — runbook step 3, while the deployer still owns
# the ValueInterpreter and the Veranta perp factory:
#   1. each Coinbase B20 stock becomes a VI primitive on its Chainlink "Coinbase <TICKER>" feed
#      (the feed prices ONE token = share price × the token's multiplier, per Chainlink's docs),
#      with a 5-day staleness limit so weekends/holidays (feeds are 24/5) never block trading;
#   2. each stock perp on Veranta is mapped onto the same token (setPairAsset).
# cast, NOT forge: B20 tokens are a Base node precompile that Foundry's EVM does not implement
# (a local call to decimals() fails with OpcodeNotFound), so a forge script dies simulating
# addPrimitive. cast sends to the real chain, where B20 works.
# Every token symbol/decimals, feed description and Veranta pair symbol is asserted on-chain
# before anything is sent.
#   Checks only (default): BASE_RPC_URL=<rpc> ./script/mainnet/list-coinbase-stocks.sh
#   Send:                  SEND=1 DEPLOYER_KEY=<key> BASE_RPC_URL=<rpc> ./script/mainnet/list-coinbase-stocks.sh
# Reads the VI + perp factory from deployments/base-mainnet.json (DeployFundsMainnet writes it).
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1

RPC=${BASE_RPC_URL:?set BASE_RPC_URL}
DEPLOYMENTS=${DEPLOYMENTS_FILE:-deployments/base-mainnet.json}
VERANTA_PAIR_STORAGE=0x5db3772136e5557EFE028Db05EE95C84D76faEC4
STALENESS=432000 # 5 days — outlives weekend + holiday closures (longest seen ≈ 92.5h); VI max is 7 days

# symbol · token (base.org/stocks) · Chainlink feed (Base RDD, "Coinbase <TICKER>") · Veranta pair · pair symbol
# GOOGL token ↔ Veranta's GOOG perp (class C vs class A trade within ~1% — accepted)
STOCKS=(
	"NVDAc  0xb20000000000000000000078ee7ce2fE4908108C 0x04689a41629776563E6822F76f2e57D148d28513 81  NVDA"
	"AAPLc  0xb200000000000000000000C2e324d24d7eEcd1fb 0x787f13dEa48Db0897CbCDD985de77809D837F988 82  AAPL"
	"AMZNc  0xb200000000000000000000d9192b6B456483C2E8 0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295 83  AMZN"
	"MSFTc  0xB200000000000000000000Ab99cFa739E253872B 0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c 84  MSFT"
	"METAc  0xb2000000000000000000008bC8786B856E61707C 0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D 85  META"
	"TSLAc  0xb2000000000000000000001e800a7f5189430cD0 0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4 86  TSLA"
	"GOOGLc 0xb2000000000000000000002D0BA3164cc74f58B7 0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2 87  GOOG"
	"SNDKc  0xb200000000000000000000397293Cb8cda9a10c5 0x388b0dC46C0Fb05A74BeE0994fa5b02c6Fcca2eA 101 SNDK"
	"SPCXc  0xb2000000000000000000007b9fcbd005511aCBd5 0x6A634B235903C4ad6376892180d6fF8612e3Fa68 105 SPCX"
	"MSTRc  0xb2000000000000000000004884b426556b92883d 0xB3cE282CD188b35DA0E38D8Bc7d58e33173D202a 108 MSTR"
)

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
else
	echo "no $DEPLOYMENTS yet — checking tokens, feeds and pairs only"
fi

echo "── on-chain checks"
for row in "${STOCKS[@]}"; do
	read -r SYM TOKEN FEED PAIR PAIR_SYM <<<"$row"
	[ "$(call "$TOKEN" 'symbol()(string)' | unquote)" = "$SYM" ] || fail "$TOKEN is not $SYM"
	[ "$(call "$TOKEN" 'decimals()(uint8)')" = "8" ] || fail "$SYM decimals"
	DESC=$(call "$FEED" 'description()(string)' | unquote)
	[ "$DESC" = "Coinbase ${PAIR_SYM/GOOG/GOOGL}" ] || fail "$FEED is '$DESC', not Coinbase ${SYM%c}"
	ANSWER=$(call "$FEED" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' | sed -n 2p | awk '{print $1}')
	[ "${ANSWER:0:1}" != "-" ] && [ "$ANSWER" != "0" ] || fail "$SYM feed answer $ANSWER"
	[ "$(call "$VERANTA_PAIR_STORAGE" 'pairData(uint256)(string,string,uint256)' "$PAIR" | head -1 | unquote)" = "$PAIR_SYM" ] \
		|| fail "Veranta pair $PAIR is not $PAIR_SYM"
	printf '✓ %-7s token ok · %s = %s · pair %s = %s\n' "$SYM" "$DESC" "$ANSWER" "$PAIR" "$PAIR_SYM"
done

if [ "${SEND:-0}" != "1" ]; then
	echo "checks passed — nothing sent (SEND=1 to list)"
	exit 0
fi
[ -n "$VI" ] || fail "SEND needs $DEPLOYMENTS (run DeployFundsMainnet first)"
KEY=${DEPLOYER_KEY:?set DEPLOYER_KEY}

echo "── listing"
for row in "${STOCKS[@]}"; do
	read -r SYM TOKEN FEED PAIR PAIR_SYM <<<"$row"
	if [ "$(call "$VI" 'isSupportedAsset(address)(bool)' "$TOKEN")" != "true" ]; then
		cast send "$VI" 'addPrimitive(address,address,uint32)' "$TOKEN" "$FEED" "$STALENESS" \
			--rpc-url "$RPC" --private-key "$KEY" >/dev/null || fail "addPrimitive $SYM"
	fi
	if [ "$(call "$PERPS" 'pairAsset(uint256)(address)' "$PAIR" | tr '[:upper:]' '[:lower:]')" != "$(echo "$TOKEN" | tr '[:upper:]' '[:lower:]')" ]; then
		cast send "$PERPS" 'setPairAsset(uint256,address)' "$PAIR" "$TOKEN" \
			--rpc-url "$RPC" --private-key "$KEY" >/dev/null || fail "setPairAsset $SYM"
	fi
	RATE=$(call "$VI" 'calcUsdRate(address)(uint256)' "$TOKEN" | awk '{print $1}')
	printf '✓ %-7s listed · VI rate %s · pair %s mapped\n' "$SYM" "$RATE" "$PAIR"
done
echo "done — every stock priced by the VI and every stock perp tradeable by funds"
