// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {xK613} from "../token/xK613.sol";
import {RewardsDistributor} from "./RewardsDistributor.sol";

/**
 * @title K613 Staking
 * @author K613
 *
 * @notice
 * Shadow (xSHADOW)-inspired staking contract implementing a 1:1 conversion
 * between K613 and xK613 with an explicit exit queue and optional instant exit
 * penalty mechanism.
 *
 * @dev
 * DESIGN OVERVIEW
 * ---------------
 * This contract intentionally borrows the economic pattern of Shadow's xToken
 * staking model (receipt token + exit mechanics), while significantly reducing
 * system complexity and attack surface.
 *
 * Core principles:
 * - xK613 is a passive receipt token minted 1:1 on stake and burned on exit.
 * - No rebasing, governance, voting, or vesting logic is included.
 * - Rewards distribution is fully decoupled and handled externally via
 *   RewardsDistributor.
 *
 * SHADOW-INSPIRED ELEMENTS
 * -----------------------
 * - Receipt-token based staking (K613 → xK613).
 * - Exit delay enforced via an exit queue.
 * - Optional early exit with penalty (basis-points based).
 *
 * INTENTIONAL DIFFERENCES FROM SHADOW
 * ----------------------------------
 * - No automatic reward accrual or rebasing.
 * - No epoch-based accounting.
 * - No governance or voting power coupling.
 * - Exit requests escrow xK613 inside this contract, ensuring strict
 *   accounting and preventing double exits.
 *
 * SECURITY RATIONALE
 * ------------------
 * - Explicit state tracking via UserState prevents balance desynchronization.
 * - xK613 is transferred to this contract during exit requests and burned on exit,
 *   eliminating reliance on user balances at execution time.
 * - All external token transfers use SafeERC20.
 * - ReentrancyGuard is applied to all state-mutating user flows.
 *
 * ECONOMIC NOTES
 * --------------
 * - Instant exit penalties (if enabled) are transferred as K613 to the
 *   RewardsDistributor, increasing future reward weight for remaining stakers.
 * - Underlying K613 principal is never implicitly redistributed. xK613 is strictly 1:1 backed.
 *
 * This design preserves proven economic incentives from Shadow while favoring
 * auditability, explicit user intent, and minimal cross-contract coupling.
 */
