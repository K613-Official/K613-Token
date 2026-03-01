// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface IStaking {
    function stake(uint256 amount) external;
    function exitQueueLength(address user) external view returns (uint256);
}

/// @title RewardsDistributor
/// @notice Users deposit xK613 (stakingToken) to earn rewards in xK613 (rewardToken). Claim anytime. Penalties from instant exit are staked to get xK613, then distributed. Rewards can be converted to K613 via Staking instant exit (50% penalty).
contract RewardsDistributor is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error NoRewards();
    error InsufficientBalance();
    error InvalidEpochDuration();
    error MinimumInitialDeposit();
    error MinimumNotify();
    /// @notice Thrown when advanceEpoch() is called before the current epoch has ended.
    error EpochNotReady();
    /// @notice Thrown when claim() is called while the user has an active exit vesting in Staking.
    error ExitVestingActive();

    /// @notice Staking token (xK613): users deposit this to earn rewards.
    IERC20 public immutable stakingToken;
    /// @notice Reward token (xK613): rewards are paid out in xK613. Same token as stakingToken.
    IERC20 public immutable rewardToken;
    /// @notice K613 token; used to stake penalty K613 in Staking to get xK613 for distribution.
    IERC20 public immutable k613;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant REWARDS_NOTIFIER_ROLE = keccak256("REWARDS_NOTIFIER_ROLE");

    /// @notice Scale for accRewardPerShare and reward math
    uint256 private constant PRECISION = 1e18;
    uint256 public constant MIN_PENALTY_FLUSH = 1e18;
    /// @notice Minimum first deposit to prevent first-depositor griefing.
    uint256 public constant MIN_INITIAL_DEPOSIT = 1e12;
    /// @notice Minimum amount per notifyReward to avoid precision loss and notify spam.
    uint256 public constant MIN_NOTIFY = 1e12;

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
    /// @notice Total stakingToken (xK613) deposited by all users.
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

    constructor(address stakingToken_, address rewardToken_, address k613_, uint256 epochDuration_) {
        if (stakingToken_ == address(0) || rewardToken_ == address(0) || k613_ == address(0)) revert ZeroAddress();
        if (epochDuration_ == 0) revert InvalidEpochDuration();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        stakingToken = IERC20(stakingToken_);
        rewardToken = IERC20(rewardToken_);
        k613 = IERC20(k613_);
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
        userRewardDebt[msg.sender] = (balanceOf[msg.sender] * accRewardPerShare) / PRECISION;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount);
    }

    /// @notice Withdraws xK613. Must withdraw from RD before initiating exit in Staking.
    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        _updateUser(msg.sender);
        balanceOf[msg.sender] -= amount;
        totalDeposits -= amount;
        userRewardDebt[msg.sender] = (balanceOf[msg.sender] * accRewardPerShare) / PRECISION;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Claims accumulated rewards. Reverts while caller has an active exit vesting in Staking (withdraw from RD first, then exit; no claim during vesting).
    function claim() external nonReentrant whenNotPaused {
        if (address(staking) != address(0) && IStaking(staking).exitQueueLength(msg.sender) > 0) {
            revert ExitVestingActive();
        }
        _stakeHeldK613();
        _updateUser(msg.sender);
        uint256 reward = userPendingRewards[msg.sender];
        if (reward == 0) revert NoRewards();
        userPendingRewards[msg.sender] = 0;
        rewardToken.safeTransfer(msg.sender, reward);
        emit Claimed(msg.sender, reward);
    }

    /// @notice Notifies new rewards in xK613. Caller must have transferred rewardToken (xK613) to this contract first.
    function notifyReward(uint256 amount) external nonReentrant onlyRole(REWARDS_NOTIFIER_ROLE) whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (amount < MIN_NOTIFY) revert MinimumNotify();
        if (totalDeposits == 0) {
            pendingRewards += amount;
            return;
        }
        accRewardPerShare += (amount * PRECISION) / totalDeposits;
        emit RewardNotified(amount);
    }

    /// @notice Receives K613 penalty from Staking; adds to pending penalties. K613 is staked to xK613 on next claim/advanceEpoch to avoid reentrancy (Staking calls this).
    function addPendingPenalty(uint256 amount) external nonReentrant onlyRole(REWARDS_NOTIFIER_ROLE) whenNotPaused {
        if (amount == 0) return;
        pendingPenalties += amount;
        emit PenaltyAdded(amount);
    }

    /// @notice Stakes any K613 held by this contract to get xK613
    function _stakeHeldK613() internal {
        if (address(staking) == address(0)) return;
        uint256 balance = k613.balanceOf(address(this));
        if (balance < 1) return;
        k613.forceApprove(address(staking), balance);
        IStaking(staking).stake(balance);
        k613.forceApprove(address(staking), 0);
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

    /// @notice Advances the epoch: flushes pending rewards/penalties.
    function advanceEpoch() external nonReentrant whenNotPaused {
        _stakeHeldK613();
        if (block.timestamp < lastEpochFlushAt + epochDuration) revert EpochNotReady();
        if (totalDeposits > 0) _distributePending();
    }

    /// @notice Returns the timestamp when the current epoch ends (or 0 if no epochs).
    function nextEpochAt() external view returns (uint256) {
        return lastEpochFlushAt + epochDuration;
    }

    function _updateUser(address user) internal {
        _distributePending();
        uint256 bal = balanceOf[user];
        uint256 accumulated = (bal * accRewardPerShare) / PRECISION;
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
            accRewardPerShare += (amount * PRECISION) / totalDeposits;
            emit RewardNotified(amount);
        }
        bool epochPassed = block.timestamp >= lastEpochFlushAt + epochDuration;
        bool shouldFlushPenalties = pendingPenalties >= MIN_PENALTY_FLUSH || (pendingPenalties > 0 && epochPassed);
        if (shouldFlushPenalties) {
            uint256 amount = pendingPenalties;
            pendingPenalties = 0;
            accRewardPerShare += (amount * PRECISION) / totalDeposits;
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
            accReward += (pendingRewards * PRECISION) / totalDeposits;
        }
        bool epochPassed = block.timestamp >= lastEpochFlushAt + epochDuration;
        bool wouldFlushPenalties = pendingPenalties >= MIN_PENALTY_FLUSH || (pendingPenalties > 0 && epochPassed);
        if (wouldFlushPenalties) {
            accReward += (pendingPenalties * PRECISION) / totalDeposits;
        }
        uint256 bal = balanceOf[account];
        uint256 accumulated = (bal * accReward) / PRECISION;
        uint256 pending = accumulated > userRewardDebt[account] ? accumulated - userRewardDebt[account] : 0;
        return userPendingRewards[account] + pending;
    }
}
