// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {xK613} from "../token/xK613.sol";
import {RewardsDistributor} from "./RewardsDistributor.sol";

/// @title Staking
/// @notice Shadow xShadow-style staking: deposit K613, lock for duration, receive xK613. Exit after lock or instant-exit with penalty.
/// @dev Simplified from Shadow (shadow.so/xshadow), no x33. Lock is fixed per deposit.
///      Penalty from instant exit goes to RewardsDistributor as xK613 for stakers.
/// @custom:source Adapted from Shadow xShadow (lib/shadow-core/contracts/xShadow/XShadow.sol)
contract Staking is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Thrown when a zero address is passed as a parameter.
    error ZeroAddress();
    /// @notice Thrown when amount is zero where a positive value is required.
    error ZeroAmount();
    /// @notice Thrown when exit is attempted before the lock period has ended.
    error Locked();
    /// @notice Thrown when instantExit is called but the stake is already unlocked (use exit instead).
    error Unlocked();
    /// @notice Thrown when instant exit penalty exceeds 10000 bps.
    error InvalidBps();
    /// @notice Thrown when user has insufficient staked balance.
    error InsufficientBalance();
    /// @notice Thrown when instantExit is called but RewardsDistributor is not set.
    error RewardsDistributorNotSet();

    /// @notice Represents a user's staked position.
    struct Deposit {
        uint256 amount;
        uint256 depositTimestamp;
    }

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IERC20 public immutable k613;
    xK613 public immutable xk613;

    /// @notice Minimum time (seconds) a stake must remain locked before exit.
    uint256 public immutable lockDuration;
    /// @notice Penalty in basis points (1–10000) applied on instant exit before lock end.
    uint256 public immutable instantExitPenaltyBps;

    RewardsDistributor public rewardsDistributor;
    mapping(address => Deposit) public deposits;

    /// @notice Emitted when a user stakes K613.
    /// @param account Staker address.
    /// @param amount Amount staked.
    /// @param depositTimestamp Timestamp of the stake.
    event Staked(address indexed account, uint256 amount, uint256 depositTimestamp);
    /// @notice Emitted when a user exits after lock period.
    /// @param account Exiter address.
    /// @param amount Amount withdrawn.
    event Exited(address indexed account, uint256 amount);
    /// @notice Emitted when a user performs instant exit (before lock end).
    /// @param account Exiter address.
    /// @param amount Total amount exited.
    /// @param penalty Penalty deducted and sent to RewardsDistributor.
    event InstantExit(address indexed account, uint256 amount, uint256 penalty);
    /// @notice Emitted when the RewardsDistributor address is updated.
    /// @param distributor New RewardsDistributor address.
    event RewardsDistributorUpdated(address indexed distributor);

    /// @notice Deploys the Staking contract.
    /// @param k613Token Address of the K613 token.
    /// @param xk613Token Address of the xK613 token.
    /// @param lockDuration_ Lock duration in seconds.
    /// @param instantExitPenaltyBps_ Instant exit penalty in basis points (max 10000).
    constructor(address k613Token, address xk613Token, uint256 lockDuration_, uint256 instantExitPenaltyBps_) {
        if (k613Token == address(0) || xk613Token == address(0)) {
            revert ZeroAddress();
        }
        if (instantExitPenaltyBps_ > 10_000) {
            revert InvalidBps();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        k613 = IERC20(k613Token);
        xk613 = xK613(xk613Token);
        lockDuration = lockDuration_;
        instantExitPenaltyBps = instantExitPenaltyBps_;
    }

    /// @notice Sets the RewardsDistributor used for instant exit penalties.
    /// @param distributor Address of the RewardsDistributor contract.
    function setRewardsDistributor(address distributor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (distributor == address(0)) {
            revert ZeroAddress();
        }
        rewardsDistributor = RewardsDistributor(distributor);
        emit RewardsDistributorUpdated(distributor);
    }

    /// @notice Stakes K613 and mints xK613 to the caller.
    /// @param amount Amount of K613 to stake.
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) {
            revert ZeroAmount();
        }
        Deposit storage info = deposits[msg.sender];
        info.amount += amount;
        info.depositTimestamp = block.timestamp;
        k613.safeTransferFrom(msg.sender, address(this), amount);
        xk613.mint(msg.sender, amount);
        emit Staked(msg.sender, amount, info.depositTimestamp);
    }

    /// @notice Exits staked position after lock period. Burns xK613 and returns K613.
    function exit() external nonReentrant whenNotPaused {
        Deposit storage info = deposits[msg.sender];
        uint256 amount = info.amount;
        if (amount == 0) {
            revert InsufficientBalance();
        }
        if (block.timestamp < info.depositTimestamp + lockDuration) {
            revert Locked();
        }
        delete deposits[msg.sender];
        xk613.burnFrom(msg.sender, amount);
        k613.safeTransfer(msg.sender, amount);
        emit Exited(msg.sender, amount);
    }

    /// @notice Exits before lock end with penalty. Penalty is sent to RewardsDistributor.
    /// @param amount Amount of K613 (staked) to exit.
    function instantExit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) {
            revert ZeroAmount();
        }
        Deposit storage info = deposits[msg.sender];
        if (info.amount < amount) {
            revert InsufficientBalance();
        }
        if (block.timestamp >= info.depositTimestamp + lockDuration) {
            revert Unlocked();
        }
        if (address(rewardsDistributor) == address(0)) {
            revert RewardsDistributorNotSet();
        }
        info.amount -= amount;
        if (info.amount == 0) {
            info.depositTimestamp = 0;
        }
        uint256 penalty = (amount * instantExitPenaltyBps) / 10_000;
        uint256 payout = amount - penalty;
        xk613.burnFrom(msg.sender, amount);
        if (penalty > 0) {
            xk613.mint(address(rewardsDistributor), penalty);
            rewardsDistributor.notifyReward(penalty);
        }
        k613.safeTransfer(msg.sender, payout);
        emit InstantExit(msg.sender, amount, penalty);
    }

    /// @notice Pauses staking operations. Only callable by PAUSER_ROLE.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resumes staking operations. Only callable by PAUSER_ROLE.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
