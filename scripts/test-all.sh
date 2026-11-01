#!/usr/bin/env bash
# Every funds-core test, fork suites included, so green means everything ran (founder 2026-11-01).
#   BASE_MAINNET_RPC=<archive rpc> ./scripts/test-all.sh     (or BASE_RPC_URL in .env)
# The CLM fork suites read funds-yield's build from ../funds-yield/out: build it there first (`forge build`).
# Fails if anything failed or was skipped.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
if [ -z "${BASE_MAINNET_RPC:-}" ] && [ -f .env ]; then BASE_MAINNET_RPC=$(grep -E '^BASE_RPC_URL=' .env | cut -d= -f2-); fi
[ -n "${BASE_MAINNET_RPC:-}" ] || { echo "set BASE_MAINNET_RPC to an archive RPC" >&2; exit 1; }
[ -f ../funds-yield/out/ClmPoolDeployerV2.sol/ClmPoolDeployerV2.json ] || { echo "build funds-yield first: ../funds-yield/out is missing" >&2; exit 1; }
export BASE_MAINNET_RPC
log=$(mktemp)
forge test "$@" 2>&1 | sed -E 's#https?://[^ "]+#<rpc>#g' | tee "$log" | grep -E '^\[FAIL|^\[SKIP|Ran [0-9]+ test suites'
summary=$(grep -E 'Ran [0-9]+ test suites' "$log" | tail -1)
rm -f "$log"
echo "$summary" | grep -qE ' 0 failed, 0 skipped' || { echo 'NOT GREEN: something failed or was skipped' >&2; exit 1; }
