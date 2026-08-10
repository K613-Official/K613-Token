#!/usr/bin/env bash
# Готовит Safe-батч катовера на V2: снимает актуальные числа с чейна, подставляет их в
# шаблон, проверяет результат и печатает по-человечески, что именно будет подписано.
#
#   ./script/ops/prepare-cutover-batch.sh 1     # возврат + заморозка
#   ./script/ops/prepare-cutover-batch.sh 2     # катовер
#   ./script/ops/prepare-cutover-batch.sh 3     # уборка: TreasuryV1 и OperatorV1 в отставку
#
# Готовый файл кладётся в /tmp/cutover-batch-N.json — его и заливать в Transaction Builder.
# Скрипт только читает чейн, ничего не отправляет.
set -euo pipefail

STEP="${1:-}"
if [ "$STEP" != "1" ] && [ "$STEP" != "2" ] && [ "$STEP" != "3" ]; then
  echo "usage: $0 <1|2|3>" >&2
  exit 1
fi

ENV_FILE="$(cd "$(dirname "$0")/../.." && pwd)/.env"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
RPC="${MONAD_RPC:?set MONAD_RPC}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Шаблоны батчей встроены сюда намеренно. Раньше скрипт читал их из docs/, но docs/
# целиком в .gitignore — на машине CEO файлов не оказалось и sed падал на полпути,
# уже после чтения чейна. Держать операционный артефакт в игнорируемом каталоге —
# значит гарантировать это на каждой второй машине.
render() {
  if [ "$TEMPLATE" = "1" ]; then cat <<'BATCH1_EOF'
{
  "version": "1.0",
  "chainId": "143",
  "createdAt": 1786060800000,
  "meta": {
    "name": "K613 V2 cutover — step 1 of 2: recover the LM stock, then freeze StakingV1",
    "description": "Two jobs in one batch, both of which MUST happen before the minter swap. (1) Recovery: StakingV1's 311,600 K613 reserve can only leave through a burn, and after the cutover nothing can burn against it — so anything still redeemable is redeemed now. TreasuryV1's xK613 is pulled to this Safe and passed through StakingV1.redeemRewards, which burns it, debits the Treasury's system-staker position and pays out K613 1:1 with no lock and no penalty. That is only possible while StakingV1 still holds MINTER_ROLE. It roughly halves what ends up stranded. (2) Freeze: pausing StakingV1 stops xK613.totalSupply() moving, which fixes the seed amount for step 2. AMOUNT IS TIME-SENSITIVE: the PullRewardsTransferStrategy drains TreasuryV1's xK613 to lenders continuously, and every token it pulls stops being recoverable. Read the balance immediately before signing and use that number in all three places. Reversible up to the pause: StakingV1.unpause() from this same Safe. Tx 1 pauses the RewardsDistributor BEFORE StakingV1, and it must stay first: `_distributePending` credits pendingPenalties into accRewardPerShare whether or not `_stakeHeldK613` managed to convert the backing K613, and that conversion fails while Staking is paused. Every entry point that reaches `_distributePending` is whenNotPaused, so pausing RD seals it. Without this, a single claim() between the two batches would credit rewards against xK613 that does not exist and the shortfall would be paid out of depositors' principal — see testPenaltyCreditedWhileStakingPaused_MakesPoolInsolvent.",
    "txBuilderVersion": "1.16.5",
    "createdFromSafeAddress": "0x7D5cF07621228a3D622b4695A1e28991E4620eBB"
  },
  "transactions": [
    {
      "to": "0xE3E8925E8554464611c86419B9e99AD7Cd47428f",
      "value": "0",
      "data": null,
      "contractMethod": {
        "inputs": [],
        "name": "pause",
        "payable": false
      },
      "contractInputsValues": {}
    },
    {
      "to": "0x3377BAB9A510A586627D2f9013e132d269Eb9871",
      "value": "0",
      "data": null,
      "contractMethod": {
        "inputs": [
          {
            "internalType": "address",
            "name": "token",
            "type": "address"
          },
          {
            "internalType": "address",
            "name": "to",
            "type": "address"
          },
          {
            "internalType": "uint256",
            "name": "amount",
            "type": "uint256"
          }
        ],
        "name": "withdraw",
        "payable": false
      },
      "contractInputsValues": {
        "token": "0x9064d55A8A8473fA39c41A16492Fa1094Eb4E8b5",
        "to": "0x7D5cF07621228a3D622b4695A1e28991E4620eBB",
        "amount": "<XK613_ON_TREASURY_V1>"
      }
    },
    {
      "to": "0x9064d55A8A8473fA39c41A16492Fa1094Eb4E8b5",
      "value": "0",
      "data": null,
      "contractMethod": {
        "inputs": [
          {
            "internalType": "address",
            "name": "spender",
            "type": "address"
          },
          {
            "internalType": "uint256",
            "name": "value",
            "type": "uint256"
          }
        ],
        "name": "approve",
        "payable": false
      },
      "contractInputsValues": {
        "spender": "0x36451F6b4c06916aafd16359CCf99eB1f584DB0b",
        "value": "<XK613_ON_TREASURY_V1>"
      }
    },
    {
      "to": "0x36451F6b4c06916aafd16359CCf99eB1f584DB0b",
      "value": "0",
      "data": null,
      "contractMethod": {
        "inputs": [
          {
            "internalType": "uint256",
            "name": "amount",
            "type": "uint256"
          }
        ],
        "name": "redeemRewards",
        "payable": false
      },
      "contractInputsValues": {
        "amount": "<XK613_ON_TREASURY_V1>"
      }
    },
    {
      "to": "0x36451F6b4c06916aafd16359CCf99eB1f584DB0b",
      "value": "0",
      "data": null,
      "contractMethod": {
        "inputs": [],
        "name": "pause",
        "payable": false
      },
      "contractInputsValues": {}
    }
  ]
}
BATCH1_EOF
  elif [ "$TEMPLATE" = "3" ]; then cat <<'BATCH3_EOF'
{
  "version": "1.0",
  "chainId": "143",
  "createdAt": 1786060800000,
  "meta": {
    "name": "K613 V2 cutover — step 3: retire TreasuryV1 and OperatorV1",
    "description": "Cleanup after the cutover. RUN ONLY AFTER the emission has been repointed to the new PullRewardsTransferStrategy (0x58fbEdaC…) — tx 1 empties the xK613 buffer that the OLD strategy is still paying lender claims from, so doing this while the old strategy is live breaks every claim until the switch happens. Tx 2 removes K613TreasuryOperatorV2's predecessor from TreasuryV1's admins: OperatorV1 has DEFAULT_ADMIN_ROLE there and its TREASURY address is immutable, so it can never operate anything else — leaving the role granted is a standing key on a contract nobody watches any more. Tx 3 pauses TreasuryV1, making stakeForExternalIncentives, depositRewards and buyback revert; withdraw stays available to the Safe, so nothing is trapped. The Safe deliberately keeps DEFAULT_ADMIN_ROLE on TreasuryV1: it is the only way to recover anything that lands there by mistake later. FILL IN before signing: <XK613_REMAINDER>.",
    "txBuilderVersion": "1.16.5",
    "createdFromSafeAddress": "0x7D5cF07621228a3D622b4695A1e28991E4620eBB"
  },
  "transactions": [
    {
      "to": "0x3377BAB9A510A586627D2f9013e132d269Eb9871",
      "value": "0",
      "data": null,
      "contractMethod": {
        "inputs": [
          { "internalType": "address", "name": "token", "type": "address" },
          { "internalType": "address", "name": "to", "type": "address" },
          { "internalType": "uint256", "name": "amount", "type": "uint256" }
        ],
        "name": "withdraw",
        "payable": false
      },
      "contractInputsValues": {
        "token": "0x9064d55A8A8473fA39c41A16492Fa1094Eb4E8b5",
        "to": "0x10aCE88f2F2c361218615F5dcA8987DD16C54282",
        "amount": "<XK613_REMAINDER>"
      }
    },
    {
      "to": "0x3377BAB9A510A586627D2f9013e132d269Eb9871",
      "value": "0",
      "data": null,
      "contractMethod": {
        "inputs": [
          { "internalType": "bytes32", "name": "role", "type": "bytes32" },
          { "internalType": "address", "name": "account", "type": "address" }
        ],
        "name": "revokeRole",
        "payable": false
      },
      "contractInputsValues": {
        "role": "0x0000000000000000000000000000000000000000000000000000000000000000",
        "account": "0xEf22fb7C5f3aE8108672f8566A1b3e5068E218a0"
      }
    },
    {
      "to": "0x3377BAB9A510A586627D2f9013e132d269Eb9871",
      "value": "0",
      "data": null,
      "contractMethod": {
        "inputs": [],
        "name": "pause",
        "payable": false
      },
      "contractInputsValues": {}
    }
  ]
}
BATCH3_EOF
  else cat <<'BATCH2_EOF'
{
  "version": "1.0",
  "chainId": "143",
  "createdAt": 1786060800000,
  "meta": {
    "name": "K613 V2 cutover — step 2 of 2: seed V2 and swap the minter",
    "description": "Atomic cutover from StakingV1 to StakingV2. Run only after v2-cutover-1-recover-and-freeze.json. Funds StakingV2 with K613 equal to the outstanding xK613 supply (seedBacking mints nothing, it only credits backing), then swaps the xK613 minter in the same batch, so no block ever has two minters and the cross-contract drain in test/StakingV2Migration.t.sol cannot occur. The seed comes straight from this Safe's own K613 balance (~59.4M held) — a fraction of a percent of it — so nothing needs to be routed out of TreasuryV1 first and the full K613 balance moves to TreasuryV2 untouched. The LM reward stock is rebuilt rather than carried over: the K613 recovered in step 1 is staked through StakingV2, so the xK613 lenders are paid in is minted and backed by the new contract instead of being legacy supply leaning on the seed. After this, every xK613 holder — including holders of tokens StakingV1 minted — redeems through StakingV2 with initiateExit + exit. FILL IN before signing: 0x5A3DA7644c25F0A74DCb0bA13ae38214D8856415, 0x10aCE88f2F2c361218615F5dcA8987DD16C54282, 0x58fbEdaC5D64022EecB3CF9115e5c9a7A82368AD, <SEED>, <RECOVERED_K613> — see docs/safe-batches/README.md section 3. ORDER MATTERS: seed before setMinter, and stakeForExternalIncentives only works after setMinter has made StakingV2 the minter.",
    "txBuilderVersion": "1.16.5",
    "createdFromSafeAddress": "0x7D5cF07621228a3D622b4695A1e28991E4620eBB"
  },
  "transactions": [
    {
      "to": "0xb09582631336068d4B0089d943f40CbF46dE5189",
      "value": "0",
      "data": null,
      "contractMethod": {
        "inputs": [
          {
            "internalType": "address",
            "name": "spender",
            "type": "address"
          },
          {
            "internalType": "uint256",
            "name": "value",
            "type": "uint256"
          }
        ],
        "name": "approve",
        "payable": false
      },
      "contractInputsValues": {
        "spender": "0x5A3DA7644c25F0A74DCb0bA13ae38214D8856415",
        "value": "<SEED>"
      }
    },
    {
      "to": "0x5A3DA7644c25F0A74DCb0bA13ae38214D8856415",
      "value": "0",
      "data": null,
      "contractMethod": {
        "inputs": [
          {
            "internalType": "uint256",
            "name": "amount",
            "type": "uint256"
          }
        ],
        "name": "seedBacking",
        "payable": false
      },
      "contractInputsValues": {
        "amount": "<SEED>"
      }
    },
    {
      "to": "0x9064d55A8A8473fA39c41A16492Fa1094Eb4E8b5",
      "value": "0",
      "data": null,
      "contractMethod": {
        "inputs": [
          {
            "internalType": "address",
            "name": "account",
            "type": "address"
          },
          {
            "internalType": "bool",
            "name": "allowed",
            "type": "bool"
          }
        ],
        "name": "setTransferWhitelist",
        "payable": false
      },
      "contractInputsValues": {
        "account": "0x5A3DA7644c25F0A74DCb0bA13ae38214D8856415",
        "allowed": "true"
      }
    },
    {
      "to": "0x9064d55A8A8473fA39c41A16492Fa1094Eb4E8b5",
      "value": "0",
      "data": null,
      "contractMethod": {
        "inputs": [
          {
            "internalType": "address",
            "name": "account",
            "type": "address"
          },
          {
            "internalType": "bool",
            "name": "allowed",
            "type": "bool"
          }
        ],
        "name": "setTransferWhitelist",
        "payable": false
      },
      "contractInputsValues": {
        "account": "0x10aCE88f2F2c361218615F5dcA8987DD16C54282",
        "allowed": "true"
      }
    },
    {
      "to": "0x9064d55A8A8473fA39c41A16492Fa1094Eb4E8b5",
      "value": "0",
      "data": null,
      "contractMethod": {
        "inputs": [
          {
            "internalType": "address",
            "name": "newMinter",
            "type": "address"
          }
        ],
        "name": "setMinter",
        "payable": false
      },
      "contractInputsValues": {
        "newMinter": "0x5A3DA7644c25F0A74DCb0bA13ae38214D8856415"
      }
    },
    {
      "to": "0xE3E8925E8554464611c86419B9e99AD7Cd47428f",
      "value": "0",
      "data": null,
      "contractMethod": {
        "inputs": [
          {
            "internalType": "address",
            "name": "staking_",
            "type": "address"
          }
        ],
        "name": "setStaking",
        "payable": false
      },
      "contractInputsValues": {
        "staking_": "0x5A3DA7644c25F0A74DCb0bA13ae38214D8856415"
      }
    },
    {
      "to": "0xE3E8925E8554464611c86419B9e99AD7Cd47428f",
      "value": "0",
      "data": null,
      "contractMethod": {
        "inputs": [
          {
            "internalType": "bytes32",
            "name": "role",
            "type": "bytes32"
          },
          {
            "internalType": "address",
            "name": "account",
            "type": "address"
          }
        ],
        "name": "grantRole",
        "payable": false
      },
      "contractInputsValues": {
        "role": "0x5cdba25167d99b7ec892ee2622f05561f779da5483692d63a6740a77a2c8d056",
        "account": "0x10aCE88f2F2c361218615F5dcA8987DD16C54282"
      }
    },
    {
      "to": "0xE3E8925E8554464611c86419B9e99AD7Cd47428f",
      "value": "0",
      "data": null,
      "contractMethod": {
        "inputs": [
          {
            "internalType": "bytes32",
            "name": "role",
            "type": "bytes32"
          },
          {
            "internalType": "address",
            "name": "account",
            "type": "address"
          }
        ],
        "name": "revokeRole",
        "payable": false
      },
      "contractInputsValues": {
        "role": "0x5cdba25167d99b7ec892ee2622f05561f779da5483692d63a6740a77a2c8d056",
        "account": "0x3377BAB9A510A586627D2f9013e132d269Eb9871"
      }
    },
    {
      "to": "0x3377BAB9A510A586627D2f9013e132d269Eb9871",
      "value": "0",
      "data": null,
      "contractMethod": {
        "inputs": [
          {
            "internalType": "address",
            "name": "token",
            "type": "address"
          },
          {
            "internalType": "address",
            "name": "to",
            "type": "address"
          },
          {
            "internalType": "uint256",
            "name": "amount",
            "type": "uint256"
          }
        ],
        "name": "withdraw",
        "payable": false
      },
      "contractInputsValues": {
        "token": "0xb09582631336068d4B0089d943f40CbF46dE5189",
        "to": "0x10aCE88f2F2c361218615F5dcA8987DD16C54282",
        "amount": "<K613_ON_TREASURY_V1>"
      }
    },
    {
      "to": "0xb09582631336068d4B0089d943f40CbF46dE5189",
      "value": "0",
      "data": null,
      "contractMethod": {
        "inputs": [
          {
            "internalType": "address",
            "name": "to",
            "type": "address"
          },
          {
            "internalType": "uint256",
            "name": "value",
            "type": "uint256"
          }
        ],
        "name": "transfer",
        "payable": false
      },
      "contractInputsValues": {
        "to": "0x10aCE88f2F2c361218615F5dcA8987DD16C54282",
        "value": "<RECOVERED_K613>"
      }
    },
    {
      "to": "0x10aCE88f2F2c361218615F5dcA8987DD16C54282",
      "value": "0",
      "data": null,
      "contractMethod": {
        "inputs": [
          {
            "internalType": "uint256",
            "name": "amount",
            "type": "uint256"
          }
        ],
        "name": "stakeForExternalIncentives",
        "payable": false
      },
      "contractInputsValues": {
        "amount": "<RECOVERED_K613>"
      }
    },
    {
      "to": "0x10aCE88f2F2c361218615F5dcA8987DD16C54282",
      "value": "0",
      "data": null,
      "contractMethod": {
        "inputs": [
          {
            "internalType": "address",
            "name": "spender",
            "type": "address"
          },
          {
            "internalType": "uint256",
            "name": "amount",
            "type": "uint256"
          }
        ],
        "name": "approveXk613PullRewards",
        "payable": false
      },
      "contractInputsValues": {
        "spender": "0x58fbEdaC5D64022EecB3CF9115e5c9a7A82368AD",
        "amount": "115792089237316195423570985008687907853269984665640564039457584007913129639935"
      }
    },
    {
      "to": "0x36451F6b4c06916aafd16359CCf99eB1f584DB0b",
      "value": "0",
      "data": null,
      "contractMethod": {
        "inputs": [],
        "name": "unpause",
        "payable": false
      },
      "contractInputsValues": {}
    },
    {
      "to": "0xE3E8925E8554464611c86419B9e99AD7Cd47428f",
      "value": "0",
      "data": null,
      "contractMethod": {
        "inputs": [],
        "name": "unpause",
        "payable": false
      },
      "contractInputsValues": {}
    }
  ]
}
BATCH2_EOF
  fi
}

