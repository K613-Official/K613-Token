# K613 + Aave Lending Integration Guide

Полное описание интеграции K613 протокола со скриптом Aave для симуляции supply/borrow рынка.

## Архитектура

```
K613 Protocol Stack
├── K613 (governance token)
├── xK613 (staking receipt)
├── Staking (K613 -> xK613)
├── RewardsDistributor (xK613 rewards)
└── Treasury (fee management + buyback)

Integrated with:
└── Aave V3 (lib/L2-Protocol)
    ├── IPool (supply/borrow)
    ├── aTokens (supply receipts)
    └── Debt tokens (borrow receipts)
```

## Полный цикл жизни

### ЦИКЛ 1: Supply & Borrow (День 1-7)

**Admin действия:**
```
1. Mint K613 для пула (награды)
2. Пополнить USDC (или другой token) для User A & B
```

**User A действия:**
```
1. Supply X USDC в Aave -> получить aUSDC
   - Теперь зарабатывает supply APY
   - Может использовать как collateral для borrow
   
2. Stake Y K613 в Staking -> получить xK613
   - Блокируется на 120 сек
   - Может выйти со штрафом 50% (instant exit)
   
3. Deposit xK613 в RewardsDistributor
   - Получает share протокольных наград
```

**User B действия:**
```
1. Supply Z USDC в Aave как collateral
   
2. Borrow X USDC из Aave
   - Платит borrow APY (e.g. 10%)
   - Accumulates debt
```

**Все получают:**
- Supply rewards из Aave (за предоставленный capital)
- Protokol rewards (K613) из Treasury

### ЦИКЛ 2: Claim & Compound (День 7-14)

**Все действия:**
```
1. Advance RD epoch -> unlock rewards
2. Claim supply rewards
   - xK613 из RewardsDistributor
   - Возможно аUSDC из Aave (зависит от конфига)
3. Claim borrow rewards (User B)
```

**User B особое:**
```
1. Может сделать instant exit на половине xK613
   - Теряет 50% в штрафе
   - Штраф идет в RewardsDistributor для остальных
   - Получает K613 обратно
```

**Admin особое:**
```
1. Собирает% от протокола
   - 15% от borrow interest -> protocol revenue
2. Распределяет на:
   - 50% Buyback (токен поддержка)
   - 50% Staking rewards (K613 для стейкеров)
```

### ЦИКЛ 3: Staking Rewards (День 14-21)

**User A особое:**
```
1. Теперь доступны staking rewards
   - Из penalties + admin allocation
   
2. Клеймит награды
   
3. Инициирует exit
   - Ждет lock period (120 сек)
   - Получает K613 обратно
```

**Все повторяют:**
```
- Можно повторить цикл 2-3 сколько угодно раз
- Каждый цикл compounds rewards
- Строится долгосрочное накопление стоимости
```

## Параметры Экономики

### Основные ставки

```solidity
// Borrow rate (зависит от utilization)
uint256 baseRate = 5%;
uint256 multiplier = 1% per 1% over 75% target;

// Результат при 75% utilization:
borrowAPY = 5% + (75% - 75%) * 1% = 5%

// Результат при 90% utilization:
borrowAPY = 5% + (90% - 75%) * 1% = 20%
```

### Supply APY (зависит от borrow)

```
supplyAPY = (borrowed * borrowAPY * protocolFee%) / supplied + treasurySeeding
```

**Пример:**
- TVL: 100M
- Utilization: 75% (75M borrowed)
- Borrow rate: 10%
- Protocol fee: 15%
- Treasury seeding: 3.5M/year (3.5% of 100M)

```
supplyAPY = (75M * 10% * 15%) / 100M + 3.5% = 1.125% + 3.5% = 4.625%
```

**Но если мы хотим 12% APY:**
```
neededFromTreasury = (100M * 12%) - (75M * 10% * 15%) = 12M - 1.125M = 10.875M
```

### Token Inflation Analysis

**За год при 100M TVL, 12% supply APY:**

```
Emissions:
  Supply rewards:  100M * 12% = 12M K613
  Staking rewards: 1.125M * 50% = 0.56M K613  (from protocol fee)
  Total:           12.56M K613

Sinks:
  Buyback:         1.125M * 50% = 0.56M K613

Net inflation:     12.56M - 0.56M = 12M K613/year
Inflation rate:    12M / 100M = 12% annual
```

**Problem:** Supply APY = Inflation Rate!
Решение: Нужна TVL growth > 12% чтобы dilution был меньше

## Скрипты для Запуска

### 1. Основной цикл (требует Aave deployment)

```bash
# Set environment variables
export PRIVATE_KEY=0x...
export AAVE_POOL_ADDRESS=0x...
export SUPPLY_TOKEN_ADDRESS=0x...
export BORROW_TOKEN_ADDRESS=0x...

# Run full cycle
forge script script/FullLendingEconomyCycle.s.sol -vvv
```

**Outputs:**
- Protocol deployment addresses
- All user balances after each cycle
- Supply/borrow amounts
- Reward distributions

