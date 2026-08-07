## K613 

<p align="center">
  <img src="image/image.png" alt="K613 logo" width="200" />
</p>

This repository contains the K613 protocol smart contracts: the base token `K613`, the staking receipt token `xK613`, the staking contract with an exit queue, the rewards distributor, the treasury that manages buybacks and topping up the rewards pool, the public sale, team vesting, and the Season 1 points campaign (points token, weekly distributor, and post-TGE conversion into K613).

The protocol is inspired by the Shadow (`xSHADOW`) model: users deposit the base token, receive a 1:1 receipt token, and exit from staking goes through a queue with an optional early exit penalty. Rewards are paid in the same receipt token and depend on the user’s share in the pool.

---

### Security & Audit

- The core protocol contracts (`K613`, `xK613`, `Staking`, `RewardsDistributor`, `Treasury`) were audited by **Hashlock**. The final report (v3) is available in [`audit/`](audit/K613-Smart-Contract-Audit-Report-Final-Report-v3.pdf).
- Contracts added after the audit window (public sale, vesting, points campaign) follow the same standards: OpenZeppelin `AccessControl` / `Pausable` / `ReentrancyGuard`, `SafeERC20`, checks-effects-interactions.
- All deployed mainnet contracts are **source-verified** (Sourcify exact match) — see the address table below.
- Every user-facing contract supports `pause` for incident response, and privileged operations are role-gated.

If you believe you have found a security issue, please contact the team privately before any public disclosure.

---

### Deployed Contracts (Monad mainnet, chainId 143)

| Contract | Address |
|---|---|
| K613 | `0xb09582631336068d4B0089d943f40CbF46dE5189` |
| xK613 | `0x9064d55A8A8473fA39c41A16492Fa1094Eb4E8b5` |
| StakingV2 | `0x5A3DA7644c25F0A74DCb0bA13ae38214D8856415` |
| TreasuryV2 | `0x10aCE88f2F2c361218615F5dcA8987DD16C54282` |
| K613TreasuryOperatorV2 | `0xc7E2Cb01634b2Ea02581aAC763367A7426fa6dBC` |
| RewardsDistributor | `0xE3E8925E8554464611c86419B9e99AD7Cd47428f` |
| K613PublicSale | `0xb83D0BEDE1C294B73c82ea0816E61E407775c7c2` |
| K613VestingManager | `0xcb521f8e2441c13F7e79205b0bC5011e0cdd7aa9` |
| K613S1 (points) | `0x4f9ba5CaE0e3F651821283EC4e303fE8D1dA542a` |
| K613S1Distributor | `0x94F71Da72c6CE71c570CF7F8e076F3097E411063` |
| K613SeasonClaim | `0xe41b3D63c7Aa5E54C57c9810217a60dc887364Be` |
| K613/USDC pool (Uniswap V3, 0.05%) | `0xDD5557CEcFD7Ba0F5F2A1C38967d83Df2951a4F4` |
| K613LpTimelock (LP locked until Jul 2027) | `0xbDB83DF26F8e554bd20754df3Dde7cab958956D5` |

