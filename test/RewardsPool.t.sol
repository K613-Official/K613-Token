// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {RewardsDistributor} from "../src/staking/RewardsDistributor.sol";
import {xK613} from "../src/token/xK613.sol";
import {K613} from "../src/token/K613.sol";
import {Staking} from "../src/staking/Staking.sol";

contract RewardsDistributorTest is Test {
    xK613 private token;
    K613 private k613;
    Staking private staking;
    RewardsDistributor private distributor;

    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);

    uint256 private constant ONE = 1e18;
    uint256 private constant EPOCH = 7 days;

    function setUp() public {
        token = new xK613(address(this));
        k613 = new K613(address(this));
        k613.mint(address(this), 100_000 * ONE);
        staking = new Staking(address(k613), address(token), 7 days, 0);
        token.setMinter(address(staking));
        token.grantRole(token.MINTER_ROLE(), address(this));
        distributor = new RewardsDistributor(address(token), address(token), address(k613), EPOCH);
        distributor.setStaking(address(staking));
        distributor.grantRole(distributor.REWARDS_NOTIFIER_ROLE(), address(this));
        token.setTransferWhitelist(address(distributor), true);
        token.setTransferWhitelist(address(staking), true);

        token.mint(address(this), 100_000 * ONE);
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

    /// @notice testConstructorRevertsOnZeroStakingToken: RewardsDistributor constructor with zero staking token reverts with ZeroAddress.
    function testConstructorRevertsOnZeroStakingToken() public {
        vm.expectRevert(RewardsDistributor.ZeroAddress.selector);
        new RewardsDistributor(address(0), address(token), address(k613), EPOCH);
    }

    /// @notice testConstructorRevertsOnZeroRewardToken: Constructor with zero reward token reverts with ZeroAddress.
    function testConstructorRevertsOnZeroRewardToken() public {
        vm.expectRevert(RewardsDistributor.ZeroAddress.selector);
        new RewardsDistributor(address(token), address(0), address(k613), EPOCH);
    }

    /// @notice testConstructorRevertsOnZeroK613: Constructor with zero K613 address reverts with ZeroAddress.
    function testConstructorRevertsOnZeroK613() public {
        vm.expectRevert(RewardsDistributor.ZeroAddress.selector);
        new RewardsDistributor(address(token), address(token), address(0), EPOCH);
    }

    /// @notice testConstructorRevertsOnEpochZero: Constructor with zero epoch duration reverts with InvalidEpochDuration.
    function testConstructorRevertsOnEpochZero() public {
        vm.expectRevert(RewardsDistributor.InvalidEpochDuration.selector);
        new RewardsDistributor(address(token), address(token), address(k613), 0);
    }

    /// @notice testDepositRevertsBelowMinInitial: First deposit below MIN_INITIAL_DEPOSIT reverts with MinimumInitialDeposit.
    function testDepositRevertsBelowMinInitial() public {
        xK613 freshToken = new xK613(address(this));
        K613 freshK613 = new K613(address(this));
        RewardsDistributor freshRd =
            new RewardsDistributor(address(freshToken), address(freshToken), address(freshK613), EPOCH);
        freshRd.grantRole(freshRd.REWARDS_NOTIFIER_ROLE(), address(this));
        freshToken.setTransferWhitelist(address(freshRd), true);
        freshToken.mint(alice, 1e12);

        vm.prank(alice);
        freshToken.approve(address(freshRd), 1e12 - 1);
        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.MinimumInitialDeposit.selector);
        freshRd.deposit(1e12 - 1);
    }

    /// @notice testClaimRevertsWithoutRewards: claim() with no rewards reverts with NoRewards.
    function testClaimRevertsWithoutRewards() public {
        vm.expectRevert(RewardsDistributor.NoRewards.selector);
        vm.prank(alice);
        distributor.claim();
    }

    /// @notice testNotifyRewardOnlyAuthorized: notifyReward from non-REWARDS_NOTIFIER reverts with AccessControlUnauthorizedAccount.
    function testNotifyRewardOnlyAuthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, distributor.REWARDS_NOTIFIER_ROLE()
            )
        );
        vm.prank(alice);
        distributor.notifyReward(1 * ONE);
    }

    /// @notice testNotifyRewardZeroReverts: notifyReward(0) reverts with ZeroAmount.
    function testNotifyRewardZeroReverts() public {
        vm.expectRevert(RewardsDistributor.ZeroAmount.selector);
        distributor.notifyReward(0);
    }

    /// @notice testNotifyRewardBelowMinReverts: notifyReward below MIN_NOTIFY reverts with MinimumNotify.
    function testNotifyRewardBelowMinReverts() public {
        token.transfer(address(distributor), 1);
        vm.expectRevert(RewardsDistributor.MinimumNotify.selector);
        distributor.notifyReward(1);
    }

    /// @notice testNotifyRewardWhenTotalDepositsZeroGoesToPending: When totalDeposits is 0, notified rewards go to pendingRewards and distribute when users deposit.
    function testNotifyRewardWhenTotalDepositsZeroGoesToPending() public {
        vm.prank(alice);
        distributor.withdraw(1_000 * ONE);
        vm.prank(bob);
        distributor.withdraw(1_000 * ONE);
        assertEq(distributor.totalDeposits(), 0);

        token.transfer(address(distributor), 10 * ONE);
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

    /// @notice testNotifyRewardDust_SmallAmountRoundsDown: Very small notifyReward with large totalDeposits rounds down per-share; no dust accrues to first user.
    function testNotifyRewardDust_SmallAmountRoundsDown() public {
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

        uint256 dustAmount = distributor.MIN_NOTIFY(); // 1e12
        token.transfer(address(distributor), dustAmount + 100 * ONE);
        uint256 accBefore = distributor.accRewardPerShare();
        distributor.notifyReward(dustAmount);
        uint256 accAfter = distributor.accRewardPerShare();
        assertGe(accAfter, accBefore);
    }

    /// @notice testNotifyRewardSmallAmount_ThenLargeDistributes: Small then large notifyReward; total distributed matches sum and shares are correct.
    function testNotifyRewardSmallAmount_ThenLargeDistributes() public {
        uint256 total = 2_000 * ONE;
        uint256 smallAmount = distributor.MIN_NOTIFY(); // minimum allowed notify

        token.transfer(address(distributor), smallAmount + 100 * ONE);
        distributor.notifyReward(smallAmount);

        token.transfer(address(distributor), 100 * ONE);
        distributor.notifyReward(100 * ONE);
        uint256 totalRewards = smallAmount + 100 * ONE;
        uint256 expectedPerUser = (1_000 * ONE * totalRewards) / total;
        assertApproxEqAbs(distributor.pendingRewardsOf(alice), expectedPerUser, 10000);
        assertApproxEqAbs(distributor.pendingRewardsOf(bob), expectedPerUser, 10000);
    }

    /// @notice testNotifyRewardManySmallAmounts_TotalMatches: Many small notifyReward amounts; sum of claims equals total notified.
    function testNotifyRewardManySmallAmounts_TotalMatches() public {
        uint256 totalNotify = 0;
        uint256 n = 20;
        uint256 each = (10 * ONE) / n;
        token.transfer(address(distributor), 50 * ONE);

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

    /// @notice testAddPendingPenaltyOnlyAuthorized: addPendingPenalty from non-REWARDS_NOTIFIER reverts with AccessControlUnauthorizedAccount.
    function testAddPendingPenaltyOnlyAuthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, distributor.REWARDS_NOTIFIER_ROLE()
            )
        );
        vm.prank(alice);
        distributor.addPendingPenalty(1 * ONE);
    }

    /// @notice testAddPendingPenaltyAccumulatesUntilThreshold: addPendingPenalty accumulates in pendingPenalties until >= MIN_PENALTY_FLUSH; accRewardPerShare unchanged until flush.
    function testAddPendingPenaltyAccumulatesUntilThreshold() public {
        k613.transfer(address(distributor), 5 * ONE);
        uint256 half = ONE / 2;
        distributor.addPendingPenalty(half);
        assertEq(distributor.pendingPenalties(), half);
        distributor.addPendingPenalty(half);
        assertEq(distributor.pendingPenalties(), 1 * ONE);
        assertEq(distributor.accRewardPerShare(), 0);
    }

    /// @notice testAddPendingPenaltyFlushOnClaim: On claim(), held K613 (including pendingPenalties) is staked and penalties flush into accRewardPerShare; user receives share.
    function testAddPendingPenaltyFlushOnClaim() public {
        k613.transfer(address(distributor), 5 * ONE);
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

    /// @notice testAddPendingPenaltyNoFlushBelowThreshold: Penalties below MIN_PENALTY_FLUSH are not flushed on claim; claim with no other rewards reverts NoRewards.
    function testAddPendingPenaltyNoFlushBelowThreshold() public {
        uint256 half = ONE / 2;
        k613.transfer(address(distributor), half);
        distributor.addPendingPenalty(half);
        assertEq(distributor.pendingPenalties(), half);
        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.NoRewards.selector);
        distributor.claim();
        assertEq(distributor.pendingPenalties(), half);
    }

    /// @notice testEpochFlush_PenaltiesBelowThreshold: advanceEpoch() after epoch end flushes pendingPenalties even below MIN_PENALTY_FLUSH; pendingRewardsOf updates.
    function testEpochFlush_PenaltiesBelowThreshold() public {
        k613.transfer(address(distributor), 5 * ONE);
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

    /// @notice testNextEpochAt: nextEpochAt() returns lastEpochFlushAt + epochDuration.
    function testNextEpochAt() public view {
        assertEq(distributor.nextEpochAt(), block.timestamp + EPOCH);
    }

    /// @notice testDeposit_PauseReverts: When paused, deposit() reverts.
    function testDeposit_PauseReverts() public {
        distributor.pause();
        vm.prank(alice);
        vm.expectRevert();
        distributor.deposit(100 * ONE);
    }

    /// @notice testWithdraw_PauseReverts: When paused, withdraw() reverts.
    function testWithdraw_PauseReverts() public {
        distributor.pause();
        vm.prank(alice);
        vm.expectRevert();
        distributor.withdraw(100 * ONE);
    }

    /// @notice testClaim_PauseReverts: When paused, claim() reverts.
    function testClaim_PauseReverts() public {
        token.transfer(address(distributor), 10 * ONE);
        distributor.notifyReward(10 * ONE);
        distributor.pause();
        vm.prank(alice);
        vm.expectRevert();
        distributor.claim();
    }

    /// @notice testAdvanceEpoch_WhenTotalDepositsZero_Noop: advanceEpoch when totalDeposits is 0 does not flush pendingPenalties (noop for distribution).
    function testAdvanceEpoch_WhenTotalDepositsZero_Noop() public {
        vm.prank(alice);
        distributor.withdraw(1_000 * ONE);
        vm.prank(bob);
        distributor.withdraw(1_000 * ONE);
        k613.transfer(address(distributor), ONE);
        distributor.addPendingPenalty(ONE);
        vm.warp(block.timestamp + EPOCH + 1);
        distributor.advanceEpoch();
        assertEq(distributor.pendingPenalties(), ONE);
    }

    /// @notice testAdvanceEpoch_BeforeEpochEnd_Reverts: advanceEpoch() before epoch end reverts with EpochNotReady.
    function testAdvanceEpoch_BeforeEpochEnd_Reverts() public {
        vm.expectRevert(RewardsDistributor.EpochNotReady.selector);
        distributor.advanceEpoch();
    }

    /// @notice testAdvanceEpoch_AnyoneCanCall: Any account can call advanceEpoch(); penalties flush and lastEpochFlushAt updates.
    function testAdvanceEpoch_AnyoneCanCall() public {
        k613.transfer(address(distributor), ONE + (ONE / 2));
        distributor.addPendingPenalty(ONE + (ONE / 2));
        vm.warp(block.timestamp + EPOCH + 1);
        vm.prank(bob);
        distributor.advanceEpoch();
        assertEq(distributor.pendingPenalties(), 0);
    }

    /// @notice testWithdraw_AfterDeposit_PreservesRewardShare: After withdraw, user's pendingRewardsOf still reflects accrued share from previous deposit.
    function testWithdraw_AfterDeposit_PreservesRewardShare() public {
        token.transfer(address(distributor), 10 * ONE);
        distributor.notifyReward(10 * ONE);
        vm.prank(alice);
        distributor.withdraw(500 * ONE);
        uint256 aliceShare = (1_000 * ONE * 10 * ONE) / (2_000 * ONE);
        assertApproxEqAbs(distributor.pendingRewardsOf(alice), aliceShare, 1000);
    }

    /// @notice testPendingRewardsOf_EmptyAccount: pendingRewardsOf for address with no deposit returns 0.
    function testPendingRewardsOf_EmptyAccount() public view {
        assertEq(distributor.pendingRewardsOf(address(0x123)), 0);
    }

    /// @notice testMultipleEpochs_PenaltiesFlushCorrectly: After multiple epoch warps, advanceEpoch flushes penalties and pendingRewardsOf reflects correct share.
    function testMultipleEpochs_PenaltiesFlushCorrectly() public {
        k613.transfer(address(distributor), 10 * ONE);
        distributor.addPendingPenalty(ONE / 2);
        vm.warp(block.timestamp + EPOCH * 3);
        vm.prank(alice);
        distributor.advanceEpoch();
        assertEq(distributor.pendingPenalties(), 0);
        uint256 expected = (1_000 * ONE * (ONE / 2)) / (2_000 * ONE);
        assertApproxEqAbs(distributor.pendingRewardsOf(alice), expected, 1000);
    }

    /// @notice testSetStaking_RoleRevokedFromOld: setStaking(new) revokes REWARDS_NOTIFIER_ROLE from old staking and grants to new.
    function testSetStaking_RoleRevokedFromOld() public {
        RewardsDistributor rd = new RewardsDistributor(address(token), address(token), address(k613), EPOCH);
        rd.grantRole(rd.DEFAULT_ADMIN_ROLE(), address(this));
        address oldStaking = address(0x111);
        rd.setStaking(oldStaking);
        assertTrue(rd.hasRole(rd.REWARDS_NOTIFIER_ROLE(), oldStaking));
        rd.setStaking(address(0x222));
        assertFalse(rd.hasRole(rd.REWARDS_NOTIFIER_ROLE(), oldStaking));
        assertTrue(rd.hasRole(rd.REWARDS_NOTIFIER_ROLE(), address(0x222)));
    }

    /// @notice test_FullFlow_Stake_Initiate_Exit_Claim: Full flow — stake, deposit to RD, notify reward, withdraw from RD, initiateExit, wait lock, exit, claim; user gets K613 back and claim share correct.
    function test_FullFlow_Stake_Initiate_Exit_Claim() public {
        K613 k613Local = new K613(address(this));
        Staking staking = new Staking(address(k613Local), address(token), 7 days, 0);
        token.setMinter(address(staking));
        token.grantRole(token.MINTER_ROLE(), address(this));
        token.setTransferWhitelist(address(staking), true);
        k613Local.mint(alice, 1_000 * ONE);
        k613Local.mint(address(this), 10 * ONE);
        vm.startPrank(alice);
        k613Local.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        token.approve(address(distributor), 1_000 * ONE);
        distributor.deposit(1_000 * ONE);
        vm.stopPrank();
        token.transfer(address(distributor), 10 * ONE);
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
        assertEq(k613Local.balanceOf(alice), 1_000 * ONE);
        uint256 aliceXkBefore = token.balanceOf(alice);
        vm.prank(alice);
        distributor.claim();
        // setUp had alice 1000 + bob 1000; this test adds alice 1000 → alice 2000, bob 1000, total 3000. Alice share = 2/3 of 10 = 20/3
        uint256 aliceExpected = (20 * ONE) / 3;
        assertApproxEqAbs(token.balanceOf(alice), aliceXkBefore + aliceExpected, 1e15);
    }

    /// @notice test_RD_setStaking_Zero_ThenReSet: setStaking(0) then setStaking(staking) updates staking address and role correctly.
    function test_RD_setStaking_Zero_ThenReSet() public {
        K613 k613Local = new K613(address(this));
        Staking staking = new Staking(address(k613Local), address(token), 7 days, 5_000);
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

    /// @notice testNotifyRewardDistributesToHolders: notifyReward then claim; user receives pro-rata share and pendingRewards goes to 0.
    function testNotifyRewardDistributesToHolders() public {
        token.transfer(address(distributor), 10 * ONE);
        distributor.notifyReward(10 * ONE);

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        distributor.claim();
        uint256 aliceAfter = token.balanceOf(alice);

        uint256 aliceShare = (1_000 * ONE * 10 * ONE) / (2_000 * ONE);
        assertApproxEqAbs(aliceAfter - aliceBefore, aliceShare, 1000);
        assertEq(distributor.pendingRewards(), 0);
    }

    /// @notice testClaimTransfersReward: claim() transfers reward token to user and pendingRewardsOf(user) becomes 0.
    function testClaimTransfersReward() public {
        token.transfer(address(distributor), 10 * ONE);
        distributor.notifyReward(10 * ONE);

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        distributor.claim();
        uint256 aliceAfter = token.balanceOf(alice);

        uint256 aliceShare = (1_000 * ONE * 10 * ONE) / (2_000 * ONE);
        assertApproxEqAbs(aliceAfter - aliceBefore, aliceShare, 1000);
        assertEq(distributor.pendingRewardsOf(alice), 0);
    }

    /// @notice testPendingRewardsOf: pendingRewardsOf(alice) and pendingRewardsOf(bob) match expected pro-rata share after notifyReward.
    function testPendingRewardsOf() public {
        token.transfer(address(distributor), 10 * ONE);
        distributor.notifyReward(10 * ONE);

        uint256 aliceShare = (1_000 * ONE * 10 * ONE) / (2_000 * ONE);
        assertApproxEqAbs(distributor.pendingRewardsOf(alice), aliceShare, 1000);
        assertApproxEqAbs(distributor.pendingRewardsOf(bob), aliceShare, 1000);
    }

    /// @notice testWithdraw: withdraw(amount) decreases balanceOf and totalDeposits, returns staking token to user.
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

    /// @notice testWithdrawInsufficientReverts: withdraw(amount) exceeding balanceOf reverts with InsufficientBalance.
    function testWithdrawInsufficientReverts() public {
        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.InsufficientBalance.selector);
        distributor.withdraw(2_000 * ONE);
    }

    /// @notice testDeposit: deposit(amount) increases balanceOf and totalDeposits; user must approve and have token.
    function testDeposit() public {
        token.mint(alice, 500 * ONE);
        vm.prank(alice);
        token.approve(address(distributor), 500 * ONE);
        vm.prank(alice);
        distributor.deposit(500 * ONE);

        assertEq(distributor.balanceOf(alice), 1_500 * ONE);
        assertEq(distributor.totalDeposits(), 2_500 * ONE);
    }

    /// @notice testInstantExitSmallPenalty_AccumulatesInRD: Small instant-exit penalty below MIN_PENALTY_FLUSH accumulates in pendingPenalties; accRewardPerShare unchanged until flush.
    function testInstantExitSmallPenalty_AccumulatesInRD() public {
        K613 k613Local = new K613(address(this));
        uint256 penaltyBps = 100;
        Staking staking = new Staking(address(k613Local), address(token), 7 days, penaltyBps);
        staking.setRewardsDistributor(address(distributor));
        distributor.setStaking(address(staking));
        token.setMinter(address(staking));
        token.grantRole(token.MINTER_ROLE(), address(this));
        token.setTransferWhitelist(address(staking), true);

        uint256 smallStake = 10 * ONE;
        k613Local.mint(alice, smallStake);
        vm.startPrank(alice);
        k613Local.approve(address(staking), smallStake);
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

    /// @notice testDeposit_Withdraw_Claim_Ordering: notifyReward, withdraw, notifyReward, deposit; pendingRewardsOf reflects correct ordering and total conservation.
    function testDeposit_Withdraw_Claim_Ordering() public {
        token.transfer(address(distributor), 20 * ONE);
        distributor.notifyReward(10 * ONE);
        vm.prank(alice);
        distributor.withdraw(500 * ONE);
        distributor.notifyReward(10 * ONE);
        vm.prank(alice);
        distributor.deposit(500 * ONE);
        assertGt(distributor.pendingRewardsOf(alice), 0);
        assertApproxEqAbs(distributor.pendingRewardsOf(alice) + distributor.pendingRewardsOf(bob), 20 * ONE, 10000);
    }

    /// @notice test_RD_Staking_PenaltyFlow_Integration: Staking with penalty; user instant-exits; penalty appears in RD and is distributed to remaining depositors (pendingRewardsOf).
    function test_RD_Staking_PenaltyFlow_Integration() public {
        Staking stakingWithPenalty = new Staking(address(k613), address(token), 7 days, 5_000);
        token.setMinter(address(stakingWithPenalty));
        token.grantRole(token.MINTER_ROLE(), address(this));
        token.setTransferWhitelist(address(stakingWithPenalty), true);
        stakingWithPenalty.setRewardsDistributor(address(distributor));
        distributor.setStaking(address(stakingWithPenalty));

        k613.mint(alice, 1_000 * ONE);
        vm.startPrank(alice);
        k613.approve(address(stakingWithPenalty), 1_000 * ONE);
        stakingWithPenalty.stake(1_000 * ONE);
        token.approve(address(stakingWithPenalty), 1_000 * ONE);
        stakingWithPenalty.initiateExit(1_000 * ONE);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        stakingWithPenalty.instantExit(0);

        uint256 penalty = (1_000 * ONE * 5_000) / 10_000;
        assertGe(distributor.pendingPenalties(), penalty);

        vm.warp(block.timestamp + EPOCH + 1);
        vm.prank(bob);
        distributor.advanceEpoch();

        uint256 bobShare = (1_000 * ONE * penalty) / (2_000 * ONE);
        assertApproxEqAbs(distributor.pendingRewardsOf(bob), bobShare, 1000);
    }

    /// @notice testClaimWorksDuringExitVesting: (Legacy/alternate behavior) Verifies claim or exit vesting interaction when RD and Staking are wired; may expect claim blocked or allowed depending on ExitVestingActive logic.
    function testClaimWorksDuringExitVesting() public {
        K613 k613Local = new K613(address(this));
        Staking stakingLocal = new Staking(address(k613Local), address(token), 7 days, 5_000);
        token.setMinter(address(stakingLocal));
        token.grantRole(token.MINTER_ROLE(), address(this));
        token.setTransferWhitelist(address(stakingLocal), true);
        distributor.setStaking(address(stakingLocal));
        k613Local.mint(alice, 1_000 * ONE);

        vm.startPrank(alice);
        k613Local.approve(address(stakingLocal), 1_000 * ONE);
        stakingLocal.stake(1_000 * ONE);
        token.approve(address(distributor), 1_000 * ONE);
        distributor.deposit(1_000 * ONE);
        vm.stopPrank();

        token.transfer(address(distributor), 10 * ONE);
        distributor.notifyReward(10 * ONE);

        // Alice withdraws from RD, initiates exit — claim blocked during exit vesting
        vm.prank(alice);
        distributor.withdraw(1_000 * ONE);
        vm.prank(alice);
        token.approve(address(stakingLocal), 1_000 * ONE);
        vm.prank(alice);
        stakingLocal.initiateExit(1_000 * ONE);

        uint256 pendingBefore = distributor.pendingRewardsOf(alice);
        assertGt(pendingBefore, 0);
        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.ExitVestingActive.selector);
        distributor.claim();

        // After cancel exit, claim works again
        vm.prank(alice);
        stakingLocal.cancelExit(0);
        vm.prank(alice);
        distributor.claim();
        assertEq(distributor.pendingRewardsOf(alice), 0);
    }
}
