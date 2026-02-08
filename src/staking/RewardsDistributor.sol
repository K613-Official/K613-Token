// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title RewardsDistributor
/// @notice Distributes xK613 rewards to depositors proportionally. Uses accumulator-based reward math.
/// @dev Users deposit xK613 to earn rewards. Treasury and Staking notify rewards; users claim via claim().
contract RewardsDistributor is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Thrown when a zero address is passed as a parameter.
    error ZeroAddress();
    /// @notice Thrown when amount is zero where a positive value is required.
    error ZeroAmount();
    /// @notice Thrown when withdraw amount exceeds user balance.
    error InsufficientBalance();
    /// @notice Thrown when claim is called but user has no pending rewards.
    error NoRewards();

    IERC20 public immutable xk613;
    address public staking;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant REWARDS_NOTIFIER_ROLE = keccak256("REWARDS_NOTIFIER_ROLE");

    /// @notice Accumulated reward per share (scaled by 1e18).
    uint256 public accRewardPerShare;
    /// @notice Rewards notified but not yet distributed (no depositors).
    uint256 public pendingRewards;
    /// @notice Total xK613 deposited across all users.
    uint256 public totalDeposits;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardDebt;
    mapping(address => uint256) public userPendingRewards;

    /// @notice Emitted when a user deposits xK613.
    /// @param account Depositor address.
    /// @param amount Amount deposited.
    event Deposited(address indexed account, uint256 amount);
    /// @notice Emitted when a user withdraws xK613.
    /// @param account Withdrawer address.
    /// @param amount Amount withdrawn.
    event Withdrawn(address indexed account, uint256 amount);
    /// @notice Emitted when a user claims rewards.
    /// @param account Claimant address.
    /// @param amount Amount claimed.
    event Claimed(address indexed account, uint256 amount);
    /// @notice Emitted when new rewards are notified/distributed.
    /// @param amount Amount of rewards.
    event RewardNotified(uint256 amount);
    /// @notice Emitted when the staking contract (REWARDS_NOTIFIER) is updated.
    /// @param staking New staking address.
    event StakingUpdated(address indexed staking);

    /// @notice Deploys the RewardsDistributor.
    /// @param xk613Token Address of the xK613 token.
    constructor(address xk613Token) {
        if (xk613Token == address(0)) {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        xk613 = IERC20(xk613Token);
    }

    /// @notice Sets the staking contract as REWARDS_NOTIFIER (receives instant exit penalties).
    /// @param staking_ Address of the Staking contract.
    function setStaking(address staking_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (staking_ == address(0)) {
            revert ZeroAddress();
        }
        if (staking != address(0)) {
            _revokeRole(REWARDS_NOTIFIER_ROLE, staking);
        }
        staking = staking_;
        _grantRole(REWARDS_NOTIFIER_ROLE, staking_);
        emit StakingUpdated(staking_);
    }

    /// @notice Deposits xK613 to earn rewards.
    /// @param amount Amount of xK613 to deposit.
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) {
            revert ZeroAmount();
        }
        _updateUser(msg.sender);
        totalDeposits += amount;
        balanceOf[msg.sender] += amount;
        userRewardDebt[msg.sender] = (balanceOf[msg.sender] * accRewardPerShare) / 1e18;
        xk613.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount);
    }

    /// @notice Withdraws xK613 from the distributor.
    /// @param amount Amount of xK613 to withdraw.
    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) {
            revert ZeroAmount();
        }
        uint256 balance = balanceOf[msg.sender];
        if (balance < amount) {
            revert InsufficientBalance();
        }
        _updateUser(msg.sender);
        balanceOf[msg.sender] = balance - amount;
        totalDeposits -= amount;
        userRewardDebt[msg.sender] = (balanceOf[msg.sender] * accRewardPerShare) / 1e18;
        xk613.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Claims accumulated rewards.
    function claim() external nonReentrant whenNotPaused {
        _updateUser(msg.sender);
        uint256 reward = userPendingRewards[msg.sender];
        if (reward == 0) {
            revert NoRewards();
        }
        userPendingRewards[msg.sender] = 0;
        xk613.safeTransfer(msg.sender, reward);
        emit Claimed(msg.sender, reward);
    }

    /// @notice Notifies new rewards. Called by Treasury and Staking (REWARDS_NOTIFIER_ROLE).
    /// @param amount Amount of xK613 rewards to distribute.
    function notifyReward(uint256 amount) external onlyRole(REWARDS_NOTIFIER_ROLE) whenNotPaused {
        if (amount == 0) {
            revert ZeroAmount();
        }
        if (totalDeposits == 0) {
            pendingRewards += amount;
            return;
        }
        accRewardPerShare += (amount * 1e18) / totalDeposits;
        emit RewardNotified(amount);
    }

    /// @notice Pauses deposit, withdraw, claim, and notifyReward. Only callable by PAUSER_ROLE.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resumes operations. Only callable by PAUSER_ROLE.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @dev Updates user's reward debt and pending rewards based on accRewardPerShare.
    function _updateUser(address account) internal {
        _distributePending();
        uint256 accumulated = (balanceOf[account] * accRewardPerShare) / 1e18;
        uint256 pending = accumulated - userRewardDebt[account];
        if (pending > 0) {
            userPendingRewards[account] += pending;
        }
        userRewardDebt[account] = accumulated;
    }

    /// @dev Distributes pending rewards into accRewardPerShare when totalDeposits > 0.
    function _distributePending() internal {
        if (pendingRewards == 0 || totalDeposits == 0) {
            return;
        }
        uint256 amount = pendingRewards;
        pendingRewards = 0;
        accRewardPerShare += (amount * 1e18) / totalDeposits;
        emit RewardNotified(amount);
    }
}