Tokenomics (allocation, vesting schedules, emissions) is documented at [docs.k613.net](https://docs.k613.net/k613-tokenomics).

---

### Core Contracts

**`K613` (src/token/K613.sol)**  
Protocol ERC‑20 token with a minter role:
- supports `mint` and `burnFrom` only for addresses with `MINTER_ROLE`;
- access control via `AccessControl` (`DEFAULT_ADMIN_ROLE`, `MINTER_ROLE`, `PAUSER_ROLE`);
- the contract can be paused, in which case all `K613` transfers are blocked;
- the initial minter is set in the constructor and can be updated by the admin.

**`xK613` (src/token/xK613.sol)**  
Staking receipt ERC‑20 token:
- minted 1:1 for deposited `K613` in the staking contract and burned on exit;
- no rebasing or automatic reward accrual — it is a plain accounting receipt;
- transfers are restricted by a whitelist (`transferWhitelist`): a regular user cannot freely transfer `xK613` to another address, only interact with Staking and `RewardsDistributor`;
- mint/burn and pause are controlled via `AccessControl`, same as for `K613`.

**`Staking` (src/staking/Staking.sol)**  
K613 staking contract, inspired by the xSHADOW model:
- user calls `stake(amount)` → `K613` is transferred to the contract and the user receives an equal amount of `xK613`;
- exit uses an **exit queue** (`ExitRequest[]` in `UserState`):
  - `initiateExit(amount)` pulls `xK613` from the user, holds it in the contract, and creates a request with a timestamp;
  - after `lockDuration` (e.g. 7 days) the user can call `exit(index)` and get `K613` back without penalty;
  - before `lockDuration` the user can call `instantExit(index)` to exit immediately, paying a penalty in `K613` at rate `instantExitPenaltyBps` (basis points);
- the early-exit penalty is not burned: it is sent to `RewardsDistributor` and counted as extra rewards for remaining stakers;
- the contract allows up to `MAX_EXIT_REQUESTS` active requests per user and is protected by `ReentrancyGuard`;
- economic invariant: `xK613.totalSupply()` must always equal internal `_totalBacking`.

**`RewardsDistributor` (src/staking/RewardsDistributor.sol)**  
Contract that distributes rewards based on `xK613` deposits:
- users deposit `xK613` via `deposit(amount)` and earn a share of rewards;
- rewards are also in `xK613` and are distributed using an `accRewardPerShare` model (like standard liquidity pools):
  - user state is updated on deposit/withdraw, and rewards accumulate in `userPendingRewards`;
  - `pendingRewardsOf(account)` returns the expected payout including not-yet-distributed penalties;
- reward sources:
  - `Treasury.depositRewards`: the treasury stakes `K613`, receives `xK613`, and sends it to `RewardsDistributor` via `notifyReward`;
  - staking penalties: `Staking.instantExit` sends the penalty in `K613` to `RewardsDistributor`, which accumulates it via `addPendingPenalty` and on the next `advanceEpoch` or `claim` stakes that `K613` to get additional `xK613` for distribution;
- accounting is epoch-based (`epochDuration`):
  - during an epoch penalties accumulate in `pendingPenalties`;
  - when a threshold is met or the epoch ends they are flushed into `accRewardPerShare`;
  - `advanceEpoch()` moves the epoch boundary and distributes accumulated penalties/rewards when there are deposits;
- safety for exiting stakers:
  - while a user has active exit requests in `Staking` (`exitQueueLength > 0`), `claim()` in `RewardsDistributor` reverts with `ExitVestingActive`;
  - so users cannot withdraw stake and claim rewards at the same time until the exit queue is completed or cancelled.

**`K613PublicSale` (src/sale/K613PublicSale.sol)**  
Fixed-price overflow public sale (10,000,000 K613 at $0.01 against USDC, $100k hard cap):
- deposits are accepted only inside the `[saleStart, saleEnd)` window and only once the contract holds the full sale allocation (`SaleNotFunded` otherwise);
- if total deposits exceed the hard cap, allocations are pro-rata and the unused part of each deposit is claimable back via `claimRefund` — the effective price never changes;
- after `finalize()` buyers claim 100% of their allocation with `claimTokens` (no vesting), claims stay open for `CLAIM_WINDOW` (365 days);
- admin can withdraw proceeds once (`withdrawProceeds`), sweep unsold tokens (`sweepUnsoldTokens`), and recover leftovers after the claim deadline.

**`K613VestingManager` / `K613VestingWallet` (src/vesting/)**  
Team vesting via OpenZeppelin `VestingWalletCliff`:
- the manager deploys one immutable vesting wallet per allocation and indexes wallets by beneficiary (`getWalletsByBeneficiary`);
- production schedule: 6-month cliff, then linear vesting until month 24; beneficiaries call `release(token)` on their own wallet.

**`K613S1` / `K613S1Distributor` / `K613SeasonClaim` (src/token/K613S1.sol, src/campaign/)**  
Season 1 points campaign:
- `K613S1` is a non-transferable points ERC-20 minted weekly by the distributor from Merkle roots (cumulative claims);
- `K613SeasonClaim` opens at TGE: it burns `K613S1` 1:1 and pays out K613 on a step-vesting schedule (20% at TGE + 4 × 20% every 15 days), funded by governance, with a 365-day claim window.

**`Treasury` (src/treasury/Treasury.sol)**  
Protocol treasury managing `K613` flows:
- holds references to `K613`, `xK613`, `Staking`, and `RewardsDistributor`;
- main **rewards deposit** flow (`depositRewards`):
  - treasury receives `K613` from the admin/DAO;
  - stakes it in `Staking`, receiving 1:1 `xK613`;
  - sends `xK613` to `RewardsDistributor` and calls `notifyReward`, increasing the rewards pool for everyone who deposited `xK613`;
- **buyback** flow (`buybackV3ExactInputSingle`):
  - via whitelisted DEX routers (`routerWhitelist`) the treasury swaps a single-hop Uniswap V3 path (`tokenIn` → `K613` at `poolFee`) using the router’s `exactInputSingle` (SwapRouter02-style ABI);
  - `tokenIn` must not be `K613`; a minimum expected output `minK613Out` is enforced;
  - with `distributeRewards` set, the received `K613` is staked, converted to `xK613`, and sent to `RewardsDistributor` as another reward source;
- admin can withdraw arbitrary ERC‑20 tokens (`withdraw`) and pause the treasury.

---

### Economic Model

1. **1:1 backing of xK613**  
   Every `xK613` token is backed by exactly one `K613` held in the staking and/or rewards distributor contracts.  
   Invariant: `xK613.totalSupply()` equals `Staking.totalBacking()`.

2. **Rewards come from outside the protocol**  
   The protocol does not “create” yield by itself; rewards come from:
   - DAO/treasury allocations via `Treasury.depositRewards`, turning `K613` into `xK613` and adding it to the pool;
   - buybacks and redistribution of external revenue: tokens received by the protocol (e.g. fees) can be swapped for `K613` via `Treasury.buybackV3ExactInputSingle`, staked, and distributed to stakers.

3. **Early-exit penalties boost yield for remaining stakers**  
   - on `instantExit` the user pays a penalty in `K613` (a percentage set by `instantExitPenaltyBps`);
   - this penalty goes to `RewardsDistributor` as `pendingPenalties`, is then staked to become `xK613`, and is distributed to those who keep `xK613` in the pool;
   - early exits thus subsidize long-term stakers.

4. **Separation of staking and rewards distribution**  
   - `Staking` only handles deposit/exit and backing correctness, not reward math;
   - `RewardsDistributor` only handles `xK613` deposits and reward distribution (`accRewardPerShare`, epochs, penalties);
   - `Treasury` is the only component authorized to bulk-fund the rewards pool or run buybacks, simplifying audit and risk control.

5. **Roles and security**  
   - critical operations (changing minter, staking/distributor config, DEX whitelist) are gated by `DEFAULT_ADMIN_ROLE` and dedicated roles (`PAUSER_ROLE`, `REWARDS_NOTIFIER_ROLE`);
   - every contract supports `pause` for quickly halting user operations in an incident;
   - all external token transfers use `SafeERC20`, and user flows are protected with `ReentrancyGuard`.

---

### Typical User Flows

1. **Staking K613**
   - User calls `stake(amount)` on `Staking` → `K613` is transferred to the contract and the user receives `xK613`.
   - (Optional) User deposits some or all `xK613` in `RewardsDistributor.deposit` to participate in reward distribution.

2. **Claiming rewards**
   - DAO/treasury funds the rewards pool via `Treasury.depositRewards` or `buybackV3ExactInputSingle` with `distributeRewards = true`.
   - When enough time has passed or penalties have accumulated, `advanceEpoch()` is called (or distribution happens lazily on `deposit`/`withdraw`/`claim`).
   - User calls `claim()` on `RewardsDistributor`, provided they have no active exit queue in `Staking`.

3. **Exiting staking**
   - User first **withdraws `xK613` from `RewardsDistributor`** via `withdraw` if they had deposited there.
   - Then calls `initiateExit(amount)` on `Staking` and waits for `lockDuration`, after which they can do a normal `exit(index)` with no penalty, or `instantExit(index)` before lock ends with a penalty.

---

### Build and Test

The project uses Foundry.

- **Build**: `forge build`
- **Test**: `forge test`

See `script/COMMANDS.md` for deploy and script commands.
