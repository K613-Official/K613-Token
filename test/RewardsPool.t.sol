// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {RewardsDistributor} from "../src/staking/RewardsDistributor.sol";
import {xK613} from "../src/token/xK613.sol";
import {K613} from "../src/token/K613.sol";
import {Staking} from "../src/staking/Staking.sol";

contract RewardsDistributorTest is Test {
    xK613 private token;
    RewardsDistributor private distributor;

    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);

    uint256 private constant ONE = 1e18;
    uint256 private constant EPOCH = 7 days;

    function setUp() public {
        token = new xK613(address(this));
        distributor = new RewardsDistributor(address(token), EPOCH);
        distributor.setStaking(address(0)); // No staking in unit tests - no claim block
        distributor.grantRole(distributor.REWARDS_NOTIFIER_ROLE(), address(this));
        token.setTransferWhitelist(address(distributor), true);

        token.mint(alice, 2_000 * ONE);
        token.mint(bob, 2_000 * ONE);

        vm.startPrank(alice);
        token.approve(address(distributor), type(uint256).max);
        distributor.deposit(1_000 * ONE);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(distributor), type(uint256).max);
        distributor.deposit(1_000 * ONE);
        vm.stopPrank();
    }

    function testConstructorRevertsOnZero() public {
        vm.expectRevert(RewardsDistributor.ZeroAddress.selector);
        new RewardsDistributor(address(0), EPOCH);
    }

    function testConstructorRevertsOnEpochZero() public {
        vm.expectRevert(RewardsDistributor.InvalidEpochDuration.selector);
        new RewardsDistributor(address(token), 0);
    }

    function testDepositRevertsBelowMinInitial() public {
        xK613 freshToken = new xK613(address(this));
        RewardsDistributor freshRd = new RewardsDistributor(address(freshToken), EPOCH);
        freshRd.grantRole(freshRd.REWARDS_NOTIFIER_ROLE(), address(this));
        freshToken.setTransferWhitelist(address(freshRd), true);
        freshToken.mint(alice, 1e12);

        vm.prank(alice);
        freshToken.approve(address(freshRd), 1e12 - 1);
        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.MinimumInitialDeposit.selector);
        freshRd.deposit(1e12 - 1);
    }

    function testClaimRevertsWithoutRewards() public {
        vm.expectRevert(RewardsDistributor.NoRewards.selector);
        vm.prank(alice);
        distributor.claim();
    }

    function testNotifyRewardOnlyAuthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, distributor.REWARDS_NOTIFIER_ROLE()
            )
        );
        vm.prank(alice);
        distributor.notifyReward(1 * ONE);
    }

    function testNotifyRewardZeroReverts() public {
        vm.expectRevert(RewardsDistributor.ZeroAmount.selector);
        distributor.notifyReward(0);
    }

    function testNotifyRewardWhenTotalDepositsZeroGoesToPending() public {
        vm.prank(alice);
        distributor.withdraw(1_000 * ONE);
        vm.prank(bob);
        distributor.withdraw(1_000 * ONE);
        assertEq(distributor.totalDeposits(), 0);

        token.mint(address(distributor), 10 * ONE);
        distributor.notifyReward(10 * ONE);

        assertEq(distributor.pendingRewards(), 10 * ONE);
        assertEq(distributor.accRewardPerShare(), 0);

        vm.prank(alice);
        distributor.deposit(1_000 * ONE);
        vm.prank(bob);
        distributor.deposit(1_000 * ONE);
        assertEq(
            distributor.pendingRewardsOf(alice) + distributor.pendingRewardsOf(bob), 10 * ONE, "total rewards preserved"
        );
    }

    function testNotifyRewardDust_Amount1_TotalDeposits1e24() public {
        vm.prank(alice);
        distributor.withdraw(1_000 * ONE);
        vm.prank(bob);
        distributor.withdraw(1_000 * ONE);
        uint256 bigDeposit = 1e24 - 1_000 * ONE;
        token.mint(alice, bigDeposit);
        vm.prank(alice);
        token.approve(address(distributor), bigDeposit);
        vm.prank(alice);
        distributor.deposit(bigDeposit);
        vm.prank(bob);
        distributor.deposit(1_000 * ONE);
        uint256 total = distributor.totalDeposits();
        assertEq(total, 1e24);

        token.mint(address(distributor), 100);
        uint256 accBefore = distributor.accRewardPerShare();
        distributor.notifyReward(1);
        uint256 accAfter = distributor.accRewardPerShare();

        assertEq((1 * 1e18) / total, 0, "dust rounds to 0");
        assertEq(accAfter, accBefore, "accRewardPerShare unchanged when dust rounds to 0");
        assertEq(distributor.pendingRewards(), 0);
    }

    function testNotifyRewardSmallAmount_RoundsToZero() public {
        uint256 total = 2_000 * ONE;
        uint256 dustAmount = (total / 1e18) - 1;
        if (dustAmount == 0) dustAmount = 1;
        assertEq((dustAmount * 1e18) / total, 0, "amount * 1e18 / total == 0");

        token.mint(address(distributor), dustAmount + 100 * ONE);
        uint256 accBefore = distributor.accRewardPerShare();
        distributor.notifyReward(dustAmount);
        uint256 accAfter = distributor.accRewardPerShare();

        assertEq(accAfter, accBefore);
        uint256 alicePending = distributor.pendingRewardsOf(alice);
        uint256 bobPending = distributor.pendingRewardsOf(bob);
        assertEq(alicePending, 0);
        assertEq(bobPending, 0);

        distributor.notifyReward(100 * ONE);
        uint256 expectedPerUser = (1_000 * ONE * 100 * ONE) / total;
        assertApproxEqAbs(distributor.pendingRewardsOf(alice), expectedPerUser, 1000);
    }

    function testNotifyRewardManySmallAmounts_TotalMatches() public {
        uint256 totalNotify = 0;
        uint256 n = 20;
        uint256 each = (10 * ONE) / n;
        token.mint(address(distributor), 50 * ONE);

        for (uint256 i = 0; i < n; i++) {
            distributor.notifyReward(each);
            totalNotify += each;
        }

        uint256 aliceExpected = (1_000 * ONE * totalNotify) / (2_000 * ONE);
        uint256 bobExpected = (1_000 * ONE * totalNotify) / (2_000 * ONE);
        assertApproxEqAbs(distributor.pendingRewardsOf(alice), aliceExpected, 10000);
        assertApproxEqAbs(distributor.pendingRewardsOf(bob), bobExpected, 10000);

        uint256 aliceBefore = token.balanceOf(alice);
        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(alice);
        distributor.claim();
        vm.prank(bob);
        distributor.claim();
        uint256 aliceGot = token.balanceOf(alice) - aliceBefore;
        uint256 bobGot = token.balanceOf(bob) - bobBefore;

        assertApproxEqAbs(aliceGot, aliceExpected, 10000);
        assertApproxEqAbs(bobGot, bobExpected, 10000);
        assertEq(aliceGot + bobGot, totalNotify, "sum of claims equals total notified");
    }

    function testAddPendingPenaltyOnlyAuthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, distributor.REWARDS_NOTIFIER_ROLE()
            )
        );
        vm.prank(alice);
        distributor.addPendingPenalty(1 * ONE);
    }

    function testAddPendingPenaltyAccumulatesUntilThreshold() public {
        token.mint(address(distributor), 5 * ONE);
        uint256 half = ONE / 2;
        distributor.addPendingPenalty(half);
        assertEq(distributor.pendingPenalties(), half);
        distributor.addPendingPenalty(half);
        assertEq(distributor.pendingPenalties(), 1 * ONE);
        assertEq(distributor.accRewardPerShare(), 0);
    }

    function testAddPendingPenaltyFlushOnClaim() public {
        token.mint(address(distributor), 5 * ONE);
        uint256 penalty = ONE + (ONE / 2);
        distributor.addPendingPenalty(penalty);
        assertEq(distributor.pendingPenalties(), penalty);

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        distributor.claim();
        uint256 aliceAfter = token.balanceOf(alice);

        assertEq(distributor.pendingPenalties(), 0);
        uint256 aliceShare = (1_000 * ONE * penalty) / (2_000 * ONE);
        assertApproxEqAbs(aliceAfter - aliceBefore, aliceShare, 1000);
    }

    function testAddPendingPenaltyNoFlushBelowThreshold() public {
        uint256 half = ONE / 2;
        distributor.addPendingPenalty(half);
        assertEq(distributor.pendingPenalties(), half);
        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.NoRewards.selector);
        distributor.claim();
        assertEq(distributor.pendingPenalties(), half);
    }

    function testEpochFlush_PenaltiesBelowThreshold() public {
        token.mint(address(distributor), 5 * ONE);
        uint256 half = ONE / 2;
        distributor.addPendingPenalty(half);
        assertEq(distributor.pendingPenalties(), half);
        assertLt(half, distributor.MIN_PENALTY_FLUSH());

        vm.warp(block.timestamp + EPOCH + 1);
        vm.prank(alice);
        distributor.advanceEpoch();

        assertEq(distributor.pendingPenalties(), 0);
        uint256 aliceShare = (1_000 * ONE * half) / (2_000 * ONE);
        assertApproxEqAbs(distributor.pendingRewardsOf(alice), aliceShare, 1000);
    }

    function testNextEpochAt() public view {
        assertEq(distributor.nextEpochAt(), block.timestamp + EPOCH);
    }

    function testDeposit_PauseReverts() public {
        distributor.pause();
        vm.prank(alice);
        vm.expectRevert();
        distributor.deposit(100 * ONE);
    }

    function testWithdraw_PauseReverts() public {
        distributor.pause();
        vm.prank(alice);
        vm.expectRevert();
        distributor.withdraw(100 * ONE);
    }

    function testClaim_PauseReverts() public {
        token.mint(address(distributor), 10 * ONE);
        distributor.notifyReward(10 * ONE);
        distributor.pause();
        vm.prank(alice);
        vm.expectRevert();
        distributor.claim();
    }

    function testAdvanceEpoch_WhenTotalDepositsZero_Noop() public {
        vm.prank(alice);
        distributor.withdraw(1_000 * ONE);
        vm.prank(bob);
        distributor.withdraw(1_000 * ONE);
        distributor.addPendingPenalty(ONE);
        distributor.advanceEpoch();
        assertEq(distributor.pendingPenalties(), ONE);
    }

    function testAdvanceEpoch_AnyoneCanCall() public {
        token.mint(address(distributor), ONE);
        distributor.addPendingPenalty(ONE + (ONE / 2));
        vm.warp(block.timestamp + EPOCH + 1);
        vm.prank(bob);
        distributor.advanceEpoch();
        assertEq(distributor.pendingPenalties(), 0);
    }

    function testWithdraw_AfterDeposit_PreservesRewardShare() public {
        token.mint(address(distributor), 10 * ONE);
        distributor.notifyReward(10 * ONE);
        vm.prank(alice);
        distributor.withdraw(500 * ONE);
        uint256 aliceShare = (1_000 * ONE * 10 * ONE) / (2_000 * ONE);
        assertApproxEqAbs(distributor.pendingRewardsOf(alice), aliceShare, 1000);
    }

    function testPendingRewardsOf_EmptyAccount() public view {
        assertEq(distributor.pendingRewardsOf(address(0x123)), 0);
    }

    function testMultipleEpochs_PenaltiesFlushCorrectly() public {
        token.mint(address(distributor), 10 * ONE);
        distributor.addPendingPenalty(ONE / 2);
        vm.warp(block.timestamp + EPOCH * 3);
        vm.prank(alice);
        distributor.advanceEpoch();
        assertEq(distributor.pendingPenalties(), 0);
        uint256 expected = (1_000 * ONE * (ONE / 2)) / (2_000 * ONE);
        assertApproxEqAbs(distributor.pendingRewardsOf(alice), expected, 1000);
    }

    function testSetStaking_RoleRevokedFromOld() public {
        RewardsDistributor rd = new RewardsDistributor(address(token), EPOCH);
        rd.grantRole(rd.DEFAULT_ADMIN_ROLE(), address(this));
        address oldStaking = address(0x111);
        rd.setStaking(oldStaking);
        assertTrue(rd.hasRole(rd.REWARDS_NOTIFIER_ROLE(), oldStaking));
        rd.setStaking(address(0x222));
        assertFalse(rd.hasRole(rd.REWARDS_NOTIFIER_ROLE(), oldStaking));
        assertTrue(rd.hasRole(rd.REWARDS_NOTIFIER_ROLE(), address(0x222)));
    }

    function test_FullFlow_Stake_Initiate_Exit_Claim() public {
        K613 k613 = new K613(address(this));
        Staking staking = new Staking(address(k613), address(token), 7 days, 0);
        token.setMinter(address(staking));
        token.grantRole(token.MINTER_ROLE(), address(this));
        token.setTransferWhitelist(address(staking), true);
        k613.mint(alice, 1_000 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        token.approve(address(distributor), 1_000 * ONE);
        distributor.deposit(1_000 * ONE);
        vm.stopPrank();
        token.mint(address(distributor), 10 * ONE);
        distributor.notifyReward(10 * ONE);
        vm.prank(alice);
        distributor.withdraw(1_000 * ONE);
        vm.prank(alice);
        token.approve(address(staking), 1_000 * ONE);
        vm.prank(alice);
        staking.initiateExit(1_000 * ONE);
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        staking.exit(0);
        assertEq(k613.balanceOf(alice), 1_000 * ONE);
        vm.prank(alice);
        distributor.claim();
        assertGt(token.balanceOf(alice), 1_000 * ONE);
    }

    function test_RD_setStaking_Zero_ThenReSet() public {
        K613 k613 = new K613(address(this));
        Staking staking = new Staking(address(k613), address(token), 7 days, 5_000);
        token.setMinter(address(staking));
        token.grantRole(token.MINTER_ROLE(), address(this));
        token.setTransferWhitelist(address(staking), true);
        distributor.setStaking(address(staking));
        staking.setRewardsDistributor(address(distributor));
        distributor.setStaking(address(0));
        assertEq(distributor.staking(), address(0));
        distributor.setStaking(address(staking));
        assertEq(distributor.staking(), address(staking));
    }

    function testNotifyRewardDistributesToHolders() public {
        token.mint(address(distributor), 10 * ONE);
        distributor.notifyReward(10 * ONE);

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        distributor.claim();
        uint256 aliceAfter = token.balanceOf(alice);

        uint256 aliceShare = (1_000 * ONE * 10 * ONE) / (2_000 * ONE);
        assertApproxEqAbs(aliceAfter - aliceBefore, aliceShare, 1000);
        assertEq(distributor.pendingRewards(), 0);
    }

    function testClaimTransfersReward() public {
        token.mint(address(distributor), 10 * ONE);
        distributor.notifyReward(10 * ONE);

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        distributor.claim();
        uint256 aliceAfter = token.balanceOf(alice);

        uint256 aliceShare = (1_000 * ONE * 10 * ONE) / (2_000 * ONE);
        assertApproxEqAbs(aliceAfter - aliceBefore, aliceShare, 1000);
        assertEq(distributor.pendingRewardsOf(alice), 0);
    }

    function testPendingRewardsOf() public {
        token.mint(address(distributor), 10 * ONE);
        distributor.notifyReward(10 * ONE);

        uint256 aliceShare = (1_000 * ONE * 10 * ONE) / (2_000 * ONE);
        assertApproxEqAbs(distributor.pendingRewardsOf(alice), aliceShare, 1000);
        assertApproxEqAbs(distributor.pendingRewardsOf(bob), aliceShare, 1000);
    }

    function testWithdraw() public {
        uint256 aliceBalBefore = distributor.balanceOf(alice); // 1000
        uint256 withdrawAmt = 500 * ONE;
        uint256 aliceTokenBefore = token.balanceOf(alice); // 1000 (2000 minted - 1000 deposited)
        vm.prank(alice);
        distributor.withdraw(withdrawAmt);

        assertEq(distributor.balanceOf(alice), aliceBalBefore - withdrawAmt);
        assertEq(token.balanceOf(alice), aliceTokenBefore + withdrawAmt);
        assertEq(distributor.totalDeposits(), 2_000 * ONE - withdrawAmt);
    }

    function testWithdrawInsufficientReverts() public {
        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.InsufficientBalance.selector);
        distributor.withdraw(2_000 * ONE);
    }

    function testDeposit() public {
        token.mint(alice, 500 * ONE);
        vm.prank(alice);
        token.approve(address(distributor), 500 * ONE);
        vm.prank(alice);
        distributor.deposit(500 * ONE);

        assertEq(distributor.balanceOf(alice), 1_500 * ONE);
        assertEq(distributor.totalDeposits(), 2_500 * ONE);
    }

    function testInstantExitSmallPenalty_AccumulatesInRD() public {
        K613 k613 = new K613(address(this));
        uint256 penaltyBps = 100;
        Staking staking = new Staking(address(k613), address(token), 7 days, penaltyBps);
        staking.setRewardsDistributor(address(distributor));
        distributor.setStaking(address(staking));
        token.setMinter(address(staking));
        token.grantRole(token.MINTER_ROLE(), address(this));
        token.setTransferWhitelist(address(staking), true);

        uint256 smallStake = 10 * ONE;
        k613.mint(alice, smallStake);
        vm.startPrank(alice);
        k613.approve(address(staking), smallStake);
        staking.stake(smallStake);
        token.approve(address(staking), smallStake);
        staking.initiateExit(smallStake);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        uint256 penaltyExpected = (smallStake * penaltyBps) / 10_000;
        assertLt(penaltyExpected, distributor.MIN_PENALTY_FLUSH(), "penalty is dust");

        vm.prank(alice);
        staking.instantExit(0);

        assertEq(distributor.pendingPenalties(), penaltyExpected);
        assertEq(distributor.accRewardPerShare(), 0);
    }

    function testDeposit_Withdraw_Claim_Ordering() public {
        token.mint(address(distributor), 20 * ONE);
        distributor.notifyReward(10 * ONE);
        vm.prank(alice);
        distributor.withdraw(500 * ONE);
        distributor.notifyReward(10 * ONE);
        vm.prank(alice);
        distributor.deposit(500 * ONE);
        assertGt(distributor.pendingRewardsOf(alice), 0);
        assertApproxEqAbs(distributor.pendingRewardsOf(alice) + distributor.pendingRewardsOf(bob), 20 * ONE, 10000);
    }

    function test_RD_Staking_PenaltyFlow_Integration() public {
        K613 k613 = new K613(address(this));
        Staking staking = new Staking(address(k613), address(token), 7 days, 5_000);
        staking.setRewardsDistributor(address(distributor));
        distributor.setStaking(address(staking));
        token.setMinter(address(staking));
        token.grantRole(token.MINTER_ROLE(), address(this));
        token.setTransferWhitelist(address(staking), true);

        k613.mint(alice, 1_000 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        token.approve(address(staking), 1_000 * ONE);
        staking.initiateExit(1_000 * ONE);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        staking.instantExit(0);

        uint256 penalty = (1_000 * ONE * 5_000) / 10_000;
        assertGe(distributor.pendingPenalties(), penalty);

        vm.warp(block.timestamp + EPOCH + 1);
        vm.prank(bob);
        distributor.advanceEpoch();

        uint256 bobShare = (1_000 * ONE * penalty) / (2_000 * ONE);
        assertApproxEqAbs(distributor.pendingRewardsOf(bob), bobShare, 1000);
    }

    function testClaimWorksDuringExitVesting() public {
        // Deploy Staking for integration test
        K613 k613 = new K613(address(this));
        Staking staking = new Staking(address(k613), address(token), 7 days, 5_000);
        token.setMinter(address(staking));
        token.grantRole(token.MINTER_ROLE(), address(this));
        token.setTransferWhitelist(address(staking), true);
        distributor.setStaking(address(staking));
        k613.mint(alice, 1_000 * ONE);

        vm.startPrank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        token.approve(address(distributor), 1_000 * ONE);
        distributor.deposit(1_000 * ONE);
        vm.stopPrank();

        token.mint(address(distributor), 10 * ONE);
        distributor.notifyReward(10 * ONE);

        // Alice withdraws from RD, initiates exit - can still claim accumulated rewards
        vm.prank(alice);
        distributor.withdraw(1_000 * ONE);
        vm.prank(alice);
        token.approve(address(staking), 1_000 * ONE);
        vm.prank(alice);
        staking.initiateExit(1_000 * ONE);

        uint256 pendingBefore = distributor.pendingRewardsOf(alice);
        vm.prank(alice);
        distributor.claim();
        assertGt(pendingBefore, 0);
    }
}
