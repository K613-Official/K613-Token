// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test, Vm} from "forge-std/Test.sol";
import {K613} from "../src/token/K613.sol";
import {xK613} from "../src/token/xK613.sol";
import {Staking} from "../src/staking/Staking.sol";
import {RewardsDistributor} from "../src/staking/RewardsDistributor.sol";
import {Treasury} from "../src/treasury/Treasury.sol";

/// @title AuditFindings — tests that verify every Hashlock finding is resolved
/// @notice Each test confirms the fix for the corresponding audit finding.
///         Tests are named test_<ID>_<short_description>. A passing test means the fix works.
contract AuditFindingsTest is Test {
    uint256 private constant ONE = 1e18;
    uint256 private constant LOCK_DURATION = 7 days;
    uint256 private constant EPOCH_DURATION = 7 days;
    uint256 private constant PENALTY_BPS = 5_000; // 50%

    K613 private k613;
    xK613 private xk613;
    Staking private staking;
    RewardsDistributor private distributor;
    Treasury private treasury;

    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);

    function setUp() public {
        k613 = new K613(address(this));
        xk613 = new xK613(address(this));
        staking = new Staking(address(k613), address(xk613), LOCK_DURATION, PENALTY_BPS);
        distributor = new RewardsDistributor(address(xk613), address(xk613), address(k613), EPOCH_DURATION);
        treasury = new Treasury(address(k613), address(xk613), address(staking), address(distributor));

        xk613.setMinter(address(staking));
        xk613.setTransferWhitelist(address(distributor), true);
        xk613.setTransferWhitelist(address(staking), true);
        xk613.setTransferWhitelist(address(treasury), true);

        staking.setRewardsDistributor(address(distributor));
        distributor.setStaking(address(staking));
        distributor.grantRole(distributor.REWARDS_NOTIFIER_ROLE(), address(treasury));

        k613.mint(alice, 100_000 * ONE);
        k613.mint(bob, 100_000 * ONE);
        k613.mint(address(this), 100_000 * ONE);
    }

    // -----------------------------------------------------------------------
    //  [H-01] FIX: redeemRewards allows converting reward xK613 back to K613
    // -----------------------------------------------------------------------

    /// @notice Alice gets reward xK613 beyond her stake. She can now redeem them
    ///         via redeemRewards() which burns xK613 and releases K613 from system staker positions.
    function test_H01_RewardXK613_CannotBeRedeemedForK613() public {
        // Register RD and Treasury as system stakers
        staking.addSystemStaker(address(distributor));
        staking.addSystemStaker(address(treasury));

        // Alice stakes 1000 K613 -> gets 1000 xK613
        vm.startPrank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(distributor), 1_000 * ONE);
        distributor.deposit(1_000 * ONE);
        vm.stopPrank();

        // Bob stakes 1000 K613, then instant-exits generating penalty
        vm.startPrank(bob);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(staking), 1_000 * ONE);
        staking.initiateExit(1_000 * ONE);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        staking.instantExit(0);

        // Advance epoch to flush penalties as rewards
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        distributor.advanceEpoch();

        // Alice claims rewards
        vm.prank(alice);
        distributor.withdraw(1_000 * ONE);
        vm.prank(alice);
        distributor.claim();

        uint256 aliceXK613 = xk613.balanceOf(alice);
        (uint256 aliceStaked,) = staking.deposits(alice);
        uint256 rewardPortion = aliceXK613 - aliceStaked;
        assertGt(rewardPortion, 0, "Alice has reward xK613 beyond her stake");

        // FIX: Alice can now redeem reward xK613 via redeemRewards
        uint256 k613Before = k613.balanceOf(alice);
        vm.startPrank(alice);
        xk613.approve(address(staking), rewardPortion);
        staking.redeemRewards(rewardPortion);
        vm.stopPrank();
        uint256 k613After = k613.balanceOf(alice);

        assertEq(k613After - k613Before, rewardPortion, "FIX: reward xK613 redeemed for K613");
    }

    /// @notice Treasury staking position K613 can now be recovered via redeemRewards.
    function test_H01_TreasuryStakingPosition_PermanentlyLocked() public {
        staking.addSystemStaker(address(treasury));

        k613.approve(address(treasury), 500 * ONE);
        treasury.depositRewards(500 * ONE);

        // Treasury has a staking position
        (uint256 treasuryStaked,) = staking.deposits(address(treasury));
        assertEq(treasuryStaked, 500 * ONE, "Treasury has staking position");

        // FIX: anyone holding xK613 from Treasury rewards can redeem against this position
        // Alice gets the xK613 rewards and redeems them
        vm.startPrank(alice);
        k613.approve(address(staking), 500 * ONE);
        staking.stake(500 * ONE);
        xk613.approve(address(distributor), 500 * ONE);
        distributor.deposit(500 * ONE);
        vm.stopPrank();

        // Advance epoch to distribute rewards
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        distributor.advanceEpoch();

        vm.prank(alice);
        distributor.withdraw(500 * ONE);
        vm.prank(alice);
        distributor.claim();

        uint256 aliceRewardXK613 = xk613.balanceOf(alice) - 500 * ONE;
        if (aliceRewardXK613 > 0) {
            uint256 k613Before = k613.balanceOf(alice);
            vm.startPrank(alice);
            xk613.approve(address(staking), aliceRewardXK613);
            staking.redeemRewards(aliceRewardXK613);
            vm.stopPrank();
            assertEq(k613.balanceOf(alice) - k613Before, aliceRewardXK613, "FIX: Treasury-backed K613 redeemed");
        }
    }

    // -----------------------------------------------------------------------
    //  [H-02] FIX: redeemRewards cannot bypass exit penalties
    // -----------------------------------------------------------------------

    /// @notice A staker who holds ONLY staking xK613 (no reward portion) cannot
    ///         call redeemRewards to bypass exit penalties. ExceedsRewardPortion reverts.
    function test_H02_RedeemRewards_CannotBypassExitPenalty() public {
        staking.addSystemStaker(address(distributor));
        staking.addSystemStaker(address(treasury));

        // Alice stakes 1000 K613 -> gets 1000 xK613
        vm.startPrank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        vm.stopPrank();

        // Alice holds exactly 1000 xK613 from staking — zero reward portion
        uint256 aliceXK613 = xk613.balanceOf(alice);
        (uint256 aliceStaked,) = staking.deposits(alice);
        assertEq(aliceXK613, aliceStaked, "Alice wallet == staked amount, no rewards");

        // FIX: redeemRewards reverts because rewardPortion == 0
        vm.startPrank(alice);
        xk613.approve(address(staking), 1_000 * ONE);
        vm.expectRevert(Staking.ExceedsRewardPortion.selector);
        staking.redeemRewards(1_000 * ONE);
        vm.stopPrank();

        // Even 1 wei should revert
        vm.startPrank(alice);
        vm.expectRevert(Staking.ExceedsRewardPortion.selector);
        staking.redeemRewards(1);
        vm.stopPrank();
    }

    /// @notice A staker who also earned rewards CAN redeem only the reward excess,
    ///         but NOT their staked portion.
    function test_H02_RedeemRewards_OnlyRewardPortionAllowed() public {
        staking.addSystemStaker(address(distributor));
        staking.addSystemStaker(address(treasury));

        // Alice stakes 1000 K613
        vm.startPrank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(distributor), 1_000 * ONE);
        distributor.deposit(1_000 * ONE);
        vm.stopPrank();

        // Bob stakes and instant-exits to generate penalty rewards
        vm.startPrank(bob);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(staking), 1_000 * ONE);
        staking.initiateExit(1_000 * ONE);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        staking.instantExit(0);

        // Advance epoch to flush penalty rewards
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        distributor.advanceEpoch();

        // Alice claims rewards
        vm.prank(alice);
        distributor.withdraw(1_000 * ONE);
        vm.prank(alice);
        distributor.claim();

        uint256 aliceXK613 = xk613.balanceOf(alice);
        (uint256 aliceStaked,) = staking.deposits(alice);
        uint256 rewardPortion = aliceXK613 - aliceStaked;
        assertGt(rewardPortion, 0, "Alice has reward xK613");

        // FIX: trying to redeem MORE than reward portion reverts
        vm.startPrank(alice);
        xk613.approve(address(staking), aliceXK613);
        vm.expectRevert(Staking.ExceedsRewardPortion.selector);
        staking.redeemRewards(rewardPortion + 1);
        vm.stopPrank();

        // FIX: redeeming exactly the reward portion succeeds
        uint256 k613Before = k613.balanceOf(alice);
        vm.startPrank(alice);
        staking.redeemRewards(rewardPortion);
        vm.stopPrank();
        assertEq(k613.balanceOf(alice) - k613Before, rewardPortion, "Only reward portion redeemed");

        // After redeeming, Alice still has her staking position intact
        (uint256 aliceStakedAfter,) = staking.deposits(alice);
        assertEq(aliceStakedAfter, 1_000 * ONE, "Staking position unchanged");
    }

    // -----------------------------------------------------------------------
    //  [H-02] ADVERSARIAL: Attempts to break the redeemRewards fix
    // -----------------------------------------------------------------------

    /// @dev Helper: Bob stakes 1000, instant-exits (50% penalty), advance epoch.
    function _generatePenaltyRewards() internal {
        vm.startPrank(bob);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(staking), 1_000 * ONE);
        staking.initiateExit(1_000 * ONE);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        staking.instantExit(0);
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        distributor.advanceEpoch();
    }

    /// @dev Helper: Alice stakes 1000, deposits to RD, generates rewards, withdraws & claims.
    ///      Returns the reward xK613 amount Alice earned.
    function _setupAliceWithRewards() internal returns (uint256 rewards) {
        staking.addSystemStaker(address(distributor));
        staking.addSystemStaker(address(treasury));

        vm.startPrank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(distributor), 1_000 * ONE);
        distributor.deposit(1_000 * ONE);
        vm.stopPrank();

        _generatePenaltyRewards();

        vm.prank(alice);
        distributor.withdraw(1_000 * ONE);
        vm.prank(alice);
        distributor.claim();

        (uint256 staked,) = staking.deposits(alice);
        rewards = xk613.balanceOf(alice) - staked;
        assertGt(rewards, 0, "Alice has reward xK613");
    }

    /// @notice ATTACK: initiateExit(800) to reduce ownPosition, then redeemRewards.
    ///         RESULT: rewardPortion unchanged -- wallet and ownPosition drop equally.
    function test_H02_Attack_InitiateExitDoesNotInflateRewardPortion() public {
        uint256 rewards = _setupAliceWithRewards();

        vm.startPrank(alice);
        xk613.approve(address(staking), type(uint256).max);
        staking.initiateExit(800 * ONE);

        // After initiateExit(800): wallet -= 800, ownPosition = 1000-800 = 200
        // rewardPortion = (wallet-800) - 200 = rewards (unchanged!)
        vm.expectRevert(Staking.ExceedsRewardPortion.selector);
        staking.redeemRewards(rewards + 1);

        // Exact reward portion still works
        staking.redeemRewards(rewards);
        vm.stopPrank();
    }

    /// @notice ATTACK: stake extra K613 to inflate wallet xK613 balance.
    ///         RESULT: ownPosition grows equally -- rewardPortion unchanged.
    function test_H02_Attack_StakeMoreDoesNotIncreaseRewardPortion() public {
        uint256 rewards = _setupAliceWithRewards();

        // Stake 5000 more -> wallet_xK613 jumps by 5000, but amount also jumps by 5000
        vm.startPrank(alice);
        k613.approve(address(staking), 5_000 * ONE);
        staking.stake(5_000 * ONE);

        xk613.approve(address(staking), type(uint256).max);
        vm.expectRevert(Staking.ExceedsRewardPortion.selector);
        staking.redeemRewards(rewards + 1);

        staking.redeemRewards(rewards);
        vm.stopPrank();
    }

    /// @notice ATTACK: many small redeems to exceed total reward portion.
    ///         RESULT: total redeemed bounded by original rewards. Next call reverts.
    function test_H02_Attack_RepeatedSmallRedeems_Bounded() public {
        uint256 rewards = _setupAliceWithRewards();
        uint256 chunk = rewards / 4;
        assertGt(chunk, 0);

        vm.startPrank(alice);
        xk613.approve(address(staking), type(uint256).max);

        uint256 totalRedeemed;
        for (uint256 i = 0; i < 4; i++) {
            staking.redeemRewards(chunk);
            totalRedeemed += chunk;
        }
        uint256 dust = rewards - totalRedeemed;
        if (dust > 0) {
            staking.redeemRewards(dust);
            totalRedeemed += dust;
        }

        assertEq(totalRedeemed, rewards, "Total redeemed == total rewards");

        // Nothing left -- must revert
        vm.expectRevert(Staking.ExceedsRewardPortion.selector);
        staking.redeemRewards(1);
        vm.stopPrank();
    }

    /// @notice ATTACK: initiateExit/cancelExit churn then redeemRewards.
    ///         RESULT: rewardPortion identical throughout cycle.
    function test_H02_Attack_CancelExitCycleNoEffect() public {
        uint256 rewards = _setupAliceWithRewards();

        vm.startPrank(alice);
        xk613.approve(address(staking), type(uint256).max);

        // Rapid churn: initiate/cancel multiple times
        staking.initiateExit(500 * ONE);
        staking.cancelExit(0);
        staking.initiateExit(200 * ONE);
        staking.cancelExit(0);
        staking.initiateExit(900 * ONE);
        staking.cancelExit(0);

        // rewardPortion unchanged after all the churn
        vm.expectRevert(Staking.ExceedsRewardPortion.selector);
        staking.redeemRewards(rewards + 1);

        staking.redeemRewards(rewards);
        vm.stopPrank();
    }

    /// @notice EDGE CASE: user who is ALSO a system staker can recursively
    ///         drain their own position penalty-free. Each redeem reduces
    ///         their amount (as system staker), which lowers ownPosition,
    ///         creating artificial rewardPortion for the next call.
    ///         REQUIRES admin misconfiguration (addSystemStaker intended for
    ///         protocol contracts only, not user EOAs).
    function test_H02_Edge_SelfSystemStaker_DrainOwnPosition() public {
        // Admin mistake: adds Alice as system staker
        staking.addSystemStaker(address(alice));

        vm.startPrank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(distributor), 1_000 * ONE);
        distributor.deposit(1_000 * ONE);
        vm.stopPrank();

        _generatePenaltyRewards();

        vm.prank(alice);
        distributor.withdraw(1_000 * ONE);
        vm.prank(alice);
        distributor.claim();

        // Alice: 1500 xK613 (1000 staked + 500 rewards), amount=1000
        (uint256 stakedBefore,) = staking.deposits(alice);
        uint256 rewards = xk613.balanceOf(alice) - stakedBefore;
        assertEq(stakedBefore, 1_000 * ONE);
        assertEq(rewards, 500 * ONE);

        uint256 k613Before = k613.balanceOf(alice);

        vm.startPrank(alice);
        xk613.approve(address(staking), type(uint256).max);

        // 1st redeem (500): legit rewardPortion = 1500 - 1000 = 500
        // Deducts 500 from Alice's OWN system-staker position -> amount = 500
        staking.redeemRewards(rewards);

        (uint256 stakedMid,) = staking.deposits(alice);
        assertEq(stakedMid, 500 * ONE, "Position reduced by own-system-staker deduction");

        // NOW: wallet = 1000, ownPosition = 500 -> artificial rewardPortion = 500
        // 2nd redeem (500): drains remaining system position
        staking.redeemRewards(rewards);

        vm.stopPrank();

        // Result: Alice recovered full 1000 K613 stake WITHOUT exit penalty
        (uint256 stakedAfter,) = staking.deposits(alice);
        assertEq(stakedAfter, 0, "Position fully drained");

        uint256 k613Gained = k613.balanceOf(alice) - k613Before;
        assertEq(k613Gained, 1_000 * ONE, "Full stake recovered penalty-free");

        // 500 reward xK613 stuck in wallet -- no system backing left
        assertEq(xk613.balanceOf(alice), 500 * ONE, "Reward xK613 orphaned");

        // Cannot redeem further: passes ExceedsRewardPortion but fails on backing
        vm.prank(alice);
        vm.expectRevert(Staking.InsufficientSystemBacking.selector);
        staking.redeemRewards(1);
    }

    // -----------------------------------------------------------------------
    //  [M-01] FIX: Paused Staking no longer blocks claim/advanceEpoch (try/catch)
    // -----------------------------------------------------------------------

    /// @notice claim() now works even when Staking is paused — _stakeHeldK613
    ///         silently skips the stake call via try/catch.
    function test_M01_PausedStaking_BlocksClaimInRewardsDistributor() public {
        // Alice stakes and deposits to RD
        vm.startPrank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(distributor), 1_000 * ONE);
        distributor.deposit(1_000 * ONE);
        vm.stopPrank();

        // Bob stakes and instant-exits -> penalty K613 goes to distributor
        vm.startPrank(bob);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(staking), 1_000 * ONE);
        staking.initiateExit(1_000 * ONE);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        staking.instantExit(0);

        // Flush penalties so Alice has claimable rewards
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        distributor.advanceEpoch();

        // Generate MORE penalty so RD is holding K613 right now:
        k613.mint(bob, 1_000 * ONE);
        vm.startPrank(bob);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(staking), 1_000 * ONE);
        staking.initiateExit(1_000 * ONE);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        staking.instantExit(0);

        uint256 rdK613Balance = k613.balanceOf(address(distributor));
        assertGt(rdK613Balance, 0, "Distributor holds K613 from penalties");

        // Pause Staking
        staking.pause();

        // FIX: Alice CAN claim — try/catch in _stakeHeldK613 absorbs the pause
        vm.prank(alice);
        distributor.claim(); // no revert

        // K613 stays in RD (not staked) but claim succeeds
        assertGt(k613.balanceOf(address(distributor)), 0, "K613 held safely until Staking unpaused");
    }

    /// @notice advanceEpoch also works when Staking is paused.
    function test_M01_PausedStaking_BlocksAdvanceEpoch() public {
        vm.startPrank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(distributor), 1_000 * ONE);
        distributor.deposit(1_000 * ONE);
        vm.stopPrank();

        // Generate penalty so RD holds K613
        vm.startPrank(bob);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(staking), 1_000 * ONE);
        staking.initiateExit(1_000 * ONE);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        staking.instantExit(0);

        assertGt(k613.balanceOf(address(distributor)), 0, "RD holds K613");

        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        staking.pause();

        // FIX: advanceEpoch succeeds — try/catch absorbs the Staking pause
        distributor.advanceEpoch(); // no revert
    }

    // -----------------------------------------------------------------------
    //  [M-02] FIX: advanceEpoch always updates lastEpochFlushAt
    // -----------------------------------------------------------------------

    /// @notice After idle epochs, advanceEpoch now always advances lastEpochFlushAt.
    ///         Dust penalties below MIN_PENALTY_FLUSH are correctly deferred.
    function test_M02_StaleEpochTracking_DustPenaltyFlushedImmediately() public {
        vm.startPrank(alice);
        k613.approve(address(staking), 10_000 * ONE);
        staking.stake(10_000 * ONE);
        xk613.approve(address(distributor), 10_000 * ONE);
        distributor.deposit(10_000 * ONE);
        vm.stopPrank();

        // Warp 5 epochs with NO penalties and NO rewards
        vm.warp(block.timestamp + 5 * EPOCH_DURATION + 1);

        // FIX: advanceEpoch now ALWAYS updates lastEpochFlushAt
        distributor.advanceEpoch();
        assertEq(distributor.lastEpochFlushAt(), block.timestamp, "FIX: lastEpochFlushAt updated");

        // Second call in same block should revert
        vm.expectRevert(RewardsDistributor.EpochNotReady.selector);
        distributor.advanceEpoch();

        // Generate a dust penalty below MIN_PENALTY_FLUSH
        uint256 dustAmount = 1e17;
        k613.mint(bob, dustAmount);
        vm.startPrank(bob);
        k613.approve(address(staking), dustAmount);
        staking.stake(dustAmount);
        xk613.approve(address(staking), dustAmount);
        staking.initiateExit(dustAmount);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        staking.instantExit(0);

        uint256 dustPenalty = distributor.pendingPenalties();
        assertGt(dustPenalty, 0, "Dust penalty exists");
        assertLt(dustPenalty, distributor.MIN_PENALTY_FLUSH(), "Penalty below threshold");

        // FIX: dust penalty is NOT flushed because epoch hasn't passed yet
        uint256 accBefore = distributor.accRewardPerShare();

        // Trigger _distributePending via deposit
        k613.mint(bob, ONE);
        vm.startPrank(bob);
        k613.approve(address(staking), ONE);
        staking.stake(ONE);
        xk613.approve(address(distributor), ONE);
        distributor.deposit(ONE);
        vm.stopPrank();

        uint256 accAfter = distributor.accRewardPerShare();

        // FIX: dust penalty correctly deferred — not flushed below threshold within epoch
        assertEq(accAfter, accBefore, "FIX: dust penalty NOT flushed before epoch boundary");
        assertGt(distributor.pendingPenalties(), 0, "Dust penalty still pending");
    }

    // -----------------------------------------------------------------------
    //  [L-01] FIX: Constructor rejects zero lockDuration and zero penaltyBps
    // -----------------------------------------------------------------------

    /// @notice Deploying Staking with lockDuration=0 now reverts.
    function test_L01_ZeroLockDuration_BreaksInstantExit() public {
        vm.expectRevert(Staking.InvalidLockDuration.selector);
        new Staking(address(k613), address(xk613), 0, PENALTY_BPS);
    }

    /// @notice Deploying Staking with instantExitPenaltyBps=0 now reverts.
    function test_L01_ZeroPenaltyBps_InstantExitIsFree() public {
        vm.expectRevert(Staking.InvalidBps.selector);
        new Staking(address(k613), address(xk613), LOCK_DURATION, 0);
    }

    // -----------------------------------------------------------------------
    //  [L-02] FIX: RewardQueued event emitted when totalDeposits == 0
    // -----------------------------------------------------------------------

    /// @notice notifyReward() when totalDeposits==0 now emits RewardQueued.
    function test_L02_NotifyReward_NoEventWhenTotalDepositsZero() public {
        k613.approve(address(treasury), 100 * ONE);
        assertEq(distributor.totalDeposits(), 0);

        vm.recordLogs();
        treasury.depositRewards(100 * ONE);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 rewardQueuedSig = keccak256("RewardQueued(uint256)");

        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == rewardQueuedSig) {
                if (logs[i].emitter == address(distributor)) {
                    found = true;
                    break;
                }
            }
        }

        // FIX: RewardQueued event is now emitted
        assertTrue(found, "FIX: RewardQueued emitted when totalDeposits==0");
        assertEq(distributor.pendingRewards(), 100 * ONE, "Rewards queued correctly");
    }

    // -----------------------------------------------------------------------
    //  [L-03] FIX: ExitVestingActive check moved to top of claim()
    // -----------------------------------------------------------------------

    /// @notice claim() now checks ExitVestingActive BEFORE _updateUser,
    ///         so no wasted gas on _distributePending when the call will revert anyway.
    ///         Verify that a subsequent caller can still flush penalties normally.
    function test_L03_ClaimRevertsAfterDistributePending_WastedWork() public {
        // Setup: Alice deposits to RD, Bob generates a penalty
        vm.startPrank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(distributor), 500 * ONE);
        distributor.deposit(500 * ONE);
        vm.stopPrank();

        vm.startPrank(bob);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(staking), 1_000 * ONE);
        staking.initiateExit(1_000 * ONE);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        staking.instantExit(0);

        // Treasury deposits rewards so Alice has something to claim
        k613.approve(address(treasury), 100 * ONE);
        treasury.depositRewards(100 * ONE);

        // Alice withdraws from RD and initiates exit
        vm.prank(alice);
        distributor.withdraw(500 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 500 * ONE);
        vm.prank(alice);
        staking.initiateExit(500 * ONE);

        // Advance epoch
        vm.warp(block.timestamp + EPOCH_DURATION + 1);

        // FIX: claim reverts immediately at the top — no wasted _distributePending work
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.ExitVestingActive.selector);
        distributor.claim();
        uint256 gasUsed = gasBefore - gasleft();

        // FIX: Gas usage should be minimal (no _distributePending executed)
        // A rough check: if _distributePending was called, it would use significantly more gas
        assertLt(gasUsed, 50_000, "FIX: early revert uses minimal gas");
    }

    // -----------------------------------------------------------------------
    //  [L-04] FIX: instantExitPenaltyBps now has a setter with access control
    // -----------------------------------------------------------------------

    /// @notice Admin can update instantExitPenaltyBps. Non-admin reverts.
    function test_L04_PenaltyBpsImmutable_NoSetter() public {
        assertEq(staking.instantExitPenaltyBps(), PENALTY_BPS);

        // FIX: admin can update
        staking.setInstantExitPenaltyBps(3_000);
        assertEq(staking.instantExitPenaltyBps(), 3_000, "FIX: penalty updated to 3000");

        // Non-admin cannot
        vm.prank(alice);
        vm.expectRevert();
        staking.setInstantExitPenaltyBps(1_000);

        // Zero and above MAX_BASIS_POINTS rejected
        vm.expectRevert(Staking.InvalidBps.selector);
        staking.setInstantExitPenaltyBps(0);
        vm.expectRevert(Staking.InvalidBps.selector);
        staking.setInstantExitPenaltyBps(10_001);
    }

    // -----------------------------------------------------------------------
    //  [Q-02] FIX: Penalty rounds UP for dust amounts
    // -----------------------------------------------------------------------

    /// @notice With 50% penalty (5000 BPS), amount=1 wei now produces penalty=1.
    ///         RewardsDistributorNotSet check is now correctly triggered.
    function test_Q02_DustAmount_PenaltyRoundsToZero() public {
        // Staking without RD set
        Staking noRDStaking = new Staking(address(k613), address(xk613), LOCK_DURATION, PENALTY_BPS);
        xk613.setMinter(address(noRDStaking));
        xk613.setTransferWhitelist(address(noRDStaking), true);

        vm.startPrank(alice);
        k613.approve(address(noRDStaking), 1);
        noRDStaking.stake(1);
        xk613.approve(address(noRDStaking), 1);
        noRDStaking.initiateExit(1);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);

        // FIX: penalty = ceil(1 * 5000 / 10000) = 1 — no longer zero
        // Because penalty > 0 and RD is not set, RewardsDistributorNotSet is triggered
        vm.prank(alice);
        vm.expectRevert(Staking.RewardsDistributorNotSet.selector);
        noRDStaking.instantExit(0);

        xk613.setMinter(address(staking));
    }

    /// @notice With ceil rounding, amount=1 * 5000 / 10000 now rounds up to 1.
    function test_Q02_DustPenaltyCalculation_IsZero() public pure {
        uint256 amount = 1;
        uint256 bps = 5_000;
        uint256 maxBps = 10_000;
        uint256 penalty = (amount * bps + maxBps - 1) / maxBps;

        // FIX: penalty rounds up to 1
        assertEq(penalty, 1, "FIX: ceil(1 * 5000 / 10000) = 1");
    }
    /*

        // -----------------------------------------------------------------------
        //  [NEW-01] xK613 pause freezes the ENTIRE protocol (cascading DoS)
        // -----------------------------------------------------------------------
        //  Unlike M-01 (Staking pause blocks RD claims), pausing the xK613 TOKEN
        //  itself blocks every single operation across Staking, RewardsDistributor,
        //  and Treasury simultaneously. The xK613 PAUSER_ROLE holder can
        //  unilaterally brick the whole protocol.

        /// @notice xK613 pause blocks staking.stake (mint reverts).
        function test_NEW01_xK613Pause_BlocksStake() public {
            xk613.pause();

            vm.startPrank(alice);
            k613.approve(address(staking), 100 * ONE);
            vm.expectRevert(); // EnforcedPause from xK613._update
            staking.stake(100 * ONE);
            vm.stopPrank();
        }

        /// @notice xK613 pause blocks staking.exit (burnFrom reverts).
        function test_NEW01_xK613Pause_BlocksExit() public {
            // Setup: stake and initiate exit while unpaused
            vm.startPrank(alice);
            k613.approve(address(staking), 100 * ONE);
            staking.stake(100 * ONE);
            xk613.approve(address(staking), 100 * ONE);
            staking.initiateExit(100 * ONE);
            vm.stopPrank();

            vm.warp(block.timestamp + LOCK_DURATION);
            xk613.pause();

            // BUG: exit reverts because burnFrom calls _update which is paused
            vm.prank(alice);
            vm.expectRevert(); // EnforcedPause
            staking.exit(0);
        }

        /// @notice xK613 pause blocks distributor.claim (transfer reverts).
        function test_NEW01_xK613Pause_BlocksClaim() public {
            vm.startPrank(alice);
            k613.approve(address(staking), 1_000 * ONE);
            staking.stake(1_000 * ONE);
            xk613.approve(address(distributor), 1_000 * ONE);
            distributor.deposit(1_000 * ONE);
            vm.stopPrank();

            k613.approve(address(treasury), 100 * ONE);
            treasury.depositRewards(100 * ONE);

            xk613.pause();

            // BUG: claim reverts -- rewards frozen
            vm.prank(alice);
            vm.expectRevert(); // EnforcedPause
            distributor.claim();
        }

        /// @notice xK613 pause blocks distributor.deposit AND withdraw.
        function test_NEW01_xK613Pause_BlocksDepositAndWithdraw() public {
            vm.startPrank(alice);
            k613.approve(address(staking), 1_000 * ONE);
            staking.stake(1_000 * ONE);
            xk613.approve(address(distributor), 500 * ONE);
            distributor.deposit(500 * ONE);
            vm.stopPrank();

            xk613.pause();

            // BUG: deposit reverts
            vm.prank(alice);
            xk613.approve(address(distributor), 500 * ONE);
            vm.prank(alice);
            vm.expectRevert(); // EnforcedPause
            distributor.deposit(100 * ONE);

            // BUG: withdraw also reverts -- user cannot even retrieve their own xK613
            vm.prank(alice);
            vm.expectRevert(); // EnforcedPause
            distributor.withdraw(100 * ONE);
        }

        /// @notice xK613 pause blocks Treasury.depositRewards (stake mints xK613).
        function test_NEW01_xK613Pause_BlocksTreasuryDeposit() public {
            xk613.pause();

            k613.approve(address(treasury), 100 * ONE);
            vm.expectRevert(); // EnforcedPause
            treasury.depositRewards(100 * ONE);
        }

        // -----------------------------------------------------------------------
        //  [NEW-02] Multiple advanceEpoch calls when lastEpochFlushAt is stale
        // -----------------------------------------------------------------------
        //  Extension of M-02: after idle epochs, advanceEpoch can be called
        //  back-to-back without waiting. Each call flushes new dust penalties
        //  individually instead of batching, causing precision loss.

        /// @notice After idle epochs, advanceEpoch can be called twice in the
        ///         same block -- epoch gating is broken when lastEpochFlushAt
        ///         never advances.
        function test_NEW02_AdvanceEpoch_CallableMultipleTimesWhenStale() public {
            vm.startPrank(alice);
            k613.approve(address(staking), 1_000 * ONE);
            staking.stake(1_000 * ONE);
            xk613.approve(address(distributor), 1_000 * ONE);
            distributor.deposit(1_000 * ONE);
            vm.stopPrank();

            uint256 initialFlushAt = distributor.lastEpochFlushAt();

            // Warp 3 epochs with no activity
            vm.warp(block.timestamp + 3 * EPOCH_DURATION + 1);

            // First advanceEpoch -- no penalties, so lastEpochFlushAt stays stale
            distributor.advanceEpoch();
            assertEq(distributor.lastEpochFlushAt(), initialFlushAt, "Still stale after first call");

            // BUG: second call in the SAME block also succeeds (should revert EpochNotReady)
            distributor.advanceEpoch();
            assertEq(distributor.lastEpochFlushAt(), initialFlushAt, "Still stale after second call");

            // Third call also works
            distributor.advanceEpoch();
        }

        // -----------------------------------------------------------------------
        //  [NEW-03] xK613.burnFrom has no allowance check
        // -----------------------------------------------------------------------
        //  K613.burnFrom correctly checks allowance(from, msg.sender).
        //  xK613.burnFrom does NOT -- MINTER_ROLE can burn from ANY address
        //  without approval. If MINTER_ROLE is ever assigned to a compromised
        //  address, they can destroy user tokens at will.

        /// @notice K613.burnFrom requires allowance; xK613.burnFrom does not.
        function test_NEW03_xK613BurnFrom_NoAllowanceCheck() public {
            // Mint some xK613 to alice via staking
            vm.startPrank(alice);
            k613.approve(address(staking), 100 * ONE);
            staking.stake(100 * ONE);
            vm.stopPrank();

            assertEq(xk613.balanceOf(alice), 100 * ONE);

            // Staking contract (MINTER_ROLE) can burn Alice's xK613 WITHOUT her approval
            // Simulate: Staking calls burnFrom(alice, 50) -- no allowance check
            vm.prank(address(staking));
            xk613.burnFrom(alice, 50 * ONE); // BUG: succeeds without allowance
            assertEq(xk613.balanceOf(alice), 50 * ONE, "Burned without allowance");

            // Compare: K613.burnFrom DOES require allowance
            k613.mint(alice, 100 * ONE);
            vm.prank(address(this)); // address(this) has MINTER_ROLE on K613
            vm.expectRevert(K613.BurnAmountExceedsAllowance.selector);
            k613.burnFrom(alice, 50 * ONE); // correctly reverts
        }

        // -----------------------------------------------------------------------
        //  [NEW-04] Direct token transfers to RewardsDistributor are permanently
        //           lost (no recovery function)
        // -----------------------------------------------------------------------
        //  K613 sent directly to RD gets staked via _stakeHeldK613 (creating
        //  an ever-growing RD staking position), but the resulting xK613 is
        //  never notified as rewards. xK613 sent directly sits in RD balance
        //  unaccounted. RD has no withdraw/rescue function.

        /// @notice K613 sent directly to RD gets staked but rewards are orphaned.
        function test_NEW04_DirectK613ToRD_StakedButOrphaned() public {
            // Alice deposits to RD so totalDeposits > 0
            vm.startPrank(alice);
            k613.approve(address(staking), 1_000 * ONE);
            staking.stake(1_000 * ONE);
            xk613.approve(address(distributor), 1_000 * ONE);
            distributor.deposit(1_000 * ONE);
            vm.stopPrank();

            uint256 accBefore = distributor.accRewardPerShare();

            // Bob accidentally sends 100 K613 directly to the distributor
            vm.prank(bob);
            k613.transfer(address(distributor), 100 * ONE);

            // Trigger _stakeHeldK613 (via advanceEpoch or deposit)
            vm.warp(block.timestamp + EPOCH_DURATION + 1);
            distributor.advanceEpoch();

            // K613 was staked -- RD now has a staking position
            (uint256 rdStaked,) = staking.deposits(address(distributor));
            assertEq(rdStaked, 100 * ONE, "RD has staking position from donation");

            // But accRewardPerShare did NOT increase -- rewards are orphaned
            assertEq(distributor.accRewardPerShare(), accBefore, "No rewards distributed from donation");

            // The orphaned xK613 sits in RD balance, unclaimable by anyone
            uint256 rdXK613 = xk613.balanceOf(address(distributor));
            // RD holds deposited xK613 (1000) + orphaned xK613 (100)
            assertEq(rdXK613, 1_100 * ONE, "Orphaned xK613 stuck in RD");

            // Alice can only claim 0 rewards -- the donation is lost
            assertEq(distributor.pendingRewardsOf(alice), 0, "Alice gets nothing from donation");

            // RD has no withdraw function to recover. K613 locked forever in
            // RD's staking position, xK613 orphaned in RD balance.
        }*/
}
