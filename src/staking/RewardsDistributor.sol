// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title RewardsDistributor
/// @notice Manual deposit/withdraw: users deposit xK613 to earn rewards. Claim anytime. Penalties flush above threshold or at epoch boundary.
contract RewardsDistributor is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error NoRewards();
    error InsufficientBalance();
    error InvalidEpochDuration();
    error MinimumInitialDeposit();

    /// @notice xK613 token used for deposits and rewards.
    IERC20 public immutable xk613;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant REWARDS_NOTIFIER_ROLE = keccak256("REWARDS_NOTIFIER_ROLE");

    uint256 public constant MIN_PENALTY_FLUSH = 1e18;
    /// @notice Minimum first deposit to prevent first-depositor griefing.
    uint256 public constant MIN_INITIAL_DEPOSIT = 1e12;

    /// @notice Epoch duration in seconds. Penalties flush at epoch boundary even if below threshold.
    uint256 public immutable epochDuration;
    /// @notice Timestamp when penalties were last flushed at epoch boundary.
    uint256 public lastEpochFlushAt;

    /// @notice Global accumulated rewards per share, scaled by 1e18.
    uint256 public accRewardPerShare;
    /// @notice Rewards notified but not yet distributed (when totalDeposits was 0).
    uint256 public pendingRewards;
    /// @notice Penalties from instant exit; flushed when >= MIN_PENALTY_FLUSH to avoid dust rounding.
    uint256 public pendingPenalties;
    /// @notice Total xK613 deposited by all users.
    uint256 public totalDeposits;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardDebt;
    mapping(address => uint256) public userPendingRewards;

    /// @notice Staking contract; receives REWARDS_NOTIFIER_ROLE for penalty rewards.
    address public staking;

    event Claimed(address indexed account, uint256 amount);
    event RewardNotified(uint256 amount);
    event StakingUpdated(address indexed staking);
    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event PenaltyAdded(uint256 amount);
    event EpochAdvanced(uint256 timestamp);

    constructor(address xk613Token, uint256 epochDuration_) {
        if (xk613Token == address(0)) revert ZeroAddress();
        if (epochDuration_ == 0) revert InvalidEpochDuration();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        xk613 = IERC20(xk613Token);
        epochDuration = epochDuration_;
        lastEpochFlushAt = block.timestamp;
    }

    /// @notice Sets the staking contract. Grants REWARDS_NOTIFIER_ROLE for penalty rewards. Pass address(0) to disable.
    function setStaking(address staking_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(staking) != address(0)) {
            _revokeRole(REWARDS_NOTIFIER_ROLE, address(staking));
        }
        staking = staking_;
        if (staking_ != address(0)) {
            _grantRole(REWARDS_NOTIFIER_ROLE, staking_);
        }
        emit StakingUpdated(staking_);
    }

    /// @notice Deposits xK613 to earn rewards. Caller must approve this contract first.
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (totalDeposits == 0 && amount < MIN_INITIAL_DEPOSIT) revert MinimumInitialDeposit();
        _updateUser(msg.sender);
        balanceOf[msg.sender] += amount;
        totalDeposits += amount;
        userRewardDebt[msg.sender] = (balanceOf[msg.sender] * accRewardPerShare) / 1e18;
        xk613.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount);
    }

    /// @notice Withdraws xK613. Must withdraw from RD before initiating exit in Staking.
    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        _updateUser(msg.sender);
        balanceOf[msg.sender] -= amount;
        totalDeposits -= amount;
        userRewardDebt[msg.sender] = (balanceOf[msg.sender] * accRewardPerShare) / 1e18;
        xk613.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Claims accumulated rewards.
    function claim() external nonReentrant whenNotPaused {
        _updateUser(msg.sender);
        uint256 reward = userPendingRewards[msg.sender];
        if (reward == 0) revert NoRewards();
        userPendingRewards[msg.sender] = 0;
        xk613.safeTransfer(msg.sender, reward);
        emit Claimed(msg.sender, reward);
    }

    /// @notice Notifies new rewards. Called by Treasury.
    function notifyReward(uint256 amount) external nonReentrant onlyRole(REWARDS_NOTIFIER_ROLE) whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (totalDeposits == 0) {
            pendingRewards += amount;
            return;
        }
        accRewardPerShare += (amount * 1e18) / totalDeposits;
        emit RewardNotified(amount);
    }

    /// @notice Adds instant-exit penalty; accumulates until MIN_PENALTY_FLUSH, then distributes. Called by Staking.
    function addPendingPenalty(uint256 amount) external nonReentrant onlyRole(REWARDS_NOTIFIER_ROLE) whenNotPaused {
        if (amount == 0) return;
        pendingPenalties += amount;
        emit PenaltyAdded(amount);
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

    /// @notice Triggers flush of pending rewards and penalties. Anyone can call to advance epoch.
    function advanceEpoch() external nonReentrant whenNotPaused {
        if (totalDeposits > 0) _distributePending();
    }

    /// @notice Returns the timestamp when the current epoch ends (or 0 if no epochs).
    function nextEpochAt() external view returns (uint256) {
        return lastEpochFlushAt + epochDuration;
    }

    function _updateUser(address user) internal {
        _distributePending();
        uint256 bal = balanceOf[user];
        uint256 accumulated = (bal * accRewardPerShare) / 1e18;
        if (accumulated > userRewardDebt[user]) {
            userPendingRewards[user] += (accumulated - userRewardDebt[user]);
        }
        userRewardDebt[user] = accumulated;
    }

    function _distributePending() internal {
        if (totalDeposits == 0) return;
        if (pendingRewards > 0) {
            uint256 amount = pendingRewards;
            pendingRewards = 0;
            accRewardPerShare += (amount * 1e18) / totalDeposits;
            emit RewardNotified(amount);
        }
        bool epochPassed = block.timestamp >= lastEpochFlushAt + epochDuration;
        bool shouldFlushPenalties = pendingPenalties >= MIN_PENALTY_FLUSH || (pendingPenalties > 0 && epochPassed);
        if (shouldFlushPenalties) {
            uint256 amount = pendingPenalties;
            pendingPenalties = 0;
            accRewardPerShare += (amount * 1e18) / totalDeposits;
            emit RewardNotified(amount);
            if (epochPassed) {
                lastEpochFlushAt = block.timestamp;
                emit EpochAdvanced(block.timestamp);
            }
        }
    }

    /// @notice Returns pending rewards for an account.
    function pendingRewardsOf(address account) external view returns (uint256) {
        if (totalDeposits == 0) return userPendingRewards[account];
        uint256 accReward = accRewardPerShare;
        if (pendingRewards > 0) {
            accReward += (pendingRewards * 1e18) / totalDeposits;
        }
        bool epochPassed = block.timestamp >= lastEpochFlushAt + epochDuration;
        bool wouldFlushPenalties = pendingPenalties >= MIN_PENALTY_FLUSH || (pendingPenalties > 0 && epochPassed);
        if (wouldFlushPenalties) {
            accReward += (pendingPenalties * 1e18) / totalDeposits;
        }
        uint256 bal = balanceOf[account];
        uint256 accumulated = (bal * accReward) / 1e18;
        uint256 pending = accumulated > userRewardDebt[account] ? accumulated - userRewardDebt[account] : 0;
        return userPendingRewards[account] + pending;
    }
}