K613=0xb09582631336068d4B0089d943f40CbF46dE5189
XK613=0x9064d55A8A8473fA39c41A16492Fa1094Eb4E8b5
STAKING_V1=0x36451F6b4c06916aafd16359CCf99eB1f584DB0b
TREASURY_V1=0x3377BAB9A510A586627D2f9013e132d269Eb9871
TREASURY_V2=0x10aCE88f2F2c361218615F5dcA8987DD16C54282
STAKING_V2=0x5A3DA7644c25F0A74DCb0bA13ae38214D8856415
RD=0xE3E8925E8554464611c86419B9e99AD7Cd47428f
# Развёрнута и верифицирована 2026-08-07, vault=TreasuryV2. Константа, а не env:
# адрес известен и постоянен, а переменная окружения — лишний способ ошибиться.
# NEW_STRATEGY= в окружении перебивает её (нужно только для репетиции на форке).
PULL_STRATEGY_V2=0x58fbEdaC5D64022EecB3CF9115e5c9a7A82368AD

call() { cast call "$1" "$2" ${3:-} --rpc-url "$RPC" | awk '{print $1}'; }
human() { python3 -c "print(f'{int('$1')/1e18:,.6f}')"; }

echo "=== чтение состояния чейна ==="

if [ "$STEP" = "1" ]; then
  SRC=""
  OUT=/tmp/cutover-batch-1.json

  # Долг конвертации. Проверяем баланс K613, а не pendingPenalties: вторая обнуляется
  # в момент начисления, то есть ровно тогда, когда долг возникает.
  DEBT=$(call "$K613" "balanceOf(address)(uint256)" "$RD")
  if [ "$DEBT" != "0" ]; then
    echo "СТОП: на RewardsDistributor $(human "$DEBT") K613 не конвертированы." >&2
    echo "  Заморозка сейчас оставит пул коротким на эту сумму до конца миграции." >&2
    echo "  Дождись чужого claim() или выполни advanceEpoch() при живом StakingV1:" >&2
    echo "    cast send $RD 'advanceEpoch()' --private-key \$PRIVATE_KEY --rpc-url \$MONAD_RPC" >&2
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

  BAL=$(call "$XK613" "balanceOf(address)(uint256)" "$TREASURY_V1")
  [ "$BAL" = "0" ] && { echo "СТОП: на TreasuryV1 нет xK613, возвращать нечего." >&2; exit 1; }

  # Забираем НЕ весь баланс. Две причины, обе проверены на живом чейне:
  #
  #  1. Сумма фиксируется здесь, а исполняется после двух подписей — часами позже.
  #     Всё это время PullRewardsTransferStrategy продолжает выдавать xK613 лендерам
  #     по их claim(), и она к паузам иммунна: performTransfer — обычный перевод,
  #     ни Staking, ни RD его не гейтят. Просядет баланс ниже суммы в батче —
  #     withdraw ревертнётся и упадёт ВЕСЬ батч.
  #
  #  2. После батча 1 активной остаётся СТАРАЯ стратегия, которая тянет из
  #     TreasuryV1. Выгребем подчистую — claim() лендеров начнёт ревертиться и будет
  #     ревертиться до шага 5 (setTransferStrategy). Остаток работает как буфер на
  #     это окно.
  #
  # 500 bps по наблюдаемому расходу (~320 xK613/час) покрывают примерно сутки.
  HAIRCUT_BPS="${HAIRCUT_BPS:-500}"
  XK_TR=$(python3 -c "print($BAL * (10000 - $HAIRCUT_BPS) // 10000)")
  echo "  xK613 на TreasuryV1    : $(human "$BAL")"
  echo "  берём (запас $HAIRCUT_BPS bps): $(human "$XK_TR")   <- вернётся 1:1 в K613"
  echo "  остаётся буфером       : $(human "$(python3 -c "print($BAL - $XK_TR)")")   <- на claim'ы до шага 5"

  TEMPLATE=1 render > "$OUT.tpl"
  sed "s|<XK613_ON_TREASURY_V1>|$XK_TR|g" "$OUT.tpl" > "$OUT"
  rm -f "$OUT.tpl"

