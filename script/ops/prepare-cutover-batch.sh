#!/usr/bin/env bash
# Готовит Safe-батч катовера на V2: снимает актуальные числа с чейна, подставляет их в
# шаблон, проверяет результат и печатает по-человечески, что именно будет подписано.
#
#   ./script/ops/prepare-cutover-batch.sh 1     # возврат + заморозка
#   ./script/ops/prepare-cutover-batch.sh 2     # катовер   (нужен NEW_STRATEGY=0x...)
#
# Готовый файл кладётся в /tmp/cutover-batch-N.json — его и заливать в Transaction Builder.
# Скрипт только читает чейн, ничего не отправляет.
set -euo pipefail

STEP="${1:-}"
if [ "$STEP" != "1" ] && [ "$STEP" != "2" ]; then
  echo "usage: $0 <1|2>" >&2
  exit 1
fi

ENV_FILE="$(cd "$(dirname "$0")/../.." && pwd)/.env"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
RPC="${MONAD_RPC:?set MONAD_RPC}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

K613=0xb09582631336068d4B0089d943f40CbF46dE5189
XK613=0x9064d55A8A8473fA39c41A16492Fa1094Eb4E8b5
STAKING_V1=0x36451F6b4c06916aafd16359CCf99eB1f584DB0b
TREASURY_V1=0x3377BAB9A510A586627D2f9013e132d269Eb9871
TREASURY_V2=0x10aCE88f2F2c361218615F5dcA8987DD16C54282
RD=0xE3E8925E8554464611c86419B9e99AD7Cd47428f
# Развёрнута и верифицирована 2026-08-07, vault=TreasuryV2. Константа, а не env:
# адрес известен и постоянен, а переменная окружения — лишний способ ошибиться.
# NEW_STRATEGY= в окружении перебивает её (нужно только для репетиции на форке).
PULL_STRATEGY_V2=0x58fbEdaC5D64022EecB3CF9115e5c9a7A82368AD

call() { cast call "$1" "$2" ${3:-} --rpc-url "$RPC" | awk '{print $1}'; }
human() { python3 -c "print(f'{int('$1')/1e18:,.6f}')"; }

echo "=== чтение состояния чейна ==="

if [ "$STEP" = "1" ]; then
  SRC="$ROOT/docs/safe-batches/v2-cutover-1-recover-and-freeze.json"
  OUT=/tmp/cutover-batch-1.json

  # Долг конвертации. Проверяем баланс K613, а не pendingPenalties: вторая обнуляется
  # в момент начисления, то есть ровно тогда, когда долг возникает.
  DEBT=$(call "$K613" "balanceOf(address)(uint256)" "$RD")
  if [ "$DEBT" != "0" ]; then
    echo "СТОП: на RewardsDistributor $(human "$DEBT") K613 не конвертированы." >&2
    echo "  Заморозка сейчас оставит пул коротким на эту сумму до конца миграции." >&2
    echo "  Дождись чужого claim() или выполни advanceEpoch() при живом StakingV1:" >&2
    echo "    cast send $RD 'advanceEpoch()' --private-key \$PRIVATE_KEY --rpc-url \$MONAD_RPC -g 200" >&2
    echo "  Эпоха созревает: $(call $RD 'nextEpochAt()(uint256)')" >&2
    exit 1
  fi
  echo "  долг конвертации на RD : 0  ok"

  MINTER=$(call "$XK613" "minter()(address)")
  if [ "$(printf '%s' "$MINTER" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$STAKING_V1" | tr 'A-Z' 'a-z')" ]; then
    echo "СТОП: xK613.minter = $MINTER, а не StakingV1. Катовер уже исполнен?" >&2
    exit 1
  fi
  echo "  xK613.minter           : StakingV1  ok"

  XK_TR=$(call "$XK613" "balanceOf(address)(uint256)" "$TREASURY_V1")
  [ "$XK_TR" = "0" ] && { echo "СТОП: на TreasuryV1 нет xK613, возвращать нечего." >&2; exit 1; }
  echo "  xK613 на TreasuryV1    : $(human "$XK_TR")   <- вернётся 1:1 в K613"

  sed "s|<XK613_ON_TREASURY_V1>|$XK_TR|g" "$SRC" > "$OUT"

