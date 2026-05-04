# K613 Token — Операционный SOP

Аудитория: операторы с правом подписи на Safe-кошельках Governance, Treasury и LM Reserve в Monad mainnet.

Документ описывает:
1. Процедуру TGE-дня (Token Generation Event) — строгий порядок шагов, не пропускать.
2. Ежемесячный buyback flow — комса с Aave Collector → swap → реварды стейкерам.
3. Vesting unlock — самообслуживание бенефициарами.
4. Аварийные процедуры — pause / unpause.
5. Справочные данные — адреса, контракты, скрипты.

> **Главное правило:** каждое on-chain действие ниже собирается батчем в **Safe Transaction Builder**, подписывается необходимым порогом и выполняется. Forge-скрипты в [script/deploy/](../script/deploy) нужны для **симуляции, dry-run и воспроизводимости** — они генерируют calldata / state transitions, которые ты копируешь в Safe.

---

## Раздел 1 — Процедура TGE-дня

Порядок имеет значение. **Не параллелить.** После каждого шага сверяй on-chain состояние через explorer перед следующим.

### Шаг 1.1 — Деплой ядра

Запустить [script/deploy/DeployK613.s.sol](../script/deploy/DeployK613.s.sol) с EOA деплоера.

#### Подготовка env
```bash
export MONAD_RPC=https://rpc.monad.xyz
export PRIVATE_KEY=0x...deployer       # одноразовый deployer-ключ; роли передаём на Safe в шаге 1.2
```

#### Dry-run (симуляция)
```bash
forge script script/deploy/DeployK613.s.sol --rpc-url $MONAD_RPC -vvvv
```

Что проверять:
- Лог `Deployer: 0x...` — твой EOA
- 5 контрактов задеплоены, их адреса видны в логах (`K613:`, `xK613:`, `Staking:`, `RewardsDistributor:`, `Treasury:`)
- Видны wiring-вызовы: `xK613.setMinter(staking)`, `setTransferWhitelist(rd/staking/treasury, true)`, `staking.setRewardsDistributor`, `staking.addSystemStaker(rd)` + `(treasury)`, `distributor.setStaking`, `distributor.grantRole(REWARDS_NOTIFIER_ROLE, treasury)`
- Скрипт реверт'ится с `WrongNetwork(chainId)` если RPC указывает не на Monad mainnet (chainId 143) — это feature, защита от ошибки

#### Broadcast
```bash
forge script script/deploy/DeployK613.s.sol --rpc-url $MONAD_RPC --broadcast --slow --verify -vvv
```

`--verify` загрузит исходники на Monad explorer (если есть Etherscan-compatible verifier). Если verifier недоступен — без него: `--broadcast --slow`, верификация отдельно.

Записать из логов:
- адрес `K613`
- адрес `xK613`
- адрес `Staking`
- адрес `RewardsDistributor`
- адрес `Treasury`

> Деплоер кратковременно держит `MINTER_ROLE` на K613 и `DEFAULT_ADMIN_ROLE` на каждом контракте. Это by design — передача в шаге 1.2.

### Шаг 1.2 — Передача админских ролей на Governance Safe

**Per-contract checklist.** Каждая операция отдельная транзакция (или собрать одним батчем через Safe sender, если деплоер сам подписывает с multisig). Порядок: сначала `grant` для Safe, потом `revoke` для деплоера — нельзя ранее снимать с себя `DEFAULT_ADMIN_ROLE`, иначе потеряешь право снимать остальные роли.

#### K613 (`src/token/K613.sol`)
- [ ] `K613.grantRole(DEFAULT_ADMIN_ROLE, GOVERNANCE_SAFE)`
- [ ] `K613.grantRole(PAUSER_ROLE, GOVERNANCE_SAFE)`
- [ ] `K613.setMinter(GOVERNANCE_SAFE)` — это **atomically revoke+grant** MINTER_ROLE с deployer на Safe в одной tx
- [ ] `K613.revokeRole(PAUSER_ROLE, deployer)`
- [ ] `K613.revokeRole(DEFAULT_ADMIN_ROLE, deployer)` ← **последним**

