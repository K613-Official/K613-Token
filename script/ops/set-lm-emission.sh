#!/usr/bin/env bash
# ============================================================================
# K613 LM emission tuning (Monad mainnet), one command:
#   scales ALL 22 reward streams (11 markets x supply+borrow) to
#   FULL_RATE / DIVISOR, keeping the agreed 65/35 weight structure intact.
#
# Usage:
#   ./script/ops/set-lm-emission.sh          # DIVISOR=10 (48,077 K613/week)
#   ./script/ops/set-lm-emission.sh 5        # DIVISOR=5  (96,154 K613/week)
#   ./script/ops/set-lm-emission.sh 1        # back to the full 480,769/week
#
# Weekly routine: as TVL grows, lower the divisor. Emission is a RATE — the
# unspent Year-1 budget is not burned, it just gets spent slower.
#
# Env: PRIVATE_KEY (must be the xK613 emission admin), MONAD_RPC (.env autoloaded).
# ============================================================================
set -u

ENV_FILE="$(cd "$(dirname "$0")/../.." && pwd)/.env"
if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
RPC="${MONAD_RPC:?set MONAD_RPC (or put it in .env)}"
PK="${PRIVATE_KEY:?set PRIVATE_KEY (or put it in .env)}"
DIVISOR="${1:-10}"
ME=$(cast wallet address "$PK")

EMISSION_MANAGER=0x7eEdb2D4D4b89b8B854c734e8fAABfB24E0537A6
DATA_PROVIDER=0xfc87bE7f3657AAD69baDb6247A88E924D1F8bc53
XK613=0x9064d55A8A8473fA39c41A16492Fa1094Eb4E8b5
RC=0xe1d8B642c83587Df813a36F361C682C0475c4ea4

# symbol : underlying : FULL-RATE eps supply : FULL-RATE eps borrow
# (canonical 25M/year 65/35 values as configured on 2026-07-28)
ASSETS=(
  "USDC:0x754704Bc059F8C67012fEd69BC8A327a5aafb603:110984271943176052:55492135971588026"
  "AUSD:0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a:103056823947234906:47564687975646879"
  "USDT0:0xe7cd86e13AC4309349F30B3435a9d337750fC82D:35673515981735159:23782343987823439"
  "wsrUSD:0x4809010926aec940b550D34a46A52739f996D75D:39637239979705733:23782343987823439"
  "WETH:0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242:79274479959411466:39637239979705733"
  "wstETH:0x10Aeaf63194db8d453d4D85a06E5eFE1dd0b5417:67383307965499746:31709791983764586"
  "WBTC:0x0555E30da8f98308EdB960aa94C0Db47230d2B9c:51528411973617453:39637239979705733"
  "WMON:0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A:11891171993911719:3963723997970573"
  "shMON:0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c:7927447995941146:3963723997970573"
  "sMON:0xA3227C5969757783154C60bF0bC1944180ed81B9:3963723997970573:3963723997970573"
  "gMON:0x8498312A6B3CbD158bf0c93AbdCF29E6e4F55081:3963723997970573:3963723997970573"
)

FAILS=0
send() { local d="$1"; shift
  if cast send --private-key "$PK" --rpc-url "$RPC" "$@" >/dev/null 2>&1; then
    echo "  OK   $d"
  else
    echo "  FAIL $d"; FAILS=$((FAILS+1)); return 1
  fi
}

echo "=== K613 LM emission: FULL_RATE / $DIVISOR ==="
echo "operator: $ME"

EA=$(cast call "$EMISSION_MANAGER" "getEmissionAdmin(address)(address)" "$XK613" --rpc-url "$RPC")
if [ "$(echo "$EA" | tr 'A-F' 'a-f')" != "$(echo "$ME" | tr 'A-F' 'a-f')" ]; then
  echo "ABORT: $ME is not the xK613 emission admin ($EA)"
  exit 1
fi

WEEK_TOTAL=0
for entry in "${ASSETS[@]}"; do
  IFS=: read -r SYM UNDER FULL_S FULL_B <<<"$entry"
  TOKENS=$(cast call "$DATA_PROVIDER" "getReserveTokensAddresses(address)(address,address,address)" "$UNDER" --rpc-url "$RPC")
  ATOKEN=$(echo "$TOKENS" | sed -n 1p | awk '{print $1}')
  VDEBT=$(echo "$TOKENS" | sed -n 3p | awk '{print $1}')
  NEW_S=$(python3 -c "print($FULL_S // $DIVISOR)")
  NEW_B=$(python3 -c "print($FULL_B // $DIVISOR)")
  send "$SYM supply eps -> $NEW_S" "$EMISSION_MANAGER" "setEmissionPerSecond(address,address[],uint88[])" "$ATOKEN" "[$XK613]" "[$NEW_S]"
  send "$SYM borrow eps -> $NEW_B" "$EMISSION_MANAGER" "setEmissionPerSecond(address,address[],uint88[])" "$VDEBT" "[$XK613]" "[$NEW_B]"
  WEEK_TOTAL=$(python3 -c "print($WEEK_TOTAL + ($NEW_S+$NEW_B)*604800//10**18)")
done

echo
echo "── audit: reading back on-chain eps"
for entry in "${ASSETS[@]}"; do
  IFS=: read -r SYM UNDER FULL_S FULL_B <<<"$entry"
  ATOKEN=$(cast call "$DATA_PROVIDER" "getReserveTokensAddresses(address)(address,address,address)" "$UNDER" --rpc-url "$RPC" | sed -n 1p | awk '{print $1}')
  GOT=$(cast call "$RC" "getRewardsData(address,address)(uint256,uint256,uint256,uint256)" "$ATOKEN" "$XK613" --rpc-url "$RPC" | sed -n 2p | awk '{print $1}')
  WANT=$(python3 -c "print($FULL_S // $DIVISOR)")
  [ "$GOT" = "$WANT" ] && echo "  OK   $SYM supply eps = $GOT" || { echo "  BAD  $SYM supply eps: got $GOT want $WANT"; FAILS=$((FAILS+1)); }
done

echo
echo "new total emission: ~$WEEK_TOTAL K613/week (full rate: 480769)"
[ "$FAILS" = "0" ] && echo "=== DONE ===" || echo "=== DONE with $FAILS issue(s) — re-run safe ==="
