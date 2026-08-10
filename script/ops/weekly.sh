#!/usr/bin/env bash
# ============================================================================
# K613 — весь недельный цикл одним запуском. Больше ничего запускать не надо.
#
#   1. advanceEpoch()      — флаш эпохи RewardsDistributor (permissionless)
#   2. комиссии протокола  — mintToTreasury -> собрать с Collector -> распаковать
#                            -> свапнуть в USDC -> доставить на Treasury
#   3. topUpTranche(...)   — добить запас наград лендинга до недельной нормы
#   4. runBuyback(...)     — выкуп K613 на собранные комиссии -> стейкерам
#   5. отчёт               — состояние протокола и таблица по рынкам
#

#
# Usage:  ./script/ops/weekly.sh
# Env: PRIVATE_KEY (нужны FUNDS_ADMIN на Collector и OPERATOR_ROLE в операторе),
#      MONAD_RPC, OPERATOR_CONTRACT. Optional: SLIPPAGE_BPS (default 100 = 1%).
# ============================================================================
set -u

ENV_FILE="$(cd "$(dirname "$0")/../.." && pwd)/.env"
if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
RPC="${MONAD_RPC:?set MONAD_RPC}"
PK="${PRIVATE_KEY:?set PRIVATE_KEY}"
OPERATOR_V2=0xc7E2Cb01634b2Ea02581aAC763367A7426fa6dBC
OP="${OPERATOR_CONTRACT:-$OPERATOR_V2}"
SLIPPAGE_BPS="${SLIPPAGE_BPS:-100}"
ME=$(cast wallet address "$PK")

RD=0xE3E8925E8554464611c86419B9e99AD7Cd47428f
TREASURY=0x10aCE88f2F2c361218615F5dcA8987DD16C54282
STAKING=0x5A3DA7644c25F0A74DCb0bA13ae38214D8856415
SAFE=0x7D5cF07621228a3D622b4695A1e28991E4620eBB
COLLECTOR=0xF689bB846eE7DD51947c3368cc3ee26713D3ED83
POOL_AAVE=0x4Ba3856a4d851d39C27e2E866daB7A95eF6e0113
XK613=0x9064d55A8A8473fA39c41A16492Fa1094Eb4E8b5
K613=0xb09582631336068d4B0089d943f40CbF46dE5189
USDC=0x754704Bc059F8C67012fEd69BC8A327a5aafb603
ROUTER=0xfE31F71C1b106EAc32F1A19239c9a9A72ddfb900
QUOTER=0x661E93cca42AfacB172121EF892830cA3b70F08d
RC=0xe1d8B642c83587Df813a36F361C682C0475c4ea4
DP=0xfc87bE7f3657AAD69baDb6247A88E924D1F8bc53
UIP=0xF872C01f32B653462a4eD7F5688342d568EeA488
PAP=0x1f6E754C6F7A49e2d69e5341d65EcB8f8506C69c
POOL_K613=0xDD5557CEcFD7Ba0F5F2A1C38967d83Df2951a4F4
ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000
FUNDS_ADMIN_ROLE=0x46554e44535f41444d494e000000000000000000000000000000000000000000

# Адреса выше переведены на V2 заранее, до исполнения катовера. Пока Safe не отдал
# StakingV2 роль минтера, запуск этого скрипта наполовину провалится и наполовину
# сработает не туда: transfer USDC на TreasuryV2 пройдёт и деньги там осядут, а
# topUpTranche упрётся в StakingV2.stake -> xK613.mint -> OnlyMinter и ревертнётся.
# Определяем готовность по факту на чейне, а не по календарю.
_minter=$(cast call "$XK613" "minter()(address)" --rpc-url "$RPC" 2>/dev/null || echo "")
if [ "$(printf '%s' "$_minter" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$STAKING" | tr 'A-Z' 'a-z')" ]; then
  echo "СТОП: катовер на V2 не исполнен." >&2
  echo "  xK613.minter = ${_minter:-<нет ответа>}" >&2
  echo "  ожидается    = $STAKING (StakingV2)" >&2
  echo "Скрипт уже указывает на TreasuryV2/StakingV2 — запускать только после того," >&2
  echo "как Safe исполнит docs/safe-batches/v2-cutover-2-switch.json." >&2
  exit 1
fi