### 2. Экономический анализ

```bash
forge script script/LendingEconomicsAnalysis.s.sol -vvv
```

**Что показывает:**
- Оптимальные borrow rates
- Распределение фи
- Динамика utilization
- Инфляция токена
- Рекомендации параметров

## Deployment Checklist

### Шаг 1: Подготовить Aave

```bash
# Deploy L2Pool или использовать существующий
# Настроить процентные ставки
# Создать USDC и K613 как поддерживаемые assets
```

### Шаг 2: Deploy K613 Stack

```bash
forge script script/DeployK613.s.sol --broadcast
# Outputs: K613, xK613, Staking, RD, Treasury addresses
```

### Шаг 3: Configure Integration

```bash
# Save addresses to .env
echo "K613_ADDRESS=0x..." >> .env
echo "AAVE_POOL_ADDRESS=0x..." >> .env
```

### Шаг 4: Seed Initial Liquidity

```bash
# Mint K613 to admin
# Mint USDC to users
# Approve Aave Pool
```

### Шаг 5: Run Full Cycle

```bash
forge script script/FullLendingEconomyCycle.s.sol --broadcast
```

## Что отслеживать

### Protocol Health

```
✓ Utilization rate (target 75%)
✓ Supply APY vs expected
✓ Borrow APY correctly floats
✓ Instant exit penalties accumulate
✓ Treasury revenue grows
```

### User Economics

```
✓ Supply rewards accrue correctly
✓ Borrow costs are reasonable
✓ Staking rewards attractive
✓ Exit penalties fair
✓ Total user returns > opportunity cost
```

### Token Economics

```
✓ Inflation rate manageable
✓ Buyback pressure meaningful
✓ No death spiral dynamics
✓ Long-term value accrual
```

## Key Decisions & Trade-offs

### Base Borrow Rate

**Lower (3%):**
- Pro: Attracts borrowers
- Con: Suppliers earn less, need more seeding

**Higher (7%):**
- Pro: Strong supplier returns
- Con: Expensive for borrowers, low utilization

**Recommended: 5%** (middle ground)

### Supply APY Target

**Lower (8%):**
- Pro: Sustainable, less treasury seeding
- Con: Weak competitive advantage

**Higher (15%):**
- Pro: Attracts deposits
- Con: High inflation, unsustainable long-term

**Recommended: 12%** (competitive + sustainable)

### Instant Exit Penalty

**Lower (20%):**
- Pro: User-friendly
- Con: Insufficient reward to stakers

**Higher (70%):**
- Pro: Strong staking incentive
- Con: Punitive, users avoid Aave

**Recommended: 50%** (fair balance)

## Expected Results After 3 Cycles

### User A (Supplier + Staker)

```
Initial:      100,000 K613 + 100,000 USDC
              (supplied USDC, staked K613)

Cycle 1:      Earning supply APY on USDC
              Earning share of protocol rewards
              
Cycle 2:      Claimed rewards
              Recompounded
              xK613 position larger

Cycle 3:      Staking rewards unlocked
              Can exit all positions
              
Final value:  ~115,000 K613 + 100,000+ USDC
              Gain: ~15% (depending on rewards)
```

### User B (Supplier + Borrower)

```
Initial:      200,000 USDC
              (supplied 200k as collateral, borrowed 50k)

Through cycle: Earning supply on 200k
              Paying borrow interest on 50k
              Net: ~2-3% gain if borrow rate < supply incentive

Cycle 2:      Can repay partial borrow
              Instant exit on K613 rewards

Final value:  ~205,000 USDC + some K613
              Gain: ~2-5% (supply APY > borrow cost)
```

### Admin

```
Initial:      10M K613 (treasury)

Cycle 1-3:    Collects ~1M K613 in protocol fees
              Uses for buyback (supports token)
              Uses for staking rewards

Final:        Budget deployed efficiently
              Token pressure mitigated
              Ecosystem incentivized
```

## Troubleshooting

### Borrow Rate Too Low
**Problem:** Borrowers profitable, utilization creeping up
**Solution:** Increase base rate or multiplier

### Borrow Rate Too High
**Problem:** No one borrows, utilization stays low
**Solution:** Decrease base rate

### Supply APY Unsustainable
**Problem:** Treasury depletes quickly
**Solution:** Either reduce APY target or grow TVL faster

### Token Inflation Spiral
**Problem:** Supply inflation > buyback
**Solution:** Reduce supply APY target or increase buyback %

## Next Steps

1. **Deploy** to testnet (Sepolia/Arbitrum)
2. **Simulate** various parameter combinations
3. **Validate** against real market dynamics
4. **Monitor** inflation/deflation ratio
5. **Adjust** before mainnet deployment

---

**Summary:** K613 + Aave creates sustainable yield environment where:
- Borrowers pay reasonable rates
- Suppliers earn attractive returns
- Protocol captures small fee for sustainability
- Token holders benefit from buyback + rewards
- Long-term value accrual through compounding
