// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/// @title K613PublicSale
/// @notice Fixed-price overflow ("fair launch") public sale. Users deposit `usdc` during the sale window with no
///         individual limits. If total deposits stay at or under `hardCap`, every depositor is filled in full at the
///         implied price; if the sale oversubscribes, the fixed `saleAllocation` is split pro-rata by deposit share and
///         the unused portion of each deposit is claimable back as a refund. Tokens unlock 100% at claim, no vesting.
/// @dev The implied price is `hardCap / saleAllocation` and is never stored, so the contract is agnostic to token
///      decimals (10,000,000e18 K613 against 100,000e6 USDC encodes $0.01 per K613). Deposits are only accepted while
///      the contract already holds at least `saleAllocation` of `saleToken`, which makes `finalize` permissionless and
///      guarantees token claims can never be stranded. Allocation and refund use floor division: the sum of all
///      allocations never exceeds `saleAllocation` and, when oversubscribed, the sum of all refunds never exceeds
///      `totalDeposits - hardCap`, so the contract stays solvent after the admin withdraws proceeds. Rounding dust
///      (at most one USDC unit and a few token wei per participant) plus never-claimed balances are recoverable by
///      the admin once the claim window (`CLAIM_WINDOW` after finalization) closes. `usdc` is assumed to be a
///      standard ERC20 without transfer fees.
contract K613PublicSale is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Thrown when a zero address is passed as a constructor argument or transfer target.
    error ZeroAddress();
    /// @notice Thrown when a zero amount is passed where a positive value is required.
    error ZeroAmount();
    /// @notice Thrown when the payment token and the sale token are the same contract.
    error TokenCollision();
    /// @notice Thrown when a sale window has a start in the past or an end not after its start.
    error InvalidSaleWindow();
    /// @notice Thrown when attempting to reschedule the sale window after the sale has started.
    error SaleAlreadyStarted();
    /// @notice Thrown when depositing outside the `[saleStart, saleEnd)` window.
    error SaleNotOpen();
    /// @notice Thrown when depositing while the contract holds less than `saleAllocation` of `saleToken`.
    error SaleNotFunded();
    /// @notice Thrown when finalizing before `saleEnd`.
    error SaleNotEnded();
    /// @notice Thrown when finalizing a sale that is already finalized.
    error AlreadyFinalized();
    /// @notice Thrown when claiming or moving funds before the sale is finalized.
    error NotFinalized();
    /// @notice Thrown when the caller repeats a one-shot claim.
    error AlreadyClaimed();
    /// @notice Thrown when the caller has no allocation or no refund to claim.
    error NothingToClaim();
    /// @notice Thrown when claiming at or after `claimDeadline`.
    error ClaimWindowClosed();
    /// @notice Thrown when recovering leftovers before `claimDeadline` (or before finalization sets it).
    error ClaimsStillOpen();
    /// @notice Thrown when `withdrawProceeds` is called a second time.
    error AlreadyWithdrawn();
    /// @notice Thrown when there is no excess `saleToken` to sweep.
    error NothingToSweep();

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Length of the claim window after finalization. After it closes, claims revert and the admin can
    ///         recover unclaimed allocations, unclaimed refunds, and rounding dust.
    uint256 public constant CLAIM_WINDOW = 365 days;

    /// @notice Lifecycle stage of the sale, derived from time and finalization state (UI helper).
    enum Stage {
        Upcoming,
        ContributionOpen,
        SaleClosed,
        ClaimOpen,
        Ended
    }

    /// @notice Payment token deposited by participants (USDC on Monad). Assumed fee-less standard ERC20.
    IERC20 public immutable usdc;
    /// @notice Token sold to participants (K613). Must be transferred to this contract before deposits open.
    IERC20 public immutable saleToken;
    /// @notice Total `saleToken` amount distributed by the sale (10,000,000e18 K613).
    uint256 public immutable saleAllocation;
    /// @notice Maximum `usdc` retained by the sale (100,000e6 = $100k). Implied price = `hardCap / saleAllocation`.
    uint256 public immutable hardCap;

    /// @notice Deposit window opening timestamp. Reschedulable by the admin only before the window opens.
    uint256 public saleStart;
    /// @notice Deposit window closing timestamp (exclusive). Reschedulable by the admin only before `saleStart`.
    uint256 public saleEnd;
    /// @notice Sum of all `usdc` deposits credited so far.
    uint256 public totalDeposits;
    /// @notice Number of unique depositors.
    uint256 public participants;
    /// @notice Total `saleToken` sold, set once by `finalize`: full `saleAllocation` when `totalDeposits >= hardCap`,
    ///         otherwise `totalDeposits * saleAllocation / hardCap`.
    uint256 public totalTokensSold;
    /// @notice Total `saleToken` paid out via `claimTokens`. Feeds the sweep reserve so unclaimed allocations stay covered.
    uint256 public totalTokensClaimed;
    /// @notice Total `usdc` paid out via `claimRefund`. Stored for off-chain observability.
    uint256 public totalRefundsClaimed;
    /// @notice Timestamp at which claims close, set once by `finalize` to `block.timestamp + CLAIM_WINDOW`.
    ///         Zero until finalization, which also blocks `recoverAfterDeadline` until the sale is finalized.
    uint256 public claimDeadline;
    /// @notice Whether `finalize` has run. Freezes allocations and refunds and opens claims.
    bool public finalized;
    /// @notice Whether the admin has withdrawn the sale proceeds.
    bool public proceedsWithdrawn;

    /// @notice `usdc` deposited per account. Never reset; both claim legs derive from it.
    mapping(address => uint256) public deposits;
    /// @notice Whether an account has claimed its `saleToken` allocation.
    mapping(address => bool) public tokensClaimed;
    /// @notice Whether an account has claimed its `usdc` refund.
    mapping(address => bool) public refundClaimed;

    /// @notice Aggregate sale parameters and live statistics in a single read (UI helper).
    struct SaleView {
        Stage stage;
        uint256 saleStart;
        uint256 saleEnd;
        uint256 saleAllocation;
        uint256 hardCap;
        uint256 totalDeposits;
        uint256 participants;
        bool finalized;
        bool funded;
        uint256 totalTokensSold;
        uint256 claimDeadline;
    }

    /// @notice Per-account position in a single read (UI helper). `allocation` and `refund` are live estimates before
    ///         finalization and exact afterwards; `claimableTokens`/`claimableRefund` are non-zero only while the
    ///         claim window is open and the corresponding leg is unclaimed.
    struct UserView {
        uint256 deposited;
        uint256 allocation;
        uint256 refund;
        bool tokensClaimed;
        bool refundClaimed;
        uint256 claimableTokens;
        uint256 claimableRefund;
    }

    /// @notice Emitted when the sale window is set (constructor) or rescheduled before start.
    event SaleWindowUpdated(uint256 saleStart, uint256 saleEnd);
    /// @notice Emitted on each deposit with the depositor's running total and the sale-wide running total.
    event Deposited(address indexed account, uint256 amount, uint256 accountTotal, uint256 saleTotal);
    /// @notice Emitted when the sale is finalized and claims open.
    event Finalized(uint256 totalDeposits, uint256 totalTokensSold, uint256 claimDeadline);
    /// @notice Emitted when an account claims its `saleToken` allocation.
    event TokensClaimed(address indexed account, uint256 amount);
    /// @notice Emitted when an account claims its `usdc` refund.
    event RefundClaimed(address indexed account, uint256 amount);
    /// @notice Emitted when the admin withdraws the sale proceeds.
    event ProceedsWithdrawn(address indexed to, uint256 amount);
    /// @notice Emitted when the admin sweeps `saleToken` in excess of outstanding claim liabilities.
    event UnsoldTokensSwept(address indexed to, uint256 amount);
    /// @notice Emitted when the admin recovers leftover tokens after the claim window closes.
    event Recovered(address indexed token, address indexed to, uint256 amount);

    /// @param _usdc Payment token accepted for deposits (USDC).
    /// @param _saleToken Token distributed by the sale (K613).
    /// @param _saleAllocation Total `_saleToken` sold (e.g. 10,000,000e18).
    /// @param _hardCap Maximum `_usdc` retained by the sale (e.g. 100,000e6).
    /// @param _saleStart Deposit window opening timestamp; must be in the future.
    /// @param _saleEnd Deposit window closing timestamp (exclusive); must be after `_saleStart`.
    /// @param _admin Address granted `DEFAULT_ADMIN_ROLE` and `PAUSER_ROLE` (typically the governance Safe).
    constructor(
        address _usdc,
        address _saleToken,
        uint256 _saleAllocation,
        uint256 _hardCap,
        uint256 _saleStart,
        uint256 _saleEnd,
        address _admin
    ) {
        if (_usdc == address(0) || _saleToken == address(0) || _admin == address(0)) {
            revert ZeroAddress();
        }
        if (_usdc == _saleToken) {
            revert TokenCollision();
        }
        if (_saleAllocation == 0 || _hardCap == 0) {
            revert ZeroAmount();
        }
        if (_saleStart <= block.timestamp || _saleEnd <= _saleStart) {
            revert InvalidSaleWindow();
        }
        usdc = IERC20(_usdc);
        saleToken = IERC20(_saleToken);
        saleAllocation = _saleAllocation;
        hardCap = _hardCap;
        saleStart = _saleStart;
        saleEnd = _saleEnd;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
        emit SaleWindowUpdated(_saleStart, _saleEnd);
    }

    /// @notice Reschedules the sale window. Only callable by `DEFAULT_ADMIN_ROLE` and only strictly before the
    ///         current `saleStart`; once the sale has started the window is immutable.
    /// @param newStart New opening timestamp; must be in the future.
    /// @param newEnd New closing timestamp; must be after `newStart`.
    function setSaleWindow(uint256 newStart, uint256 newEnd) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (block.timestamp >= saleStart) {
            revert SaleAlreadyStarted();
        }
        if (newStart <= block.timestamp || newEnd <= newStart) {
            revert InvalidSaleWindow();
        }
        saleStart = newStart;
        saleEnd = newEnd;
        emit SaleWindowUpdated(newStart, newEnd);
    }

    /// @notice Deposits `usdc` into the sale. Callable any number of times per account during `[saleStart, saleEnd)`
    ///         with no individual limit. Requires the contract to already hold the full `saleAllocation` of
    ///         `saleToken` so that claims are guaranteed deliverable.
    /// @param amount `usdc` amount to deposit; the caller must have approved it beforehand.
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (block.timestamp < saleStart || block.timestamp >= saleEnd) {
            revert SaleNotOpen();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        if (deposits[msg.sender] == 0) {
            participants++;
        }
        // CEI: every state write precedes every external call. The funding check sits between them; if it
        // fails, the whole call (including the credits above) reverts atomically.
        deposits[msg.sender] += amount;
        totalDeposits += amount;
        if (saleToken.balanceOf(address(this)) < saleAllocation) {
            revert SaleNotFunded();
        }
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount, deposits[msg.sender], totalDeposits);
    }

    /// @notice Finalizes the sale after `saleEnd`, freezing allocations and opening claims until `claimDeadline`.
    /// @dev Deliberately permissionless, free of external calls, and not gated by pause: no actor, including a
    ///      compromised admin or pauser, can prevent finalization once the sale has ended.
    function finalize() external {
        if (finalized) {
            revert AlreadyFinalized();
        }
        if (block.timestamp < saleEnd) {
            revert SaleNotEnded();
        }
        finalized = true;
        totalTokensSold = totalDeposits >= hardCap ? saleAllocation : totalDeposits * saleAllocation / hardCap;
        claimDeadline = block.timestamp + CLAIM_WINDOW;
        emit Finalized(totalDeposits, totalTokensSold, claimDeadline);
    }

    /// @notice Claims the caller's full `saleToken` allocation. One-shot, available from finalization until
    ///         `claimDeadline`. 100% unlock, no vesting.
    function claimTokens() external nonReentrant whenNotPaused {
        _checkClaimOpen();
        if (tokensClaimed[msg.sender]) {
            revert AlreadyClaimed();
        }
        uint256 amount = allocationOf(msg.sender);
        if (amount == 0) {
            revert NothingToClaim();
        }
        // CEI: mark claimed before the transfer.
        tokensClaimed[msg.sender] = true;
        totalTokensClaimed += amount;
        saleToken.safeTransfer(msg.sender, amount);
        emit TokensClaimed(msg.sender, amount);
    }

    /// @notice Claims the caller's `usdc` refund (oversubscribed sales only). One-shot, available from finalization
    ///         until `claimDeadline`. Refunds go to the depositing wallet itself.
    function claimRefund() external nonReentrant whenNotPaused {
        _checkClaimOpen();
        if (refundClaimed[msg.sender]) {
            revert AlreadyClaimed();
        }
        uint256 amount = refundOf(msg.sender);
        if (amount == 0) {
            revert NothingToClaim();
        }
        // CEI: mark claimed before the transfer.
        refundClaimed[msg.sender] = true;
        totalRefundsClaimed += amount;
        usdc.safeTransfer(msg.sender, amount);
        emit RefundClaimed(msg.sender, amount);
    }

    /// @notice Withdraws the sale proceeds, `min(totalDeposits, hardCap)` of `usdc`, leaving the refund pool intact.
    ///         Only callable by `DEFAULT_ADMIN_ROLE`, after finalization, once.
    /// @param to Recipient of the proceeds.
    function withdrawProceeds(address to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (!finalized) {
            revert NotFinalized();
        }
        if (proceedsWithdrawn) {
            revert AlreadyWithdrawn();
        }
        if (to == address(0)) {
            revert ZeroAddress();
        }
        proceedsWithdrawn = true;
        uint256 amount = totalDeposits < hardCap ? totalDeposits : hardCap;
        usdc.safeTransfer(to, amount);
        emit ProceedsWithdrawn(to, amount);
    }

    /// @notice Sweeps `saleToken` held above the outstanding claim liability (`totalTokensSold - totalTokensClaimed`).
    ///         Covers unsold tokens in an undersubscribed sale and any over-funding. Only callable by
    ///         `DEFAULT_ADMIN_ROLE`, after finalization; repeatable, since the reserve shrinks as users claim.
    /// @param to Recipient of the excess tokens.
    function sweepUnsoldTokens(address to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (!finalized) {
            revert NotFinalized();
        }
        if (to == address(0)) {
            revert ZeroAddress();
        }
        uint256 reserved = totalTokensSold - totalTokensClaimed;
        uint256 excess = saleToken.balanceOf(address(this)) - reserved;
        if (excess == 0) {
            revert NothingToSweep();
        }
        saleToken.safeTransfer(to, excess);
        emit UnsoldTokensSwept(to, excess);
    }

    /// @notice After `claimDeadline`, recovers any token still held by the contract (never-claimed allocations and
    ///         refunds, rounding dust, accidental sends). Only callable by `DEFAULT_ADMIN_ROLE`.
    /// @dev `claimDeadline` is zero until finalization, so recovery is impossible while the funding gate protects
    ///      deposits and for the full claim window afterwards.
    /// @param token Token to recover.
    /// @param to Recipient.
    /// @param amount Amount to transfer.
    function recoverAfterDeadline(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (claimDeadline == 0 || block.timestamp < claimDeadline) {
            revert ClaimsStillOpen();
        }
        if (to == address(0)) {
            revert ZeroAddress();
        }
        IERC20(token).safeTransfer(to, amount);
        emit Recovered(token, to, amount);
    }

    /// @notice Pauses deposits and both claim legs. Only callable by `PAUSER_ROLE`. `finalize` and admin fund
    ///         management are never pausable.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resumes deposits and claims. Only callable by `PAUSER_ROLE`.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Current lifecycle stage, derived from time and finalization state.
    function stage() public view returns (Stage) {
        if (finalized) {
            return block.timestamp >= claimDeadline ? Stage.Ended : Stage.ClaimOpen;
        }
        if (block.timestamp >= saleEnd) {
            return Stage.SaleClosed;
        }
        if (block.timestamp >= saleStart) {
            return Stage.ContributionOpen;
        }
        return Stage.Upcoming;
    }

    /// @notice Whether the contract holds the full `saleAllocation` of `saleToken` (deposits require it).
    function funded() public view returns (bool) {
        return saleToken.balanceOf(address(this)) >= saleAllocation;
    }

    /// @notice `saleToken` allocation of `account`: `deposit * saleAllocation / max(totalDeposits, hardCap)`.
    ///         A live estimate while deposits are open; exact once the sale ends. Floor-rounded, so the sum of all
    ///         allocations never exceeds `saleAllocation`.
    /// @param account Account to query.
    function allocationOf(address account) public view returns (uint256) {
        uint256 total = totalDeposits;
        uint256 denominator = total > hardCap ? total : hardCap;
        return deposits[account] * saleAllocation / denominator;
    }

    /// @notice `usdc` refund of `account`: `deposit * (totalDeposits - hardCap) / totalDeposits` when the sale is
    ///         oversubscribed, zero otherwise. A live estimate while deposits are open; exact once the sale ends.
    ///         Floor-rounded, so the sum of all refunds never exceeds `totalDeposits - hardCap` and every refund
    ///         remains payable after the admin withdraws `hardCap` of proceeds.
    /// @param account Account to query.
    function refundOf(address account) public view returns (uint256) {
        uint256 total = totalDeposits;
        if (total <= hardCap) {
            return 0;
        }
        return deposits[account] * (total - hardCap) / total;
    }

    /// @notice Aggregate sale parameters and statistics for the sale page in a single call.
    function saleInfo() external view returns (SaleView memory) {
        return SaleView({
            stage: stage(),
            saleStart: saleStart,
            saleEnd: saleEnd,
            saleAllocation: saleAllocation,
            hardCap: hardCap,
            totalDeposits: totalDeposits,
            participants: participants,
            finalized: finalized,
            funded: funded(),
            totalTokensSold: totalTokensSold,
            claimDeadline: claimDeadline
        });
    }

    /// @notice Full position of `account` for the user dashboard in a single call.
    /// @param account Account to query.
    function userInfo(address account) external view returns (UserView memory) {
        uint256 allocation = allocationOf(account);
        uint256 refund = refundOf(account);
        bool claimOpen = finalized && block.timestamp < claimDeadline;
        return UserView({
            deposited: deposits[account],
            allocation: allocation,
            refund: refund,
            tokensClaimed: tokensClaimed[account],
            refundClaimed: refundClaimed[account],
            claimableTokens: claimOpen && !tokensClaimed[account] ? allocation : 0,
            claimableRefund: claimOpen && !refundClaimed[account] ? refund : 0
        });
    }

    /// @dev Shared claim gate: the sale must be finalized and the claim window still open.
    function _checkClaimOpen() private view {
        if (!finalized) {
            revert NotFinalized();
        }
        if (block.timestamp >= claimDeadline) {
            revert ClaimWindowClosed();
        }
    }
}