# symbol : underlying : decimals : fee-tier для свапа в USDC (0 = пула нет, копим)
ASSETS=(
  "USDC:0x754704Bc059F8C67012fEd69BC8A327a5aafb603:6:0"
  "AUSD:0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a:6:500"
  "USDT0:0xe7cd86e13AC4309349F30B3435a9d337750fC82D:6:500"
  "wsrUSD:0x4809010926aec940b550D34a46A52739f996D75D:6:0"
  "WETH:0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242:18:3000"
  "wstETH:0x10Aeaf63194db8d453d4D85a06E5eFE1dd0b5417:18:3000"
  "WBTC:0x0555E30da8f98308EdB960aa94C0Db47230d2B9c:8:3000"
  "WMON:0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A:18:3000"
  "shMON:0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c:18:0"
  "sMON:0xA3227C5969757783154C60bF0bC1944180ed81B9:18:0"
  "gMON:0x8498312A6B3CbD158bf0c93AbdCF29E6e4F55081:18:0"
)

ISSUES=0
say()  { echo; echo "── $*"; }
warn() { echo "  WARN $*"; ISSUES=$((ISSUES+1)); }
call() { cast call "$@" --rpc-url "$RPC" 2>/dev/null | head -1 | awk '{print $1}'; }
send() { local d="$1"; shift
  if cast send --private-key "$PK" --rpc-url "$RPC" "$@" >/dev/null 2>&1; then
    echo "  OK   $d"
  else
    echo "  FAIL $d"; ISSUES=$((ISSUES+1)); return 1
  fi
}
quote() { cast call "$QUOTER" \
  "quoteExactInputSingle((address,address,uint256,uint24,uint160))(uint256,uint160,uint32,uint256)" \
  "($1,$2,$3,$4,0)" --rpc-url "$RPC" 2>/dev/null | head -1 | awk '{print $1}'; }

echo "=== K613 weekly | $(date -u '+%Y-%m-%d %H:%M UTC') ==="
echo "ключ: $ME"

# резолвим токены рынков один раз — нужны и для сбора, и для отчёта
declare -A ATOK VDBT
for e in "${ASSETS[@]}"; do
  IFS=: read -r SYM UND DEC FEE <<<"$e"
  T=$(cast call "$DP" "getReserveTokensAddresses(address)(address,address,address)" "$UND" --rpc-url "$RPC" 2>/dev/null)
  ATOK[$SYM]=$(echo "$T" | sed -n 1p | awk '{print $1}')
  VDBT[$SYM]=$(echo "$T" | sed -n 3p | awk '{print $1}')
done

# ── 1. флаш эпохи ───────────────────────────────────────────────────────────
say "1. advanceEpoch"
LAST=$(call "$RD" "lastEpochFlushAt()(uint256)")
NOW=$(date -u +%s)
if [ "$(python3 -c "print(1 if $NOW < $LAST+604800 else 0)")" = "1" ]; then
  python3 -c "print('  эпоха ещё не закрылась, осталось %.1f ч — пропуск' % (($LAST+604800-$NOW)/3600))"
else
  send "advanceEpoch" "$RD" "advanceEpoch()"
fi

# ── 2. комиссии протокола ───────────────────────────────────────────────────
say "2. сбор комиссий"
IS_FA=$(call "$COLLECTOR" "hasRole(bytes32,address)(bool)" "$FUNDS_ADMIN_ROLE" "$ME")
if [ "$IS_FA" != "true" ]; then
  warn "у $ME нет FUNDS_ADMIN на Collector — сбор комиссий пропущен"
