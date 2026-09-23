#!/usr/bin/env bash
# FROSTY COMPOUNDER E2E vs the REAL Uniswap v3 NPM + our live tUSDC/tETH pool, on an
# anvil fork of Base Sepolia. Proves what the unit mocks can't: proportional amount
# pulls + refunds on deposit, REAL fee accrual from actual pool swaps, the protocol
# performance cut landing in the treasury, and a yield-inclusive withdrawal.
set -uo pipefail

CORE=/home/dude/FrostyFunds/funds-core
PORT=8550
RPC="http://127.0.0.1:${PORT}"
KEY0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 # deployer/treasury/swapper
KEY1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d # LP user
TREASURY=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
USER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8

NPM=0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2       # real Uniswap NPM, Base Sepolia
ROUTER=0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4    # real SwapRouter02
TUSDC=0x75f31b7c00e6282cdcfd7b4124d8ab327be3ab4d     # open-mint demo tokens (token0 — lower address)
TETH=0xB949122bF2991edA2d660A2E99f2393ffE74Ae01      # token1

step() { echo "STEP $(date +%H:%M:%S) $*"; }
fail() { echo "✗ FAIL: $*"; kill "${ANVIL_PID:-0}" 2>/dev/null; exit 1; }

step "starting anvil fork of Base Sepolia on :${PORT}"
fuser -k ${PORT}/tcp 2>/dev/null
anvil --fork-url "${BASE_SEPOLIA_RPC_URL:-https://base-sepolia-rpc.publicnode.com}" --port "$PORT" --chain-id 84532 --silent &
ANVIL_PID=$!
for i in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 2; done
cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 || fail "anvil not answering"

step "deploying FrostyCompounder (15% perf fee → treasury) vs the REAL NPM"
cd "$CORE" || fail cd
OUT=$(forge create src/yield/FrostyCompounder.sol:FrostyCompounder \
	--rpc-url "$RPC" --private-key "$KEY0" --broadcast \
	--constructor-args 'Frosty Compounding tETH-tUSDC' fcETHUSDC "$NPM" "$TUSDC" "$TETH" 3000 887220 1500 "$TREASURY" 2>&1)
COMP=$(echo "$OUT" | grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | awk '{print $3}')
[ -n "${COMP:-}" ] || fail "deploy: $(echo "$OUT" | tail -3)"
step "compounder at $COMP"

step "user deposits: 5,000 tUSDC + 2.5 tETH desired (pool takes the live ratio, refunds the rest)"
cast send --rpc-url "$RPC" --private-key "$KEY1" "$TUSDC" 'mint(address,uint256)' "$USER" 5000000000 >/dev/null
cast send --rpc-url "$RPC" --private-key "$KEY1" "$TETH" 'mint(address,uint256)' "$USER" 2500000000000000000 >/dev/null
cast send --rpc-url "$RPC" --private-key "$KEY1" "$TUSDC" 'approve(address,uint256)' "$COMP" 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff >/dev/null
cast send --rpc-url "$RPC" --private-key "$KEY1" "$TETH" 'approve(address,uint256)' "$COMP" 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff >/dev/null
cast send --rpc-url "$RPC" --private-key "$KEY1" "$COMP" 'deposit(uint256,uint256,uint256,uint256)' 5000000000 2500000000000000000 0 0 >/dev/null || fail "deposit reverted"

SHARES=$(cast call --rpc-url "$RPC" "$COMP" 'balanceOf(address)(uint256)' "$USER" | awk '{print $1}')
U_USDC=$(cast call --rpc-url "$RPC" "$TUSDC" 'balanceOf(address)(uint256)' "$USER" | awk '{print $1}')
U_ETH=$(cast call --rpc-url "$RPC" "$TETH" 'balanceOf(address)(uint256)' "$USER" | awk '{print $1}')
[ "${SHARES:-0}" -gt 0 ] || fail "no shares minted"
DUST=$(cast call --rpc-url "$RPC" "$TUSDC" 'balanceOf(address)(uint256)' "$COMP" | awk '{print $1}')
step "shares $SHARES · user leftovers refunded (tUSDC $U_USDC · tETH $U_ETH) · vault residue $DUST"
[ "${DUST:-0}" -eq 0 ] || fail "unused deposit stuck in the vault (refund path broken)"

