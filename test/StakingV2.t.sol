// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {K613} from "../src/token/K613.sol";
import {xK613} from "../src/token/xK613.sol";
import {StakingV2} from "../src/staking/StakingV2.sol";
import {RewardsDistributor} from "../src/staking/RewardsDistributor.sol";

/// @title StakingV2Test
/// @notice Two groups of tests:
///         1. Ported from Staking.t.sol (V1) — same behavior, unaffected by the redesign. Where V1
///            asserted on `deposits(user).amount`, the expected values are unchanged: in every one
///            of these flows the "V1 position after processing" and "V2 live xK613 balance" are
///            numerically identical (they only diverge for reward-derived xK613, which V1 handled
///            via a separate side door — see group 2). Two V1 tests are gone because their error
///            (`NothingToInitiate` / `AmountExceedsStake`) no longer exists — the single balance
///            check (`InsufficientxK613`) now covers both cases.
///         2. New — prove the structural fix: xK613 a wallet holds because someone ELSE staked and
///            distributed it (RewardsDistributor, Treasury) exits through the ordinary queue, same
///            as self-staked xK613, with no side door and no free pass on the instant-exit penalty.
contract StakingV2Test is Test {
    uint256 private constant LOCK_DURATION = 7 days;
    uint256 private constant EPOCH_DURATION = 7 days;
    uint256 private constant PENALTY_BPS = 5_000; // 50%
    uint256 private constant ONE = 1e18;

    K613 private k613;
    xK613 private xk613;
    StakingV2 private staking;
    RewardsDistributor private distributor;

    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    /// @notice Stands in for Treasury/RD as an external xK613 source, so reward-flow tests don't
    ///         need to deploy the full Treasury contract just to push tokens into a wallet.
    address private rewardSource = address(this);

    function setUp() public {
        k613 = new K613(address(this));
        xk613 = new xK613(address(this));
        staking = new StakingV2(address(k613), address(xk613), LOCK_DURATION, PENALTY_BPS);
        distributor = new RewardsDistributor(address(xk613), address(xk613), address(k613), EPOCH_DURATION);

        staking.setRewardsDistributor(address(distributor));
        distributor.setStaking(address(staking));

        xk613.setMinter(address(staking));
        xk613.setTransferWhitelist(address(distributor), true);
        xk613.setTransferWhitelist(address(staking), true);
        xk613.setTransferWhitelist(rewardSource, true);

        k613.mint(alice, 10_000 * ONE);
        k613.mint(bob, 10_000 * ONE);
        k613.mint(rewardSource, 10_000 * ONE);
    }

    // =========================================================================================
    //  GROUP 1 — ported from V1, unaffected by the redesign
    // =========================================================================================

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
        vm.expectRevert(StakingV2.ZeroAmount.selector);
        staking.stake(0);
    }

    /// @notice test_Stake_CanAddMore: Multiple stakes from same user accumulate.
    function test_Stake_CanAddMore() public {
        vm.startPrank(alice);
        k613.approve(address(staking), 200 * ONE);
        staking.stake(100 * ONE);
        staking.stake(50 * ONE);
        vm.stopPrank();

        (uint256 amount,) = staking.deposits(alice);
        assertEq(amount, 150 * ONE);
        assertEq(xk613.balanceOf(alice), 150 * ONE);
    }

    /// @notice test_TotalBacking_HoldsAfterStakeAndExit: total backing and supply match after stake and full exit.
    function test_TotalBacking_HoldsAfterStakeAndExit() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        assertEq(xk613.totalSupply(), staking.totalBacking());

        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);
        vm.warp(block.timestamp + LOCK_DURATION);
        vm.prank(alice);
        staking.exit(0);
        assertEq(xk613.totalSupply(), staking.totalBacking());
    }

    /// @notice test_InitiateExit_StartsCountdown: initiateExit creates queue entry with exitInitiatedAt.
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

    /// @notice test_InitiateExit_ZeroBalanceReverts: initiateExit with no xK613 at all reverts with
    ///         InsufficientxK613 — replaces V1's NothingToInitiate, same outcome for this case.
    function test_InitiateExit_ZeroBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(StakingV2.InsufficientxK613.selector);
        staking.initiateExit(1);
    }

    /// @notice test_InitiateExit_AmountExceedsBalanceReverts: initiateExit(amount) exceeding the
    ///         caller's balance reverts with InsufficientxK613 — replaces V1's AmountExceedsStake,
    ///         same outcome for this case (V1 had two errors for what is now one check).
    function test_InitiateExit_AmountExceedsBalanceReverts() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);

        vm.prank(alice);
        vm.expectRevert(StakingV2.InsufficientxK613.selector);
        staking.initiateExit(101 * ONE);
    }

    /// @notice test_InitiateExit_InsufficientxK613Reverts: after sending xK613 away, initiateExit for
    ///         more than the remaining balance reverts with InsufficientxK613.
    function test_InitiateExit_InsufficientxK613Reverts() public {
        xk613.setTransferWhitelist(address(bob), true);
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        vm.prank(alice);
        xk613.transfer(bob, 50 * ONE);

        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        vm.expectRevert(StakingV2.InsufficientxK613.selector);
        staking.initiateExit(100 * ONE);
    }

    /// @notice test_CancelExit_ResetsQueue: cancelExit returns xK613 to user and removes request from queue.
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
        vm.expectRevert(StakingV2.InvalidExitIndex.selector);
        staking.cancelExit(0);
    }

    /// @notice test_Exit_WithoutInitiateReverts: exit(index) with empty queue reverts with InvalidExitIndex.
    function test_Exit_WithoutInitiateReverts() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);

        vm.warp(block.timestamp + LOCK_DURATION);
        vm.prank(alice);
        vm.expectRevert(StakingV2.InvalidExitIndex.selector);
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
        vm.expectRevert(StakingV2.Locked.selector);
        staking.exit(0);
    }

    /// @notice test_Exit_AfterLockSuccess: After lock, exit(0) burns xK613 and returns K613 to user.
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

    /// @notice test_Exit_ExactLockBoundary: exit at exactly lockDuration boundary succeeds.
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
        vm.expectRevert(StakingV2.InvalidExitIndex.selector);
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
        vm.expectRevert(StakingV2.Unlocked.selector);
        staking.instantExit(0);
    }

    /// @notice test_SetRewardsDistributor_AllowsZero: setRewardsDistributor(address(0)) is allowed.
    function test_SetRewardsDistributor_AllowsZero() public {
        staking.setRewardsDistributor(address(0));
        assertEq(address(staking.rewardsDistributor()), address(0));
    }

    /// @notice stake(amount) with K613 balance < amount reverts.
    function test_Stake_InsufficientK613Balance_Reverts() public {
        address carol = address(0xC0C);
        k613.mint(carol, 50 * ONE);

        vm.startPrank(carol);
        k613.approve(address(staking), 100 * ONE);
        vm.expectRevert();
        staking.stake(100 * ONE);
        vm.stopPrank();

        assertEq(k613.balanceOf(address(staking)), 0);
        (uint256 amount,) = staking.deposits(carol);
        assertEq(amount, 0);
    }

    /// @notice test_InstantExit_RevertsWhenDistributorZeroAndPenalty.
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
        vm.expectRevert(StakingV2.RewardsDistributorNotSet.selector);
        staking.instantExit(0);
    }

    /// @notice Only DEFAULT_ADMIN_ROLE can call setRewardsDistributor.
    function test_SetRewardsDistributor_OnlyAdmin() public {
        address nonAdmin = address(0xBAD);
        address newRd = address(0x1234);

        staking.setRewardsDistributor(address(distributor));
        assertEq(address(staking.rewardsDistributor()), address(distributor));

        vm.prank(nonAdmin);
        vm.expectRevert();
        staking.setRewardsDistributor(newRd);
    }

    /// @notice test_InstantExit_PenaltyToDistributor: instantExit sends penalty K613 to RewardsDistributor.
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

    /// @notice test_InstantExit_PartialRequest: instantExit on one request leaves the rest of the balance liquid.
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

    /// @notice test_InstantExit_FullClearsQueue: instantExit on only request clears queue.
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

    /// @notice test_StakeAfterCancelExit: After cancelExit user can stake again.
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

    /// @notice test_ExitAfterCancelAndReinitiate.
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

    /// @notice test_ExitQueue_MultipleRequests.
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

    /// @notice test_InstantExit_PenaltyGoesToRewardsDistributor.
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

    /// @notice test_Pause_BlocksStake.
    function test_Pause_BlocksStake() public {
        staking.pause();
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        vm.expectRevert();
        staking.stake(100 * ONE);
    }

    /// @notice test_Pause_BlocksExit.
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

    /// @notice test_InitiateExit_ExitQueueFull.
    function test_InitiateExit_ExitQueueFull() public {
        uint256 maxRequests = staking.MAX_EXIT_REQUESTS();
        uint256 perExit = 1 * ONE;
        uint256 totalNeeded = perExit * (maxRequests + 1);

        vm.prank(alice);
        k613.approve(address(staking), totalNeeded);
        vm.prank(alice);
        staking.stake(totalNeeded);
        vm.prank(alice);
        xk613.approve(address(staking), totalNeeded);
        for (uint256 i = 0; i < maxRequests; i++) {
            vm.prank(alice);
            staking.initiateExit(perExit);
        }
        vm.prank(alice);
        vm.expectRevert(StakingV2.ExitQueueFull.selector);
        staking.initiateExit(perExit);
    }

    /// @notice test_InstantExit_PenaltyZeroBps: Constructor rejects instantExitPenaltyBps == 0.
    function test_InstantExit_PenaltyZeroBps() public {
        xK613 freshXk = new xK613(address(this));
        vm.expectRevert(StakingV2.InvalidBps.selector);
        new StakingV2(address(k613), address(freshXk), LOCK_DURATION, 0);
    }

    /// @notice test_Pause_BlocksInitiateExit.
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

    /// @notice test_Pause_BlocksCancelExit.
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

    /// @notice test_Pause_BlocksInstantExit.
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

    /// @notice test_InvalidBps_Reverts.
    function test_InvalidBps_Reverts() public {
        vm.expectRevert(StakingV2.InvalidBps.selector);
        new StakingV2(address(k613), address(xk613), LOCK_DURATION, 10_001);
    }

    /// @notice test_ExitQueue_SwapRemove_IndexIntegrity.
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

    /// @notice test_InstantExit_Multiple_PenaltiesGoToRewardsDistributor.
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

    /// @notice Invariant: xK613.totalSupply should equal staking.totalBacking across typical flows.
    function test_Invariant_xK613Supply_EqualsTotalBacking() public {
        vm.prank(alice);
        k613.approve(address(staking), 300 * ONE);
        vm.prank(alice);
        staking.stake(300 * ONE);

        vm.prank(bob);
        k613.approve(address(staking), 200 * ONE);
        vm.prank(bob);
        staking.stake(200 * ONE);

        assertEq(xk613.totalSupply(), staking.totalBacking());

        vm.startPrank(alice);
        xk613.approve(address(staking), 100 * ONE);
        staking.initiateExit(100 * ONE);
        vm.warp(block.timestamp + LOCK_DURATION);
        staking.exit(0);
        vm.stopPrank();

        assertEq(xk613.totalSupply(), staking.totalBacking());

        vm.startPrank(bob);
        xk613.approve(address(staking), 200 * ONE);
        staking.initiateExit(200 * ONE);
        vm.warp(block.timestamp + 1 days);
        staking.instantExit(0);
        vm.stopPrank();

        assertEq(xk613.totalSupply(), staking.totalBacking());
    }

    /// @notice Direct K613 transfers to staking contract do not change tracked total backing.
    function test_DirectK613Transfer_DoesNotChangeTotalBacking() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        assertEq(staking.totalBacking(), 100 * ONE);

        vm.prank(alice);
        k613.transfer(address(staking), 10 * ONE);

        assertEq(staking.totalBacking(), 100 * ONE);
    }

    /// @notice testConstructorZeroAddressReverts.
    function testConstructorZeroAddressReverts() public {
        vm.expectRevert(StakingV2.ZeroAddress.selector);
        new StakingV2(address(0), address(xk613), LOCK_DURATION, PENALTY_BPS);

        vm.expectRevert(StakingV2.ZeroAddress.selector);
        new StakingV2(address(k613), address(0), LOCK_DURATION, PENALTY_BPS);
    }

    /// @notice testPauseUnpauseOnlyPauser.
    function testPauseUnpauseOnlyPauser() public {
        vm.prank(alice);
        vm.expectRevert();
        staking.pause();

        staking.pause();

        vm.prank(alice);
        vm.expectRevert();
        staking.unpause();
    }

    /// @notice testInitiateExitZeroAmountReverts.
    function testInitiateExitZeroAmountReverts() public {
        vm.prank(alice);
        vm.expectRevert(StakingV2.ZeroAmount.selector);
        staking.initiateExit(0);
    }

    /// @notice testCancelExitInvalidIndexRevertsWhenQueueNotEmpty.
    function testCancelExitInvalidIndexRevertsWhenQueueNotEmpty() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);

        vm.prank(alice);
        vm.expectRevert(StakingV2.InvalidExitIndex.selector);
        staking.cancelExit(1);
    }

    // =========================================================================================
    //  GROUP 2 — new: the structural H-01 fix, and its stated consequence
    // =========================================================================================

    /// @notice Gives `to` `amount` xK613 that `to` never personally staked, by having `rewardSource`
    ///         stake on its own behalf and forward the resulting xK613 — the same shape as a
    ///         RewardsDistributor claim or a Treasury distribution landing in a wallet.
    function _giveRewardXK613(address to, uint256 amount) internal {
        k613.approve(address(staking), amount);
        staking.stake(amount);
        xk613.transfer(to, amount);
    }

    /// @notice test_RewardRecipient_CanInitiateExit_NoPriorStake: a wallet that never called stake()
    ///         itself, only received xK613 as a reward, can call initiateExit directly. This is the
    ///         H-01 fix: no redeemRewards side door needed, the main path just works.
    function test_RewardRecipient_CanInitiateExit_NoPriorStake() public {
        _giveRewardXK613(alice, 500 * ONE);
        assertEq(xk613.balanceOf(alice), 500 * ONE);

        vm.prank(alice);
        xk613.approve(address(staking), 500 * ONE);
        vm.prank(alice);
        staking.initiateExit(500 * ONE);

        assertEq(staking.exitQueueLength(alice), 1);
        assertEq(xk613.balanceOf(alice), 0);
    }

    /// @notice test_RewardRecipient_ExitsAfterLock_FullAmount_NoPenalty: after the lock, the reward
    ///         recipient gets 100% of the K613 back — same terms as a self-staker, exactly what the
    ///         public documentation promises for xK613 -> K613 conversion.
    function test_RewardRecipient_ExitsAfterLock_FullAmount_NoPenalty() public {
        _giveRewardXK613(alice, 500 * ONE);

        vm.prank(alice);
        xk613.approve(address(staking), 500 * ONE);
        vm.prank(alice);
        staking.initiateExit(500 * ONE);

        vm.warp(block.timestamp + LOCK_DURATION);
        vm.prank(alice);
        staking.exit(0);

        assertEq(k613.balanceOf(alice), 10_000 * ONE + 500 * ONE);
    }

    /// @notice test_RewardRecipient_InstantExit_PaysSamePenaltyAsSelfStaker: a reward recipient who
    ///         exits early pays the same penalty as anyone else — V1's redeemRewards let this
    ///         portion out instantly and penalty-free, which this test proves V2 no longer allows.
    function test_RewardRecipient_InstantExit_PaysSamePenaltyAsSelfStaker() public {
        _giveRewardXK613(alice, 500 * ONE);

        vm.prank(alice);
        xk613.approve(address(staking), 500 * ONE);
        vm.prank(alice);
        staking.initiateExit(500 * ONE);

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        staking.instantExit(0);

        uint256 penalty = (500 * ONE * PENALTY_BPS) / 10_000;
        assertEq(k613.balanceOf(alice), 10_000 * ONE + 500 * ONE - penalty);
        assertEq(k613.balanceOf(address(distributor)), penalty);
    }

    /// @notice test_MixedBalance_SelfStakedAndReward_QueueTogetherUpToFullBalance: a user who both
    ///         staked their own K613 AND received a reward can queue their FULL combined balance in
    ///         one call — V1 capped `initiateExit` at the self-staked portion only (`s.amount`),
    ///         forcing the reward portion through the separate instant/no-penalty side door. V2 has
    ///         no such split.
    function test_MixedBalance_SelfStakedAndReward_QueueTogetherUpToFullBalance() public {
        vm.prank(alice);
        k613.approve(address(staking), 300 * ONE);
        vm.prank(alice);
        staking.stake(300 * ONE);

        _giveRewardXK613(alice, 200 * ONE);
        assertEq(xk613.balanceOf(alice), 500 * ONE);

        vm.prank(alice);
        xk613.approve(address(staking), 500 * ONE);
        vm.prank(alice);
        staking.initiateExit(500 * ONE);

        vm.warp(block.timestamp + LOCK_DURATION);
        vm.prank(alice);
        staking.exit(0);
        assertEq(k613.balanceOf(alice), 10_000 * ONE - 300 * ONE + 500 * ONE);
    }

    /// @notice test_TreasuryStakingPosition_NotPermanentlyLocked: the exact H-01 scenario (audit
    ///         finding, see test/AuditFindings.t.sol for the V1 side-door version) — an address
    ///         stakes, distributes all the resulting xK613 onward, and is left with a "position" it
    ///         can never personally unstake. In V2 this isn't even a distinguishable state: the
    ///         distributing address simply has a lower balance, and whoever received the xK613 exits
    ///         it through the ordinary queue. Nothing is stranded.
    function test_TreasuryStakingPosition_NotPermanentlyLocked() public {
        // rewardSource stakes, then gives every bit of the resulting xK613 to Alice.
        k613.approve(address(staking), 500 * ONE);
        staking.stake(500 * ONE);
        xk613.transfer(alice, 500 * ONE);
        assertEq(xk613.balanceOf(rewardSource), 0);

        // Alice, who never called stake() herself, exits the full amount through the ordinary queue.
        vm.prank(alice);
        xk613.approve(address(staking), 500 * ONE);
        vm.prank(alice);
        staking.initiateExit(500 * ONE);
        vm.warp(block.timestamp + LOCK_DURATION);
        vm.prank(alice);
        staking.exit(0);

        assertEq(k613.balanceOf(alice), 10_000 * ONE + 500 * ONE);
        assertEq(xk613.totalSupply(), staking.totalBacking());
        assertEq(staking.totalBacking(), 0);
    }

    /// @notice exitPendingSum reports escrowed xK613, so `deposits().amount + exitPendingSum()`
    ///         reconstructs the user's full holding — the live balance alone understates it.
    function test_ExitPendingSum_ComplementsLiveBalance() public {
        vm.prank(alice);
        k613.approve(address(staking), 300 * ONE);
        vm.prank(alice);
        staking.stake(300 * ONE);
        assertEq(staking.exitPendingSum(alice), 0);

        vm.prank(alice);
        xk613.approve(address(staking), 180 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);
        vm.prank(alice);
        staking.initiateExit(80 * ONE);

        (uint256 live,) = staking.deposits(alice);
        assertEq(live, 120 * ONE);
        assertEq(staking.exitPendingSum(alice), 180 * ONE);
        assertEq(live + staking.exitPendingSum(alice), 300 * ONE);

        // Cancelling returns the escrow to the live balance; the total is unchanged.
        vm.prank(alice);
        staking.cancelExit(0);
        (uint256 liveAfter,) = staking.deposits(alice);
        assertEq(liveAfter + staking.exitPendingSum(alice), 300 * ONE);
    }

    /// @notice test_Deposits_TracksLiveBalance_NotStaleStakePosition: after a reward lands and part
    ///         of the balance is queued for exit, `deposits(user).amount` reflects the live,
    ///         queueable balance (staked + reward, minus whatever is already escrowed in the queue) —
    ///         not a separate stale record.
    function test_Deposits_TracksLiveBalance_NotStaleStakePosition() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);
        _giveRewardXK613(alice, 50 * ONE);

        (uint256 amountBefore,) = staking.deposits(alice);
        assertEq(amountBefore, 150 * ONE);

        vm.prank(alice);
        xk613.approve(address(staking), 60 * ONE);
        vm.prank(alice);
        staking.initiateExit(60 * ONE);

        (uint256 amountAfter,) = staking.deposits(alice);
        assertEq(amountAfter, 90 * ONE);
        assertEq(amountAfter, xk613.balanceOf(alice));
    }
}