else
  SRC="$ROOT/docs/safe-batches/v2-cutover-2-switch.json"
  OUT=/tmp/cutover-batch-2.json
  NEW_STRATEGY="${NEW_STRATEGY:-$PULL_STRATEGY_V2}"

  # Непустой переменной мало. Батч выдаёт этому адресу безлимитный аллаунс на xK613
  # казны, так что проверяем, что это действительно стратегия и действительно наша.
  if [ "$(cast code "$NEW_STRATEGY" --rpc-url "$RPC" 2>/dev/null || echo 0x)" = "0x" ]; then
    echo "СТОП: по адресу NEW_STRATEGY=$NEW_STRATEGY нет кода." >&2
    exit 1
  fi
  SV=$(cast call "$NEW_STRATEGY" "getRewardsVault()(address)" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}' || echo "")
  if [ -z "$SV" ]; then
    echo "СТОП: $NEW_STRATEGY не отвечает на getRewardsVault() — это не PullRewardsTransferStrategy." >&2
    exit 1
  fi
  if [ "$(printf '%s' "$SV" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$TREASURY_V2" | tr 'A-Z' 'a-z')" ]; then
    echo "СТОП: стратегия смотрит не туда." >&2
    echo "  getRewardsVault() = $SV" >&2
    echo "  ожидается         = $TREASURY_V2 (TreasuryV2)" >&2
    echo "  Похоже, запущен InstallXk613PullStrategy.s.sol — он копирует vault со старой" >&2
    echo "  стратегии, то есть TreasuryV1. Нужен DeployXk613PullStrategyV2.s.sol." >&2
    exit 1
  fi
  LIVE=$(cast call 0xe1d8B642c83587Df813a36F361C682C0475c4ea4 \
    "getTransferStrategy(address)(address)" "$XK613" --rpc-url "$RPC" | awk '{print $1}')
  if [ "$(printf '%s' "$LIVE" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$NEW_STRATEGY" | tr 'A-Z' 'a-z')" ]; then
    echo "СТОП: $NEW_STRATEGY уже подключена как действующая стратегия." >&2
    echo "  Переключать эмиссию можно только ПОСЛЕ этого батча — иначе клеймы лендеров" >&2
    echo "  ревертятся, пока TreasuryV2 без xK613 и без аллаунса." >&2
    exit 1
  fi
  echo "  LM-стратегия           : $NEW_STRATEGY  ok (vault=TreasuryV2, ещё не подключена)"

  PAUSED=$(call "$STAKING_V1" "paused()(bool)")
  [ "$PAUSED" != "true" ] && { echo "СТОП: StakingV1 не на паузе — батч 1 не исполнен." >&2; exit 1; }
  echo "  StakingV1 на паузе     : да  ok  (totalSupply заморожен)"

  SEED=$(call "$XK613" "totalSupply()(uint256)")
  K_TR=$(call "$K613" "balanceOf(address)(uint256)" "$TREASURY_V1")
  # redeemRewards отдаёт ровно 1:1, поэтому возврат равен тому, что ушло в батче 1.
  RECOVERED=$(python3 -c "
import json,re
d=json.load(open('/tmp/cutover-batch-1.json'))
print(d['transactions'][3]['contractInputsValues']['amount'])
" 2>/dev/null || echo "")
  [ -z "$RECOVERED" ] && { echo "СТОП: /tmp/cutover-batch-1.json не найден, не могу взять сумму возврата." >&2; exit 1; }

  echo "  SEED (xK613 supply)    : $(human "$SEED")"
  echo "  K613 на TreasuryV1     : $(human "$K_TR")"
  echo "  возвращено в батче 1   : $(human "$RECOVERED")"
  echo "  новая LM-стратегия     : $NEW_STRATEGY"

  sed -e "s|<SEED>|$SEED|g" \
      -e "s|<K613_ON_TREASURY_V1>|$K_TR|g" \
      -e "s|<RECOVERED_K613>|$RECOVERED|g" \
      -e "s|<NEW_PULL_STRATEGY>|$NEW_STRATEGY|g" \
      "$SRC" > "$OUT"
fi

echo
echo "=== проверка файла ==="
python3 - "$OUT" <<'PY'
import json, re, sys
path = sys.argv[1]
raw = open(path).read()

left = sorted(set(re.findall(r'<[A-Z_0-9]+>', raw)))
if left:
    print("ПРОВАЛ: остались незаполненные плейсхолдеры:", ", ".join(left))
    sys.exit(1)

d = json.loads(raw)          # бросит исключение, если JSON битый
txs = d["transactions"]
print(f"  JSON валиден, плейсхолдеров не осталось, транзакций: {len(txs)}")
print()
print("=== что будет подписано ===")
for i, t in enumerate(txs, 1):
    name = t["contractMethod"]["name"]
    args = t["contractInputsValues"]
    pretty = []
    for k, v in args.items():
        if isinstance(v, str) and v.isdigit() and len(v) > 12:
            pretty.append(f"{k}={int(v)/1e18:,.4f}e18")
        else:
            pretty.append(f"{k}={v}")
    print(f"  {i:2}. {name}({', '.join(pretty)})")
    print(f"      -> {t['to']}")
PY

echo
echo "Готово: $OUT"
echo "Залить в Safe -> New transaction -> Transaction Builder -> Upload batch."
