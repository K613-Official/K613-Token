// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title RewardsDistributor
/// @notice Deposit/withdraw model: users deposit xK613, rewards accrue proportionally. exitPending excluded from accrual.
/// @dev Staking calls depositFor, addExitPending, removeExitPending, withdrawFor. claim blocked when exitPending > 0.
contract RewardsDistributor is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error NoRewards();
    error ExitPending();
    error InsufficientBalance();

    IERC20 public immutable xk613;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant REWARDS_NOTIFIER_ROLE = keccak256("REWARDS_NOTIFIER_ROLE");
    bytes32 public constant STAKING_ROLE = keccak256("STAKING_ROLE");

    uint256 public accRewardPerShare;
    uint256 public pendingRewards;
    uint256 public totalDeposits;
    uint256 public totalExitPending;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public exitPending;
    mapping(address => uint256) public userRewardDebt;
    mapping(address => uint256) public userPendingRewards;

    address public staking;

    event Claimed(address indexed account, uint256 amount);
    event RewardNotified(uint256 amount);
    event StakingUpdated(address indexed staking);
    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event ExitPendingAdded(address indexed account, uint256 amount);
    event ExitPendingRemoved(address indexed account, uint256 amount);

    constructor(address xk613Token) {
        if (xk613Token == address(0)) {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        xk613 = IERC20(xk613Token);
    }

    /// @notice Sets the staking contract. Grants STAKING_ROLE and REWARDS_NOTIFIER_ROLE.
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

    /// @notice Called by Staking when user stakes. Expects xK613 minted to this contract first.
    function depositFor(address user, uint256 amount) external onlyRole(STAKING_ROLE) whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        _updateUser(user);
        balanceOf[user] += amount;
        totalDeposits += amount;
        userRewardDebt[user] = (_effectiveBalance(user) * accRewardPerShare) / 1e18;
        emit Deposited(user, amount);
    }

    /// @notice Called by Staking when user initiates exit. Excludes amount from reward accrual.
    function addExitPending(address user, uint256 amount) external onlyRole(STAKING_ROLE) whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        _updateUser(user);
        exitPending[user] += amount;
        totalExitPending += amount;
        userRewardDebt[user] = (_effectiveBalance(user) * accRewardPerShare) / 1e18;
        emit ExitPendingAdded(user, amount);
    }

    /// @notice Called by Staking when user cancels exit.
    function removeExitPending(address user, uint256 amount) external onlyRole(STAKING_ROLE) whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        _updateUser(user);
        exitPending[user] -= amount;
        totalExitPending -= amount;
        userRewardDebt[user] = (_effectiveBalance(user) * accRewardPerShare) / 1e18;
        emit ExitPendingRemoved(user, amount);
    }

    /// @notice Called by Staking when user exits. Transfers xK613 to Staking.
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

    /// @notice Claims accumulated rewards. Reverts if user has exitPending.
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

    /// @notice Notifies new rewards. Called by Treasury and Staking (penalties).
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

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function _effectiveBalance(address user) internal view returns (uint256) {
        uint256 bal = balanceOf[user];
        uint256 pending = exitPending[user];
        return bal > pending ? bal - pending : 0;
    }

    function _updateUser(address user) internal {
        _distributePending();
        uint256 eff = _effectiveBalance(user);
        uint256 accumulated = (eff * accRewardPerShare) / 1e18;
        if (accumulated > userRewardDebt[user]) {
            userPendingRewards[user] += (accumulated - userRewardDebt[user]);
        }
        userRewardDebt[user] = accumulated;
    }

    function _distributePending() internal {
        uint256 effective = totalDeposits - totalExitPending;
        if (pendingRewards == 0 || effective == 0) return;
        uint256 amount = pendingRewards;
        pendingRewards = 0;
        accRewardPerShare += (amount * 1e18) / effective;
        emit RewardNotified(amount);
    }

    /// @notice Returns pending rewards for an account (0 if exitPending > 0).
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
