// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title RewardsDistributor
/// @notice Deposit/withdraw model: users deposit xK613, rewards accrue proportionally. `exitPending` is excluded from accrual.
/// @dev Staking calls `depositFor`, `addExitPending`, `removeExitPending`, `withdrawFor`. `claim` is blocked when `exitPending > 0`.
contract RewardsDistributor is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error NoRewards();
    error ExitPending();
    error InsufficientBalance();

    /// @notice xK613 token used both as staked asset and reward token.
    IERC20 public immutable xk613;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant REWARDS_NOTIFIER_ROLE = keccak256("REWARDS_NOTIFIER_ROLE");
    bytes32 public constant STAKING_ROLE = keccak256("STAKING_ROLE");

    /// @notice Global accumulated rewards per effective share, scaled by 1e18.
    uint256 public accRewardPerShare;
    /// @notice Rewards that have been notified but not yet distributed into `accRewardPerShare`.
    uint256 public pendingRewards;
    /// @notice Total amount of xK613 credited to all users (including `exitPending`).
    uint256 public totalDeposits;
    /// @notice Total amount of xK613 that is pending exit across all users and excluded from accrual.
    uint256 public totalExitPending;

    /// @notice Recorded xK613 deposits per user.
    mapping(address => uint256) public balanceOf;
    /// @notice Portion of each user's deposit that is pending exit and excluded from rewards.
    mapping(address => uint256) public exitPending;
    /// @notice Reward debt per user used for reward accounting.
    mapping(address => uint256) public userRewardDebt;
    /// @notice Rewards accumulated but not yet claimed per user.
    mapping(address => uint256) public userPendingRewards;

    /// @notice Address of the staking contract that owns `STAKING_ROLE`.
    address public staking;

    /// @notice Emitted when a user successfully claims rewards.
    /// @param account Address of the user that claimed.
    /// @param amount Amount of rewards claimed.
    event Claimed(address indexed account, uint256 amount);
    /// @notice Emitted when new rewards are added to the distributor.
    /// @param amount Amount of rewards notified.
    event RewardNotified(uint256 amount);
    /// @notice Emitted when the staking contract address is updated.
    /// @param staking Address of the new staking contract.
    event StakingUpdated(address indexed staking);
    /// @notice Emitted when a user deposit is increased.
    /// @param account Address of the user whose balance increased.
    /// @param amount Amount deposited.
    event Deposited(address indexed account, uint256 amount);
    /// @notice Emitted when a user deposit is decreased.
    /// @param account Address of the user whose balance decreased.
    /// @param amount Amount withdrawn.
    event Withdrawn(address indexed account, uint256 amount);
    /// @notice Emitted when a portion of a user's deposit becomes pending exit.
    /// @param account Address of the user.
    /// @param amount Amount marked as pending exit.
    event ExitPendingAdded(address indexed account, uint256 amount);
    /// @notice Emitted when a portion of a user's pending exit is removed.
    /// @param account Address of the user.
    /// @param amount Amount removed from pending exit.
    event ExitPendingRemoved(address indexed account, uint256 amount);

    /// @notice Initializes the rewards distributor contract.
    /// @param xk613Token Address of the xK613 token used for staking and rewards.
    constructor(address xk613Token) {
        if (xk613Token == address(0)) {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        xk613 = IERC20(xk613Token);
    }

    /// @notice Sets the staking contract and grants it the required roles.
    /// @dev Grants `STAKING_ROLE` and `REWARDS_NOTIFIER_ROLE` to the new staking contract and revokes them from the old one.
    /// @param staking_ Address of the staking contract.
    function setStaking(address staking_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (staking_ == address(0)) {
            revert ZeroAddress();
        }
        if (staking != address(0)) {
            _revokeRole(REWARDS_NOTIFIER_ROLE, staking);
            _revokeRole(STAKING_ROLE, staking);
        }
        staking = staking_;
        _grantRole(REWARDS_NOTIFIER_ROLE, staking_);
        _grantRole(STAKING_ROLE, staking_);
        emit StakingUpdated(staking_);
    }

    /// @notice Increases the recorded deposit for a user.
    /// @dev Called by the staking contract after minting `amount` xK613 to this contract.
    /// @param user Address of the user whose balance is increased.
    /// @param amount Amount of xK613 credited to the user.
    function depositFor(address user, uint256 amount) external onlyRole(STAKING_ROLE) whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        _updateUser(user);
        balanceOf[user] += amount;
        totalDeposits += amount;
        userRewardDebt[user] = (_effectiveBalance(user) * accRewardPerShare) / 1e18;
        emit Deposited(user, amount);
    }

    /// @notice Marks a portion of a user's deposit as pending exit, excluding it from reward accrual.
    /// @dev Called by the staking contract when a user initiates an exit.
    /// @param user Address of the user whose deposit is updated.
    /// @param amount Amount to mark as pending exit.
    function addExitPending(address user, uint256 amount) external onlyRole(STAKING_ROLE) whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        _updateUser(user);
        exitPending[user] += amount;
        totalExitPending += amount;
        userRewardDebt[user] = (_effectiveBalance(user) * accRewardPerShare) / 1e18;
        emit ExitPendingAdded(user, amount);
    }

    /// @notice Removes a portion of a user's pending exit amount, returning it to the effective balance.
    /// @dev Called by the staking contract when a user cancels an exit request.
    /// @param user Address of the user whose pending exit is reduced.
    /// @param amount Amount to remove from pending exit.
    function removeExitPending(address user, uint256 amount) external onlyRole(STAKING_ROLE) whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        _updateUser(user);
        exitPending[user] -= amount;
        totalExitPending -= amount;
        userRewardDebt[user] = (_effectiveBalance(user) * accRewardPerShare) / 1e18;
        emit ExitPendingRemoved(user, amount);
    }

    /// @notice Decreases the user's deposit and transfers xK613 to the staking contract.
    /// @dev Called by the staking contract when a user fully exits for `amount`.
    /// @param user Address of the user whose deposit is decreased.
    /// @param amount Amount of xK613 withdrawn for the user.
    function withdrawFor(address user, uint256 amount) external onlyRole(STAKING_ROLE) whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        _updateUser(user);
        if (balanceOf[user] < amount) revert InsufficientBalance();
        balanceOf[user] -= amount;
        totalDeposits -= amount;
        userRewardDebt[user] = (_effectiveBalance(user) * accRewardPerShare) / 1e18;
        xk613.safeTransfer(staking, amount);
        emit Withdrawn(user, amount);
    }

    /// @notice Claims all accumulated rewards for the caller.
    /// @dev Reverts with {ExitPending} if the caller has any amount in `exitPending`.
    function claim() external nonReentrant whenNotPaused {
        if (exitPending[msg.sender] > 0) {
            revert ExitPending();
        }
        _updateUser(msg.sender);
        uint256 reward = userPendingRewards[msg.sender];
        if (reward == 0) revert NoRewards();
        userPendingRewards[msg.sender] = 0;
        xk613.safeTransfer(msg.sender, reward);
        emit Claimed(msg.sender, reward);
    }

    /// @notice Notifies the contract about newly added rewards.
    /// @dev Called by Treasury or staking contract (for penalties). If there is no effective stake, the amount is stored in `pendingRewards`.
    /// @param amount Amount of xK613 to be distributed as rewards.
    function notifyReward(uint256 amount) external nonReentrant onlyRole(REWARDS_NOTIFIER_ROLE) whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        uint256 effective = totalDeposits - totalExitPending;
        if (effective == 0) {
            pendingRewards += amount;
            return;
        }
        accRewardPerShare += (amount * 1e18) / effective;
        emit RewardNotified(amount);
    }

    /// @notice Pauses reward-related state-changing operations.
    /// @dev Functions guarded by `whenNotPaused` will revert while the contract is paused.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses the contract, re-enabling state-changing operations.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Computes the effective balance of a user used for reward accrual.
    /// @param user Address of the user.
    /// @return Effective balance equal to `balanceOf[user] - exitPending[user]`, floored at zero.
    function _effectiveBalance(address user) internal view returns (uint256) {
        uint256 bal = balanceOf[user];
        uint256 pending = exitPending[user];
        return bal > pending ? bal - pending : 0;
    }

    /// @notice Updates reward accounting for a user based on the current global state.
    /// @param user Address of the user to update.
    function _updateUser(address user) internal {
        _distributePending();
        uint256 eff = _effectiveBalance(user);
        uint256 accumulated = (eff * accRewardPerShare) / 1e18;
        if (accumulated > userRewardDebt[user]) {
            userPendingRewards[user] += (accumulated - userRewardDebt[user]);
        }
        userRewardDebt[user] = accumulated;
    }

    /// @notice Distributes any `pendingRewards` into `accRewardPerShare` if there is effective stake.
    function _distributePending() internal {
        uint256 effective = totalDeposits - totalExitPending;
        if (pendingRewards == 0 || effective == 0) return;
        uint256 amount = pendingRewards;
        pendingRewards = 0;
        accRewardPerShare += (amount * 1e18) / effective;
        emit RewardNotified(amount);
    }

    /// @notice Returns pending rewards for an account.
    /// @dev Returns 0 if the account has any amount in `exitPending`.
    /// @param account Address of the account to query.
    /// @return Total pending rewards for `account` in xK613.
    function pendingRewardsOf(address account) external view returns (uint256) {
        if (exitPending[account] > 0) return 0;
        uint256 effective = totalDeposits - totalExitPending;
        if (effective == 0) return userPendingRewards[account];
        uint256 accReward = accRewardPerShare;
        if (pendingRewards > 0) {
            accReward += (pendingRewards * 1e18) / effective;
        }
        uint256 eff = _effectiveBalance(account);
        uint256 accumulated = (eff * accReward) / 1e18;
        uint256 pending = accumulated > userRewardDebt[account] ? accumulated - userRewardDebt[account] : 0;
        return userPendingRewards[account] + pending;
    }
}
