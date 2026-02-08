// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title RewardsDistributor
/// @notice Aave-style: rewards accrue to xK613 holders directly. No deposit. xK613 calls handleAction on every transfer/mint/burn.
/// @dev handleAction updates user reward accounting. notifyReward (penalties + buybacks) increases accRewardPerShare.
/// @custom:source handleAction pattern from Aave RewardsController (lib/L2-Protocol/src/contracts/rewards/RewardsController.sol)
contract RewardsDistributor is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error NoRewards();
    error OnlyXK613();

    IERC20 public immutable xk613;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant REWARDS_NOTIFIER_ROLE = keccak256("REWARDS_NOTIFIER_ROLE");

    uint256 public accRewardPerShare;
    uint256 public pendingRewards;

    mapping(address => uint256) public userRewardDebt;
    mapping(address => uint256) public userPendingRewards;

    event Claimed(address indexed account, uint256 amount);
    event RewardNotified(uint256 amount);
    event StakingUpdated(address indexed staking);

    address public staking;

    constructor(address xk613Token) {
        if (xk613Token == address(0)) {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        xk613 = IERC20(xk613Token);
    }

    /// @notice Sets the staking contract as REWARDS_NOTIFIER (receives instant exit penalties).
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

    /// @param user Address whose xK613 balance changed.
    /// @param totalSupply xK613 total supply after the change.
    /// @param userBalance User's xK613 balance after the change.
    function handleAction(address user, uint256 totalSupply, uint256 userBalance) external whenNotPaused {
        if (msg.sender != address(xk613)) {
            revert OnlyXK613();
        }
        _distributePending(totalSupply);
        uint256 accumulated = (userBalance * accRewardPerShare) / 1e18;
        if (accumulated > userRewardDebt[user]) {
            userPendingRewards[user] += (accumulated - userRewardDebt[user]);
        }
        userRewardDebt[user] = accumulated;
    }

    /// @notice Claims accumulated rewards in xK613.
    function claim() external nonReentrant whenNotPaused {
        uint256 totalSupply = xk613.totalSupply();
        uint256 userBalance = xk613.balanceOf(msg.sender);
        _distributePending(totalSupply);
        uint256 accumulated = (userBalance * accRewardPerShare) / 1e18;
        if (accumulated > userRewardDebt[msg.sender]) {
            userPendingRewards[msg.sender] += (accumulated - userRewardDebt[msg.sender]);
        }
        userRewardDebt[msg.sender] = accumulated;

        uint256 reward = userPendingRewards[msg.sender];
        if (reward == 0) {
            revert NoRewards();
        }
        userPendingRewards[msg.sender] = 0;
        xk613.safeTransfer(msg.sender, reward);
        emit Claimed(msg.sender, reward);
    }

    /// @notice Notifies new rewards. Called by Treasury and Staking (REWARDS_NOTIFIER_ROLE).
    function notifyReward(uint256 amount) external onlyRole(REWARDS_NOTIFIER_ROLE) whenNotPaused {
        if (amount == 0) {
            revert ZeroAmount();
        }
        uint256 totalSupply = xk613.totalSupply();
        if (totalSupply == 0) {
            pendingRewards += amount;
            return;
        }
        accRewardPerShare += (amount * 1e18) / totalSupply;
        emit RewardNotified(amount);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function _distributePending(uint256 totalSupply) internal {
        if (pendingRewards == 0 || totalSupply == 0) {
            return;
        }
        uint256 amount = pendingRewards;
        pendingRewards = 0;
        accRewardPerShare += (amount * 1e18) / totalSupply;
        emit RewardNotified(amount);
    }

    /// @notice Returns pending rewards for an account (view only, does not update state).
    function pendingRewardsOf(address account) external view returns (uint256) {
        uint256 totalSupply = xk613.totalSupply();
        if (totalSupply == 0) {
            return userPendingRewards[account];
        }
        uint256 accReward = accRewardPerShare;
        if (pendingRewards > 0) {
            accReward += (pendingRewards * 1e18) / totalSupply;
        }
        uint256 accumulated = (xk613.balanceOf(account) * accReward) / 1e18;
        uint256 pending = accumulated > userRewardDebt[account] ? accumulated - userRewardDebt[account] : 0;
        return userPendingRewards[account] + pending;
    }
}
