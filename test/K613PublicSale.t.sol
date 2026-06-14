// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {K613} from "../src/token/K613.sol";
import {K613PublicSale} from "../src/sale/K613PublicSale.sol";

/// @notice Minimal 6-decimal USDC stand-in for sale tests.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract K613PublicSaleTest is Test {
    K613PublicSale private sale;
    K613 private k613;
    MockUSDC private usdc;

    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    address private carol = address(0xCAFE);
    address private treasury = address(0x77E45);

    uint256 private constant SALE_ALLOCATION = 10_000_000e18; // 10M K613
    uint256 private constant HARD_CAP = 100_000e6; // $100k USDC

    // Worked oversubscription example: alice 100k + bob 50k = 150k total (1.5x).
    uint256 private constant ALICE_DEP = 100_000e6;
    uint256 private constant BOB_DEP = 50_000e6;
    uint256 private constant ALICE_ALLOC_150K = 6_666_666_666_666_666_666_666_666; // floor(2/3 * 1e25)
    uint256 private constant BOB_ALLOC_150K = 3_333_333_333_333_333_333_333_333; // floor(1/3 * 1e25)
    uint256 private constant ALICE_REFUND_150K = 33_333_333_333; // floor(1e11 * 5e10 / 1.5e11)
    uint256 private constant BOB_REFUND_150K = 16_666_666_666; // floor(5e10 * 5e10 / 1.5e11)

    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 private constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint256 private saleStart;
    uint256 private saleEnd;

    event SaleWindowUpdated(uint256 saleStart, uint256 saleEnd);
    event Deposited(address indexed account, uint256 amount, uint256 accountTotal, uint256 saleTotal);
    event Finalized(uint256 totalDeposits, uint256 totalTokensSold, uint256 claimDeadline);
    event TokensClaimed(address indexed account, uint256 amount);
    event RefundClaimed(address indexed account, uint256 amount);

    function setUp() public {
        vm.warp(1_750_000_000); // realistic base timestamp
        saleStart = block.timestamp + 1 days;
        saleEnd = saleStart + 3 days;

        k613 = new K613(address(this)); // test contract is K613 minter + admin
        usdc = new MockUSDC();
        sale = new K613PublicSale(
            address(usdc), address(k613), SALE_ALLOCATION, HARD_CAP, saleStart, saleEnd, address(this)
        );
        k613.mint(address(sale), SALE_ALLOCATION);

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        usdc.mint(carol, 1_000_000e6);
    }

    // ---------- helpers ----------

    function _deposit(address user, uint256 amount) private {
        vm.startPrank(user);
        usdc.approve(address(sale), amount);
        sale.deposit(amount);
        vm.stopPrank();
    }

    function _warpOpen() private {
        vm.warp(saleStart);
    }

    function _finalize() private {
        vm.warp(saleEnd);
        sale.finalize();
    }

    /// @dev Deploys an identical sale that has NOT been funded with K613.
    function _newUnfundedSale() private returns (K613PublicSale) {
        return
            new K613PublicSale(
                address(usdc), address(k613), SALE_ALLOCATION, HARD_CAP, saleStart, saleEnd, address(this)
            );
    }

    function _expectNotAdmin(address account) private {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, account, DEFAULT_ADMIN_ROLE
            )
        );
    }

    // ---------- constructor ----------

    /// @notice Constructor stores parameters, grants roles to the admin, and starts in Upcoming.
    function testConstructorStoresParamsAndRoles() public view {
        assertEq(address(sale.usdc()), address(usdc), "usdc");
        assertEq(address(sale.saleToken()), address(k613), "sale token");
        assertEq(sale.saleAllocation(), SALE_ALLOCATION, "allocation");
        assertEq(sale.hardCap(), HARD_CAP, "hard cap");
        assertEq(sale.saleStart(), saleStart, "start");
        assertEq(sale.saleEnd(), saleEnd, "end");
        assertTrue(sale.hasRole(DEFAULT_ADMIN_ROLE, address(this)), "admin role");
        assertTrue(sale.hasRole(PAUSER_ROLE, address(this)), "pauser role");
        assertFalse(sale.finalized(), "not finalized");
        assertEq(uint256(sale.stage()), uint256(K613PublicSale.Stage.Upcoming), "stage");
    }

    /// @notice Constructor rejects zero addresses for usdc, sale token, and admin.
    function testConstructorRevertsOnZeroAddresses() public {
        vm.expectRevert(K613PublicSale.ZeroAddress.selector);
        new K613PublicSale(address(0), address(k613), SALE_ALLOCATION, HARD_CAP, saleStart, saleEnd, address(this));
        vm.expectRevert(K613PublicSale.ZeroAddress.selector);
        new K613PublicSale(address(usdc), address(0), SALE_ALLOCATION, HARD_CAP, saleStart, saleEnd, address(this));
        vm.expectRevert(K613PublicSale.ZeroAddress.selector);
        new K613PublicSale(address(usdc), address(k613), SALE_ALLOCATION, HARD_CAP, saleStart, saleEnd, address(0));
    }

    /// @notice Constructor rejects identical payment and sale tokens.
    function testConstructorRevertsOnTokenCollision() public {
        vm.expectRevert(K613PublicSale.TokenCollision.selector);
        new K613PublicSale(address(usdc), address(usdc), SALE_ALLOCATION, HARD_CAP, saleStart, saleEnd, address(this));
    }

    /// @notice Constructor rejects zero sale allocation and zero hard cap.
    function testConstructorRevertsOnZeroAmounts() public {
        vm.expectRevert(K613PublicSale.ZeroAmount.selector);
        new K613PublicSale(address(usdc), address(k613), 0, HARD_CAP, saleStart, saleEnd, address(this));
        vm.expectRevert(K613PublicSale.ZeroAmount.selector);
        new K613PublicSale(address(usdc), address(k613), SALE_ALLOCATION, 0, saleStart, saleEnd, address(this));
    }

    /// @notice Constructor rejects a start in the past/present and an end not after the start.
    function testConstructorRevertsOnInvalidWindow() public {
        vm.expectRevert(K613PublicSale.InvalidSaleWindow.selector);
        new K613PublicSale(
            address(usdc), address(k613), SALE_ALLOCATION, HARD_CAP, block.timestamp, saleEnd, address(this)
        );
        vm.expectRevert(K613PublicSale.InvalidSaleWindow.selector);
        new K613PublicSale(address(usdc), address(k613), SALE_ALLOCATION, HARD_CAP, saleStart, saleStart, address(this));
    }

    // ---------- setSaleWindow ----------

    /// @notice Admin can reschedule the window strictly before the sale starts.
    function testSetSaleWindowReschedules() public {
        uint256 newStart = saleStart + 2 days;
        uint256 newEnd = newStart + 5 days;
        vm.expectEmit(false, false, false, true);
        emit SaleWindowUpdated(newStart, newEnd);
        sale.setSaleWindow(newStart, newEnd);
        assertEq(sale.saleStart(), newStart, "rescheduled start");
        assertEq(sale.saleEnd(), newEnd, "rescheduled end");
    }

    /// @notice Rescheduling reverts once the sale has started: parameters are immutable after start.
    function testSetSaleWindowRevertsAfterStart() public {
        _warpOpen();
        vm.expectRevert(K613PublicSale.SaleAlreadyStarted.selector);
        sale.setSaleWindow(block.timestamp + 1 days, block.timestamp + 2 days);
    }

    /// @notice Rescheduling rejects windows starting in the past or ending before they start.
    function testSetSaleWindowRevertsOnInvalidWindow() public {
        vm.expectRevert(K613PublicSale.InvalidSaleWindow.selector);
        sale.setSaleWindow(block.timestamp, block.timestamp + 1 days);
        vm.expectRevert(K613PublicSale.InvalidSaleWindow.selector);
        sale.setSaleWindow(saleStart, saleStart);
    }

    /// @notice Only the admin can reschedule the window.
    function testSetSaleWindowOnlyAdmin() public {
        _expectNotAdmin(alice);
        vm.prank(alice);
        sale.setSaleWindow(saleStart + 1, saleEnd + 1);
    }

    // ---------- stage / views ----------

    /// @notice Stage walks Upcoming -> ContributionOpen -> SaleClosed -> ClaimOpen -> Ended.
    function testStageProgression() public {
        assertEq(uint256(sale.stage()), uint256(K613PublicSale.Stage.Upcoming), "upcoming");
        _warpOpen();
        assertEq(uint256(sale.stage()), uint256(K613PublicSale.Stage.ContributionOpen), "open");
        vm.warp(saleEnd);
        assertEq(uint256(sale.stage()), uint256(K613PublicSale.Stage.SaleClosed), "closed");
        sale.finalize();
        assertEq(uint256(sale.stage()), uint256(K613PublicSale.Stage.ClaimOpen), "claim open");
        vm.warp(sale.claimDeadline());
        assertEq(uint256(sale.stage()), uint256(K613PublicSale.Stage.Ended), "ended");
    }

    /// @notice funded() reflects whether the contract holds the full sale allocation.
    function testFundedFlag() public {
        assertTrue(sale.funded(), "funded after setUp mint");
        K613PublicSale unfunded = _newUnfundedSale();
        assertFalse(unfunded.funded(), "unfunded fresh deploy");
        k613.mint(address(unfunded), SALE_ALLOCATION - 1);
        assertFalse(unfunded.funded(), "one wei short");
        k613.mint(address(unfunded), 1);
        assertTrue(unfunded.funded(), "exactly funded");
    }

    /// @notice saleInfo() aggregates parameters and live statistics.
    function testSaleInfoSnapshot() public {
        _warpOpen();
        _deposit(alice, ALICE_DEP);
        K613PublicSale.SaleView memory info = sale.saleInfo();
        assertEq(uint256(info.stage), uint256(K613PublicSale.Stage.ContributionOpen), "stage");
        assertEq(info.saleStart, saleStart, "start");
        assertEq(info.saleEnd, saleEnd, "end");
        assertEq(info.saleAllocation, SALE_ALLOCATION, "allocation");
        assertEq(info.hardCap, HARD_CAP, "cap");
        assertEq(info.totalDeposits, ALICE_DEP, "total deposits");
        assertEq(info.participants, 1, "participants");
        assertFalse(info.finalized, "finalized");
        assertTrue(info.funded, "funded");
        assertEq(info.totalTokensSold, 0, "sold not set yet");
        assertEq(info.claimDeadline, 0, "deadline not set yet");
    }

    /// @notice userInfo() live estimates equal the exact post-finalize payouts when no further deposits occur.
    function testUserInfoMatchesClaims() public {
        _warpOpen();
        _deposit(alice, ALICE_DEP);
        _deposit(bob, BOB_DEP);

        K613PublicSale.UserView memory before = sale.userInfo(alice);
        assertEq(before.deposited, ALICE_DEP, "deposited");
        assertEq(before.allocation, ALICE_ALLOC_150K, "live allocation estimate");
        assertEq(before.refund, ALICE_REFUND_150K, "live refund estimate");
        assertEq(before.claimableTokens, 0, "nothing claimable before finalize");
        assertEq(before.claimableRefund, 0, "no refund claimable before finalize");

        _finalize();
        K613PublicSale.UserView memory open = sale.userInfo(alice);
        assertEq(open.claimableTokens, ALICE_ALLOC_150K, "claimable tokens");
        assertEq(open.claimableRefund, ALICE_REFUND_150K, "claimable refund");

        vm.startPrank(alice);
        sale.claimTokens();
        sale.claimRefund();
        vm.stopPrank();

        K613PublicSale.UserView memory done = sale.userInfo(alice);
        assertTrue(done.tokensClaimed && done.refundClaimed, "claim flags");
        assertEq(done.claimableTokens, 0, "tokens no longer claimable");
        assertEq(done.claimableRefund, 0, "refund no longer claimable");
        assertEq(k613.balanceOf(alice), before.allocation, "payout equals pre-finalize estimate");
    }

    // ---------- deposit ----------

    /// @notice Deposit credits the user, updates totals, pulls USDC, and emits running totals.
    function testDepositCreditsAndEmits() public {
        _warpOpen();
        vm.startPrank(alice);
        usdc.approve(address(sale), 1_000e6);
        vm.expectEmit(true, false, false, true);
        emit Deposited(alice, 1_000e6, 1_000e6, 1_000e6);
        sale.deposit(1_000e6);
        vm.stopPrank();

        assertEq(sale.deposits(alice), 1_000e6, "user deposit");
        assertEq(sale.totalDeposits(), 1_000e6, "total deposits");
        assertEq(sale.participants(), 1, "participants");
        assertEq(usdc.balanceOf(address(sale)), 1_000e6, "usdc held");
    }

    /// @notice Multiple deposits by the same user aggregate and count one participant.
    function testDepositAggregatesSameUser() public {
        _warpOpen();
        _deposit(alice, 1_000e6);
        _deposit(alice, 2_500e6);
        assertEq(sale.deposits(alice), 3_500e6, "aggregated");
        assertEq(sale.totalDeposits(), 3_500e6, "total");
        assertEq(sale.participants(), 1, "still one participant");
    }

    /// @notice Each unique depositor increments the participant counter once.
    function testDepositCountsParticipants() public {
        _warpOpen();
        _deposit(alice, 100e6);
        _deposit(bob, 100e6);
        _deposit(carol, 100e6);
        _deposit(bob, 100e6);
        assertEq(sale.participants(), 3, "three unique participants");
    }

    /// @notice The deposit window is [saleStart, saleEnd): first and last second accepted, saleEnd rejected.
    function testDepositWindowBoundaries() public {
        vm.warp(saleStart);
        _deposit(alice, 100e6);
        vm.warp(saleEnd - 1);
        _deposit(alice, 100e6);
        vm.warp(saleEnd);
        vm.startPrank(alice);
        usdc.approve(address(sale), 100e6);
        vm.expectRevert(K613PublicSale.SaleNotOpen.selector);
        sale.deposit(100e6);
        vm.stopPrank();
    }

    /// @notice Depositing before the sale opens reverts.
    function testDepositRevertsBeforeStart() public {
        vm.startPrank(alice);
        usdc.approve(address(sale), 100e6);
        vm.expectRevert(K613PublicSale.SaleNotOpen.selector);
        sale.deposit(100e6);
        vm.stopPrank();
    }

    /// @notice Zero-amount deposits revert.
    function testDepositRevertsZeroAmount() public {
        _warpOpen();
        vm.prank(alice);
        vm.expectRevert(K613PublicSale.ZeroAmount.selector);
        sale.deposit(0);
    }

    /// @notice Deposits revert until the contract holds the full sale allocation, then succeed.
    function testDepositRevertsWhenUnfunded() public {
        K613PublicSale unfunded = _newUnfundedSale();
        _warpOpen();
        vm.startPrank(alice);
        usdc.approve(address(unfunded), 100e6);
        vm.expectRevert(K613PublicSale.SaleNotFunded.selector);
        unfunded.deposit(100e6);
        vm.stopPrank();

        k613.mint(address(unfunded), SALE_ALLOCATION);
        vm.prank(alice);
        unfunded.deposit(100e6);
        assertEq(unfunded.deposits(alice), 100e6, "deposit after funding");
    }

    /// @notice Deposits revert while paused and resume after unpause.
    function testDepositRevertsWhenPaused() public {
        _warpOpen();
        sale.pause();
        vm.startPrank(alice);
        usdc.approve(address(sale), 100e6);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        sale.deposit(100e6);
        vm.stopPrank();

        sale.unpause();
        vm.prank(alice);
        sale.deposit(100e6);
        assertEq(sale.deposits(alice), 100e6, "deposit after unpause");
    }

    /// @notice Deposits without sufficient allowance revert inside the USDC transferFrom.
    function testDepositRevertsWithoutApproval() public {
        _warpOpen();
        vm.prank(alice);
        vm.expectRevert(); // OZ ERC20InsufficientAllowance
        sale.deposit(100e6);
    }

    // ---------- finalize ----------

    /// @notice Anyone (even a non-depositor) can finalize once the sale has ended.
    function testFinalizeByAnyone() public {
        _warpOpen();
        _deposit(alice, ALICE_DEP);
        vm.warp(saleEnd);
        vm.expectEmit(false, false, false, true);
        emit Finalized(ALICE_DEP, SALE_ALLOCATION, block.timestamp + 365 days);
        vm.prank(carol);
        sale.finalize();
        assertTrue(sale.finalized(), "finalized");
        assertEq(sale.claimDeadline(), block.timestamp + 365 days, "deadline");
    }

    /// @notice Finalize reverts strictly before saleEnd and succeeds exactly at saleEnd.
    function testFinalizeBoundary() public {
        vm.warp(saleEnd - 1);
        vm.expectRevert(K613PublicSale.SaleNotEnded.selector);
        sale.finalize();
        vm.warp(saleEnd);
        sale.finalize();
        assertTrue(sale.finalized(), "finalized at exact end");
    }

    /// @notice Finalize cannot run twice.
    function testFinalizeRevertsTwice() public {
        _finalize();
        vm.expectRevert(K613PublicSale.AlreadyFinalized.selector);
        sale.finalize();
    }

    /// @notice Undersubscribed: tokens sold scale linearly with deposits at the implied price.
    function testFinalizeUndersubscribed() public {
        _warpOpen();
        _deposit(alice, 50_000e6);
        _finalize();
        assertEq(sale.totalTokensSold(), 5_000_000e18, "half the cap -> half the allocation");
    }

    /// @notice Oversubscribed: the full allocation is sold.
    function testFinalizeOversubscribed() public {
        _warpOpen();
        _deposit(alice, ALICE_DEP);
        _deposit(bob, BOB_DEP);
        _finalize();
        assertEq(sale.totalTokensSold(), SALE_ALLOCATION, "full allocation");
    }

    /// @notice Deposits exactly at the hard cap sell the full allocation with zero refunds.
    function testFinalizeAtExactHardCap() public {
        _warpOpen();
        _deposit(alice, HARD_CAP);
        _finalize();
        assertEq(sale.totalTokensSold(), SALE_ALLOCATION, "full allocation at exact cap");
        assertEq(sale.allocationOf(alice), SALE_ALLOCATION, "alice gets everything");
        assertEq(sale.refundOf(alice), 0, "no refund at exact cap");
    }

    /// @notice A sale with zero deposits still finalizes cleanly.
    function testFinalizeZeroDeposits() public {
        _finalize();
        assertEq(sale.totalTokensSold(), 0, "nothing sold");
        assertEq(sale.claimDeadline(), block.timestamp + 365 days, "deadline still set");
    }

    /// @notice Pause cannot block finalization.
    function testFinalizeWorksWhilePaused() public {
        sale.pause();
        vm.warp(saleEnd);
        sale.finalize();
        assertTrue(sale.finalized(), "finalized while paused");
    }

    // ---------- claims: undersubscribed ----------

    /// @notice Undersubscribed: a $30k deposit buys exactly 3,000,000 K613 at $0.01.
    function testClaimTokensFullFillUndersubscribed() public {
        _warpOpen();
        _deposit(alice, 30_000e6);
        _finalize();
        assertEq(sale.allocationOf(alice), 3_000_000e18, "exact full fill");

        vm.expectEmit(true, false, false, true);
        emit TokensClaimed(alice, 3_000_000e18);
        vm.prank(alice);
        sale.claimTokens();
        assertEq(k613.balanceOf(alice), 3_000_000e18, "tokens received");
    }

    /// @notice Undersubscribed: there is nothing to refund.
    function testClaimRefundRevertsWhenUndersubscribed() public {
        _warpOpen();
        _deposit(alice, 30_000e6);
        _finalize();
        vm.prank(alice);
        vm.expectRevert(K613PublicSale.NothingToClaim.selector);
        sale.claimRefund();
    }

    // ---------- claims: oversubscribed (1.5x worked example) ----------

    function _setUpOversubscribed() private {
        _warpOpen();
        _deposit(alice, ALICE_DEP);
        _deposit(bob, BOB_DEP);
        _finalize();
    }

    /// @notice Oversubscribed 1.5x: allocations are pro-rata with exact floor values.
    function testClaimTokensProRataOversubscribed() public {
        _setUpOversubscribed();
        vm.prank(alice);
        sale.claimTokens();
        vm.prank(bob);
        sale.claimTokens();
        assertEq(k613.balanceOf(alice), ALICE_ALLOC_150K, "alice 2/3 of allocation");
        assertEq(k613.balanceOf(bob), BOB_ALLOC_150K, "bob 1/3 of allocation");
        assertEq(ALICE_ALLOC_150K + BOB_ALLOC_150K, SALE_ALLOCATION - 1, "1 wei floor dust");
    }

    /// @notice Oversubscribed 1.5x: refunds return the unused 1/3 of each deposit to the same wallet.
    function testClaimRefundProRataOversubscribed() public {
        _setUpOversubscribed();
        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.expectEmit(true, false, false, true);
        emit RefundClaimed(alice, ALICE_REFUND_150K);
        vm.prank(alice);
        sale.claimRefund();
        vm.prank(bob);
        sale.claimRefund();

        assertEq(usdc.balanceOf(alice) - aliceBefore, ALICE_REFUND_150K, "alice refund");
        assertEq(ALICE_REFUND_150K + BOB_REFUND_150K, 50_000e6 - 1, "1 unit floor dust");
        // Spec identity: refund = deposit - usedFunds, usedFunds = ceil(deposit * cap / total).
        assertEq(ALICE_DEP - ALICE_REFUND_150K, 66_666_666_667, "alice used funds");
    }

    /// @notice Token and refund claims are independent and work in either order.
    function testClaimOrderIndependence() public {
        _setUpOversubscribed();
        vm.startPrank(alice);
        sale.claimTokens();
        sale.claimRefund();
        vm.stopPrank();
        vm.startPrank(bob);
        sale.claimRefund();
        sale.claimTokens();
        vm.stopPrank();
        assertEq(k613.balanceOf(alice), ALICE_ALLOC_150K, "alice tokens");
        assertEq(k613.balanceOf(bob), BOB_ALLOC_150K, "bob tokens");
    }

    /// @notice After all claims and the proceeds withdrawal, only bounded dust remains in the contract.
    function testDustBoundAfterFullLifecycle() public {
        _setUpOversubscribed();
        vm.startPrank(alice);
        sale.claimTokens();
        sale.claimRefund();
        vm.stopPrank();
        vm.startPrank(bob);
        sale.claimTokens();
        sale.claimRefund();
        vm.stopPrank();
        sale.withdrawProceeds(treasury);

        assertEq(usdc.balanceOf(treasury), HARD_CAP, "proceeds = hard cap");
        assertEq(usdc.balanceOf(address(sale)), 1, "exactly 1 USDC unit of dust");
        assertEq(k613.balanceOf(address(sale)), 1, "exactly 1 token wei of dust");
    }

    /// @notice Oversubscribed by a single USDC unit: individual refunds floor to zero.
    function testOversubscribedByOneUnitRefundsZero() public {
        _warpOpen();
        _deposit(alice, HARD_CAP);
        _deposit(bob, 1);
        _finalize();
        assertEq(sale.refundOf(alice), 0, "alice refund floors to zero");
        assertEq(sale.refundOf(bob), 0, "bob refund floors to zero");
        assertEq(sale.totalTokensSold(), SALE_ALLOCATION, "oversubscribed");
        assertLe(sale.allocationOf(alice) + sale.allocationOf(bob), SALE_ALLOCATION, "solvent");
    }

    // ---------- claims: gating ----------

    /// @notice Claims revert before finalization, even after the sale has ended.
    function testClaimsRevertBeforeFinalize() public {
        _warpOpen();
        _deposit(alice, ALICE_DEP);
        vm.warp(saleEnd); // ended but not finalized
        vm.startPrank(alice);
        vm.expectRevert(K613PublicSale.NotFinalized.selector);
        sale.claimTokens();
        vm.expectRevert(K613PublicSale.NotFinalized.selector);
        sale.claimRefund();
        vm.stopPrank();
    }

    /// @notice Each claim leg is one-shot.
    function testClaimsRevertTwice() public {
        _setUpOversubscribed();
        vm.startPrank(alice);
        sale.claimTokens();
        vm.expectRevert(K613PublicSale.AlreadyClaimed.selector);
        sale.claimTokens();
        sale.claimRefund();
        vm.expectRevert(K613PublicSale.AlreadyClaimed.selector);
        sale.claimRefund();
        vm.stopPrank();
    }

    /// @notice Non-depositors have nothing to claim on either leg.
    function testClaimsRevertForNonDepositor() public {
        _setUpOversubscribed();
        vm.startPrank(carol);
        vm.expectRevert(K613PublicSale.NothingToClaim.selector);
        sale.claimTokens();
        vm.expectRevert(K613PublicSale.NothingToClaim.selector);
        sale.claimRefund();
        vm.stopPrank();
    }

    /// @notice Claims close at the claim deadline.
    function testClaimsRevertAtDeadline() public {
        _setUpOversubscribed();
        vm.warp(sale.claimDeadline());
        vm.startPrank(alice);
        vm.expectRevert(K613PublicSale.ClaimWindowClosed.selector);
        sale.claimTokens();
        vm.expectRevert(K613PublicSale.ClaimWindowClosed.selector);
        sale.claimRefund();
        vm.stopPrank();
    }

    /// @notice Claims revert while paused and resume after unpause.
    function testClaimsRevertWhenPaused() public {
        _setUpOversubscribed();
        sale.pause();
        vm.startPrank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        sale.claimTokens();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        sale.claimRefund();
        vm.stopPrank();

        sale.unpause();
        vm.startPrank(alice);
        sale.claimTokens();
        sale.claimRefund();
        vm.stopPrank();
        assertEq(k613.balanceOf(alice), ALICE_ALLOC_150K, "claimed after unpause");
    }

    // ---------- withdrawProceeds ----------

    /// @notice Undersubscribed: proceeds equal total deposits.
    function testWithdrawProceedsUndersubscribed() public {
        _warpOpen();
        _deposit(alice, 30_000e6);
        _finalize();
        sale.withdrawProceeds(treasury);
        assertEq(usdc.balanceOf(treasury), 30_000e6, "all deposits withdrawn");
    }

    /// @notice Oversubscribed: proceeds are capped at the hard cap, leaving the refund pool intact.
    function testWithdrawProceedsOversubscribed() public {
        _setUpOversubscribed();
        sale.withdrawProceeds(treasury);
        assertEq(usdc.balanceOf(treasury), HARD_CAP, "proceeds capped");
        assertEq(usdc.balanceOf(address(sale)), 50_000e6, "refund pool stays");
    }

    /// @notice Every refund is still payable after the admin withdraws proceeds first (solvency end-to-end).
    function testWithdrawThenAllRefundsSucceed() public {
        _setUpOversubscribed();
        sale.withdrawProceeds(treasury);
        vm.prank(alice);
        sale.claimRefund();
        vm.prank(bob);
        sale.claimRefund();
        assertEq(usdc.balanceOf(address(sale)), 1, "only dust left");
    }

    /// @notice withdrawProceeds is admin-only, post-finalize, one-shot, and rejects the zero address.
    function testWithdrawProceedsGates() public {
        vm.expectRevert(K613PublicSale.NotFinalized.selector);
        sale.withdrawProceeds(treasury);

        _setUpOversubscribed();
        _expectNotAdmin(alice);
        vm.prank(alice);
        sale.withdrawProceeds(treasury);

        vm.expectRevert(K613PublicSale.ZeroAddress.selector);
        sale.withdrawProceeds(address(0));

        sale.withdrawProceeds(treasury);
        vm.expectRevert(K613PublicSale.AlreadyWithdrawn.selector);
        sale.withdrawProceeds(treasury);
    }

    // ---------- sweepUnsoldTokens ----------

    /// @notice Undersubscribed: the unsold half of the allocation is sweepable; claims still succeed afterwards.
    function testSweepUndersubscribed() public {
        _warpOpen();
        _deposit(alice, 50_000e6);
        _finalize();
        sale.sweepUnsoldTokens(treasury);
        assertEq(k613.balanceOf(treasury), 5_000_000e18, "unsold half swept");

        vm.prank(alice);
        sale.claimTokens();
        assertEq(k613.balanceOf(alice), 5_000_000e18, "claim unaffected by sweep");
    }

    /// @notice Oversubscribed with exact funding: everything is reserved for claims, nothing to sweep.
    function testSweepOversubscribedNothingToSweep() public {
        _setUpOversubscribed();
        vm.expectRevert(K613PublicSale.NothingToSweep.selector);
        sale.sweepUnsoldTokens(treasury);
    }

    /// @notice Over-funding above the sale allocation is sweepable without touching claim reserves.
    function testSweepWithOverfunding() public {
        k613.mint(address(sale), 1_000_000e18); // 11M total in the contract
        _setUpOversubscribed();
        sale.sweepUnsoldTokens(treasury);
        assertEq(k613.balanceOf(treasury), 1_000_000e18, "only the excess swept");

        vm.prank(alice);
        sale.claimTokens();
        vm.prank(bob);
        sale.claimTokens();
        assertEq(k613.balanceOf(alice), ALICE_ALLOC_150K, "alice claim intact");
        assertEq(k613.balanceOf(bob), BOB_ALLOC_150K, "bob claim intact");

        vm.expectRevert(K613PublicSale.NothingToSweep.selector);
        sale.sweepUnsoldTokens(treasury); // only floor dust remains, still reserved
    }

    /// @notice Sweep is admin-only and post-finalize.
    function testSweepGates() public {
        vm.expectRevert(K613PublicSale.NotFinalized.selector);
        sale.sweepUnsoldTokens(treasury);

        _setUpOversubscribed();
        _expectNotAdmin(alice);
        vm.prank(alice);
        sale.sweepUnsoldTokens(treasury);

        vm.expectRevert(K613PublicSale.ZeroAddress.selector);
        sale.sweepUnsoldTokens(address(0));
    }

    // ---------- recoverAfterDeadline ----------

    /// @notice Recovery is blocked before finalization and during the entire claim window.
    function testRecoverGates() public {
        vm.expectRevert(K613PublicSale.ClaimsStillOpen.selector);
        sale.recoverAfterDeadline(address(k613), treasury, 1);

        _setUpOversubscribed();
        vm.expectRevert(K613PublicSale.ClaimsStillOpen.selector);
        sale.recoverAfterDeadline(address(k613), treasury, 1);

        vm.warp(sale.claimDeadline());
        _expectNotAdmin(alice);
        vm.prank(alice);
        sale.recoverAfterDeadline(address(k613), treasury, 1);

        vm.expectRevert(K613PublicSale.ZeroAddress.selector);
        sale.recoverAfterDeadline(address(k613), address(0), 1);
    }

    /// @notice After the deadline the admin recovers never-claimed allocations, refunds, and dust.
    function testRecoverAfterDeadline() public {
        _setUpOversubscribed();
        vm.startPrank(alice);
        sale.claimTokens();
        sale.claimRefund();
        vm.stopPrank();
        sale.withdrawProceeds(treasury);
        // bob never claims either leg
        vm.warp(sale.claimDeadline());

        uint256 k613Left = k613.balanceOf(address(sale));
        uint256 usdcLeft = usdc.balanceOf(address(sale));
        assertEq(k613Left, BOB_ALLOC_150K + 1, "bob's allocation + dust");
        assertEq(usdcLeft, BOB_REFUND_150K + 1, "bob's refund + dust");

        sale.recoverAfterDeadline(address(k613), treasury, k613Left);
        sale.recoverAfterDeadline(address(usdc), treasury, usdcLeft);
        assertEq(k613.balanceOf(address(sale)), 0, "k613 emptied");
        assertEq(usdc.balanceOf(address(sale)), 0, "usdc emptied");
    }

    // ---------- pause roles ----------

    /// @notice Only PAUSER_ROLE can pause and unpause.
    function testPauseOnlyPauser() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, PAUSER_ROLE)
        );
        vm.prank(alice);
        sale.pause();

        sale.pause();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, PAUSER_ROLE)
        );
        vm.prank(alice);
        sale.unpause();
    }

    // ---------- fuzz ----------

    /// @notice Fuzz: repeated deposits aggregate exactly and count one participant.
    function testFuzzDepositAggregation(uint256 first, uint256 second) public {
        first = bound(first, 1, 100_000e6);
        second = bound(second, 1, 100_000e6);
        _warpOpen();
        _deposit(alice, first);
        _deposit(alice, second);
        assertEq(sale.deposits(alice), first + second, "aggregated deposit");
        assertEq(sale.totalDeposits(), first + second, "total");
        assertEq(sale.participants(), 1, "one participant");
    }

    /// @notice Fuzz: full lifecycle stays solvent in every regime (under, exact, over the cap).
    ///         All claims succeed, proceeds equal min(total, cap), and only bounded dust remains.
    function testFuzzSolvencyFullLifecycle(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 1, 200_000e6);
        b = bound(b, 1, 200_000e6);
        c = bound(c, 1, 200_000e6);
        _warpOpen();
        _deposit(alice, a);
        _deposit(bob, b);
        _deposit(carol, c);
        _finalize();
        uint256 total = a + b + c;

        address[3] memory users = [alice, bob, carol];
        uint256 claimedTokens;
        for (uint256 i = 0; i < 3; i++) {
            uint256 alloc = sale.allocationOf(users[i]);
            uint256 refund = sale.refundOf(users[i]);
            uint256 usdcBefore = usdc.balanceOf(users[i]);
            vm.prank(users[i]);
            sale.claimTokens();
            if (refund > 0) {
                vm.prank(users[i]);
                sale.claimRefund();
            }
            assertEq(k613.balanceOf(users[i]), alloc, "token payout matches view");
            assertEq(usdc.balanceOf(users[i]) - usdcBefore, refund, "refund payout matches view");
            claimedTokens += alloc;
        }
        assertLe(claimedTokens, sale.totalTokensSold(), "allocations never exceed tokens sold");

        sale.withdrawProceeds(treasury);
        assertEq(usdc.balanceOf(treasury), total < HARD_CAP ? total : HARD_CAP, "proceeds = min(total, cap)");

        if (total < HARD_CAP) {
            sale.sweepUnsoldTokens(treasury); // unsold tokens exist
        } else {
            vm.expectRevert(K613PublicSale.NothingToSweep.selector);
            sale.sweepUnsoldTokens(treasury); // everything reserved (incl. floor dust)
        }

        assertLt(k613.balanceOf(address(sale)), 3, "token dust < participants");
        assertLt(usdc.balanceOf(address(sale)), 3, "usdc dust < participants");
    }

    /// @notice Fuzz: refund identity matches the spec, refund = deposit - ceil(deposit * cap / total),
    ///         and a user never receives more token value than the USDC they spent.
    function testFuzzRefundIdentity(uint256 aliceDep, uint256 bobDep) public {
        aliceDep = bound(aliceDep, 1, 400_000e6);
        bobDep = bound(bobDep, 1, 400_000e6);
        vm.assume(aliceDep + bobDep > HARD_CAP);
        _warpOpen();
        _deposit(alice, aliceDep);
        _deposit(bob, bobDep);
        _finalize();

        uint256 total = aliceDep + bobDep;
        uint256 refund = sale.refundOf(alice);
        uint256 used = aliceDep - refund;
        assertEq(used, (aliceDep * HARD_CAP + total - 1) / total, "usedFunds = ceil(deposit * cap / total)");
        assertLe(sale.allocationOf(alice) * HARD_CAP, used * SALE_ALLOCATION, "never over-extracts value");
    }

    /// @notice Fuzz: a strictly larger deposit never receives a smaller allocation or refund.
    function testFuzzAllocationMonotonic(uint256 small, uint256 large) public {
        small = bound(small, 1, 500_000e6);
        large = bound(large, small, 500_000e6);
        _warpOpen();
        _deposit(alice, large);
        _deposit(bob, small);
        _finalize();
        assertGe(sale.allocationOf(alice), sale.allocationOf(bob), "allocation monotonic");
        assertGe(sale.refundOf(alice), sale.refundOf(bob), "refund monotonic");
    }

    /// @notice Fuzz: deposits succeed exactly within [saleStart, saleEnd) and revert outside.
    function testFuzzDepositWindowBoundary(uint256 ts) public {
        ts = bound(ts, saleStart - 1 days, saleEnd + 1 days);
        vm.warp(ts);
        vm.startPrank(alice);
        usdc.approve(address(sale), 100e6);
        if (ts >= saleStart && ts < saleEnd) {
            sale.deposit(100e6);
            assertEq(sale.deposits(alice), 100e6, "deposit inside window");
        } else {
            vm.expectRevert(K613PublicSale.SaleNotOpen.selector);
            sale.deposit(100e6);
        }
        vm.stopPrank();
    }

    /// @notice Fuzz: any address can finalize at any time after saleEnd; the deadline anchors to the call.
    function testFuzzFinalizePermissionless(address caller, uint256 delay) public {
        vm.assume(caller != address(0));
        delay = bound(delay, 0, 730 days);
        _warpOpen();
        _deposit(alice, ALICE_DEP);
        vm.warp(saleEnd + delay);
        vm.prank(caller);
        sale.finalize();
        assertTrue(sale.finalized(), "finalized by arbitrary caller");
        assertEq(sale.claimDeadline(), block.timestamp + 365 days, "deadline anchored to finalize call");
    }
}
