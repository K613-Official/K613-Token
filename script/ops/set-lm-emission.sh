#!/usr/bin/env bash
# ============================================================================
# K613 LM emission tuning (Monad mainnet), one command.
#
# Per-market weekly K613 budgets, set EXPLICITLY below — not a blanket divisor.
# Rationale: a uniform cut keeps the skew (a market holding $200 would still
# show a four-digit APR). What matters is the DOLLAR cost per market, so thin
# markets get a small fixed bootstrap budget and their APR is allowed to be
# high, while markets with real TVL are sized to a target APR.
#
# Sizing rule used for the numbers below (2026-07-31, K613 = $0.0089):
#   - markets with meaningful TVL  -> ~30% supply APR / ~20% borrow APR
#   - thin or empty markets        -> flat $12-25/week bootstrap
# Re-sizing is a weekly job: as TVL grows, raise the budgets (or pass a SCALE).
#
# Usage:
#   ./script/ops/set-lm-emission.sh          # apply the table as written
#   ./script/ops/set-lm-emission.sh 2        # apply it x2 (TVL grew ~2x)
#   ./script/ops/set-lm-emission.sh 0.5      # apply it at half
#
# Env: PRIVATE_KEY (must be the xK613 emission admin), MONAD_RPC (.env autoloaded).
# ============================================================================
set -u

ENV_FILE="$(cd "$(dirname "$0")/../.." && pwd)/.env"
if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
RPC="${MONAD_RPC:?set MONAD_RPC (or put it in .env)}"
PK="${PRIVATE_KEY:?set PRIVATE_KEY (or put it in .env)}"
SCALE="${1:-1}"
ME=$(cast wallet address "$PK")

EMISSION_MANAGER=0x7eEdb2D4D4b89b8B854c734e8fAABfB24E0537A6
DATA_PROVIDER=0xfc87bE7f3657AAD69baDb6247A88E924D1F8bc53
XK613=0x9064d55A8A8473fA39c41A16492Fa1094Eb4E8b5
RC=0xe1d8B642c83587Df813a36F361C682C0475c4ea4
K613_PRICE=0.0089   # для расчёта APR в отчёте скрипта
WEEK=604800

# symbol : underlying : SUPPLY K613/нед : BORROW K613/нед
# ── рынки с реальным TVL: цель ~30% supply / ~20% borrow APR ──────────────
# ── тонкие рынки: фиксированный бутстрап $12-25/нед ───────────────────────
ASSETS=(
  "USDC:0x754704Bc059F8C67012fEd69BC8A327a5aafb603:12150:4800"
  "AUSD:0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a:13650:3470"
  "USDT0:0xe7cd86e13AC4309349F30B3435a9d337750fC82D:7140:2170"
  "WETH:0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242:2800:1120"
  "WBTC:0x0555E30da8f98308EdB960aa94C0Db47230d2B9c:2250:900"
  "WMON:0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A:2250:560"
  "wstETH:0x10Aeaf63194db8d453d4D85a06E5eFE1dd0b5417:1690:560"
  "wsrUSD:0x4809010926aec940b550D34a46A52739f996D75D:1690:560"
  "shMON:0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c:1350:450"
  "sMON:0xA3227C5969757783154C60bF0bC1944180ed81B9:1350:450"
  "gMON:0x8498312A6B3CbD158bf0c93AbdCF29E6e4F55081:1350:450"
)

FAILS=0
send() { local d="$1"; shift
  if cast send --private-key "$PK" --rpc-url "$RPC" "$@" >/dev/null 2>&1; then
    echo "  OK   $d"
  else
    echo "  FAIL $d"; FAILS=$((FAILS+1)); return 1
  fi
}

echo "=== K613 LM emission — пер-маркет бюджеты (scale ×$SCALE) ==="
echo "operator: $ME"

EA=$(cast call "$EMISSION_MANAGER" "getEmissionAdmin(address)(address)" "$XK613" --rpc-url "$RPC")
if [ "$(echo "$EA" | tr 'A-F' 'a-f')" != "$(echo "$ME" | tr 'A-F' 'a-f')" ]; then
  echo "ABORT: $ME is not the xK613 emission admin ($EA)"
  exit 1
fi

