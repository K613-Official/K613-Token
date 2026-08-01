#!/usr/bin/env bash
# ============================================================================
# LM report generator: per-market TVL, weekly rewards (tokens + USD), APRs.
# All prices are pulled LIVE from Uniswap V3 pools on Monad via QuoterV2:
#   - K613/USDC 0.05% pool  -> K613 price (reward valuation)
#   - <asset>/USDC pools (SOP D.4) -> asset prices
#   - stables (USDC/USDT0/AUSD/wsrUSD) priced at $1.00 (flagged)
#   - shMON/sMON/gMON proxied at WMON price (staked MON ~= MON, flagged)
# Output: human table + CSV block (paste straight into Google Sheets).
# Read-only: no PRIVATE_KEY needed, only MONAD_RPC.
# ============================================================================
set -u
ENV_FILE="$(cd "$(dirname "$0")/../.." && pwd)/.env"
if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
RPC="${MONAD_RPC:?set MONAD_RPC}"

QUOTER=0x661E93cca42AfacB172121EF892830cA3b70F08d
DP=0xfc87bE7f3657AAD69baDb6247A88E924D1F8bc53
RC=0xe1d8B642c83587Df813a36F361C682C0475c4ea4
USDC=0x754704Bc059F8C67012fEd69BC8A327a5aafb603
K613=0xb09582631336068d4B0089d943f40CbF46dE5189
XK613=0x9064d55A8A8473fA39c41A16492Fa1094Eb4E8b5

# symbol : underlying : decimals : price-source (1=stable $1, K613POOL, V3:fee, MONPROXY)
ASSETS=(
  "USDC:0x754704Bc059F8C67012fEd69BC8A327a5aafb603:6:1"
  "AUSD:0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a:6:1"
  "USDT0:0xe7cd86e13AC4309349F30B3435a9d337750fC82D:6:1"
  "wsrUSD:0x4809010926aec940b550D34a46A52739f996D75D:18:1"
  "WETH:0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242:18:V3:3000"
  "wstETH:0x10Aeaf63194db8d453d4D85a06E5eFE1dd0b5417:18:V3:3000"
  "WBTC:0x0555E30da8f98308EdB960aa94C0Db47230d2B9c:8:V3:3000"
  "WMON:0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A:18:V3:3000"
  "shMON:0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c:18:MONPROXY"
  "sMON:0xA3227C5969757783154C60bF0bC1944180ed81B9:18:MONPROXY"
  "gMON:0x8498312A6B3CbD158bf0c93AbdCF29E6e4F55081:18:MONPROXY"
)

q() { cast call "$QUOTER" "quoteExactInputSingle((address,address,uint256,uint24,uint160))(uint256,uint160,uint32,uint256)" "($1,$USDC,$2,$3,0)" --rpc-url "$RPC" 2>/dev/null | head -1 | awk '{print $1}'; }

# K613 price from our pool: quote 100 K613 -> USDC (small enough not to skew)
K613_RAW=$(q "$K613" 100000000000000000000 500)
K613_PRICE=$(python3 -c "print(${K613_RAW:-0}/1e6/100)")
# MON price: 1 WMON -> USDC
MON_RAW=$(q 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A 1000000000000000000 3000)
MON_PRICE=$(python3 -c "print(${MON_RAW:-0}/1e6)")

echo "=== K613 LM report | $(date -u '+%F %T') UTC ==="
echo "K613 price (Uni 0.05% pool): \$$K613_PRICE"
echo "MON price  (Uni 0.3% pool):  \$$MON_PRICE"
echo
CSV="market,price_usd,price_source,supplied_usd,borrowed_usd,eps_supply,eps_borrow,rewards_week_tokens,rewards_week_usd,apr_supply_pct,apr_borrow_pct"
for entry in "${ASSETS[@]}"; do
  IFS=: read -r SYM UNDER DEC SRC FEE <<<"$entry"
  case "$SRC" in
    1) PRICE=1; PSRC="stable=\$1";;
    MONPROXY) PRICE=$MON_PRICE; PSRC="MON proxy";;
    V3) RAW=$(q "$UNDER" $(python3 -c "print(10**$DEC)") "$FEE"); PRICE=$(python3 -c "print(${RAW:-0}/1e6)"); PSRC="UniV3 $FEE";;
  esac
  T=$(cast call "$DP" "getReserveTokensAddresses(address)(address,address,address)" "$UNDER" --rpc-url "$RPC")
  AT=$(echo "$T" | sed -n 1p | awk '{print $1}'); VD=$(echo "$T" | sed -n 3p | awk '{print $1}')
  SUP=$(cast call "$AT" "totalSupply()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
  BOR=$(cast call "$VD" "totalSupply()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
  EPS_S=$(cast call "$RC" "getRewardsData(address,address)(uint256,uint256,uint256,uint256)" "$AT" "$XK613" --rpc-url "$RPC" | sed -n 2p | awk '{print $1}')
  EPS_B=$(cast call "$RC" "getRewardsData(address,address)(uint256,uint256,uint256,uint256)" "$VD" "$XK613" --rpc-url "$RPC" | sed -n 2p | awk '{print $1}')
  LINE=$(python3 - <<PY
sup_usd = $SUP/10**$DEC*$PRICE
bor_usd = $BOR/10**$DEC*$PRICE
wk_s = ${EPS_S:-0}*604800/1e18
wk_b = ${EPS_B:-0}*604800/1e18
wk_tok = wk_s+wk_b
wk_usd = wk_tok*$K613_PRICE
apr_s = (wk_s*$K613_PRICE*52/sup_usd*100) if sup_usd>0 else 0
apr_b = (wk_b*$K613_PRICE*52/bor_usd*100) if bor_usd>0 else 0
print(f"$SYM,{$PRICE:.6f},$PSRC,{sup_usd:.0f},{bor_usd:.0f},{${EPS_S:-0}},{${EPS_B:-0}},{wk_tok:.0f},{wk_usd:.2f},{apr_s:.1f},{apr_b:.1f}")
print(f"  {'$SYM':7s} price=\${$PRICE:.4f} supplied=\${sup_usd:>10,.0f} rewards/wk={wk_tok:>8,.0f} K613 (\${wk_usd:>8,.2f}) APRsup={apr_s:>8.1f}% APRbor={apr_b:>7.1f}%", file=__import__('sys').stderr)
PY
)
  CSV="$CSV
$LINE"
done
echo
echo "── CSV (вставить в Google Sheets: Data → Split text to columns):"
echo "$CSV"