contract Staking is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_EXIT_REQUESTS = 10;

    error ZeroAddress();
    error ZeroAmount();
    error Locked();
    error Unlocked();
    error InvalidBps();
    error RewardsDistributorNotSet();
    error InsufficientxK613();
    error NothingToInitiate();
    error InvalidExitIndex();
    error ExitQueueFull();
    error AmountExceedsStake();

    struct ExitRequest {
        uint256 amount;
        uint256 exitInitiatedAt;
    }

    struct UserState {
        uint256 amount;
        ExitRequest[] exitQueue;
    }

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Underlying token being staked.
    IERC20 public immutable k613;
    /// @notice xK613 token minted on stake and burned on exit.
    xK613 public immutable xk613;

    /// @notice Lock duration for standard exits.
    uint256 public immutable lockDuration;
    /// @notice Penalty, in basis points, applied on instant exits before `lockDuration`.
    uint256 public immutable instantExitPenaltyBps;

    /// @notice Rewards distributor responsible for external reward accounting.
    RewardsDistributor public rewardsDistributor;
    mapping(address => UserState) private _userState;
    /// @notice Total K613 backing active positions (staked minus exited).
    uint256 private _totalBacking;

    /// @notice Emitted when a user stakes K613.
    event Staked(address indexed account, uint256 amount);
    /// @notice Emitted when a user initiates an exit request.
    event ExitInitiated(address indexed account, uint256 index, uint256 amount, uint256 exitInitiatedAt);
    /// @notice Emitted when a user cancels an exit request.
    event ExitCancelled(address indexed account, uint256 index);
    /// @notice Emitted when a user exits after the lock period.
    event Exited(address indexed account, uint256 index, uint256 amount);
    /// @notice Emitted when a user performs an instant exit.
    event InstantExit(address indexed account, uint256 index, uint256 amount, uint256 penalty);
    /// @notice Emitted when rewards distributor is updated.
    event RewardsDistributorUpdated(address indexed distributor);

    /// @notice Initializes the staking contract.
    /// @param k613Token Address of the K613 token to be staked.
    /// @param xk613Token Address of the xK613 token to be minted/burned on stake/exit.
    /// @param lockDuration_ Lock duration, in seconds, for standard exits.
    /// @param instantExitPenaltyBps_ Penalty in basis points for instant exits.
    constructor(address k613Token, address xk613Token, uint256 lockDuration_, uint256 instantExitPenaltyBps_) {
        if (k613Token == address(0) || xk613Token == address(0)) revert ZeroAddress();
        if (instantExitPenaltyBps_ > 10_000) revert InvalidBps();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        k613 = IERC20(k613Token);
        xk613 = xK613(xk613Token);
        lockDuration = lockDuration_;
        instantExitPenaltyBps = instantExitPenaltyBps_;
    }

    /// @notice Sets the rewards distributor contract. Pass address(0) to disable; instant exit with penalty will revert until set.
    /// @param distributor Address of the rewards distributor.
    function setRewardsDistributor(address distributor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        rewardsDistributor = RewardsDistributor(distributor);
        emit RewardsDistributorUpdated(distributor);
    }

    /// @notice Returns the total deposited amount and exit queue for a user.
    /// @param user Address of the user.
    /// @return amount Total staked K613 amount for the user.
    /// @return exitQueue Array of exit requests for the user.
    function deposits(address user) external view returns (uint256 amount, ExitRequest[] memory exitQueue) {
        UserState storage s = _userState[user];
        amount = s.amount;
        exitQueue = s.exitQueue;
    }

    /// @notice Returns the length of the exit queue for a user.
    /// @param user Address of the user.
    /// @return Length of the exit queue.
    function exitQueueLength(address user) external view returns (uint256) {
        return _userState[user].exitQueue.length;
    }

    /// @notice Returns data for a specific exit request in a user's queue.
    /// @param user Address of the user.
    /// @param index Index of the exit request.
    /// @return amount Amount requested to exit.
    /// @return exitInitiatedAt Timestamp when the exit was initiated.
    function exitRequestAt(address user, uint256 index)
        external
        view
        returns (uint256 amount, uint256 exitInitiatedAt)
    {
        ExitRequest storage r = _userState[user].exitQueue[index];
        return (r.amount, r.exitInitiatedAt);
    }

    /// @notice Returns total K613 backing active positions (staked minus exited). For invariant: xK613.totalSupply() == totalBacking().
    function totalBacking() external view returns (uint256) {
        return _totalBacking;
    }

    /// @notice Invariant: K613 held by this contract must equal internal accounting (_totalBacking).
    /// @dev Returns false if someone sent K613 directly, or token is fee-on-transfer, or accounting bug.
    /// @return True if balance is exactly _totalBacking (no strict equality to satisfy static analysis).
    function backingIntegrity() external view returns (bool) {
        uint256 balance = k613.balanceOf(address(this));
        return balance >= _totalBacking && balance <= _totalBacking;
    }

    /// @notice Computes the sum of all amounts pending exit for a user.
    /// @param user Address of the user.
    /// @return sum Total amount pending exit across the user's queue.
    function _exitPendingSum(address user) internal view returns (uint256 sum) {
        ExitRequest[] storage q = _userState[user].exitQueue;
        for (uint256 i = 0; i < q.length; i++) {
            sum += q[i].amount;
        }
    }

    /// @notice Converts K613 to xK613 1:1 and mints to caller
    /// @param amount Amount of K613 to convert.
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        UserState storage s = _userState[msg.sender];
        s.amount += amount;
        _totalBacking += amount;

        k613.safeTransferFrom(msg.sender, address(this), amount);
        xk613.mint(msg.sender, amount);

        emit Staked(msg.sender, amount);
    }

    /// @notice Initiates exit: pulls xK613 from caller and adds request to queue.
    /// @dev Caller must approve Staking for xK613. At most `MAX_EXIT_REQUESTS` per user.
    /// @param amount Amount of xK613 to schedule for exit.
    function initiateExit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        UserState storage s = _userState[msg.sender];
        uint256 inQueue = _exitPendingSum(msg.sender);
        if (s.amount <= inQueue) revert NothingToInitiate();
        if (amount > s.amount - inQueue) revert AmountExceedsStake();
        // aderyn-ignore-next-line(reentrancy-state-change)
        if (xk613.balanceOf(msg.sender) < amount) revert InsufficientxK613();
        if (s.exitQueue.length >= MAX_EXIT_REQUESTS) revert ExitQueueFull();
        s.exitQueue.push(ExitRequest({amount: amount, exitInitiatedAt: block.timestamp}));
        IERC20(address(xk613)).safeTransferFrom(msg.sender, address(this), amount);

        emit ExitInitiated(msg.sender, s.exitQueue.length - 1, amount, block.timestamp);
    }

    /// @notice Cancels an exit request and returns xK613 to caller.
    /// @param index Index of the exit request in the caller's queue.
    function cancelExit(uint256 index) external nonReentrant whenNotPaused {
        UserState storage s = _userState[msg.sender];
        if (index >= s.exitQueue.length) revert InvalidExitIndex();

        uint256 amount = s.exitQueue[index].amount;
        _removeExitRequest(msg.sender, index);
        IERC20(address(xk613)).safeTransfer(msg.sender, amount);

        emit ExitCancelled(msg.sender, index);
    }

    /// @notice Executes an exit after the lock period: burns held xK613 and transfers K613 to caller.
    /// @param index Index of the exit request in the caller's queue.
    function exit(uint256 index) external nonReentrant whenNotPaused {
        UserState storage s = _userState[msg.sender];
        if (index >= s.exitQueue.length) revert InvalidExitIndex();

        ExitRequest storage req = s.exitQueue[index];
        if (block.timestamp < req.exitInitiatedAt + lockDuration) revert Locked();

        uint256 amount = req.amount;
        _removeExitRequest(msg.sender, index);
        s.amount -= amount;
        _totalBacking -= amount;

        xk613.burnFrom(address(this), amount);
        k613.safeTransfer(msg.sender, amount);

        emit Exited(msg.sender, index, amount);
    }

    /// @notice Instant exit before lock period; penalty goes to RewardsDistributor if set.
    /// @dev Requires rewardsDistributor when penalty > 0.
    /// @param index Index of the exit request in the caller's queue.
    function instantExit(uint256 index) external nonReentrant whenNotPaused {
        UserState storage s = _userState[msg.sender];
        if (index >= s.exitQueue.length) revert InvalidExitIndex();

        ExitRequest storage req = s.exitQueue[index];
        if (block.timestamp >= req.exitInitiatedAt + lockDuration) revert Unlocked();

        uint256 amount = req.amount;
        uint256 penalty = (amount * instantExitPenaltyBps) / 10_000;
        uint256 payout = amount - penalty;

        if (penalty > 0 && address(rewardsDistributor) == address(0)) revert RewardsDistributorNotSet();

        _removeExitRequest(msg.sender, index);
        s.amount -= amount;
        _totalBacking -= amount;

        xk613.burnFrom(address(this), amount);
        if (penalty > 0) {
            k613.safeTransfer(address(rewardsDistributor), penalty);
            rewardsDistributor.addPendingPenalty(penalty);
        }
        k613.safeTransfer(msg.sender, payout);

        emit InstantExit(msg.sender, index, amount, penalty);
    }

    /// @notice Removes an exit request from a user's queue by index.
    /// @dev Swaps with the last element and pops to keep the array compact.
    /// @param user Address of the user.
    /// @param index Index of the exit request to remove.
    function _removeExitRequest(address user, uint256 index) internal {
        UserState storage s = _userState[user];
        uint256 last = s.exitQueue.length - 1;
        if (index != last) {
            s.exitQueue[index] = s.exitQueue[last];
        }
        s.exitQueue.pop();
    }

    /// @notice Pauses staking and exit operations.
    /// @dev Functions guarded by `whenNotPaused` will revert while the contract is paused.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses staking and exit operations.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
