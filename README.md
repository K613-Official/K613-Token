## K613 

<p align="center">
  <img src="image/image.png" alt="K613 logo" width="200" />
</p>

This repository contains the K613 protocol smart contracts: the base token `K613`, the staking receipt token `xK613`, the staking contract with an exit queue, the rewards distributor, and the treasury that manages buybacks and topping up the rewards pool.

The protocol is inspired by the Shadow (`xSHADOW`) model: users deposit the base token, receive a 1:1 receipt token, and exit from staking goes through a queue with an optional early exit penalty. Rewards are paid in the same receipt token and depend on the user’s share in the pool.

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
- economic invariant: `xK613.totalSupply()` must always equal internal `_totalBacking` (and the `K613` balance held by staking), enforced by `backingIntegrity()`.

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

**`Treasury` (src/treasury/Treasury.sol)**  
Protocol treasury managing `K613` flows:
- holds references to `K613`, `xK613`, `Staking`, and `RewardsDistributor`;
- main **rewards deposit** flow (`depositRewards`):
  - treasury receives `K613` from the admin/DAO;
  - stakes it in `Staking`, receiving 1:1 `xK613`;
  - sends `xK613` to `RewardsDistributor` and calls `notifyReward`, increasing the rewards pool for everyone who deposited `xK613`;
- **buyback** flow (`buyback`):
  - via whitelisted DEX routers (`routerWhitelist`) the treasury can swap any `tokenIn` for `K613`;
  - a minimum expected output `minK613Out` is enforced; the call reverts if output is lower;
  - with `distributeRewards` set, the bought `K613` can be staked, converted to `xK613`, and sent to `RewardsDistributor` as another reward source;
- admin can withdraw arbitrary ERC‑20 tokens (`withdraw`) and pause the treasury.

---

### Economic Model

1. **1:1 backing of xK613**  
   Every `xK613` token is backed by exactly one `K613` held in the staking and/or rewards distributor contracts.  
   Invariant: `xK613.totalSupply()` equals `Staking.totalBacking()` and the `K613` balance on Staking. Any breach (e.g. sending `K613` directly to the contract) is detected by `backingIntegrity()`.

2. **Rewards come from outside the protocol**  
   The protocol does not “create” yield by itself; rewards come from:
   - DAO/treasury allocations via `Treasury.depositRewards`, turning `K613` into `xK613` and adding it to the pool;
   - buybacks and redistribution of external revenue: any tokens received by the protocol (e.g. fees) can be swapped for `K613` via `Treasury.buyback`, staked, and distributed to stakers.

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
   - DAO/treasury funds the rewards pool via `Treasury.depositRewards` or `buyback` with `distributeRewards = true`.
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
