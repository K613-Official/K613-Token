#!/usr/bin/env bash
# ============================================================================
# K613 monthly fee cycle (Monad mainnet), one command:
#   fees on Aave Collector -> unwrap -> swap to USDC -> Treasury -> buyback
#   K613 -> stake -> xK613 rewards to stakers.
#
# Usage:
#   source .env && ./script/ops/monthly-fee-cycle.sh
#
# Why bash+cast and not forge script: foundry's local simulation underestimates
# Monad gas ~2x on incentives-heavy aToken ops (batched txs kept OOM-failing in
# one block). cast send asks the NODE for the estimate (accurate), each tx is
# mined before the next starts, amounts are read live right before each call,
# and one failed step never poisons the rest.
#
# Env: PRIVATE_KEY (FUNDS_ADMIN on Collector + Treasury admin), MONAD_RPC.
# Optional: SLIPPAGE_BPS (default 100 = 1%).
# ============================================================================
set -u

# Auto-load .env from the repo root (works no matter where the script is run from):
# `source .env` in the parent shell does NOT export vars to child processes.
ENV_FILE="$(cd "$(dirname "$0")/../.." && pwd)/.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

RPC="${MONAD_RPC:?set MONAD_RPC (or put it in .env)}"
PK="${PRIVATE_KEY:?set PRIVATE_KEY (or put it in .env)}"
SLIPPAGE_BPS="${SLIPPAGE_BPS:-100}"
ME=$(cast wallet address "$PK")

POOL=0x4Ba3856a4d851d39C27e2E866daB7A95eF6e0113
COLLECTOR=0xF689bB846eE7DD51947c3368cc3ee26713D3ED83
DATA_PROVIDER=0xfc87bE7f3657AAD69baDb6247A88E924D1F8bc53
TREASURY=0x3377BAB9A510A586627D2f9013e132d269Eb9871
USDC=0x754704Bc059F8C67012fEd69BC8A327a5aafb603
K613=0xb09582631336068d4B0089d943f40CbF46dE5189
ROUTER=0xfE31F71C1b106EAc32F1A19239c9a9A72ddfb900
QUOTER=0x661E93cca42AfacB172121EF892830cA3b70F08d
BUYBACK_POOL_FEE=500

# symbol : underlying : v3 fee tier for the /USDC swap (0 = no pool -> hold)
ASSETS=(
  "USDC:0x754704Bc059F8C67012fEd69BC8A327a5aafb603:0"
  "AUSD:0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a:500"
  "USDT0:0xe7cd86e13AC4309349F30B3435a9d337750fC82D:500"
  "wsrUSD:0x4809010926aec940b550D34a46A52739f996D75D:0"
  "WETH:0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242:3000"
  "wstETH:0x10Aeaf63194db8d453d4D85a06E5eFE1dd0b5417:3000"
  "WBTC:0x0555E30da8f98308EdB960aa94C0Db47230d2B9c:3000"
  "WMON:0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A:3000"
  "shMON:0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c:0"
  "sMON:0xA3227C5969757783154C60bF0bC1944180ed81B9:0"
  "gMON:0x8498312A6B3CbD158bf0c93AbdCF29E6e4F55081:0"
)

FAILS=0
say()  { echo; echo "── $*"; }
bal()  { cast call "$1" "balanceOf(address)(uint256)" "$2" --rpc-url "$RPC" | awk '{print $1}'; }
send() { # send "<description>" <to> <sig> <args...> [--gas-limit N]
  local desc="$1"; shift
  local out
  if out=$(cast send --private-key "$PK" --rpc-url "$RPC" "$@" 2>&1); then
    echo "  OK   $desc"
    return 0
  else
    echo "  FAIL $desc"
    echo "$out" | tail -2 | sed 's/^/       /'
    FAILS=$((FAILS + 1))
    return 1
  fi
}
quote() { # quote <tokenIn> <tokenOut> <amount> <fee> -> stdout amountOut (empty on failure)
  cast call "$QUOTER" \
    "quoteExactInputSingle((address,address,uint256,uint24,uint160))(uint256,uint160,uint32,uint256)" \
    "($1,$2,$3,$4,0)" --rpc-url "$RPC" 2>/dev/null | head -1 | awk '{print $1}'
}

echo "=== K613 monthly fee cycle ==="
echo "operator: $ME"
echo "slippage: ${SLIPPAGE_BPS} bps"

# Preflight: collect (Collector.transfer) needs FUNDS_ADMIN, buyback needs Treasury admin.
FUNDS_ADMIN_ROLE=0x46554e44535f41444d494e000000000000000000000000000000000000000000
IS_FA=$(cast call "$COLLECTOR" "hasRole(bytes32,address)(bool)" "$FUNDS_ADMIN_ROLE" "$ME" --rpc-url "$RPC" | awk '{print $1}')
if [ "$IS_FA" != "true" ]; then
  echo
  echo "ABORT: $ME does not hold FUNDS_ADMIN on the Collector — run this with the funds-admin key."
  exit 1
