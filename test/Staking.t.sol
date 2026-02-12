// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

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
        distributor = new RewardsDistributor(address(xk613), EPOCH_DURATION);

        staking.setRewardsDistributor(address(distributor));
        distributor.setStaking(address(staking));

        xk613.setMinter(address(staking));
        xk613.setTransferWhitelist(address(distributor), true);
        xk613.setTransferWhitelist(address(staking), true);

        k613.mint(alice, 10_000 * ONE);
        k613.mint(bob, 10_000 * ONE);
    }

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

    function test_Stake_ZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(Staking.ZeroAmount.selector);
        staking.stake(0);
    }

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

    function test_InitiateExit_NothingStakedReverts() public {
        vm.prank(alice);
        vm.expectRevert(Staking.NothingToInitiate.selector);
        staking.initiateExit(1);
    }

    function test_InitiateExit_AmountExceedsReverts() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);

        vm.prank(alice);
        vm.expectRevert(Staking.AmountExceedsStake.selector);
        staking.initiateExit(101 * ONE);
    }

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

    function test_CancelExit_NotInitiatedReverts() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);

        vm.prank(alice);
        vm.expectRevert(Staking.InvalidExitIndex.selector);
        staking.cancelExit(0);
    }

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

    function test_InstantExit_WithoutInitiateReverts() public {
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.stake(100 * ONE);

        vm.prank(alice);
        vm.expectRevert(Staking.InvalidExitIndex.selector);
        staking.instantExit(0);
    }

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

    function test_WithdrawPenalties_TransfersToRecipient() public {
        address treasury = address(0xDeaDbEEf);
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

        uint256 penalty = (100 * ONE * PENALTY_BPS) / 10_000;
        assertEq(staking.withdrawablePenalties(), penalty);

        uint256 treasuryBefore = k613.balanceOf(treasury);
        staking.withdrawPenalties(treasury);
        assertEq(k613.balanceOf(treasury), treasuryBefore + penalty);
        assertEq(staking.withdrawablePenalties(), 0);
    }

    function test_WithdrawPenalties_OnlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        staking.withdrawPenalties(address(0x1));
    }

    function test_WithdrawPenalties_ZeroRecipientReverts() public {
        vm.expectRevert(Staking.ZeroAddress.selector);
        staking.withdrawPenalties(address(0));
    }

    function test_Pause_BlocksStake() public {
        staking.pause();

        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        vm.expectRevert();
        staking.stake(100 * ONE);
    }

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
}