else
  ASSET_LIST="[$(printf '%s\n' "${ASSETS[@]}" | cut -d: -f2 | paste -sd, -)]"
  send "mintToTreasury (11 резервов)" "$POOL_AAVE" "mintToTreasury(address[])" "$ASSET_LIST" --gas-limit 3000000

  for e in "${ASSETS[@]}"; do
    IFS=: read -r SYM UND DEC FEE <<<"$e"
    AMT=$(call "${ATOK[$SYM]}" "balanceOf(address)(uint256)" "$COLLECTOR")
    if [ -z "${AMT:-}" ] || [ "$AMT" = "0" ]; then echo "  skip $SYM (на Collector пусто)"; continue; fi

    send "собрать   $SYM" "$COLLECTOR" "transfer(address,address,uint256)" "${ATOK[$SYM]}" "$ME" "$AMT" || continue
    send "распаковать $SYM" "$POOL_AAVE" "withdraw(address,uint256,address)" "$UND" "$AMT" "$ME" || continue

    if [ "$SYM" = "USDC" ]; then
      send "на Treasury: $SYM" "$USDC" "transfer(address,uint256)" "$TREASURY" "$AMT"
      continue
    fi
    if [ "$FEE" = "0" ]; then echo "  копим $SYM (нет V3/USDC пула — Kuru вручную, когда накопится)"; continue; fi

    Q=$(quote "$UND" "$USDC" "$AMT" "$FEE")
    if [ -z "${Q:-}" ] || [ "$Q" = "0" ]; then echo "  копим $SYM (нет котировки)"; continue; fi
    # Порог для стейблов: котировка ниже 95% номинала = пул сломан/пуст.
    # 30.07.2026 так утекли 7.8 AUSD за $0.07 в опустошённый пул.
    case "$SYM" in
      AUSD|USDT0)
        if [ "$(python3 -c "print(1 if $Q < $AMT*9500//10000 else 0)")" = "1" ]; then
          echo "  копим $SYM (котировка ниже 95% номинала — пул нездоров)"; continue
        fi ;;
    esac
    MINOUT=$(python3 -c "print($Q*(10000-$SLIPPAGE_BPS)//10000)")
    send "approve   $SYM" "$UND" "approve(address,uint256)" "$ROUTER" "$AMT" || continue
    # recipient = Treasury: выменянный USDC сразу там, без лишнего перевода
    send "свап      $SYM -> USDC" "$ROUTER" \
      "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))" \
      "($UND,$USDC,$FEE,$TREASURY,$AMT,$MINOUT,0)"
  done
fi

# ── 3. запас наград лендинга ────────────────────────────────────────────────
say "3. пополнение запаса наград"
STOCK=$(call "$XK613" "balanceOf(address)(uint256)" "$TREASURY")
EPS=0
for e in "${ASSETS[@]}"; do
  IFS=: read -r SYM UND DEC FEE <<<"$e"
  for t in "${ATOK[$SYM]}" "${VDBT[$SYM]}"; do
    v=$(cast call "$RC" "getRewardsData(address,address)(uint256,uint256,uint256,uint256)" "$t" "$XK613" --rpc-url "$RPC" 2>/dev/null | sed -n 2p | awk '{print $1}')
    [ -n "${v:-}" ] && EPS=$((EPS + v))
  done
done
WEEKLY=$(python3 -c "print(int($EPS*604800))")
LEFT=$(call "$OP" "trancheRemaining()(uint256)")
NEED=$(python3 -c "print(max(0, min($WEEKLY - ${STOCK:-0}, ${LEFT:-0})))")
python3 -c "print('  запас %.0f xK613 | расход %.0f/нед | лимит недели %.0f' % (${STOCK:-0}/1e18, $WEEKLY/1e18, ${LEFT:-0}/1e18))"
if [ "$NEED" = "0" ]; then
  echo "  пропуск: запаса хватает или лимит недели исчерпан"
else
  python3 -c "print('  к пополнению: %.0f' % ($NEED/1e18))"
  send "topUpTranche" "$OP" "topUpTranche(uint256)" "$NEED"
fi

# ── 4. выкуп ────────────────────────────────────────────────────────────────
say "4. buyback -> стейкерам"
TB=$(call "$USDC" "balanceOf(address)(uint256)" "$TREASURY")
BLEFT=$(call "$OP" "buybackRemaining()(uint256)")
AMT=$(python3 -c "print(min(${TB:-0}, ${BLEFT:-0}))")
if [ "$AMT" = "0" ]; then
  python3 -c "print('  пропуск: USDC на Treasury \$%.2f, лимит недели \$%.2f' % (${TB:-0}/1e6, ${BLEFT:-0}/1e6))"
else
  Q=$(quote "$USDC" "$K613" "$AMT" 500)
  if [ -z "${Q:-}" ] || [ "$Q" = "0" ]; then
    warn "нет котировки из пула K613/USDC — выкуп пропущен"
  else
    MINOUT=$(python3 -c "print($Q*(10000-$SLIPPAGE_BPS)//10000)")
    python3 -c "print('  выкуп на \$%.2f -> >= %.0f K613' % ($AMT/1e6, $MINOUT/1e18))"
    send "runBuyback" "$OP" "runBuyback(uint256,uint256)" "$AMT" "$MINOUT"
  fi
fi

# ── 5. отчёт ────────────────────────────────────────────────────────────────
say "5. состояние"
ORACLE=$(call "$RC" "getRewardOracle(address)(address)" "$XK613")
ANSWER=$(cast call "$ORACLE" "latestAnswer()(int256)" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')
if [ -z "${ANSWER:-}" ] || [ "$ANSWER" = "0" ]; then
  warn "оракул $ORACLE не отвечает — страница рынков может лечь"
  PRICE=0.0089
else
  PRICE=$(python3 -c "print(${ANSWER}/1e8)")
  python3 -c "print('  цена K613: \$%.6f' % (${ANSWER}/1e8))"
fi

OUT=$(cast call "$UIP" "getReservesIncentivesData(address)" "$PAP" --rpc-url "$RPC" 2>&1 | tr -d '\n')
[ "${OUT:0:5}" = "Error" ] && warn "UiIncentiveDataProvider ревертит — APR наград не отобразятся" \
                           || echo "  UI-провайдер: отвечает"

PU=$(call "$USDC" "balanceOf(address)(uint256)" "$POOL_K613")
python3 -c "print('  ликвидность пула: \$%.0f' % (${PU:-0}/1e6))"
[ "$(python3 -c "print(1 if ${PU:-0}/1e6 < 500 else 0)")" = "1" ] && warn "ликвидность ниже \$500 — большое проскальзывание при выкупе"

NEWSTOCK=$(call "$XK613" "balanceOf(address)(uint256)" "$TREASURY")
DAYS=$(python3 -c "print(f'{${NEWSTOCK:-0}/$EPS/86400:.1f}' if $EPS>0 else '999')")
echo "  запаса наград хватит на: $DAYS дней"
[ "$(python3 -c "print(1 if float('$DAYS')<7 else 0)")" = "1" ] && warn "запас меньше недели — поднять лимит оператора (Safe: setCaps)"

RDBAL=$(call "$XK613" "balanceOf(address)(uint256)" "$RD")
RDDEP=$(call "$RD" "totalDeposits()(uint256)")
python3 -c "print('  пул наград стейкерам: %.2f xK613 (депозитов %.0f)' % ((${RDBAL:-0}-${RDDEP:-0})/1e18, ${RDDEP:-0}/1e18))"

for e in "K613:$K613" "xK613:$XK613" "Treasury:$TREASURY" "RewardsDistributor:$RD"; do
  IFS=: read -r NAME ADDR <<<"$e"
  S=$(call "$ADDR" "hasRole(bytes32,address)(bool)" "$ADMIN_ROLE" "$SAFE")
  [ "$S" != "true" ] && warn "$NAME: Safe больше не админ!"
done

say "рынки"
printf "  %-8s %12s %12s %10s %10s\n" "рынок" "supplied\$" "borrowed\$" "APRsup" "APRbor"
TOTS=0
for e in "${ASSETS[@]}"; do
  IFS=: read -r SYM UND DEC FEE <<<"$e"
  ES=$(cast call "$RC" "getRewardsData(address,address)(uint256,uint256,uint256,uint256)" "${ATOK[$SYM]}" "$XK613" --rpc-url "$RPC" 2>/dev/null | sed -n 2p | awk '{print $1}')
  EB=$(cast call "$RC" "getRewardsData(address,address)(uint256,uint256,uint256,uint256)" "${VDBT[$SYM]}" "$XK613" --rpc-url "$RPC" 2>/dev/null | sed -n 2p | awk '{print $1}')
  SUP=$(call "${ATOK[$SYM]}" "totalSupply()(uint256)")
  BOR=$(call "${VDBT[$SYM]}" "totalSupply()(uint256)")
  PX=$(curl -s -m 10 "https://coins.llama.fi/prices/current/monad:$UND" | python3 -c "
import json,sys
try:
    c=json.load(sys.stdin)['coins']; print(list(c.values())[0]['price'] if c else 0)
except Exception: print(0)" 2>/dev/null)
  RES=$(python3 -c "
sup=${SUP:-0}/10**$DEC*${PX:-0}; bor=${BOR:-0}/10**$DEC*${PX:-0}
aps=(${ES:-0}*31536000/1e18*$PRICE/sup*100) if sup>0 else 0
apb=(${EB:-0}*31536000/1e18*$PRICE/bor*100) if bor>0 else 0
print('%-8s %12.0f %12.0f %9.0f%% %9.0f%%|%.0f' % ('$SYM', sup, bor, aps, apb, $TOTS+sup))")
  echo "  ${RES%%|*}"
  TOTS=${RES##*|}
done
python3 -c "print('  ИТОГО supplied: \$%.0f' % $TOTS)"

echo
if [ "$ISSUES" = "0" ]; then
  echo "=== DONE ==="
else
  echo "=== DONE, проблем: $ISSUES ==="
  exit 1
fi
