#!/usr/bin/env bash
# Writes deployments/release-assets.json: every asset today's ValueInterpreter prices, from the production subgraph
# (the VI can't list them), as ListRelease.s.sol reads it. One query to the Studio development endpoint.
# Run right before the listings so a token registered in the meantime is included.
set -euo pipefail
cd "$(dirname "$0")/../.."
URL=${SUBGRAPH_URL:-https://api.studio.thegraph.com/query/1721900/frosty-funds/version/latest}
OUT=deployments/release-assets.json
curl -sf -X POST -H 'Content-Type: application/json' \
	-d '{"query":"{ assets(first: 1000, where: {active: true}) { id assetClass feed } _meta { block { number } } }"}' "$URL" |
	jq '{
		block: .data._meta.block.number,
		primitives: [.data.assets[] | select(.assetClass == "PRIMITIVE") | .id],
		derivatives: [.data.assets[] | select(.assetClass == "DERIVATIVE") | .id],
		derivativeFeeds: [.data.assets[] | select(.assetClass == "DERIVATIVE") | .feed]
	}' >"$OUT"
jq -r '"block \(.block): \(.primitives | length) primitives, \(.derivatives | length) derivatives"' "$OUT"
[ "$(jq '.primitives | length' "$OUT")" -lt 1000 ] || { echo 'over 1000 assets: page the query' >&2; exit 1; }
