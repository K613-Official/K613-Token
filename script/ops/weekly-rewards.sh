#!/usr/bin/env bash
# ============================================================================
# K613 weekly rewards — то, что раньше требовало подписей Safe, теперь крон.
#
#   1. advanceEpoch()        — флаш эпохи RewardsDistributor (permissionless)
#   2. topUpTranche(...)     — пополнение запаса наград лендинга (через оператора)
#   3. runBuyback(...)       — выкуп K613 на собранные комиссии -> стейкерам
#
# Шаги 2-3 идут через K613TreasuryOperator: он держит админку Treasury и режет
# любой вызов недельным лимитом, так что ключ крона не может потратить больше
# бюджета. Safe отзывает контракт одной транзакцией, если что-то пойдёт не так.
#
# Суммы считаются от факта: транш — по остатку запаса, выкуп — по балансу USDC
# Treasury, minOut — свежая котировка минус SLIPPAGE_BPS.
#
# Usage:  ./script/ops/weekly-rewards.sh
# Env: PRIVATE_KEY (ключ с OPERATOR_ROLE), MONAD_RPC, OPERATOR_CONTRACT.
#      Optional: SLIPPAGE_BPS (default 100 = 1%).
# ============================================================================
set -u

ENV_FILE="$(cd "$(dirname "$0")/../.." && pwd)/.env"
if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
RPC="${MONAD_RPC:?set MONAD_RPC}"
PK="${PRIVATE_KEY:?set PRIVATE_KEY}"
OP="${OPERATOR_CONTRACT:?set OPERATOR_CONTRACT (адрес K613TreasuryOperator в .env)}"
SLIPPAGE_BPS="${SLIPPAGE_BPS:-100}"
ME=$(cast wallet address "$PK")

RD=0xE3E8925E8554464611c86419B9e99AD7Cd47428f
TREASURY=0x3377BAB9A510A586627D2f9013e132d269Eb9871
XK613=0x9064d55A8A8473fA39c41A16492Fa1094Eb4E8b5
K613=0xb09582631336068d4B0089d943f40CbF46dE5189
USDC=0x754704Bc059F8C67012fEd69BC8A327a5aafb603
QUOTER=0x661E93cca42AfacB172121EF892830cA3b70F08d
RC=0xe1d8B642c83587Df813a36F361C682C0475c4ea4
DP=0xfc87bE7f3657AAD69baDb6247A88E924D1F8bc53

FAILS=0
say()  { echo; echo "── $*"; }
call() { cast call "$@" --rpc-url "$RPC" 2>/dev/null | head -1 | awk '{print $1}'; }
send() { local d="$1"; shift
  if cast send --private-key "$PK" --rpc-url "$RPC" "$@" >/dev/null 2>&1; then
    echo "  OK   $d"
  else
    echo "  FAIL $d"; FAILS=$((FAILS+1)); return 1
  fi
}

echo "=== K613 weekly rewards | $(date -u '+%Y-%m-%d %H:%M UTC') ==="
echo "operator key: $ME"

# ── 1. флаш эпохи (никаких ролей не нужно) ──────────────────────────────────
say "1. advanceEpoch"
LAST=$(call "$RD" "lastEpochFlushAt()(uint256)")
NOW=$(date -u +%s)
if [ "$(python3 -c "print(1 if $NOW < $LAST+604800 else 0)")" = "1" ]; then
  python3 -c "print('  эпоха ещё не закрылась, осталось %.1f ч — пропуск' % (($LAST+604800-$NOW)/3600))"
else
  send "advanceEpoch" "$RD" "advanceEpoch()"
fi

# ── 2. транш наград лендинга ────────────────────────────────────────────────
say "2. пополнение запаса наград"
STOCK=$(call "$XK613" "balanceOf(address)(uint256)" "$TREASURY")
LEFT=$(call "$OP" "trancheRemaining()(uint256)")
# недельный расход = сумма eps по 22 потокам * 604800
EPS=0
for a in 0x754704Bc059F8C67012fEd69BC8A327a5aafb603 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a \
         0xe7cd86e13AC4309349F30B3435a9d337750fC82D 0x4809010926aec940b550D34a46A52739f996D75D \
         0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242 0x10Aeaf63194db8d453d4D85a06E5eFE1dd0b5417 \
         0x0555E30da8f98308EdB960aa94C0Db47230d2B9c 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A \
         0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c 0xA3227C5969757783154C60bF0bC1944180ed81B9 \
         0x8498312A6B3CbD158bf0c93AbdCF29E6e4F55081; do
  T=$(cast call "$DP" "getReserveTokensAddresses(address)(address,address,address)" "$a" --rpc-url "$RPC" 2>/dev/null)
  for i in 1 3; do
    t=$(echo "$T" | sed -n "${i}p" | awk '{print $1}')
    e=$(cast call "$RC" "getRewardsData(address,address)(uint256,uint256,uint256,uint256)" "$t" "$XK613" --rpc-url "$RPC" 2>/dev/null | sed -n 2p | awk '{print $1}')
    [ -n "${e:-}" ] && EPS=$((EPS + e))
  done
done
WEEKLY=$(python3 -c "print(int($EPS*604800))")
NEED=$(python3 -c "print(max(0, min($WEEKLY - $STOCK, $LEFT)))")
python3 -c "
print('  запас %.0f xK613, расход %.0f/нед, лимит оператора %.0f' % ($STOCK/1e18, $WEEKLY/1e18, $LEFT/1e18))
print('  к пополнению: %.0f' % ($NEED/1e18))"
if [ "$NEED" = "0" ]; then
  echo "  пропуск: запаса хватает (или лимит недели исчерпан)"
else
  send "topUpTranche $NEED" "$OP" "topUpTranche(uint256)" "$NEED"
fi

# ── 3. выкуп на собранные комиссии ──────────────────────────────────────────
say "3. buyback -> стейкерам"
TB=$(call "$USDC" "balanceOf(address)(uint256)" "$TREASURY")
BLEFT=$(call "$OP" "buybackRemaining()(uint256)")
AMT=$(python3 -c "print(min($TB, $BLEFT))")
if [ "$AMT" = "0" ]; then
  python3 -c "print('  пропуск: USDC на Treasury %.2f, лимит недели %.2f' % ($TB/1e6, $BLEFT/1e6))"
else
  Q=$(cast call "$QUOTER" "quoteExactInputSingle((address,address,uint256,uint24,uint160))(uint256,uint160,uint32,uint256)" \
      "($USDC,$K613,$AMT,500,0)" --rpc-url "$RPC" 2>/dev/null | head -1 | awk '{print $1}')
  if [ -z "${Q:-}" ] || [ "$Q" = "0" ]; then
    echo "  FAIL нет котировки из пула K613/USDC"; FAILS=$((FAILS+1))
  else
    MINOUT=$(python3 -c "print($Q*(10000-$SLIPPAGE_BPS)//10000)")
    python3 -c "print('  выкуп на \$%.2f -> >= %.0f K613' % ($AMT/1e6, $MINOUT/1e18))"
    send "runBuyback" "$OP" "runBuyback(uint256,uint256)" "$AMT" "$MINOUT"
  fi
fi

echo
[ "$FAILS" = "0" ] && echo "=== DONE ===" || { echo "=== DONE with $FAILS issue(s) ==="; exit 1; }
