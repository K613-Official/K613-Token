// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract RewardsDistributor is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();
    error NoRewards();

    IERC20 public immutable xk613;
    address public staking;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant REWARDS_NOTIFIER_ROLE = keccak256("REWARDS_NOTIFIER_ROLE");

    uint256 public accRewardPerShare;
    uint256 public pendingRewards;
    uint256 public totalDeposits;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardDebt;
    mapping(address => uint256) public userPendingRewards;

    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event Claimed(address indexed account, uint256 amount);
    event RewardNotified(uint256 amount);
    event StakingUpdated(address indexed staking);

    constructor(address xk613Token) {
        if (xk613Token == address(0)) {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        xk613 = IERC20(xk613Token);
    }

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

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function _updateUser(address account) internal {
        _distributePending();
        uint256 accumulated = (balanceOf[account] * accRewardPerShare) / 1e18;
        uint256 pending = accumulated - userRewardDebt[account];
        if (pending > 0) {
            userPendingRewards[account] += pending;
        }
        userRewardDebt[account] = accumulated;
    }

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
