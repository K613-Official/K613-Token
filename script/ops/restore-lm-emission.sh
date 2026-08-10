#!/usr/bin/env bash
# Восстанавливает LM-эмиссию ровно в те значения, что стояли на чейне до обнуления
# 2026-08-10 02:27 UTC перед катовером на StakingV2/TreasuryV2.
#
# Почему отдельный скрипт, а не set-lm-emission.sh: та таблица посчитана 2026-07-31
# под целевые APR и даёт 479,452 K613/нед против 3,639,041, которые реально стояли —
# расхождение по рынкам от 1.8x до 34x, никаким множителем не сводится. Значения ниже
# сняты из событий AssetConfigUpdated (поле oldEmission) той самой транзакции обнуления,
# то есть это факт с чейна, а не пересчёт.
#
# Итого восстанавливает 24.93M K613/год — бюджет LM Year-1.
#
# Env: PRIVATE_KEY (должен быть xK613 emission admin — ключ CEO), MONAD_RPC.
#   ./script/ops/restore-lm-emission.sh          # применить
#   DRY=1 ./script/ops/restore-lm-emission.sh    # только показать
set -u

ENV_FILE="$(cd "$(dirname "$0")/../.." && pwd)/.env"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
RPC="${MONAD_RPC:?set MONAD_RPC}"
PK="${PRIVATE_KEY:?set PRIVATE_KEY}"
DRY="${DRY:-0}"
ME=$(cast wallet address "$PK")

EMISSION_MANAGER=0x7eEdb2D4D4b89b8B854c734e8fAABfB24E0537A6
RC=0xe1d8B642c83587Df813a36F361C682C0475c4ea4
XK613=0x9064d55A8A8473fA39c41A16492Fa1094Eb4E8b5
WEEK=604800

# символ : supply|borrow : токен (aToken или varDebtToken) : emissionPerSecond в wei
ASSETS=(
  "USDC:supply:0x4fdc7bccabf4ee4ca08af24aaabf3531ea6519de:110984271943176052"
  "USDC:borrow:0xc5ba5d5b0bd61fa520e2b7727c7521550adcf2f0:55492135971588026"
  "AUSD:supply:0x6e8e9da5bcdd2ee69c51406e2267ec65841fa307:103056823947234906"
  "AUSD:borrow:0x06c26b7444488539d70d9ad4c2e3796ad86ee151:47564687975646879"
  "USDT0:supply:0x88fb417cffc3858697da31e1415f54f6e82c666c:35673515981735159"
  "USDT0:borrow:0xfd5c96f3bda2a55265dcef2deb25c03247070c54:23782343987823439"
  "WETH:supply:0x793dbde5a51849fa73109a6dae913fc6c9209394:79274479959411466"
  "WETH:borrow:0x2d465eb541173d5e81eb1fd257a57759b933f52a:39637239979705733"
  "WBTC:supply:0x24cd55e35f65585fb02448035a1ebbf154a7892f:51528411973617453"
  "WBTC:borrow:0xa7411f421d4050713898c5c44be3037016846587:39637239979705733"
  "WMON:supply:0xd1d0b50038afe4c74c4fa87d4661c1d5a53822e9:11891171993911719"
  "WMON:borrow:0x2b32369615832d74113e01d2f750d84e203d5074:3963723997970573"
  "wstETH:supply:0x6ea228a2429907bceaa6351370c4db07145cd4ac:67383307965499746"
  "wstETH:borrow:0x0c617b0b7864e3ee948938c6e917095819dd5b1f:31709791983764586"
  "wsrUSD:supply:0xb6d63ea862bf17cd1cfd719173e731fe5588d1d0:39637239979705733"
  "wsrUSD:borrow:0xb5878d9104116ec3eca048430c9effc3781698f5:23782343987823439"
  "shMON:supply:0x95d0acdd70e398501754741ad896e27ec693dc07:7927447995941146"
  "shMON:borrow:0x1d46ca4b7745bc7720e41ed62eacbb95662c0cda:3963723997970573"
  "sMON:supply:0x54521b12d429133ca4fbbffcafb282d71bff5784:3963723997970573"
  "sMON:borrow:0x3a985318849848624235551e4284c765c582c21d:3963723997970573"
  "gMON:supply:0x4eda1817ae13c1634bd94bee697d63e546e7605f:3963723997970573"
  "gMON:borrow:0x6168be2d5ff343dfe8667607b216c7cfdfe82e3c:3963723997970573"
)

# Проверка ключа нужна только для реального прогона: DRY ничего не отправляет и
# должен читаться с любого ключа, иначе им нельзя проверить план перед передачей CEO.
if [ "$DRY" != "1" ]; then
  EA=$(cast call "$EMISSION_MANAGER" "getEmissionAdmin(address)(address)" "$XK613" --rpc-url "$RPC" | awk '{print $1}')
  if [ "$(echo "$EA" | tr 'A-F' 'a-f')" != "$(echo "$ME" | tr 'A-F' 'a-f')" ]; then
    echo "ABORT: $ME не emission admin для xK613 ($EA)" >&2
    exit 1
  fi
fi

echo "=== восстановление LM-эмиссии, оператор $ME ==="
FAILS=0
for entry in "${ASSETS[@]}"; do
  IFS=: read -r SYM KIND TOK EPS <<<"$entry"
  WK=$(python3 -c "print(f'{$EPS*$WEEK/1e18:,.0f}')")
  if [ "$DRY" = "1" ]; then
    printf "  DRY  %-8s %-7s %14s K613/нед\n" "$SYM" "$KIND" "$WK"
    continue
  fi
  if cast send --private-key "$PK" --rpc-url "$RPC" -g 200 "$EMISSION_MANAGER" \
      "setEmissionPerSecond(address,address[],uint88[])" "$TOK" "[$XK613]" "[$EPS]" >/dev/null 2>&1; then
    printf "  OK   %-8s %-7s %14s K613/нед\n" "$SYM" "$KIND" "$WK"
  else
    printf "  FAIL %-8s %-7s\n" "$SYM" "$KIND"; FAILS=$((FAILS+1))
  fi
done

[ "$DRY" = "1" ] && exit 0

echo
echo "── сверка ончейн"
for entry in "${ASSETS[@]}"; do
  IFS=: read -r SYM KIND TOK EPS <<<"$entry"
  GOT=$(cast call "$RC" "getRewardsData(address,address)(uint256,uint256,uint256,uint256)" "$TOK" "$XK613" --rpc-url "$RPC" | sed -n 2p | awk '{print $1}')
  [ "$GOT" != "$EPS" ] && { echo "  BAD  $SYM $KIND: ончейн $GOT != $EPS"; FAILS=$((FAILS+1)); }
done
[ "$FAILS" = "0" ] && echo "  всё сошлось" || echo "  ОШИБОК: $FAILS"
exit $FAILS
