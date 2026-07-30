#!/usr/bin/env bash
# ============================================================================
# K613 handover to the Governance Safe, one command:
#   - 5 core contracts (K613, xK613, Staking, RewardsDistributor, Treasury):
#     admin+pauser -> Safe, revoked from the deployer EOA (HandoverRoles.s.sol)
#   - Sale: sweep unsold K613 to the Safe, admin+pauser -> Safe, EOA renounced
#   - Collector: DEFAULT_ADMIN -> Safe (ownership), FUNDS_ADMIN stays on the
#     EOA on purpose (operational role for the monthly fee cycle)
#   Ends with a full on-chain role audit printout.
#
# Usage:  ./script/ops/handover-to-safe.sh      (reads .env from repo root)
# Env: PRIVATE_KEY (deployer EOA holding the roles), MONAD_RPC.
# ============================================================================
set -u

ENV_FILE="$(cd "$(dirname "$0")/../.." && pwd)/.env"
if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
RPC="${MONAD_RPC:?set MONAD_RPC (or put it in .env)}"
PK="${PRIVATE_KEY:?set PRIVATE_KEY (or put it in .env)}"
ME=$(cast wallet address "$PK")

SAFE=0x7D5cF07621228a3D622b4695A1e28991E4620eBB
SALE=0xb83D0BEDE1C294B73c82ea0816E61E407775c7c2
COLLECTOR=0xF689bB846eE7DD51947c3368cc3ee26713D3ED83
K613=0xb09582631336068d4B0089d943f40CbF46dE5189
XK613=0x9064d55A8A8473fA39c41A16492Fa1094Eb4E8b5
STAKING=0x36451F6b4c06916aafd16359CCf99eB1f584DB0b
RD=0xE3E8925E8554464611c86419B9e99AD7Cd47428f
TREASURY=0x3377BAB9A510A586627D2f9013e132d269Eb9871

ADMIN=0x0000000000000000000000000000000000000000000000000000000000000000
PAUSER=$(cast keccak "PAUSER_ROLE")
FUNDS_ADMIN=0x46554e44535f41444d494e000000000000000000000000000000000000000000

FAILS=0
say()  { echo; echo "── $*"; }
send() { local d="$1"; shift
  if cast send --private-key "$PK" --rpc-url "$RPC" "$@" >/dev/null 2>&1; then
    echo "  OK   $d"
  else
    echo "  FAIL $d"; FAILS=$((FAILS+1)); return 1
  fi
}

echo "=== K613 handover to Governance Safe ==="
echo "operator: $ME"
echo "safe:     $SAFE"

if [ "$ME" != "0xF18Fcc2dCDCdc197B036b290BEcBeD692B9d2678" ]; then
  echo "ABORT: must be run with the deployer key 0xF18Fcc2d... (it holds the roles)"
  exit 1
fi

say "A. Core five (K613, xK613, Staking, RewardsDistributor, Treasury)"
if forge script script/deploy/HandoverRoles.s.sol --rpc-url "$RPC" --private-key "$PK" --broadcast -g 300 >/dev/null 2>&1; then
  echo "  OK   HandoverRoles (grant Safe + revoke EOA on all five)"
else
  echo "  FAIL HandoverRoles - inspect: forge script script/deploy/HandoverRoles.s.sol --rpc-url \$MONAD_RPC --private-key \$PRIVATE_KEY"
  FAILS=$((FAILS+1))
fi

say "B. Sale: sweep unsold K613, community payouts, remainder -> Safe, roles"
# Sweep lands on the operator first so the community payouts below can be paid,
# then the ENTIRE remaining K613 balance moves to the Safe.
send "sweep unsold K613 -> operator" "$SALE" "sweepUnsoldTokens(address)" "$ME"

# Community payouts (K613, whole tokens)
PAYOUTS=(
  "0x282cbe7e4ed3f7b5fD2cB4307e95875fb4120613:700"   # thanhtd91
  "0xa883f0e08615ce4783c4a47779125c8a433de8a8:510"   # blev.o
  "0x70002b02aff8e79a81957dc912594b4805f6a2b2:345"   # geniusspecs
  "0xB1Ad60a07b284e56f6A825C6d1E860D4B00508DD:240"   # sbr4699
  "0xe53a3efe7cb8931cccdcf6b165545586e467adad:100"   # jfxxx13
)
for p in "${PAYOUTS[@]}"; do
  IFS=: read -r ADDR TOKENS <<<"$p"
  WEI=$(python3 -c "print($TOKENS * 10**18)")
  send "payout $TOKENS K613 -> ${ADDR:0:10}..." "$K613" "transfer(address,uint256)" "$ADDR" "$WEI"
done

# Everything that's left (unsold remainder + POL leftovers) goes to the Safe
REST=$(cast call "$K613" "balanceOf(address)(uint256)" "$ME" --rpc-url "$RPC" | awk '{print $1}')
if [ -n "$REST" ] && [ "$REST" != "0" ]; then
  send "remaining K613 ($REST) -> Safe" "$K613" "transfer(address,uint256)" "$SAFE" "$REST"
fi

send "sale: grant admin  -> Safe" "$SALE" "grantRole(bytes32,address)" "$ADMIN" "$SAFE"
send "sale: grant pauser -> Safe" "$SALE" "grantRole(bytes32,address)" "$PAUSER" "$SAFE"
send "sale: renounce pauser (EOA)" "$SALE" "renounceRole(bytes32,address)" "$PAUSER" "$ME"
send "sale: renounce admin (EOA)" "$SALE" "renounceRole(bytes32,address)" "$ADMIN" "$ME"

say "C. Collector: ownership -> Safe (FUNDS_ADMIN stays on EOA for monthly ops)"
send "collector: grant admin -> Safe" "$COLLECTOR" "grantRole(bytes32,address)" "$ADMIN" "$SAFE"
send "collector: renounce admin (EOA)" "$COLLECTOR" "renounceRole(bytes32,address)" "$ADMIN" "$ME"

say "Audit (on-chain)"
check() { # check <name> <contract> <role> <holder> <expected>
  local got
  got=$(cast call "$2" "hasRole(bytes32,address)(bool)" "$3" "$4" --rpc-url "$RPC" | awk '{print $1}')
  if [ "$got" = "$5" ]; then echo "  OK   $1"; else echo "  BAD  $1 (got $got, want $5)"; FAILS=$((FAILS+1)); fi
}
for entry in "K613:$K613" "xK613:$XK613" "Staking:$STAKING" "RewardsDistributor:$RD" "Treasury:$TREASURY" "Sale:$SALE" "Collector:$COLLECTOR"; do
  IFS=: read -r NAME ADDR <<<"$entry"
  check "$NAME admin = Safe"    "$ADDR" "$ADMIN" "$SAFE" true
  check "$NAME admin != EOA"    "$ADDR" "$ADMIN" "$ME"   false
done
check "Collector FUNDS_ADMIN = EOA (operational, intended)" "$COLLECTOR" "$FUNDS_ADMIN" "$ME" true

echo
if [ "$FAILS" = "0" ]; then
  echo "=== DONE: all treasury-grade roles are on the Safe ==="
else
  echo "=== DONE with $FAILS issue(s) - safe to re-run, every step is idempotent ==="
fi
