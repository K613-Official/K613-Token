// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {xK613} from "../token/xK613.sol";
import {RewardsDistributor, IStaking} from "./RewardsDistributor.sol";

/**
 * @title K613 Staking V2
 * @author K613
 *
 * @notice
 * Shadow (xSHADOW)-inspired staking contract implementing a 1:1 conversion
 * between K613 and xK613 with an explicit exit queue and optional instant exit
 * penalty mechanism.
 */
/// @dev Inherits `IStaking` — the hand-written interface RewardsDistributor uses to call back
///      into staking. RD is already deployed and cannot be changed, so that interface stays as it
///      is; inheriting it here at least makes the compiler prove V2 satisfies what RD expects,
///      instead of the two agreeing only by convention until a call reverts on-chain.
contract StakingV2 is IStaking, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public maxExitRequests;
    uint256 public constant MAX_BASIS_POINTS = 10_000;

    /// @notice Thrown when a zero address is passed where a non-zero address is required.
    error ZeroAddress();
    /// @notice Thrown when a zero amount is passed where a positive amount is required.
    error ZeroAmount();
    /// @notice Thrown when attempting to exit before the lock duration has passed.
    error Locked();
    /// @notice Thrown when attempting an instant exit after the lock duration has already passed.
    error Unlocked();
    /// @notice Thrown when the instant exit penalty basis points exceed MAX_BASIS_POINTS.
    error InvalidBps();
    /// @notice Thrown when an instant exit with a non-zero penalty is attempted without a rewards distributor set.
    error RewardsDistributorNotSet();
    /// @notice Thrown when the caller does not hold enough xK613 to cover the requested exit amount.
    error InsufficientxK613();
    /// @notice Thrown when an invalid exit queue index is provided.
    error InvalidExitIndex();
    /// @notice Thrown when the user's exit queue has reached maxExitRequests.
    error ExitQueueFull();
    /// @notice Thrown when lockDuration is zero.
    error InvalidLockDuration();
    /// @notice Thrown when maxExitRequests is zero.
    error InvalidMaxExitRequests();

    /// @notice Exit request struct
    struct ExitRequest {
        uint256 amount;
        uint256 exitInitiatedAt;
    }

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Underlying token being staked
    IERC20 public immutable k613;
    /// @notice xK613 token minted on stake and burned on exit
    xK613 public immutable xk613;

    /// @notice Lock duration for standard exits
    uint256 public immutable lockDuration;
    /// @notice Penalty, in basis points, applied on instant exits before `lockDuration`
    uint256 public instantExitPenaltyBps;

    /// @notice Rewards distributor responsible for external reward accounting
    RewardsDistributor public rewardsDistributor;
    /// @notice Per-user queue of pending exit requests. Liquid (non-queued) balance lives
    ///         entirely on the xK613 token — there is no separate position record.
    /// @dev Written in `initiateExit` via a storage pointer (`q.push(...)`). Slither's
    ///      uninitialized-state-variables detector flags every mapping this way: it looks for a
    ///      direct `_exitQueues = ...` assignment, which is not expressible for a mapping.
    // slither-disable-next-line uninitialized-state
    mapping(address => ExitRequest[]) private _exitQueues;
    /// @notice Total K613 backing active positions (staked minus exited). Maintained as a
    ///         standalone counter — incremented in `stake`, decremented in `exit`/`instantExit` —
    ///         independent of any per-user record.
    /// @dev `xK613.totalSupply() == totalBacking()` holds ONLY while this contract is xK613's sole
    ///      minter. totalSupply is global to the token; this counter tracks what THIS contract
    ///      minted and has not burned. During any period where V1 also holds MINTER_ROLE the two
    ///      diverge by V1's outstanding supply — see the deployment hazard above.
    uint256 private _totalBacking;

    /// @notice Emitted when a user stakes K613
    event Staked(address indexed account, uint256 amount);
    /// @notice Emitted when a user initiates an exit request
    event ExitInitiated(address indexed account, uint256 index, uint256 amount, uint256 exitInitiatedAt);
    /// @notice Emitted when a user cancels an exit request
    event ExitCancelled(address indexed account, uint256 index);
    /// @notice Emitted when a user exits after the lock period
    event Exited(address indexed account, uint256 index, uint256 amount);
    /// @notice Emitted when a user performs an instant exit
    event InstantExit(address indexed account, uint256 index, uint256 amount, uint256 penalty);
    /// @notice Emitted when rewards distributor is updated
    event RewardsDistributorUpdated(address indexed distributor);
    /// @notice Emitted when instantExitPenaltyBps is updated
    event InstantExitPenaltyBpsUpdated(uint256 oldBps, uint256 newBps);
    /// @notice Emitted when maxExitRequests is updated
    event MaxExitRequestsUpdated(uint256 oldValue, uint256 newValue);
    /// @notice Emitted when backing is credited for externally-minted xK613 during a migration
    event BackingSeeded(address indexed from, uint256 amount);

    /// @notice Initializes the staking contract.
    /// @param k613Token Address of the K613 token to be staked.
    /// @param xk613Token Address of the xK613 token to be minted/burned on stake/exit.
    /// @param lockDuration_ Lock duration, in seconds, for standard exits.
    /// @param instantExitPenaltyBps_ Penalty in basis points for instant exits.
    constructor(address k613Token, address xk613Token, uint256 lockDuration_, uint256 instantExitPenaltyBps_) {
        if (k613Token == address(0) || xk613Token == address(0)) revert ZeroAddress();
        if (lockDuration_ == 0) revert InvalidLockDuration();
        if (instantExitPenaltyBps_ == 0 || instantExitPenaltyBps_ > MAX_BASIS_POINTS) revert InvalidBps();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        k613 = IERC20(k613Token);
        xk613 = xK613(xk613Token);
        lockDuration = lockDuration_;
        instantExitPenaltyBps = instantExitPenaltyBps_;
        maxExitRequests = 100;
    }

    /// @notice Sets the rewards distributor contract. Pass address(0) to disable; instant exit with penalty will revert until set.
    /// @param distributor Address of the rewards distributor.
    function setRewardsDistributor(address distributor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        rewardsDistributor = RewardsDistributor(distributor);
        emit RewardsDistributorUpdated(distributor);
    }

    function MAX_EXIT_REQUESTS() external view returns (uint256) {
        return maxExitRequests;
    }

    /// @notice Returns the user's liquid (queueable) xK613 balance and their exit queue.
    /// @dev `amount` is `xk613.balanceOf(user)` — V2 has no separate position record, so this
    ///      is simply what the user could still call `initiateExit` for right now. The total
    ///      the user has "in the system" is `amount + sum(exitQueue[i].amount)`.
    /// @param user Address of the user.
    /// @return amount Liquid xK613 balance of the user.
    /// @return exitQueue Array of exit requests for the user.
    function deposits(address user) external view returns (uint256 amount, ExitRequest[] memory exitQueue) {
        amount = xk613.balanceOf(user);
        exitQueue = _exitQueues[user];
    }

    /// @notice Returns the length of the exit queue for a user.
    /// @param user Address of the user.
    /// @return Length of the exit queue.
    function exitQueueLength(address user) external view returns (uint256) {
        return _exitQueues[user].length;
    }

    /// @notice Total xK613 the user currently has queued for exit.
    /// @dev Queued xK613 is escrowed in this contract, so it is not part of the user's live
    ///      balance: their total in the system is `deposits(user).amount + exitPendingSum(user)`.
    /// @param user Address of the user.
    /// @return sum Total amount pending exit across the user's queue.
    function exitPendingSum(address user) external view returns (uint256 sum) {
        ExitRequest[] storage q = _exitQueues[user];
        for (uint256 i = 0; i < q.length; ++i) {
            sum += q[i].amount;
        }
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
        ExitRequest storage r = _exitQueues[user][index];
        return (r.amount, r.exitInitiatedAt);
    }

    /// @notice Returns total K613 backing active positions (staked minus exited). For invariant: xK613.totalSupply() == totalBacking().
    function totalBacking() external view returns (uint256) {
        return _totalBacking;
    }

    /// @notice Converts K613 to xK613 1:1 and mints to caller
    /// @param amount Amount of K613 to convert.
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        _totalBacking += amount;

        k613.safeTransferFrom(msg.sender, address(this), amount);
        xk613.mint(msg.sender, amount);

        emit Staked(msg.sender, amount);
    }

    /// @notice Credits backing for xK613 this contract did not mint. The migration hook: pulls
    ///         `amount` K613 from the caller and raises `_totalBacking` WITHOUT minting, so xK613
    ///         issued by a predecessor becomes redeemable here 1:1.
    /// @dev Exists because a predecessor's K613 cannot be moved: StakingV1 releases backing only
    ///      through user exits, and those need the MINTER_ROLE that the cutover takes away. Seeding
    ///      here lets the whole outstanding supply exit through V2 in one step, at the cost of
    ///      stranding the predecessor's reserve — a trade that is only correct when that reserve is
    ///      small relative to the operational risk of the alternative, which is granting both
    ///      contracts MINTER_ROLE and letting the predecessor drain naturally. What that alternative
    ///      actually costs is pinned in test/StakingV2Migration.t.sol: xK613 carries no record of
    ///      which contract minted it, so with both roles live a predecessor's holder exits here and
    ///      is paid out of this contract's backing.
    /// @dev Not `whenNotPaused` on purpose: the cutover is meant to be executable while staking is
    ///      paused, so no user action can interleave between seeding and the minter handover.
    /// @dev Size against `xK613.totalSupply()` at cutover, never by feel. Seeding less than the
    ///      outstanding supply leaves holders whose `exit()` underflows; seeding more leaves K613
    ///      that no xK613 can ever claim. There is deliberately no un-seed.
    /// @param amount K613 to pull from the caller and credit as backing.
    function seedBacking(uint256 amount) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (amount == 0) revert ZeroAmount();

        _totalBacking += amount;

        k613.safeTransferFrom(msg.sender, address(this), amount);

        emit BackingSeeded(msg.sender, amount);
    }

    /// @notice Initiates exit: pulls xK613 from caller and adds request to queue.
    /// @dev Caller must approve Staking for xK613. At most `maxExitRequests` per user. Gated
    ///      purely on the caller's live xK613 balance — see contract NatSpec for why this
    ///      replaces V1's separate position check.
    /// @param amount Amount of xK613 to schedule for exit.
    function initiateExit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        // aderyn-ignore-next-line(reentrancy-state-change)
        if (xk613.balanceOf(msg.sender) < amount) revert InsufficientxK613();

        ExitRequest[] storage q = _exitQueues[msg.sender];
        if (q.length >= maxExitRequests) revert ExitQueueFull();
        q.push(ExitRequest({amount: amount, exitInitiatedAt: block.timestamp}));
        IERC20(address(xk613)).safeTransferFrom(msg.sender, address(this), amount);

        emit ExitInitiated(msg.sender, q.length - 1, amount, block.timestamp);
    }

    /// @notice Cancels an exit request and returns xK613 to caller.
    /// @param index Index of the exit request in the caller's queue.
    function cancelExit(uint256 index) external nonReentrant whenNotPaused {
        ExitRequest[] storage q = _exitQueues[msg.sender];
        if (index >= q.length) revert InvalidExitIndex();

        uint256 amount = q[index].amount;
        _removeExitRequest(msg.sender, index);
        IERC20(address(xk613)).safeTransfer(msg.sender, amount);

        emit ExitCancelled(msg.sender, index);
    }

    /// @notice Executes an exit after the lock period: burns held xK613 and transfers K613 to caller.
    /// @param index Index of the exit request in the caller's queue.
    function exit(uint256 index) external nonReentrant whenNotPaused {
        ExitRequest[] storage q = _exitQueues[msg.sender];
        if (index >= q.length) revert InvalidExitIndex();

        ExitRequest storage req = q[index];
        if (block.timestamp < req.exitInitiatedAt + lockDuration) revert Locked();

        uint256 amount = req.amount;
        _removeExitRequest(msg.sender, index);
        _totalBacking -= amount;

        xk613.burnFrom(address(this), amount);
        k613.safeTransfer(msg.sender, amount);

        emit Exited(msg.sender, index, amount);
    }

    /// @notice Instant exit before lock period; penalty goes to RewardsDistributor if set.
    /// @dev Requires rewardsDistributor when penalty > 0.
    /// @param index Index of the exit request in the caller's queue.
    function instantExit(uint256 index) external nonReentrant whenNotPaused {
        ExitRequest[] storage q = _exitQueues[msg.sender];
        if (index >= q.length) revert InvalidExitIndex();

        ExitRequest storage req = q[index];
        if (block.timestamp >= req.exitInitiatedAt + lockDuration) revert Unlocked();

        uint256 amount = req.amount;
        uint256 penalty = (amount * instantExitPenaltyBps + MAX_BASIS_POINTS - 1) / MAX_BASIS_POINTS;
        uint256 payout = amount - penalty;

        if (penalty > 0 && address(rewardsDistributor) == address(0)) revert RewardsDistributorNotSet();

        _removeExitRequest(msg.sender, index);
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
        ExitRequest[] storage q = _exitQueues[user];
        uint256 last = q.length - 1;
        if (index != last) {
            q[index] = q[last];
        }
        q.pop();
    }

    /// @notice Updates the instant exit penalty. Only callable by DEFAULT_ADMIN_ROLE.
    /// @param newBps New penalty in basis points. Must be > 0 and <= MAX_BASIS_POINTS.
    function setInstantExitPenaltyBps(uint256 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps == 0 || newBps > MAX_BASIS_POINTS) revert InvalidBps();
        emit InstantExitPenaltyBpsUpdated(instantExitPenaltyBps, newBps);
        instantExitPenaltyBps = newBps;
    }

    /// @notice Updates the maximum number of concurrent exit requests per user.
    /// @param newValue New maximum. Must be > 0.
    function setMaxExitRequests(uint256 newValue) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newValue == 0) revert InvalidMaxExitRequests();
        emit MaxExitRequestsUpdated(maxExitRequests, newValue);
        maxExitRequests = newValue;
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