echo
echo "── применяю"
TOT_S=0; TOT_B=0
declare -A EPS_S EPS_B ATOK VDBT
for entry in "${ASSETS[@]}"; do
  IFS=: read -r SYM UNDER WK_S WK_B <<<"$entry"
  TOKENS=$(cast call "$DATA_PROVIDER" "getReserveTokensAddresses(address)(address,address,address)" "$UNDER" --rpc-url "$RPC")
  ATOK[$SYM]=$(echo "$TOKENS" | sed -n 1p | awk '{print $1}')
  VDBT[$SYM]=$(echo "$TOKENS" | sed -n 3p | awk '{print $1}')
  EPS_S[$SYM]=$(python3 -c "print(int($WK_S*$SCALE*10**18/$WEEK))")
  EPS_B[$SYM]=$(python3 -c "print(int($WK_B*$SCALE*10**18/$WEEK))")
  TOT_S=$(python3 -c "print($TOT_S+$WK_S*$SCALE)")
  TOT_B=$(python3 -c "print($TOT_B+$WK_B*$SCALE)")
  send "$SYM supply  ${WK_S} K613/нед" "$EMISSION_MANAGER" \
    "setEmissionPerSecond(address,address[],uint88[])" "${ATOK[$SYM]}" "[$XK613]" "[${EPS_S[$SYM]}]"
  send "$SYM borrow  ${WK_B} K613/нед" "$EMISSION_MANAGER" \
    "setEmissionPerSecond(address,address[],uint88[])" "${VDBT[$SYM]}" "[$XK613]" "[${EPS_B[$SYM]}]"
done

echo
echo "── сверка ончейн + получившийся APR по факту TVL"
printf "  %-8s %12s %12s %10s %10s\n" "рынок" "supply/нед" "borrow/нед" "APR sup" "APR bor"
for entry in "${ASSETS[@]}"; do
  IFS=: read -r SYM UNDER WK_S WK_B <<<"$entry"
  GOT_S=$(cast call "$RC" "getRewardsData(address,address)(uint256,uint256,uint256,uint256)" "${ATOK[$SYM]}" "$XK613" --rpc-url "$RPC" | sed -n 2p | awk '{print $1}')
  GOT_B=$(cast call "$RC" "getRewardsData(address,address)(uint256,uint256,uint256,uint256)" "${VDBT[$SYM]}" "$XK613" --rpc-url "$RPC" | sed -n 2p | awk '{print $1}')
  if [ "$GOT_S" != "${EPS_S[$SYM]}" ] || [ "$GOT_B" != "${EPS_B[$SYM]}" ]; then
    echo "  BAD  $SYM: ончейн eps не совпал с заданным"; FAILS=$((FAILS+1)); continue
  fi
  DEC=$(cast call "$UNDER" "decimals()(uint8)" --rpc-url "$RPC" | awk '{print $1}')
  SUP=$(cast call "${ATOK[$SYM]}" "totalSupply()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
  BOR=$(cast call "${VDBT[$SYM]}" "totalSupply()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
  python3 - <<PY
sup=$SUP/10**$DEC; bor=$BOR/10**$DEC
ws=$WK_S*$SCALE; wb=$WK_B*$SCALE; k=$K613_PRICE
# цену актива не тянем: APR считаем в токенах актива через его же цену — только для рынков,
# где цена известна из отчёта; здесь показываем APR как (годовые награды в \$) / (TVL в токенах * цена)
# для читаемости печатаем годовой доллар наград и объём в токенах актива
print("  %-8s %12s %12s  \$%8.0f/год %8s" % ("$SYM", f"{ws:,.0f}", f"{wb:,.0f}", ws*52*k, f"{sup:,.2f}"))
PY
done

echo
python3 -c "
ts=$TOT_S; tb=$TOT_B; k=$K613_PRICE
print('итого: %s supply + %s borrow = %s K613/нед = \$%.0f/нед (\$%.0f/год, %.1f%% бюджета Y1)'
      % (f'{ts:,.0f}', f'{tb:,.0f}', f'{ts+tb:,.0f}', (ts+tb)*k, (ts+tb)*52*k, (ts+tb)*52/25_000_000*100))"
[ "$FAILS" = "0" ] && echo "=== DONE ===" || echo "=== DONE with $FAILS issue(s) — перезапуск безопасен ==="