#### xK613 (`src/token/xK613.sol`)
- [ ] `xK613.grantRole(DEFAULT_ADMIN_ROLE, GOVERNANCE_SAFE)`
- [ ] `xK613.grantRole(PAUSER_ROLE, GOVERNANCE_SAFE)`
- [ ] **НЕ менять `xK613.setMinter`** — он уже выставлен на Staking контракт в шаге 1.1 ([DeployK613.s.sol:60](../script/deploy/DeployK613.s.sol#L60)). Менять его на Safe сломает стейкинг.
- [ ] `xK613.revokeRole(PAUSER_ROLE, deployer)`
- [ ] `xK613.revokeRole(DEFAULT_ADMIN_ROLE, deployer)`

#### Staking (`src/staking/Staking.sol`)
- [ ] `Staking.grantRole(DEFAULT_ADMIN_ROLE, GOVERNANCE_SAFE)`
- [ ] `Staking.grantRole(PAUSER_ROLE, GOVERNANCE_SAFE)`
- [ ] `Staking.revokeRole(PAUSER_ROLE, deployer)`
- [ ] `Staking.revokeRole(DEFAULT_ADMIN_ROLE, deployer)`

#### RewardsDistributor (`src/staking/RewardsDistributor.sol`)
- [ ] `RewardsDistributor.grantRole(DEFAULT_ADMIN_ROLE, GOVERNANCE_SAFE)`
- [ ] `RewardsDistributor.grantRole(PAUSER_ROLE, GOVERNANCE_SAFE)`
- [ ] **НЕ грантить `REWARDS_NOTIFIER_ROLE` на Safe** — она уже у Staking и Treasury (в DeployK613). Грантить Safe не надо.
- [ ] `RewardsDistributor.revokeRole(PAUSER_ROLE, deployer)`
- [ ] `RewardsDistributor.revokeRole(DEFAULT_ADMIN_ROLE, deployer)`

#### Treasury (`src/treasury/Treasury.sol`)
- [ ] `Treasury.grantRole(DEFAULT_ADMIN_ROLE, GOVERNANCE_SAFE)`
- [ ] `Treasury.grantRole(PAUSER_ROLE, GOVERNANCE_SAFE)`
- [ ] `Treasury.revokeRole(PAUSER_ROLE, deployer)`
- [ ] `Treasury.revokeRole(DEFAULT_ADMIN_ROLE, deployer)`

> **Проверка после шага 1.2 (must all be true):**
> ```
> K613.hasRole(DEFAULT_ADMIN_ROLE, GOVERNANCE_SAFE) == true
> K613.hasRole(MINTER_ROLE, GOVERNANCE_SAFE) == true
> K613.hasRole(MINTER_ROLE, deployer) == false
> K613.hasRole(DEFAULT_ADMIN_ROLE, deployer) == false
> // ... аналогично для остальных 4 контрактов
> xK613.hasRole(MINTER_ROLE, address(Staking)) == true   // не должно меняться
> ```
> Используй любой read-only скрипт / Etherscan-like view для верификации.

### Шаг 1.3 — Премайнт всего supply

С **Governance Safe** (после шага 1.2 он держит `MINTER_ROLE`) выполнить одну транзакцию:

```
K613.mint(GOVERNANCE_SAFE, 100_000_000e18)
```

Референс-скрипт — [script/deploy/PremintK613.s.sol](../script/deploy/PremintK613.s.sol). Реальная prod-tx собирается в Safe Transaction Builder с тем же calldata.

#### Подготовка env
```bash
export MONAD_RPC=https://rpc.monad.xyz
export PRIVATE_KEY=0x...                   # ключ держателя MINTER_ROLE (после шага 1.2 = GOVERNANCE_SAFE EOA или sim ключ)
export K613_ADDRESS=0x...                  # из шага 1.1
export GOVERNANCE_ADDRESS=0x...Safe        # куда падает 100M
```

#### Dry-run (симуляция)
```bash
forge script script/deploy/PremintK613.s.sol --rpc-url $MONAD_RPC -vvvv
```

Что проверять:
- Лог `Caller (minter):` совпадает с ожидаемым адресом MINTER_ROLE
- Лог `Minted (K613): 100000000` — ровно 100M
- В трейсе виден `K613.mint(GOVERNANCE_SAFE, 1e26)` который проходит без revert

#### Broadcast (реальная отправка)
```bash
forge script script/deploy/PremintK613.s.sol --rpc-url $MONAD_RPC --broadcast --slow -vvv
```

> **Эффект:** `totalSupply == cap == 100,000,000 K613`. С этого момента **любой mint реверт'ится** благодаря `ERC20Capped`. "Откатить" нельзя.

#### Verification после broadcast
```bash
cast call $K613_ADDRESS "totalSupply()(uint256)" --rpc-url $MONAD_RPC
# expected: 100000000000000000000000000

cast call $K613_ADDRESS "balanceOf(address)(uint256)" $GOVERNANCE_ADDRESS --rpc-url $MONAD_RPC
# expected: 100000000000000000000000000
```

### Шаг 1.4 — Деплой VestingManager

[script/deploy/DeployVestingManager.s.sol](../script/deploy/DeployVestingManager.s.sol) — деплоит `K613VestingManager` с указанным owner (Governance Safe).

#### Подготовка env
```bash
export MONAD_RPC=https://rpc.monad.xyz
export PRIVATE_KEY=0x...                       # деплоер
export K613_ADDRESS=0x...                      # из шага 1.1
export VESTING_OWNER_ADDRESS=0x...Safe         # = GOVERNANCE_SAFE
```

#### Dry-run
```bash
forge script script/deploy/DeployVestingManager.s.sol --rpc-url $MONAD_RPC -vvvv
```

Что проверять: трейс показывает `new K613VestingManager(VESTING_OWNER_ADDRESS, K613_ADDRESS)` и логирует адрес.

#### Broadcast
```bash
forge script script/deploy/DeployVestingManager.s.sol --rpc-url $MONAD_RPC --broadcast --slow -vvv
```

Записать адрес `K613VestingManager` из логов.

#### Verification
```bash
cast call $VESTING_MGR "owner()(address)" --rpc-url $MONAD_RPC
# expected: $VESTING_OWNER_ADDRESS

cast call $VESTING_MGR "token()(address)" --rpc-url $MONAD_RPC
# expected: $K613_ADDRESS
```

### Шаг 1.5 — Распределение supply по 7 бакетам

Отредактировать [script/deploy/distribution.example.json](../script/deploy/distribution.example.json):
- Заменить каждый `0x000000000000000000000000000000000000DEAD` на реальный адрес получателя.
- Сверить что `transferCount` и `vestingCount` совпадают с длинами массивов.
- Сверить что `transfers[].amount + vestings[].amount` сумма ровно равна `100_000_000e18`.
- Сохранить как `distribution.json` (локально, не коммитить).

#### Подготовка env
```bash
export MONAD_RPC=https://rpc.monad.xyz
export PRIVATE_KEY=0x...                                    # broadcaster (= Governance Safe EOA или sim)
export K613_ADDRESS=0x...                                   # из шага 1.1
export VESTING_MANAGER_ADDRESS=0x...                        # из шага 1.4
export DISTRIBUTION_CONFIG=script/deploy/distribution.json  # отредактированный JSON, не committed
```

#### Dry-run
```bash
forge script script/deploy/DistributeK613.s.sol --rpc-url $MONAD_RPC -vvvv
```

Что проверять:
- Лог `Caller (broadcaster):` совпадает с GOVERNANCE_SAFE
- `Transfers count: 7` и `Vestings count: 2` (или сколько у тебя в JSON)
- `Total transfers + Total vestings == 100M K613`
- Логи каждого `transfer:` и `vesting:` (с адресом wallet'а) совпадают с JSON
- `Caller balance after: 0` — вся сумма распределена
- Pre-flight инварианты не упали (`TotalMismatch`, `InsufficientBalance`, `CallerBalanceMustEqualMaxSupply`, `InvalidVestingSchedule`)

#### Broadcast (только для EOA-flow)
```bash
forge script script/deploy/DistributeK613.s.sol --rpc-url $MONAD_RPC --broadcast --slow -vvv
```

> ⚠️ **Production через Safe:** EOA broadcast'у мы предпочитаем Safe Transaction Builder батчем, чтобы каждый шаг подписывался multisig'ом. См. порядок ниже. Forge-скрипт нужен для dry-run и копирования calldata.

Для реального запуска — собрать в Safe Transaction Builder **одним батчем в строго указанном порядке**:

1. **Сначала:** `K613.approve(K613VestingManager, sum_of_vestings)` — одна транзакция, не больше и не меньше
2. **Потом:** `K613.transfer(recipient, amount)` для каждой transfer-записи (в любом порядке между собой)
3. **В конце:** `K613VestingManager.createVestingWallet(beneficiary, startTs, durationSec, cliffSec, amount)` для каждой vesting-записи

> ⚠️ **Порядок критичен:** если `createVestingWallet` пойдёт ДО `approve` — транзакция упадёт на `transferFrom`. Если `approve` дать на сумму меньше чем `sum_of_vestings` — упадёт на первой же `createVestingWallet` где allowance кончится.

> **Pre-flight инварианты, которые скрипт enforces (вручную тоже сверять при ревью батча):**
> - сумма всех amounts == `MAX_SUPPLY` (100M)
> - **balance вызывающего == `MAX_SUPPLY`** (строгое равенство — если у Safe есть K613 откуда-то ещё, расследовать прежде чем продолжать)
> - `cliffSeconds <= durationSeconds` для каждой vesting-записи

### Шаг 1.5b — Funding Aave incentives (LM bucket)

Только если в `distribution.json` есть бакет `LM-Rewards-Vault` (стандартно — да, 40M K613 на отдельный Safe = REWARDS_VAULT). После шага 1.5 **REWARDS_VAULT держит K613 — но Aave incentives платятся в xK613**.

> ⚠️ **MUST FIX FIRST** — иначе все claim'ы Aave-ревардов будут реверт'иться. `xK613` имеет **transfer whitelist** ([xK613.sol:103-110](../src/token/xK613.sol#L103)) — `from` ИЛИ `to` обязан быть в whitelist. После TGE в whitelist только `Staking`/`RewardsDistributor`/`Treasury`. REWARDS_VAULT там НЕТ. Когда `PullRewardsTransferStrategy` пытается `transferFrom(VAULT, user, amount)`, оба адреса не в whitelist → revert `TransfersDisabled()`.

**Шаги (в порядке) с Governance Safe (DEFAULT_ADMIN_ROLE на xK613):**

0. **`xK613.setTransferWhitelist(REWARDS_VAULT_SAFE, true)`** ← обязательный prerequisite, без этого ревард-flow не работает.

**Шаги с REWARDS_VAULT через Safe Transaction Builder:**

1. `K613.approve(STAKING_ADDRESS, 40_000_000e18)` — Vault разрешает Staking тянуть свои K613.
2. `Staking.stake(40_000_000e18)` — Vault стейкает 40M K613 → получает 40M xK613 (теперь Vault — whitelisted, может держать xK613).
3. **После того как `PullRewardsTransferStrategy` deployed** (выполняется скриптом [`ConfigureSupplyIncentives.s.sol`](../lib/k613-markets-config/script/incentives/ConfigureSupplyIncentives.s.sol) на стороне `k613-markets-config` репо): `xK613.approve(PullRewardsTransferStrategy, type(uint256).max)` — Vault разрешает Strategy тянуть xK613 при claim'е ревардов.

> **Timing handoff:** sub-step 3 **зависит от внешнего скрипта** который запускается с другого репо. Sequence:
> - День TGE: выполнить sub-steps 0-2 (whitelist + stake). Vault держит 40M xK613, готов.
> - **День TGE +N (когда лендинг готов запустить incentives):** оператор k613-markets-config запускает [`ConfigureSupplyIncentives.s.sol`](../lib/k613-markets-config/script/incentives/ConfigureSupplyIncentives.s.sol) с env `INCENTIVES_REWARDS_VAULT=<наш REWARDS_VAULT>`. Скрипт деплоит `PullRewardsTransferStrategy` и логирует адрес `TransferStrategy: 0x...`. **Записать этот адрес.**
> - **Сразу после:** на нашей стороне выполнить sub-step 3 — `xK613.approve(<полученный адрес>, type(uint256).max)` через REWARDS_VAULT Safe.
>
> Без sub-step 3 strategy будет реверт'иться при первом же claim'е (`safeTransferFrom` не пройдёт без allowance).
>
> Helper-скрипт [script/utils/InstallXk613PullStrategy.s.sol](../script/utils/InstallXk613PullStrategy.s.sol) (опционально) принимает strategy address как env и эмитит готовый calldata для Safe Transaction Builder.

**Verification после всех шагов:**
- `xK613.transferWhitelist(REWARDS_VAULT_SAFE) == true`
- `xK613.balanceOf(REWARDS_VAULT_SAFE) == 40_000_000e18` (или соответствующий годовой бюджет)
- `xK613.allowance(REWARDS_VAULT_SAFE, PullRewardsTransferStrategy) == type(uint256).max`

> **Внимание по объёму:** держать сразу 40M xK613 в одном Safe = трёх-летний бюджет ревардов в одном кошельке. **Безопаснее годовая ротация:**
> - На TGE стейк только **25M K613 → 25M xK613** (Year 1 бюджет).
> - Через 12 месяцев — следующий стейк 10M (Year 2).
> - Через 24 месяца — следующий стейк 5M (Year 3).
> - Остальные K613 хранятся в отдельном Safe (LM Reserve по `distribution.example.json`).
>
> Если выбрать годовую ротацию, поправь `distribution.json`: `LM-Rewards-Vault` = 25M, добавь `LM-Future-Years` = 15M (или раздели по годам). Сумма транзакций должна сходиться к 100M.

> **Note про first week:** даже после funding — реварды стейкерам в `RewardsDistributor` начнут начисляться **только через первую `EPOCH_DURATION` (7 дней)**. Это by design (см. `lastEpochFlushAt` в `RewardsDistributor.sol:107`). Buyback flow (раздел 2) можно начинать после этого момента.

### Шаг 1.6 — Создание initial K613/USDC LP на Uniswap V3

Из [script/deploy/SeedInitialLP.s.sol](../script/deploy/SeedInitialLP.s.sol) — **broadcast'ит с Governance Safe**. Поэтому в `distribution.json` бакет `POL-Initial-LP` (5M K613) **должен иметь recipient == GOVERNANCE_SAFE** — иначе K613 уйдёт в другой Safe и SeedInitialLP упадёт на отсутствии баланса.

USDC ($40k) тоже должен быть на Governance Safe **до** запуска шага 1.6. Источник USDC — отдельный pre-step (например, перевод от seed-инвесторов согласно их договорам).

Параметры при TGE-цене $0.008/K613:
```
PRICE_K613_USDC_RAW = 8000
FEE_TIER            = 3000
NPM_ADDRESS         = 0x7197E214c0b767cFB76Fb734ab638E2c192F4E53
USDC_ADDRESS        = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603
K613_AMOUNT         = 5000000000000000000000000   ; 5M K613 (bootstrap LP)
USDC_AMOUNT         = 40000000000                 ; 40,000 USDC = 5M × $0.008
LP_RECIPIENT        = GOVERNANCE_SAFE             ; намеренно НЕ 0xdEaD здесь — см. шаг 1.7
```

Стратегия **bootstrap LP**: 5M K613 + $40k USDC на старт. Остальные 10M из POL allocation лежат в Governance Safe (бакет POL-Reserve-Future-LP) для постепенного дозалива по мере роста объёмов / TVL.

#### Подготовка env (заполнить перед запуском)

```bash
export MONAD_RPC=https://rpc.monad.xyz
export PRIVATE_KEY=0x...                                # ключ broadcaster'а (= GOVERNANCE_SAFE EOA или dev/sim ключ)
export K613_ADDRESS=0x...                               # из шага 1.1
export USDC_ADDRESS=0x754704Bc059F8C67012fEd69BC8A327a5aafb603
export NPM_ADDRESS=0x7197E214c0b767cFB76Fb734ab638E2c192F4E53
export FEE_TIER=3000
export PRICE_K613_USDC_RAW=8000
export K613_AMOUNT=5000000000000000000000000           # 5M K613 (raw, 18 dec)
export USDC_AMOUNT=40000000000                          # 40,000 USDC (raw, 6 dec)
export LP_RECIPIENT=0x...GovernanceSafe                 # NFT receiver
export SLIPPAGE_BPS=100                                 # 1% (default; max 5000 = 50%)
```

#### Dry-run (симуляция, ничего не отправляется в сеть)

Этот запуск **читает on-chain state** через RPC, прогоняет всю логику локально и печатает full trace + ожидаемые changes. В сеть **не пишет**.

```bash
forge script script/deploy/SeedInitialLP.s.sol \
  --rpc-url $MONAD_RPC \
  -vvvv
```

Что проверять в выводе симуляции:
- `pool: 0x...` — адрес создаваемого пула
- `token0:`/`token1:` — порядок (lower address first)
- `amount0 (desired)` / `amount1 (desired)` — суммы соответствуют ожидаемым raw values
- `amount0 (min)` / `amount1 (min)` — равны `desired * 0.99` (при SLIPPAGE_BPS=100)
- В трейсе виден вызов `createAndInitializePoolIfNecessary` с правильными параметрами
- В трейсе виден `mint(MintParams{...})` который возвращает `tokenId`, `liquidity`, `amount0`, `amount1`
- `caller balance after` — K613 и USDC уменьшаются на amount0/amount1

Если что-то выглядит не так — **СТОП**. Перепроверить env. Не запускать broadcast.

#### Broadcast (реальная отправка в Monad mainnet)

После того как dry-run прошёл успешно и значения проверены — добавить флаг `--broadcast`:

```bash
forge script script/deploy/SeedInitialLP.s.sol \
  --rpc-url $MONAD_RPC \
  --broadcast \
  --slow \
  -vvv
```

Флаги:
- `--broadcast` — реально отправляет транзакции
- `--slow` — отправляет последовательно, ждёт mining между tx (стабильнее на свежей сети)
- `-vvv` — verbose, увидишь tx-хэши и pool address в логах

> ⚠️ Если broadcast'ишь не с EOA а через **Safe** (правильный production paттерн) — `forge script ... --broadcast` напрямую не подойдёт. Нужно вручную собрать те же 4 транзакции (`createAndInitializePoolIfNecessary`, `IERC20.approve` x2, `NPM.mint`) в Safe Transaction Builder батчем. Скрипт всё ещё полезен как dry-run reference — calldata из verbose-трейса можно копировать в Safe.

#### Проверка после broadcast

- прочитать адрес V3 пула из логов, открыть в Monad explorer
- `sqrtPriceX96` соответствует ожиданию (логируется скриптом)
- оба резерва присутствуют (`pool.token0().balanceOf(pool)`, `pool.token1().balanceOf(pool)`)
- position NFT (логируется `tokenId`) принадлежит `LP_RECIPIENT`:
  ```bash
  cast call $NPM_ADDRESS "ownerOf(uint256)(address)" <tokenId> --rpc-url $MONAD_RPC
  # expected: $LP_RECIPIENT
  ```

### Шаг 1.7 — Lock LP NFT в TimelockController (12 месяцев)

После проверки в шаге 1.6 — выбран **Timelock approach**: NFT под контролем OZ `TimelockController` с 365-day delay на любую операцию.

**1.7a. Деплоить OpenZeppelin `TimelockController`** с параметрами:
```
minDelay  = 31_536_000        // 365 days
proposers = [GOVERNANCE_SAFE]
executors = [GOVERNANCE_SAFE]
admin     = address(0)        // self-managed, никто не может изменить delay
```

Команда (forge create) — **замени `0xYourGovernanceSafeHere` на реальный адрес Safe перед запуском**:
```bash
GOV_SAFE=0xYourGovernanceSafeHere   # ← REPLACE
forge create lib/openzeppelin-contracts/contracts/governance/TimelockController.sol:TimelockController \
  --rpc-url $MONAD_RPC \
  --private-key $DEPLOYER_PK \
  --constructor-args 31536000 "[$GOV_SAFE]" "[$GOV_SAFE]" 0x0000000000000000000000000000000000000000
```

Записать адрес деплоя как `LP_TIMELOCK`.

**Verification после деплоя (read-only через cast call):**
```bash
cast call $LP_TIMELOCK "getMinDelay()(uint256)" --rpc-url $MONAD_RPC
# expected: 31536000

# PROPOSER_ROLE = keccak256("PROPOSER_ROLE")
cast call $LP_TIMELOCK "hasRole(bytes32,address)(bool)" \
  0xb09aa5aeb3702cfd50b6b62bc4532604938f21248a27a1d5ca736082b6819cc1 $GOV_SAFE --rpc-url $MONAD_RPC
# expected: true

# EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE")
cast call $LP_TIMELOCK "hasRole(bytes32,address)(bool)" \
  0xd8aa0f3194971a2a116679f7c2090f6939c8d4e01a2a8d7e41d55e5351469e63 $GOV_SAFE --rpc-url $MONAD_RPC
# expected: true

# DEFAULT_ADMIN_ROLE — must be REVOKED (admin=address(0) in constructor)
cast call $LP_TIMELOCK "hasRole(bytes32,address)(bool)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 $GOV_SAFE --rpc-url $MONAD_RPC
# expected: false
```

**1.7b. Перевести LP NFT с `GOVERNANCE_SAFE` на `LP_TIMELOCK`** (одна Safe TX):
```
NPM.safeTransferFrom(GOVERNANCE_SAFE, LP_TIMELOCK, tokenId)
```

> Используем `safeTransferFrom` вместо `transferFrom` намеренно — он проверяет что receiver реализует `IERC721Receiver`. `TimelockController` от OZ наследует `ERC721Holder` → check проходит. Защищает от случайной отправки на не-receiver контракт.

После этого LP NFT в Timelock'е. Любая операция с ним (`decreaseLiquidity`, `collect`, `burn`) требует **12 месяцев задержки** через 2-step процедуру:

```
1. GOVERNANCE_SAFE → LP_TIMELOCK.schedule(NPM, 0, calldata, bytes32(0), salt, 31_536_000)
2. ... подождать 365 дней ...
3. GOVERNANCE_SAFE → LP_TIMELOCK.execute(NPM, 0, calldata, bytes32(0), salt)
```

> ⚠️ **Trade-off:** 12-month delay применяется ко **всему** включая `collect()` для fees. Это значит fees собираются **раз в год** одной транзакцией. Для protocol-owned LP это приемлемо — годовой батч ~$1k gas против вечно-замороженных fees при `0xdEaD` варианте.

> **Что НЕ делать:**
> - Не давать `proposers`/`executors` ролей кому-то кроме `GOVERNANCE_SAFE`.
> - Не оставлять `admin` ненулевым (admin может менять delay → ломает гарантии).
> - Не передавать LP NFT куда-то ещё после Timelock — это финальный destination.

> **Future migration** (если позже захочется fee-only locker): через ту же 12-month процедуру делается `transferFrom(LP_TIMELOCK, NEW_LOCKER, tokenId)`. Не быстрая операция, но возможная.

Зафиксировать выбор в публичных docs (gitbook): "POL LP locked in TimelockController с 12-month delay; fees claimable annually by Governance Safe".

### Шаг 1.8 — Whitelist SwapRouter02 в Treasury

С Governance Safe:

```
Treasury.setRouterWhitelist(0xfE31F71C1b106EAc32F1A19239c9a9A72ddfb900, true)
```

> ⚠️ **Этот шаг идёт ПОСЛЕ шага 1.6 (создание K613/USDC пула) намеренно.** Если whitelist'нуть router до того как пул существует, первый `buybackV3ExactInputSingle` упадёт на отсутствии пула. Не нарушать порядок.

Без этого ежемесячный buyback flow (раздел 2) не выполнится.

### Шаг 1.9 — Финальный TGE-чеклист

Перед публичным анонсом TGE:
- [ ] `K613.totalSupply() == 100_000_000e18`
- [ ] `K613.cap() == 100_000_000e18`
- [ ] Сумма K613-балансов всех получателей + LP пула + vesting wallets == 100M
- [ ] Governance Safe держит `DEFAULT_ADMIN_ROLE` на K613, xK613, Staking, RewardsDistributor, Treasury
- [ ] EOA деплоера **не держит ролей** ни на одном контракте
- [ ] LP NFT для K613/USDC пула на выбранной lock-цели
- [ ] `Treasury.routerWhitelist(SwapRouter02) == true`
- [ ] Все vesting wallets видны через `K613VestingManager.getAllWallets()` с правильными бенефициарами и amounts

---

## Раздел 2 — Ежемесячный buyback flow

**Частота:** раз в месяц (или по триггеру когда накопленная стоимость fee ≥ ~$10k чтобы амортизировать газ).

**Цель:** сконвертировать балансы 11 fee-ассетов на Aave Collector в K613 и распределить как `xK613` реварды стейкерам.

**Почему off-chain swap (а не on-chain в Treasury):** `buybackV3ExactInputSingle` в Treasury делает только single-hop. Для не-USDC fee-ассетов нужен multi-hop или aggregator support, что мы отложили. Off-chain Safe flow полностью ручной, но прозрачный.

### Шаг 2.1 — Чтение балансов Collector

Off-chain: запросить `IERC20(aToken).balanceOf(AAVE_COLLECTOR)` для каждого из 11 aToken'ов. Пропускать активы где balance × spot price < ~$50 (газ не оправдан).

11 aToken'ов (Monad mainnet):

| Symbol | Underlying | aToken |
|---|---|---|
| USDC | `0x754704Bc059F8C67012fEd69BC8A327a5aafb603` | `0x4fDc7bcCABF4EE4ca08aF24aaaBF3531Ea6519dE` |
| AUSD | `0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a` | `0x6E8E9DA5BcDd2ee69c51406e2267ec65841FA307` |
| USDT0 | `0xe7cd86e13AC4309349F30B3435a9d337750fC82D` | `0x88fb417cfFc3858697Da31E1415f54f6E82c666c` |
| wsrUSD | `0x4809010926aec940b550D34a46A52739f996D75D` | `0xB6d63Ea862Bf17cD1CFd719173E731FE5588D1d0` |
| WETH | `0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242` | `0x793dBdE5a51849FA73109A6DAe913fC6C9209394` |
| wstETH | `0x10Aeaf63194db8d453d4D85a06E5eFE1dd0b5417` | `0x6Ea228a2429907BcEaa6351370C4dB07145cd4ac` |
| WBTC | `0x0555E30da8f98308EdB960aa94C0Db47230d2B9c` | `0x24cd55e35F65585Fb02448035A1EbbF154a7892f` |
| WMON | `0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A` | `0xd1d0B50038AFE4C74c4fA87D4661C1d5a53822e9` |
| shMON | `0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c` | `0x95d0acdd70E398501754741AD896E27eC693Dc07` |
| sMON | `0xA3227C5969757783154C60bF0bC1944180ed81B9` | `0x54521b12D429133cA4fbBFfcaFB282d71BFf5784` |
| gMON | `0x8498312A6B3CbD158bf0c93AbdCF29E6e4F55081` | `0x4eDa1817Ae13c1634BD94Bee697D63E546E7605f` |

Адрес Aave Collector: `0xF689bB846eE7DD51947c3368cc3ee26713D3ED83` (это `NEXT_PUBLIC_MONAD_TREASURY` — Aave-овский Collector, **не** наш Treasury контракт).

### Шаг 2.2 — Стянуть aToken'ы с Collector на Governance Safe

Для каждого ассета с нетривиальным балансом — собрать в Safe Transaction Builder:

```
AaveCollector.transfer(aToken, GOVERNANCE_SAFE, balance)
```

> `transfer` Aave Collector — admin-only; убедиться что Governance Safe — admin (устанавливается при деплое K613-Protocol). Сверить через Aave `ACLManager` / `EmergencyAdmin` views перед подписанием.

### Шаг 2.3 — Redeem aToken'ов в underlying

Для каждого стянутого aToken'а, с Governance Safe:

```
Pool.withdraw(underlying, type(uint256).max, GOVERNANCE_SAFE)
```

`Pool` = `0x4Ba3856a4d851d39C27e2E866daB7A95eF6e0113`.

После этого Safe держит сырые underlying токены (USDC, WETH, WBTC и т.д.).

### Шаг 2.4 — Off-chain свап в USDC

С Governance Safe через Uniswap V3 UI (https://app.uniswap.org с выбранной сетью Monad) или через Safe + SwapRouter02 calldata:

Для каждого не-USDC ассета — свапнуть в USDC. Адреса пулов для main пар (верифицированы on-chain):

| Asset | Best fee tier | Pool |
|---|---|---|
| WMON/USDC | 3000 | `0x659bD0BC4167BA25c62E05656F78043E7eD4a9da` |
| WETH/USDC | 3000 | `0x25EF1a210fF55BcEe9F8fee979aAFf6bD1bE5Bf1` |
| WBTC/USDC | 3000 | `0xB0B083E0353f7df4D5EE1C812eA8c6960c080373` |
| wstETH/USDC | 3000 | `0x4F77A2bbd4CB436D894D4b2060D99ba19465993C` |
| USDT0/USDC | 500 | `0xa00D8Ec3c0cC20E93Cad749695392a0B61fe8Ca3` |
| AUSD/USDC | 500 | `0x0E9876A149112242A4C60D589C548ba877C0512e` |

Для экзотики без V3 пулов (wsrUSD, shMON, sMON, gMON) — использовать Kuru DEX или копить пока пул не появится.

> **Slippage:** сначала котируем через `QuoterV2 = 0x661E93cca42AfacB172121EF892830cA3b70F08d`, ставим `amountOutMinimum = quote × 0.97` (3% tolerance).

### Шаг 2.5 — Перевод USDC на Treasury

```
USDC.transfer(TREASURY, totalUsdcAccumulated)
```

### Шаг 2.6 — Триггер buyback + распределение ревардов

Один Safe-вызов:

```
Treasury.buybackV3ExactInputSingle(
  tokenIn:           0x754704Bc059F8C67012fEd69BC8A327a5aafb603,  // USDC
  router:            0xfE31F71C1b106EAc32F1A19239c9a9A72ddfb900,  // SwapRouter02
  amountIn:          <накопленный USDC>,
  minK613Out:        <котировка K613 - 3% slippage>,
  poolFee:           3000,
  distributeRewards: true
)
```

Атомарно делает:
1. Свап USDC → K613 через пул
2. Стейк K613 → xK613
3. Перевод xK613 в RewardsDistributor
4. Вызов `notifyReward` чтобы стейкеры могли клеймить

### Шаг 2.7 — Проверка

- `Treasury.balanceOf(USDC) == 0`
- xK613 балас RewardsDistributor вырос на amount K613-out
- Эмитится event `BuybackExecuted(USDC, SwapRouter02, amountIn, k613Out, true)`

---

## Раздел 3 — Vesting Unlocks (самообслуживание бенефициарами)

**Действий оператора не требуется.** Vesting wallets деплоятся через `K613VestingManager.createVestingWallet`. Каждый бенефициар сам вызывает `release(K613)` на своём vesting wallet чтобы заклеймить то что уже vested.

Найти кошельки бенефициара:
```
K613VestingManager.getWalletsByBeneficiary(beneficiary) -> address[]
```

Проверить сколько сейчас доступно к release:
```
VestingWallet.releasable(K613) -> uint256
```

Семантика cliff/duration (по OpenZeppelin `VestingWalletCliff`):
- Ничего не releasable до `start + cliffSeconds`.
- После cliff vesting "догоняет" сразу до `(now - start) / durationSeconds * totalAllocation`.
- Полностью vested на `start + durationSeconds`.

> **Семантика team vesting (зафиксировано):** "6mo cliff + 18mo linear after" = **24 месяца total**, из них первые 6mo ничего не releasable, оставшиеся 18mo — линейный vesting.
>
> Параметры в OZ `VestingWalletCliff` model:
> - `cliffSeconds = 15_552_000` (6mo × 30d × 86400s)
> - `durationSeconds = 62_208_000` (24mo × 30d × 86400s) — **TOTAL от start, не линейная фаза**
>
> Эти значения уже зашиты в [distribution.example.json](../script/deploy/distribution.example.json) для team-бакетов. Не путать `durationSeconds` с "линейной фазой" — у OZ это общая длина окна.

---

## Раздел 4 — Аварийные процедуры

### 4.1 Pause трансферов K613

Если обнаружен критический эксплойт на контракте, который держит K613 и вот-вот будет drained:

```
K613.pause()   // требует PAUSER_ROLE
```

Когда paused — **все K613-трансферы реверт'ятся** (mint, burn, transfer, transferFrom). Vesting `release` тоже реверт'ится (внутри вызывает `transfer`). Использовать только как last resort.

Возобновить:
```
K613.unpause()
```

### 4.2 Pause Staking / Treasury / RewardsDistributor

У каждого свой `pause()` / `unpause()`, callable PAUSER_ROLE:

- `Staking.pause()` — блокирует `stake`, `initiateExit`, `cancelExit`, `instantExit`, `exit`.
- `Treasury.pause()` — блокирует `depositRewards`, `buybackV3ExactInputSingle`. **`withdraw` НЕ блокируется** — это by design (admin recovery hatch на случай compromise).
- `RewardsDistributor.pause()` — блокирует claim ревардов и notify. **Side-effect: `Staking.instantExit` тоже упадёт**, потому что внутри вызывает `RewardsDistributor.addPendingPenalty` (`whenNotPaused`). Стейкеры не смогут exit'нуть instant пока RD на паузе. Standard exit через 90-дневную queue по-прежнему работает (он не дёргает RD).

Pause независим для каждого контракта. Pause одного не auto-pause других.

### 4.3 Revoke скомпрометированного подписанта

Если ключ подписанта Safe скомпрометирован:
1. Немедленно убрать подписанта через Safe owner-management UI (требует threshold от оставшихся подписантов).
2. Добавить нового подписанта.
3. Ротировать любые контрактные роли всё ещё привязанные к скомпрометированному подписанту (обычно нет, если инвариант "Safe владеет всеми ролями" из шага 1.2 соблюдён).

---

## Раздел 5 — Справочные данные

### 5.1 Адреса контрактов на Monad mainnet

#### Стек K613 (заполняется на TGE)
```
K613:                  0x...
xK613:                 0x...
Staking:               0x...
RewardsDistributor:    0x...
Treasury:              0x...
K613VestingManager:    0x...
GOVERNANCE_SAFE:       0x...
TREASURY_SAFE:         0x...   (отдельный от контракта Treasury)
LM_RESERVE_SAFE:       0x...
```

#### K613-Protocol (Aave fork) — уже задеплоен
```
PoolAddressesProvider:    0x1f6E754C6F7A49e2d69e5341d65EcB8f8506C69c
Pool:                     0x4Ba3856a4d851d39C27e2E866daB7A95eF6e0113
PoolConfigurator:         0x3F16A467c3fC589fB96864196047F2f417CAc28F
Oracle:                   0x0dFfb00A751a74ac8CF8B022Bf86b1ECd9D7ae6F
AaveCollector:            0xF689bB846eE7DD51947c3368cc3ee26713D3ED83
IncentivesController:     0xe1d8B642c83587Df813a36F361C682C0475c4ea4
ACLManager:               0x115840CF79eb27713E0Bd3B66076651f8C081B0B
DataProvider:             0xfc87bE7f3657AAD69baDb6247A88E924D1F8bc53
```

#### Uniswap V3 на Monad (верифицировано on-chain)
```
Factory:                  0x204FAca1764B154221e35c0d20aBb3c525710498
NonfungiblePositionMgr:   0x7197E214c0b767cFB76Fb734ab638E2c192F4E53
SwapRouter02:             0xfE31F71C1b106EAc32F1A19239c9a9A72ddfb900
QuoterV2:                 0x661E93cca42AfacB172121EF892830cA3b70F08d
UniversalRouter:          0x0D97Dc33264bfC1c226207428A79b26757fb9dc3
WMON (=WETH9):            0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A
USDC (canonical):         0x754704Bc059F8C67012fEd69BC8A327a5aafb603
```

### 5.2 Распределение токена (по gitbook tokenomics)

```
Total supply: 100,000,000 K613

| Бакет                       | Amount       | Vesting                       |
|-----------------------------|--------------|-------------------------------|
| LM (IncentivesController)   | 40,000,000   | по графику Y1=25M Y2=10M Y3=5M|
| LM Reserve (отдельный Safe) | 10,000,000   | unlocked, future programs     |
| POL Initial LP              |  5,000,000   | locked (LP NFT) — bootstrap   |
| POL Reserve / Future LP     | 10,000,000   | unlocked, для дозалива LP     |
| Treasury / Governance       | 10,000,000   | unlocked                      |
| Seed                        | 10,000,000   | TGE unlock, "all to LP"       |
| Team & Core                 | 15,000,000   | 6mo cliff + 18mo linear       |
```

### 5.3 Inventory скриптов

| Скрипт | Назначение | Когда |
|---|---|---|
| [DeployK613.s.sol](../script/deploy/DeployK613.s.sol) | Деплой K613 + xK613 + Staking + RD + Treasury | TGE шаг 1.1 |
| [DeployVestingManager.s.sol](../script/deploy/DeployVestingManager.s.sol) | Деплой K613VestingManager | TGE шаг 1.4 |
| [PremintK613.s.sol](../script/deploy/PremintK613.s.sol) | Минт 100M на Governance Safe (one-shot) | TGE шаг 1.3 |
| [DistributeK613.s.sol](../script/deploy/DistributeK613.s.sol) | Батч-распределение 7 бакетов по JSON | TGE шаг 1.5 |
| [SeedInitialLP.s.sol](../script/deploy/SeedInitialLP.s.sol) | Создание + инициализация V3 K613/USDC пула, mint LP | TGE шаг 1.6 |
| [MintInitialK613.s.sol](../script/deploy/MintInitialK613.s.sol) | **Только для тестов** — минтит 1M на деплоера для economic-симуляций | dev only, не TGE |

### 5.4 Команды для тестов

```bash
forge test                                    # полный suite
forge test --match-path test/K613.t.sol -vv   # один контракт
forge test --no-match-path "test/Invariant*"  # пропустить медленные invariant runs
```

---

## Открытые вопросы блокирующие production-run

Нужно решить перед заполнением `distribution.json` и выполнением TGE:

1. ~~Решение по LP capital~~ — **выбран bootstrap: 5M K613 + $40k USDC**. Остальные 10M из POL → бакет POL-Reserve-Future-LP, дозалив по мере роста.
2. **3 адреса Safe** — Governance / Treasury / LM Reserve. Каждый — multisig с задокументированными подписантами и threshold.
3. **Список team vesting** — адреса бенефициаров + amounts (сумма 15M).
4. **Список seed-инвесторов** — адреса + amounts (сумма 10M); подтвердить идут ли токены инвесторам напрямую или "all to LP" по docs (последнее значит инвесторы заплатили USDC, K613 который они получили бы — идёт в LP, а не им).
5. ~~LP lock target~~ — **РЕШЕНО**: OZ `TimelockController` с 365-day delay. Деплой и transfer NFT описаны в шаге 1.7.
6. ~~Семантика vesting duration~~ — **РЕШЕНО**: 24mo total (6mo cliff + 18mo linear after). `cliffSeconds=15_552_000`, `durationSeconds=62_208_000` зафиксированы в `distribution.example.json` и SOP разделе 3.
7. ~~IncentivesController funding mechanism~~ — **РАЗРЕШЕНО**: PULL-based через `PullRewardsTransferStrategy`. K613 идёт на REWARDS_VAULT (отдельный Safe), не на IncentivesController. Vault стейкает K613 → xK613 → approve strategy. Реализовано в `LM-Rewards-Vault` бакете distribution.json и шаге 1.5b.
