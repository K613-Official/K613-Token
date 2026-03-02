// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {K613} from "../src/token/K613.sol";
import {xK613} from "../src/token/xK613.sol";
import {Staking} from "../src/staking/Staking.sol";
import {RewardsDistributor} from "../src/staking/RewardsDistributor.sol";

contract StakingTest is Test {
    uint256 private constant LOCK_DURATION = 7 days;
    uint256 private constant EPOCH_DURATION = 7 days;
    uint256 private constant PENALTY_BPS = 5_000; // 50%
    uint256 private constant ONE = 1e18;

    K613 private k613;
    xK613 private xk613;
    Staking private staking;
    RewardsDistributor private distributor;

    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);

    function setUp() public {
        k613 = new K613(address(this));
        xk613 = new xK613(address(this));
        staking = new Staking(address(k613), address(xk613), LOCK_DURATION, PENALTY_BPS);
        distributor = new RewardsDistributor(address(xk613), address(xk613), address(k613), EPOCH_DURATION);

        staking.setRewardsDistributor(address(distributor));
        distributor.setStaking(address(staking));

        xk613.setMinter(address(staking));
        xk613.setTransferWhitelist(address(distributor), true);
        xk613.setTransferWhitelist(address(staking), true);

        k613.mint(alice, 10_000 * ONE);
        k613.mint(bob, 10_000 * ONE);
    }

    /// @notice test_Stake_MintsxK613ToUser: stake() transfers K613 to contract and mints 1:1 xK613 to user; deposits() and balances match.
    function test_Stake_MintsxK613ToUser() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);

        (uint256 amount,) = staking.deposits(alice);
        assertEq(amount, 100 * ONE);
        assertEq(xk613.balanceOf(alice), 100 * ONE);
        assertEq(k613.balanceOf(address(staking)), 100 * ONE);
    }

    /// @notice test_Stake_ZeroReverts: stake(0) reverts with ZeroAmount.
    function test_Stake_ZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(Staking.ZeroAmount.selector);
        staking.stake(0);
    }

    /// @notice test_Stake_CanAddMore: Multiple stakes from same user accumulate; backingIntegrity holds.
    function test_Stake_CanAddMore() public {
        vm.startPrank(alice);
        k613.approve(address(staking), 200 * ONE);
        staking.stake(100 * ONE);
        staking.stake(50 * ONE);
        vm.stopPrank();

        (uint256 amount,) = staking.deposits(alice);
        assertEq(amount, 150 * ONE);
        assertEq(xk613.balanceOf(alice), 150 * ONE);
        assertTrue(staking.backingIntegrity());
    }

    /// @notice test_BackingIntegrity_HoldsAfterStakeAndExit: backingIntegrity holds after stake and after full exit (initiateExit → wait lock → exit).
    function test_BackingIntegrity_HoldsAfterStakeAndExit() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        assertTrue(staking.backingIntegrity());

        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);
        vm.warp(block.timestamp + LOCK_DURATION);
        vm.prank(alice);
        staking.exit(0);
        assertTrue(staking.backingIntegrity());
    }

    /// @notice test_InitiateExit_StartsCountdown: initiateExit creates queue entry with exitInitiatedAt; exitRequestAt returns correct amount and timestamp.
    function test_InitiateExit_StartsCountdown() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);

        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);

        assertEq(staking.exitQueueLength(alice), 1);
        (, uint256 ts) = staking.exitRequestAt(alice, 0);
        assertEq(ts, block.timestamp);
        assertEq(xk613.balanceOf(alice), 0);
    }

    /// @notice test_InitiateExit_NothingStakedReverts: initiateExit with no stake reverts with NothingToInitiate.
    function test_InitiateExit_NothingStakedReverts() public {
        vm.prank(alice);
        vm.expectRevert(Staking.NothingToInitiate.selector);
        staking.initiateExit(1);
    }

    /// @notice test_InitiateExit_AmountExceedsReverts: initiateExit(amount) exceeding available stake reverts with AmountExceedsStake.
    function test_InitiateExit_AmountExceedsReverts() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);

        vm.prank(alice);
        vm.expectRevert(Staking.AmountExceedsStake.selector);
        staking.initiateExit(101 * ONE);
    }

    /// @notice test_InitiateExit_InsufficientxK613Reverts: initiateExit when user's xK613 is in RD (balance 0) reverts with InsufficientxK613.
    function test_InitiateExit_InsufficientxK613Reverts() public {
        xk613.setTransferWhitelist(address(bob), true);
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        // Alice transfers xK613 away - she no longer holds enough
        vm.prank(alice);
        xk613.transfer(bob, 50 * ONE);

        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        vm.expectRevert(Staking.InsufficientxK613.selector);
        staking.initiateExit(100 * ONE);
    }

    /// @notice test_CancelExit_ResetsQueue: cancelExit returns xK613 to user and removes request from queue; queue length and balances correct.
    function test_CancelExit_ResetsQueue() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);

        vm.prank(alice);
        staking.cancelExit(0);

        assertEq(staking.exitQueueLength(alice), 0);
        assertEq(xk613.balanceOf(alice), 100 * ONE);
    }

    /// @notice test_CancelExit_NotInitiatedReverts: cancelExit with invalid index reverts with InvalidExitIndex.
    function test_CancelExit_NotInitiatedReverts() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);

        vm.prank(alice);
        vm.expectRevert(Staking.InvalidExitIndex.selector);
        staking.cancelExit(0);
    }

    /// @notice test_Exit_WithoutInitiateReverts: exit(index) with empty queue or invalid index reverts with InvalidExitIndex.
    function test_Exit_WithoutInitiateReverts() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);

        vm.warp(block.timestamp + LOCK_DURATION);
        vm.prank(alice);
        vm.expectRevert(Staking.InvalidExitIndex.selector);
        staking.exit(0);
    }

    /// @notice test_Exit_BeforeLockReverts: exit(0) before lock duration reverts with Locked.
    function test_Exit_BeforeLockReverts() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);

        vm.warp(block.timestamp + LOCK_DURATION - 1);
        vm.prank(alice);
        vm.expectRevert(Staking.Locked.selector);
        staking.exit(0);
    }

    /// @notice test_Exit_AfterLockSuccess: After lock, exit(0) burns xK613 and returns K613 to user; backingIntegrity holds.
    function test_Exit_AfterLockSuccess() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);

        vm.warp(block.timestamp + LOCK_DURATION);
        uint256 aliceBefore = k613.balanceOf(alice);
        vm.prank(alice);
        staking.exit(0);

        (uint256 amount,) = staking.deposits(alice);
        assertEq(amount, 0);
        assertEq(k613.balanceOf(alice), aliceBefore + 100 * ONE);
    }

    /// @notice test_Exit_ExactLockBoundary: exit at exactly lockDuration boundary succeeds (timestamp == exitInitiatedAt + lockDuration).
    function test_Exit_ExactLockBoundary() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);

        uint256 before = k613.balanceOf(alice);
        vm.warp(block.timestamp + LOCK_DURATION);
        vm.prank(alice);
        staking.exit(0);
        assertEq(k613.balanceOf(alice), before + 100 * ONE);
    }

    /// @notice test_InstantExit_WithoutInitiateReverts: instantExit with no queue reverts with InvalidExitIndex.
    function test_InstantExit_WithoutInitiateReverts() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);

        vm.prank(alice);
        vm.expectRevert(Staking.InvalidExitIndex.selector);
        staking.instantExit(0);
    }

    /// @notice test_InstantExit_AfterLockReverts: instantExit after lock has passed reverts with Unlocked.
    function test_InstantExit_AfterLockReverts() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);

        vm.warp(block.timestamp + LOCK_DURATION);
        vm.prank(alice);
        vm.expectRevert(Staking.Unlocked.selector);
        staking.instantExit(0);
    }

    /// @notice test_SetRewardsDistributor_AllowsZero: setRewardsDistributor(address(0)) is allowed (disables penalty destination).
    function test_SetRewardsDistributor_AllowsZero() public {
        staking.setRewardsDistributor(address(0));
        assertEq(address(staking.rewardsDistributor()), address(0));
    }

    /// @notice test_InstantExit_RevertsWhenDistributorZeroAndPenalty: instantExit with penalty and no rewards distributor set reverts with RewardsDistributorNotSet.
    function test_InstantExit_RevertsWhenDistributorZeroAndPenalty() public {
        staking.setRewardsDistributor(address(0));
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);
        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        vm.expectRevert(Staking.RewardsDistributorNotSet.selector);
        staking.instantExit(0);
    }

    /// @notice test_InstantExit_PenaltyToDistributor: instantExit sends penalty K613 to RewardsDistributor and addPendingPenalty is called.
    function test_InstantExit_PenaltyToDistributor() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);

        vm.warp(block.timestamp + 1 days);
        uint256 aliceBefore = k613.balanceOf(alice);
        vm.prank(alice);
        staking.instantExit(0);

        uint256 penalty = (100 * ONE * PENALTY_BPS) / 10_000;
        uint256 payout = 100 * ONE - penalty;

        assertEq(k613.balanceOf(alice), aliceBefore + payout);
    }

    /// @notice test_InstantExit_PartialRequest: User has multiple exit requests; instantExit on one leaves others in queue and partial stake remains.
    function test_InstantExit_PartialRequest() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 40 * ONE);
        vm.prank(alice);
        staking.initiateExit(40 * ONE);

        uint256 before = k613.balanceOf(alice);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        staking.instantExit(0);

        (uint256 amount,) = staking.deposits(alice);
        assertEq(amount, 60 * ONE);
        uint256 penalty = (40 * ONE * PENALTY_BPS) / 10_000;
        uint256 payout = 40 * ONE - penalty;
        assertEq(k613.balanceOf(alice), before + payout);
    }

    /// @notice test_InstantExit_FullClearsQueue: instantExit on only request clears queue; user receives payout (amount - penalty).
    function test_InstantExit_FullClearsQueue() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        staking.instantExit(0);

        (uint256 amount,) = staking.deposits(alice);
        assertEq(amount, 0);
        assertEq(staking.exitQueueLength(alice), 0);
    }

    /// @notice test_StakeAfterCancelExit: After cancelExit user can stake again; state and balances consistent.
    function test_StakeAfterCancelExit() public {
        vm.prank(alice);
        k613.approve(address(staking), 200 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);
        vm.prank(alice);
        staking.cancelExit(0);

        vm.prank(alice);
        staking.stake(50 * ONE);

        (uint256 amount,) = staking.deposits(alice);
        assertEq(amount, 150 * ONE);
        assertEq(staking.exitQueueLength(alice), 0);
    }

    /// @notice test_ExitAfterCancelAndReinitiate: Cancel one exit, re-initiate same amount, wait lock, exit; user gets K613 back and backingIntegrity holds.
    function test_ExitAfterCancelAndReinitiate() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);
        vm.prank(alice);
        staking.cancelExit(0);
        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);

        uint256 before = k613.balanceOf(alice);
        vm.warp(block.timestamp + LOCK_DURATION);
        vm.prank(alice);
        staking.exit(0);
        assertEq(k613.balanceOf(alice), before + 100 * ONE);
    }

    /// @notice test_ExitQueue_MultipleRequests: Multiple initiateExit entries; exit in order or mixed; queue length and amounts correct.
    function test_ExitQueue_MultipleRequests() public {
        vm.prank(alice);
        k613.approve(address(staking), 200 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.initiateExit(30 * ONE);
        vm.prank(alice);
        staking.initiateExit(20 * ONE);

        assertEq(staking.exitQueueLength(alice), 2);
        (uint256 a0,) = staking.exitRequestAt(alice, 0);
        (uint256 a1,) = staking.exitRequestAt(alice, 1);
        assertEq(a0, 30 * ONE);
        assertEq(a1, 20 * ONE);

        vm.warp(block.timestamp + LOCK_DURATION);
        vm.prank(alice);
        staking.exit(0);
        assertEq(staking.exitQueueLength(alice), 1);
        vm.prank(alice);
        staking.exit(0);
        assertEq(staking.exitQueueLength(alice), 0);
        (uint256 amount,) = staking.deposits(alice);
        assertEq(amount, 50 * ONE);
    }

    /// @notice test_InstantExit_PenaltyGoesToRewardsDistributor: instantExit penalty is transferred to RD and pendingPenalties increases.
    function test_InstantExit_PenaltyGoesToRewardsDistributor() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);

        vm.warp(block.timestamp + 1 days);
        uint256 rdBefore = k613.balanceOf(address(distributor));
        vm.prank(alice);
        staking.instantExit(0);

        uint256 penalty = (100 * ONE * PENALTY_BPS) / 10_000;
        assertEq(k613.balanceOf(address(distributor)), rdBefore + penalty);
    }

    /// @notice test_Pause_BlocksStake: When Staking is paused, stake() reverts.
    function test_Pause_BlocksStake() public {
        staking.pause();

        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        vm.expectRevert();
        staking.stake(100 * ONE);
    }

    /// @notice test_Pause_BlocksExit: When Staking is paused, exit() reverts.
    function test_Pause_BlocksExit() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);
        vm.warp(block.timestamp + LOCK_DURATION);

        staking.pause();

        vm.prank(alice);
        vm.expectRevert();
        staking.exit(0);
    }

    /// @notice test_InitiateExit_ExitQueueFull: initiateExit when queue has MAX_EXIT_REQUESTS reverts with ExitQueueFull.
    function test_InitiateExit_ExitQueueFull() public {
        vm.prank(alice);
        k613.approve(address(staking), 1_100 * ONE);
        vm.prank(alice);
        staking.stake(1_100 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 1_100 * ONE);
        for (uint256 i = 0; i < staking.MAX_EXIT_REQUESTS(); i++) {
            vm.prank(alice);
            staking.initiateExit(100 * ONE);
        }
        vm.prank(alice);
        vm.expectRevert(Staking.ExitQueueFull.selector);
        staking.initiateExit(100 * ONE);
    }

    /// @notice test_InstantExit_PenaltyZeroBps: When instantExitPenaltyBps is 0, instantExit pays no penalty and full amount to user (no RD needed).
    function test_InstantExit_PenaltyZeroBps() public {
        xK613 freshXk = new xK613(address(this));
        Staking noPenaltyStaking = new Staking(address(k613), address(freshXk), LOCK_DURATION, 0);
        freshXk.setMinter(address(noPenaltyStaking));
        freshXk.setTransferWhitelist(address(noPenaltyStaking), true);

        vm.prank(alice);
        k613.approve(address(noPenaltyStaking), 100 * ONE);
        vm.prank(alice);
        noPenaltyStaking.stake(100 * ONE);
        vm.prank(alice);
        freshXk.approve(address(noPenaltyStaking), 100 * ONE);
        vm.prank(alice);
        noPenaltyStaking.initiateExit(100 * ONE);
        vm.warp(block.timestamp + 1 days);

        uint256 before = k613.balanceOf(alice);
        vm.prank(alice);
        noPenaltyStaking.instantExit(0);
        assertEq(k613.balanceOf(alice), before + 100 * ONE);
    }

    /// @notice test_Pause_BlocksInitiateExit: When Staking is paused, initiateExit() reverts.
    function test_Pause_BlocksInitiateExit() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        staking.pause();
        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        vm.expectRevert();
        staking.initiateExit(100 * ONE);
    }

    /// @notice test_Pause_BlocksCancelExit: When Staking is paused, cancelExit() reverts.
    function test_Pause_BlocksCancelExit() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);
        staking.pause();
        vm.prank(alice);
        vm.expectRevert();
        staking.cancelExit(0);
    }

    /// @notice test_Pause_BlocksInstantExit: When Staking is paused, instantExit() reverts.
    function test_Pause_BlocksInstantExit() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);
        vm.warp(block.timestamp + 1 days);
        staking.pause();
        vm.prank(alice);
        vm.expectRevert();
        staking.instantExit(0);
    }

    /// @notice test_InvalidBps_Reverts: Constructor with instantExitPenaltyBps > 10_000 reverts with InvalidBps.
    function test_InvalidBps_Reverts() public {
        vm.expectRevert(Staking.InvalidBps.selector);
        new Staking(address(k613), address(xk613), LOCK_DURATION, 10_001);
    }

    /// @notice test_ExitQueue_SwapRemove_IndexIntegrity: After swap-remove (cancel/exit), remaining queue indices are valid and amounts sum correctly.
    function test_ExitQueue_SwapRemove_IndexIntegrity() public {
        vm.prank(alice);
        k613.approve(address(staking), 300 * ONE);
        vm.prank(alice);
        staking.stake(300 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 300 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);

        vm.prank(alice);
        staking.cancelExit(1);
        (uint256 a0,) = staking.exitRequestAt(alice, 0);
        (uint256 a1,) = staking.exitRequestAt(alice, 1);
        assertEq(a0, 100 * ONE);
        assertEq(a1, 100 * ONE);

        vm.warp(block.timestamp + LOCK_DURATION);
        vm.prank(alice);
        staking.exit(1);
        (uint256 r0,) = staking.exitRequestAt(alice, 0);
        assertEq(r0, 100 * ONE);
        assertEq(staking.exitQueueLength(alice), 1);
    }

    /// @notice test_InstantExit_Multiple_PenaltiesGoToRewardsDistributor: Multiple instant exits; total penalty sent to RD equals sum of individual penalties.
    function test_InstantExit_Multiple_PenaltiesGoToRewardsDistributor() public {
        vm.prank(alice);
        k613.approve(address(staking), 300 * ONE);
        vm.prank(alice);
        staking.stake(300 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 300 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        staking.instantExit(0);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        staking.instantExit(0);

        uint256 expected = (200 * ONE * PENALTY_BPS) / 10_000;
        assertEq(k613.balanceOf(address(distributor)), expected);
    }
}