elif [ "$STEP" = "2" ]; then
  SRC=""
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

  TEMPLATE=2 render > "$OUT.tpl"
  sed -e "s|<SEED>|$SEED|g" \
      -e "s|<K613_ON_TREASURY_V1>|$K_TR|g" \
      -e "s|<RECOVERED_K613>|$RECOVERED|g" \
      -e "s|<NEW_PULL_STRATEGY>|$NEW_STRATEGY|g" \
      "$OUT.tpl" > "$OUT"
  rm -f "$OUT.tpl"
elif [ "$STEP" = "3" ]; then
  OUT=/tmp/cutover-batch-3.json

  # Пока активна СТАРАЯ стратегия, остаток на TreasuryV1 — это касса, из которой
  # оплачиваются claim'ы лендеров. Опустошить её раньше переключения = сломать клеймы.
  LIVE=$(cast call 0xe1d8B642c83587Df813a36F361C682C0475c4ea4 \
    "getTransferStrategy(address)(address)" "$XK613" --rpc-url "$RPC" | awk '{print $1}')
  if [ "$(printf '%s' "$LIVE" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$PULL_STRATEGY_V2" | tr 'A-Z' 'a-z')" ]; then
    echo "СТОП: активна ещё старая стратегия ($LIVE)." >&2
    echo "  Сначала setTransferStrategy на $PULL_STRATEGY_V2 ключом emission admin," >&2
    echo "  иначе эта уборка заберёт кассу, из которой сейчас платят лендерам." >&2
    exit 1
  fi
  echo "  активная стратегия     : новая  ok"

  MINTER=$(call "$XK613" "minter()(address)")
  if [ "$(printf '%s' "$MINTER" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$STAKING_V2" | tr 'A-Z' 'a-z')" ]; then
    echo "СТОП: xK613.minter = $MINTER, катовер не завершён." >&2
    exit 1
  fi
  echo "  xK613.minter           : StakingV2  ok"

  REM=$(call "$XK613" "balanceOf(address)(uint256)" "$TREASURY_V1")
  [ "$REM" = "0" ] && { echo "СТОП: на TreasuryV1 нет xK613, забирать нечего." >&2; exit 1; }
  echo "  остаток на TreasuryV1  : $(human "$REM")   -> переедет на TreasuryV2"

  TEMPLATE=3 render > "$OUT.tpl"
  sed "s|<XK613_REMAINDER>|$REM|g" "$OUT.tpl" > "$OUT"
  rm -f "$OUT.tpl"

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