fi

# ── Step 0: materialize accruedToTreasury on the Collector ──────────────────
say "0. Pool.mintToTreasury (11 reserves)"
ASSET_LIST="[$(printf '%s\n' "${ASSETS[@]}" | cut -d: -f2 | paste -sd, -)]"
send "mintToTreasury" "$POOL" "mintToTreasury(address[])" "$ASSET_LIST" --gas-limit 3000000

# ── Steps 1-2: per asset: collect -> unwrap -> swap straight into Treasury ──
say "1-2. collect + unwrap + swap (each amount is read live)"
for entry in "${ASSETS[@]}"; do
  IFS=: read -r SYM UNDER FEE <<<"$entry"

  ATOKEN=$(cast call "$DATA_PROVIDER" "getReserveTokensAddresses(address)(address,address,address)" "$UNDER" --rpc-url "$RPC" | head -1 | awk '{print $1}')
  AMT=$(bal "$ATOKEN" "$COLLECTOR")
  if [ -z "$AMT" ] || [ "$AMT" = "0" ]; then echo "  skip $SYM (nothing on Collector)"; continue; fi

  send "collect  $SYM ($AMT)" "$COLLECTOR" "transfer(address,address,uint256)" "$ATOKEN" "$ME" "$AMT" || continue
  send "unwrap   $SYM" "$POOL" "withdraw(address,uint256,address)" "$UNDER" "$AMT" "$ME" || continue

  if [ "$SYM" = "USDC" ]; then
    send "to Treasury: $SYM ($AMT)" "$USDC" "transfer(address,uint256)" "$TREASURY" "$AMT"
    continue
  fi
  if [ "$FEE" = "0" ]; then echo "  hold $SYM (no V3/USDC pool - Kuru manually when material)"; continue; fi

  Q=$(quote "$UNDER" "$USDC" "$AMT" "$FEE")
  if [ -z "$Q" ] || [ "$Q" = "0" ]; then echo "  hold $SYM (no quote)"; continue; fi
  # Stablecoin sanity floor: a stable/USDC quote below 95% of face value means the pool is
  # broken/empty (2026-07-30: 7.8 AUSD sold for $0.07 into a drained pool). Hold instead.
  case "$SYM" in
    AUSD|USDT0)
      FLOOR=$(python3 -c "print($AMT*9500//10000)")
      if [ "$(python3 -c "print(1 if $Q < $FLOOR else 0)")" = "1" ]; then
        echo "  hold $SYM (quote $Q < 95% of face value - pool unhealthy)"
        continue
      fi
      ;;
  esac
  MINOUT=$(python3 -c "print($Q*(10000-$SLIPPAGE_BPS)//10000)")

  send "approve  $SYM" "$UNDER" "approve(address,uint256)" "$ROUTER" "$AMT" || continue
  # recipient = Treasury: swapped USDC lands there directly, no extra hop
  send "swap     $SYM -> USDC (~$Q raw)" "$ROUTER" \
    "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))" \
    "($UNDER,$USDC,$FEE,$TREASURY,$AMT,$MINOUT,0)"
done

# ── Step 3: buyback K613 with the Treasury's USDC, rewards to stakers ───────
say "3. buyback + distribute to stakers"
TB=$(bal "$USDC" "$TREASURY")
if [ -z "$TB" ] || [ "$TB" = "0" ]; then
  echo "  skip buyback (Treasury USDC = 0)"
else
  Q=$(quote "$USDC" "$K613" "$TB" "$BUYBACK_POOL_FEE")
  if [ -z "$Q" ] || [ "$Q" = "0" ]; then
    echo "  FAIL buyback: no quote from K613/USDC pool"
    FAILS=$((FAILS + 1))
  else
    MINOUT=$(python3 -c "print($Q*(10000-$SLIPPAGE_BPS)//10000)")
    send "buyback $TB raw USDC -> >=$MINOUT K613 -> stakers" "$TREASURY" \
      "buybackV3ExactInputSingle(address,address,uint256,uint256,uint24,bool)" \
      "$USDC" "$ROUTER" "$TB" "$MINOUT" "$BUYBACK_POOL_FEE" true --gas-limit 1500000
  fi
fi

echo
if [ "$FAILS" = "0" ]; then
  echo "=== DONE: cycle completed with no failures ==="
else
  echo "=== DONE with $FAILS failed step(s) - re-run the script: it always reads live balances, so leftovers are picked up next time ==="
fi
