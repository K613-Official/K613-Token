// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStaking} from "./IStaking.sol";

/// @title RewardsDistributor
/// @notice Manual deposit/withdraw: users deposit xK613 to earn rewards. Claim blocked while user has active exit in Staking.
contract RewardsDistributor is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error NoRewards();
    error ExitVestingActive();
    error InsufficientBalance();

    /// @notice xK613 token used for deposits and rewards.
    IERC20 public immutable xk613;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant REWARDS_NOTIFIER_ROLE = keccak256("REWARDS_NOTIFIER_ROLE");

    /// @notice Global accumulated rewards per share, scaled by 1e18.
    uint256 public accRewardPerShare;
    /// @notice Rewards notified but not yet distributed.
    uint256 public pendingRewards;
    /// @notice Total xK613 deposited by all users.
    uint256 public totalDeposits;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardDebt;
    mapping(address => uint256) public userPendingRewards;

    /// @notice Staking contract; used to block claim while user has active exit.
    IStaking public staking;

    event Claimed(address indexed account, uint256 amount);
    event RewardNotified(uint256 amount);
    event StakingUpdated(address indexed staking);
    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);

    constructor(address xk613Token) {
        if (xk613Token == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        xk613 = IERC20(xk613Token);
    }

    /// @notice Sets the staking contract. Grants REWARDS_NOTIFIER_ROLE for penalty rewards. Pass address(0) to disable.
    function setStaking(address staking_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(staking) != address(0)) {
            _revokeRole(REWARDS_NOTIFIER_ROLE, address(staking));
        }
        staking = IStaking(staking_);
        if (staking_ != address(0)) {
            _grantRole(REWARDS_NOTIFIER_ROLE, staking_);
        }
        emit StakingUpdated(staking_);
    }

    /// @notice Deposits xK613 to earn rewards. Caller must approve this contract first.
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
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

    /// @notice Claims accumulated rewards. Reverts if user has active exit in Staking.
    function claim() external nonReentrant whenNotPaused {
        // aderyn-fp-next-line(reentrancy-state-change)
        if (address(staking) != address(0) && staking.exitQueueLength(msg.sender) > 0) {
            revert ExitVestingActive();
        }
        _updateUser(msg.sender);
        uint256 reward = userPendingRewards[msg.sender];
        if (reward == 0) revert NoRewards();
        userPendingRewards[msg.sender] = 0;
        xk613.safeTransfer(msg.sender, reward);
        emit Claimed(msg.sender, reward);
    }

    /// @notice Notifies new rewards. Called by Treasury or Staking (penalties).
    function notifyReward(uint256 amount) external nonReentrant onlyRole(REWARDS_NOTIFIER_ROLE) whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (totalDeposits == 0) {
            pendingRewards += amount;
            return;
        }
        accRewardPerShare += (amount * 1e18) / totalDeposits;
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
        if (pendingRewards == 0 || totalDeposits == 0) return;
        uint256 amount = pendingRewards;
        pendingRewards = 0;
        accRewardPerShare += (amount * 1e18) / totalDeposits;
        emit RewardNotified(amount);
    }

    /// @notice Returns pending rewards. Returns 0 if user has active exit in Staking.
    function pendingRewardsOf(address account) external view returns (uint256) {
        if (address(staking) != address(0) && staking.exitQueueLength(account) > 0) return 0;
        if (totalDeposits == 0) return userPendingRewards[account];
        uint256 accReward = accRewardPerShare;
        if (pendingRewards > 0) {
            accReward += (pendingRewards * 1e18) / totalDeposits;
        }
        uint256 bal = balanceOf[account];
        uint256 accumulated = (bal * accReward) / 1e18;
        uint256 pending = accumulated > userRewardDebt[account] ? accumulated - userRewardDebt[account] : 0;
        return userPendingRewards[account] + pending;
    }
}