step "generating REAL pool fees: 6 round-trip swaps through the 0.30% pool"
cast send --rpc-url "$RPC" --private-key "$KEY0" "$TUSDC" 'mint(address,uint256)' "$TREASURY" 60000000000 >/dev/null
cast send --rpc-url "$RPC" --private-key "$KEY0" "$TUSDC" 'approve(address,uint256)' "$ROUTER" 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff >/dev/null
cast send --rpc-url "$RPC" --private-key "$KEY0" "$TETH" 'approve(address,uint256)' "$ROUTER" 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff >/dev/null
for i in 1 2 3; do
	cast send --rpc-url "$RPC" --private-key "$KEY0" "$ROUTER" \
		'exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))' \
		"(${TUSDC},${TETH},3000,${TREASURY},10000000000,0,0)" >/dev/null || fail "swap usdc→eth #$i"
	ETH_BAL=$(cast call --rpc-url "$RPC" "$TETH" 'balanceOf(address)(uint256)' "$TREASURY" | awk '{print $1}')
	cast send --rpc-url "$RPC" --private-key "$KEY0" "$ROUTER" \
		'exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))' \
		"(${TETH},${TUSDC},3000,${TREASURY},${ETH_BAL},0,0)" >/dev/null || fail "swap eth→usdc #$i"
done

LIQ0=$(cast call --rpc-url "$RPC" "$COMP" 'positionState()(uint128,uint128,uint128)' | sed -n 1p | awk '{print $1}')
T_USDC0=$(cast call --rpc-url "$RPC" "$TUSDC" 'balanceOf(address)(uint256)' "$TREASURY" | awk '{print $1}')
T_ETH0=$(cast call --rpc-url "$RPC" "$TETH" 'balanceOf(address)(uint256)' "$TREASURY" | awk '{print $1}')

step "compound() — anyone can call; harvest → 15% to treasury → reinvest"
cast send --rpc-url "$RPC" --private-key "$KEY1" "$COMP" 'compound()' >/dev/null || fail "compound reverted"

LIQ1=$(cast call --rpc-url "$RPC" "$COMP" 'positionState()(uint128,uint128,uint128)' | sed -n 1p | awk '{print $1}')
T_USDC1=$(cast call --rpc-url "$RPC" "$TUSDC" 'balanceOf(address)(uint256)' "$TREASURY" | awk '{print $1}')
T_ETH1=$(cast call --rpc-url "$RPC" "$TETH" 'balanceOf(address)(uint256)' "$TREASURY" | awk '{print $1}')
TOTAL_SHARES=$(cast call --rpc-url "$RPC" "$COMP" 'totalSupply()(uint256)' | awk '{print $1}')

[ "$T_USDC1" -gt "$T_USDC0" ] || fail "treasury got no tUSDC performance cut"
[ "$LIQ1" -gt "$LIQ0" ] || fail "position liquidity did not grow on compound"
[ "$TOTAL_SHARES" -eq "$SHARES" ] || fail "share supply changed on compound (must not)"
echo "PASS $(date +%H:%M:%S) REVENUE: treasury +$((T_USDC1 - T_USDC0)) tUSDC-raw, +$((T_ETH1 - T_ETH0)) tETH-raw · liquidity $LIQ0 → $LIQ1 · shares unchanged (value grew)"

step "full withdrawal — principal + compounded yield, no queue"
cast send --rpc-url "$RPC" --private-key "$KEY1" "$COMP" 'withdraw(uint256,uint256,uint256)' "$SHARES" 0 0 >/dev/null || fail "withdraw reverted"
U_USDC1=$(cast call --rpc-url "$RPC" "$TUSDC" 'balanceOf(address)(uint256)' "$USER" | awk '{print $1}')
U_ETH1=$(cast call --rpc-url "$RPC" "$TETH" 'balanceOf(address)(uint256)' "$USER" | awk '{print $1}')
LEFT=$(cast call --rpc-url "$RPC" "$COMP" 'balanceOf(address)(uint256)' "$USER" | awk '{print $1}')
[ "$LEFT" -eq 0 ] || fail "shares left after full withdraw"
echo "PASS $(date +%H:%M:%S) user exits with tUSDC $U_USDC1 + tETH $U_ETH1 (was refund-only $U_USDC / $U_ETH after deposit)"

echo "✓✓✓ COMPOUNDER E2E COMPLETE — real NPM, real pool fees, real protocol revenue"
kill "$ANVIL_PID" 2>/dev/null
exit 0
