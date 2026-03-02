// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {K613} from "../src/token/K613.sol";
import {xK613} from "../src/token/xK613.sol";
import {Staking} from "../src/staking/Staking.sol";
import {RewardsDistributor} from "../src/staking/RewardsDistributor.sol";
import {Treasury} from "../src/treasury/Treasury.sol";

contract IntegrationTest is Test {
    uint256 private constant ONE = 1e18;
    uint256 private constant LOCK_DURATION = 7 days;
    uint256 private constant EPOCH_DURATION = 7 days;
    uint256 private constant PENALTY_BPS = 5_000;

    K613 private k613;
    xK613 private xk613;
    Staking private staking;
    RewardsDistributor private distributor;
    Treasury private treasury;

    address private deployer;
    bool private useDeployed;
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    address private carol = address(0xC0C);
    address private dave = address(0xD0D);

    function setUp() public {
        deployer = address(this);
        address k613Addr = vm.envOr("K613_ADDRESS", address(0));
        if (k613Addr != address(0)) {
            address xk613Addr = vm.envOr("XK613_ADDRESS", address(0));
            address stakingAddr = vm.envOr("STAKING_ADDRESS", address(0));
            address distributorAddr = vm.envOr("REWARDS_DISTRIBUTOR_ADDRESS", address(0));
            address treasuryAddr = vm.envOr("TREASURY_ADDRESS", address(0));
            if (xk613Addr != address(0) && stakingAddr != address(0) && distributorAddr != address(0) && treasuryAddr != address(0)) {
                _attachDeployed(k613Addr, xk613Addr, stakingAddr, distributorAddr, treasuryAddr);
                useDeployed = true;
                deployer = vm.envOr("DEPLOYER_ADDRESS", address(this));
                return;
            }
        }
        _deployFullStack(deployer);
        useDeployed = false;
    }

    /// @dev Attach to deployed contracts when all five env vars are set 
    function _attachDeployed(
        address k613Addr,
        address xk613Addr,
        address stakingAddr,
        address distributorAddr,
        address treasuryAddr
    ) internal {
        k613 = K613(k613Addr);
        xk613 = xK613(xk613Addr);
        staking = Staking(stakingAddr);
        distributor = RewardsDistributor(distributorAddr);
        treasury = Treasury(treasuryAddr);
    }

    /// @dev Lock duration: from contract on fork 
    function _lockDuration() internal view returns (uint256) {
        return useDeployed ? staking.lockDuration() : LOCK_DURATION;
    }

    /// @dev Epoch duration: from contract on fork, else test constant.
    function _epochDuration() internal view returns (uint256) {
        return useDeployed ? distributor.epochDuration() : EPOCH_DURATION;
    }

    function _deployFullStack(address deployer_) internal {
        k613 = new K613(deployer_);
        xk613 = new xK613(deployer_);
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

        k613.mint(deployer_, 1_000_000 * ONE);
    }

    /// @dev Fund a user with K613. On local deploy: mints.
    function _fundUser(address user, uint256 amount) internal {
        if (useDeployed) {
            vm.prank(deployer);
            k613.transfer(user, amount);
        } else {
            k613.mint(user, amount);
        }
    }

    /// @dev Fund alice, bob, carol, dave with the same K613 amount each.
    function _fundTestUsers(uint256 amountEach) internal {
        _fundUser(alice, amountEach);
        _fundUser(bob, amountEach);
        _fundUser(carol, amountEach);
        _fundUser(dave, amountEach);
    }

    /// @dev Deposit rewards via Treasury. On fork deployer must have K613 and will be used as caller.
    function _depositRewards(uint256 amount) internal {
        if (amount == 0) return;
        if (useDeployed) {
            vm.prank(deployer);
            k613.approve(address(treasury), amount);
            vm.prank(deployer);
            treasury.depositRewards(amount);
        } else {
            k613.approve(address(treasury), amount);
            treasury.depositRewards(amount);
        }
    }

    /// @notice test_FullStack_DeploySetup: Asserts post-deploy wiring (xK613 minter, whitelists, staking↔distributor, Treasury REWARDS_NOTIFIER_ROLE).
    function test_FullStack_DeploySetup() public view {
        assertEq(xk613.minter(), address(staking));
        assertTrue(xk613.transferWhitelist(address(distributor)));
        assertTrue(xk613.transferWhitelist(address(staking)));
        assertEq(address(staking.rewardsDistributor()), address(distributor));
        assertEq(distributor.staking(), address(staking));
        assertTrue(distributor.hasRole(distributor.REWARDS_NOTIFIER_ROLE(), address(treasury)));
    }

    /// @notice test_FullStack_Stake_DepositRD_TreasuryRewards_Claim: Full flow — stake K613, deposit xK613 to RD, Treasury adds rewards, user claims and receives expected xK613.
    function test_FullStack_Stake_DepositRD_TreasuryRewards_Claim() public {
        _fundUser(alice, 1_000 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(distributor), 1_000 * ONE);
        distributor.deposit(1_000 * ONE);
        vm.stopPrank();

        _depositRewards(100 * ONE);

        uint256 aliceBefore = xk613.balanceOf(alice);
        vm.prank(alice);
        distributor.claim();
        uint256 aliceAfter = xk613.balanceOf(alice);
        assertEq(aliceAfter - aliceBefore, 100 * ONE);
    }

    /// @notice test_FullStack_TreasuryAndPenaltiesInSameRD: Treasury rewards and instant-exit penalties share one RD pool; after advanceEpoch, pending rewards reflect both for two users.
    function test_FullStack_TreasuryAndPenaltiesInSameRD() public {
        _fundUser(alice, 1_000 * ONE);
        _fundUser(bob, 1_000 * ONE);

        vm.startPrank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(distributor), 1_000 * ONE);
        distributor.deposit(500 * ONE);
        vm.stopPrank();

        vm.startPrank(bob);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(distributor), 1_000 * ONE);
        distributor.deposit(500 * ONE);
        vm.stopPrank();

        _depositRewards(50 * ONE);

        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        staking.instantExit(0);

        uint256 penalty = (100 * ONE * PENALTY_BPS) / 10_000;
        vm.warp(block.timestamp + _epochDuration() + 1);
        distributor.advanceEpoch();

        uint256 totalRewards = 50 * ONE + penalty;
        uint256 aliceExpected = (500 * ONE * totalRewards) / (1_000 * ONE);
        uint256 bobExpected = (500 * ONE * totalRewards) / (1_000 * ONE);
        assertApproxEqAbs(distributor.pendingRewardsOf(alice), aliceExpected, 1e15);
        assertApproxEqAbs(distributor.pendingRewardsOf(bob), bobExpected, 1e15);
    }

    /// @notice test_FullStack_CompleteLifecycle_NormalExit: Full lifecycle with normal exit — stake, deposit to RD, rewards, withdraw from RD, initiateExit, wait lock, exit(0), then claim rewards.
    function test_FullStack_CompleteLifecycle_NormalExit() public {
        _fundUser(alice, 1_000 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(distributor), 1_000 * ONE);
        distributor.deposit(1_000 * ONE);
        vm.stopPrank();

        _depositRewards(100 * ONE);

        vm.prank(alice);
        distributor.withdraw(1_000 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 1_000 * ONE);
        vm.prank(alice);
        staking.initiateExit(1_000 * ONE);

        vm.warp(block.timestamp + _lockDuration());

        uint256 k613Before = k613.balanceOf(alice);
        uint256 xk613Before = xk613.balanceOf(alice);
        vm.prank(alice);
        staking.exit(0);
        assertEq(k613.balanceOf(alice), k613Before + 1_000 * ONE);
        assertEq(xk613.balanceOf(alice), xk613Before);

        uint256 xk613BeforeClaim = xk613.balanceOf(alice);
        vm.prank(alice);
        distributor.claim();
        assertEq(xk613.balanceOf(alice), xk613BeforeClaim + 100 * ONE);
    }

    /// @notice test_FullStack_CompleteLifecycle_InstantExit: Full lifecycle with instant exit — two users, one does instant exit (penalty); after epoch, exiting user claims half of pool rewards.
    function test_FullStack_CompleteLifecycle_InstantExit() public {
        _fundUser(alice, 1_000 * ONE);
        _fundUser(bob, 1_000 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(distributor), 1_000 * ONE);
        distributor.deposit(1_000 * ONE);
        vm.stopPrank();
        vm.startPrank(bob);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(distributor), 1_000 * ONE);
        distributor.deposit(1_000 * ONE);
        vm.stopPrank();

        _depositRewards(100 * ONE);

        vm.prank(alice);
        distributor.withdraw(1_000 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 1_000 * ONE);
        vm.prank(alice);
        staking.initiateExit(1_000 * ONE);
        vm.warp(block.timestamp + 1 days);

        uint256 penalty = (1_000 * ONE * PENALTY_BPS) / 10_000;
        uint256 payout = 1_000 * ONE - penalty;
        uint256 k613Before = k613.balanceOf(alice);
        vm.prank(alice);
        staking.instantExit(0);
        assertEq(k613.balanceOf(alice), k613Before + payout);

        vm.warp(block.timestamp + _epochDuration() + 1);
        distributor.advanceEpoch();

        uint256 aliceBefore = xk613.balanceOf(alice);
        vm.prank(alice);
        distributor.claim();
        uint256 aliceClaimed = xk613.balanceOf(alice) - aliceBefore;
        assertEq(aliceClaimed, 50 * ONE);
    }

    /// @notice test_FullStack_Migration_NewRD: Migrates to a new RewardsDistributor; user withdraws from old RD, staking switches to new RD, user deposits and instant-exits; new RD has pending penalties (skipped on fork).
    function test_FullStack_Migration_NewRD() public {
        if (useDeployed) vm.skip(true); // skip on fork: deploys new RD and changes admin state
        _fundUser(alice, 1_000 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(distributor), 500 * ONE);
        distributor.deposit(500 * ONE);
        vm.stopPrank();

        _depositRewards(50 * ONE);

        vm.prank(alice);
        distributor.claim();
        vm.prank(alice);
        distributor.withdraw(500 * ONE);

        RewardsDistributor distributor2 =
            new RewardsDistributor(address(xk613), address(xk613), address(k613), EPOCH_DURATION);
        distributor2.setStaking(address(staking));
        xk613.setTransferWhitelist(address(distributor2), true);

        staking.setRewardsDistributor(address(distributor2));
        distributor.setStaking(address(0));

        vm.prank(alice);
        xk613.approve(address(distributor2), 500 * ONE);
        vm.prank(alice);
        distributor2.deposit(500 * ONE);

        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        staking.instantExit(0);

        assertGt(distributor2.pendingPenalties(), 0);
    }

    /// @notice test_Integration_MultiUser_RewardsAndPenalties_ClaimAfterExit: Four users stake/deposit at different times; Treasury adds rewards twice; one user instant-exits (penalties to pool); advanceEpoch; all claim; verifies total distribution and backingIntegrity.
    function test_Integration_MultiUser_RewardsAndPenalties_ClaimAfterExit() public {
        _fundTestUsers(2_000 * ONE);

        // Alice: stake 2k, deposit 2k to RD
        vm.startPrank(alice);
        k613.approve(address(staking), 2_000 * ONE);
        staking.stake(2_000 * ONE);
        xk613.approve(address(distributor), 2_000 * ONE);
        distributor.deposit(2_000 * ONE);
        vm.stopPrank();

        _depositRewards(200 * ONE);

        // Bob: stake 2k, deposit 1k to RD
        vm.startPrank(bob);
        k613.approve(address(staking), 2_000 * ONE);
        staking.stake(2_000 * ONE);
        xk613.approve(address(distributor), 1_000 * ONE);
        distributor.deposit(1_000 * ONE);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        _depositRewards(100 * ONE);

        // Carol: stake 1k, deposit 1k
        vm.startPrank(carol);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(distributor), 1_000 * ONE);
        distributor.deposit(1_000 * ONE);
        vm.stopPrank();

        // Dave: stake 500, deposit 500
        vm.startPrank(dave);
        k613.approve(address(staking), 500 * ONE);
        staking.stake(500 * ONE);
        xk613.approve(address(distributor), 500 * ONE);
        distributor.deposit(500 * ONE);
        vm.stopPrank();

        // Bob withdraws half from RD and initiates exit (instant exit) — penalties go to RD
        vm.prank(bob);
        distributor.withdraw(500 * ONE);
        vm.prank(bob);
        xk613.approve(address(staking), 500 * ONE);
        vm.prank(bob);
        staking.initiateExit(500 * ONE);
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        staking.instantExit(0);

        uint256 penalty = (500 * ONE * PENALTY_BPS) / 10_000;
        vm.warp(block.timestamp + _epochDuration() + 1);
        distributor.advanceEpoch();

        // Bob cannot claim while he still has exit queue (he had 2 requests? no — he only initiated 500, instant exited that one, so queue is empty). So Bob can claim.
        // Alice, Carol, Dave claim
        uint256 aliceXBefore = xk613.balanceOf(alice);
        uint256 bobXBefore = xk613.balanceOf(bob);
        uint256 carolXBefore = xk613.balanceOf(carol);
        uint256 daveXBefore = xk613.balanceOf(dave);

        vm.prank(alice);
        distributor.claim();
        vm.prank(bob);
        distributor.claim();
        vm.prank(carol);
        distributor.claim();
        vm.prank(dave);
        distributor.claim();

        uint256 totalRewardsAndPenalty = 200 * ONE + 100 * ONE + penalty;
        uint256 totalDepositsAtDistribution = 2_000 * ONE + 500 * ONE + 1_000 * ONE + 500 * ONE; // alice 2k, bob 500 (after withdraw), carol 1k, dave 500
        assertEq(totalDepositsAtDistribution, distributor.totalDeposits() + 0); // totalDeposits might be before some claims
        uint256 aliceGot = xk613.balanceOf(alice) - aliceXBefore;
        uint256 bobGot = xk613.balanceOf(bob) - bobXBefore;
        uint256 carolGot = xk613.balanceOf(carol) - carolXBefore;
        uint256 daveGot = xk613.balanceOf(dave) - daveXBefore;
        assertApproxEqAbs(aliceGot + bobGot + carolGot + daveGot, totalRewardsAndPenalty, 1e16);
        assertGt(aliceGot, 0);
        assertGt(bobGot, 0);
        assertGt(carolGot, 0);
        assertGt(daveGot, 0);
        assertTrue(staking.backingIntegrity());
        assertEq(xk613.totalSupply(), staking.totalBacking());
    }

    /// @notice test_Integration_ClaimBlockedDuringExitVesting_ThenClaimAfterExit: Withdraw from RD then initiate exit; claim reverts with ExitVestingActive during vesting; after normal exit, claim succeeds and pays full pending rewards.
    function test_Integration_ClaimBlockedDuringExitVesting_ThenClaimAfterExit() public {
        _fundUser(alice, 1_000 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(distributor), 1_000 * ONE);
        distributor.deposit(1_000 * ONE);
        vm.stopPrank();

        _depositRewards(100 * ONE);

        uint256 pending = distributor.pendingRewardsOf(alice);
        assertGt(pending, 0);

        vm.prank(alice);
        distributor.withdraw(1_000 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 1_000 * ONE);
        vm.prank(alice);
        staking.initiateExit(1_000 * ONE);

        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.ExitVestingActive.selector);
        distributor.claim();

        vm.warp(block.timestamp + _lockDuration());
        vm.prank(alice);
        staking.exit(0);

        uint256 aliceXBefore = xk613.balanceOf(alice);
        vm.prank(alice);
        distributor.claim();
        assertEq(xk613.balanceOf(alice) - aliceXBefore, pending);
        assertEq(distributor.pendingRewardsOf(alice), 0);
        assertTrue(staking.backingIntegrity());
        assertEq(xk613.totalSupply(), staking.totalBacking());
    }

    /// @notice test_Integration_MultipleExitRequests_CancelNormalInstant: Multiple exit requests in queue; cancel one, instant exit one, normal exit one; verifies queue length, remaining stake, and backingIntegrity after claim.
    function test_Integration_MultipleExitRequests_CancelNormalInstant() public {
        _fundUser(alice, 3_000 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 3_000 * ONE);
        staking.stake(3_000 * ONE);
        xk613.approve(address(distributor), 3_000 * ONE);
        distributor.deposit(2_000 * ONE);
        vm.stopPrank();

        _depositRewards(150 * ONE);

        vm.prank(alice);
        distributor.withdraw(1_000 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 1_000 * ONE);
        vm.prank(alice);
        staking.initiateExit(400 * ONE);
        vm.prank(alice);
        staking.initiateExit(300 * ONE);
        vm.prank(alice);
        staking.initiateExit(300 * ONE);

        assertEq(staking.exitQueueLength(alice), 3);

        vm.prank(alice);
        staking.cancelExit(1);
        assertEq(staking.exitQueueLength(alice), 2);

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        staking.instantExit(0);

        vm.warp(block.timestamp + _lockDuration());
        vm.prank(alice);
        staking.exit(0);

        (uint256 amount,) = staking.deposits(alice);
        assertEq(amount, 3_000 * ONE - 400 * ONE - 300 * ONE);
        assertEq(staking.exitQueueLength(alice), 0);

        vm.warp(block.timestamp + _epochDuration() + 1);
        distributor.advanceEpoch();
        vm.prank(alice);
        distributor.claim();
        assertGt(xk613.balanceOf(alice), 0);
        assertTrue(staking.backingIntegrity());
        assertEq(xk613.totalSupply(), staking.totalBacking());
    }

    /// @notice test_Integration_AsymmetricShares_PenaltyDistributedProRata: Two users with 70/30 RD shares; one instant-exits; advance epoch; both claim; verifies total conservation and Alice share > Bob share.
    function test_Integration_AsymmetricShares_PenaltyDistributedProRata() public {
        _fundUser(alice, 10_000 * ONE);
        _fundUser(bob, 10_000 * ONE);

        vm.startPrank(alice);
        k613.approve(address(staking), 7_000 * ONE);
        staking.stake(7_000 * ONE);
        xk613.approve(address(distributor), 7_000 * ONE);
        distributor.deposit(7_000 * ONE);
        vm.stopPrank();

        vm.startPrank(bob);
        k613.approve(address(staking), 3_000 * ONE);
        staking.stake(3_000 * ONE);
        xk613.approve(address(distributor), 3_000 * ONE);
        distributor.deposit(3_000 * ONE);
        vm.stopPrank();

        _depositRewards(500 * ONE);

        vm.prank(bob);
        distributor.withdraw(1_000 * ONE);
        vm.prank(bob);
        xk613.approve(address(staking), 1_000 * ONE);
        vm.prank(bob);
        staking.initiateExit(1_000 * ONE);
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        staking.instantExit(0);

        uint256 penalty = (1_000 * ONE * PENALTY_BPS) / 10_000;
        vm.warp(block.timestamp + _epochDuration() + 1);
        distributor.advanceEpoch();

        uint256 aliceBefore = xk613.balanceOf(alice);
        uint256 bobBefore = xk613.balanceOf(bob);
        vm.prank(alice);
        distributor.claim();
        vm.prank(bob);
        distributor.claim();
        uint256 aliceGot = xk613.balanceOf(alice) - aliceBefore;
        uint256 bobGot = xk613.balanceOf(bob) - bobBefore;

        uint256 total = 500 * ONE + penalty;
        assertApproxEqAbs(aliceGot + bobGot, total, 1e15);
        assertTrue(aliceGot > bobGot, "alice share > bob share");
        assertTrue(staking.backingIntegrity());
        assertEq(xk613.totalSupply(), staking.totalBacking());
    }

    // ---------- Staking edge cases & reverts (run on fork too) ----------

    /// @notice test_Staking_StakeZero_Reverts: stake(0) reverts with ZeroAmount.
    function test_Staking_StakeZero_Reverts() public {
        _fundUser(alice, 100 * ONE);
        vm.prank(alice);
        k613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        vm.expectRevert(Staking.ZeroAmount.selector);
        staking.stake(0);
    }

    /// @notice test_Staking_InitiateExitZero_Reverts: initiateExit(0) reverts with ZeroAmount.
    function test_Staking_InitiateExitZero_Reverts() public {
        _fundUser(alice, 100 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 100 * ONE);
        staking.stake(100 * ONE);
        vm.expectRevert(Staking.ZeroAmount.selector);
        staking.initiateExit(0);
        vm.stopPrank();
    }

    /// @notice test_Staking_InitiateExitAmountExceedsStake_Reverts: initiateExit(amount) greater than staked balance reverts with AmountExceedsStake.
    function test_Staking_InitiateExitAmountExceedsStake_Reverts() public {
        _fundUser(alice, 100 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 100 * ONE);
        staking.stake(100 * ONE);
        vm.expectRevert(Staking.AmountExceedsStake.selector);
        staking.initiateExit(101 * ONE);
        vm.stopPrank();
    }

    /// @notice test_Staking_InitiateExitInsufficientxK613_Reverts: initiateExit reverts with InsufficientxK613 when user's xK613 is all deposited in RD (balance 0).
    function test_Staking_InitiateExitInsufficientxK613_Reverts() public {
        _fundUser(alice, 100 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 100 * ONE);
        staking.stake(100 * ONE);
        xk613.approve(address(distributor), 100 * ONE);
        distributor.deposit(100 * ONE); // alice's xK613 now in RD, balance 0
        vm.expectRevert(Staking.InsufficientxK613.selector);
        staking.initiateExit(50 * ONE);
        vm.stopPrank();
    }

    /// @notice test_Staking_ExitInvalidIndex_Reverts: exit(index) with out-of-range index reverts with InvalidExitIndex.
    function test_Staking_ExitInvalidIndex_Reverts() public {
        _fundUser(alice, 100 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 100 * ONE);
        staking.stake(100 * ONE);
        xk613.approve(address(staking), 100 * ONE);
        staking.initiateExit(50 * ONE);
        vm.expectRevert(Staking.InvalidExitIndex.selector);
        staking.exit(1);
        vm.stopPrank();
    }

    /// @notice test_Staking_ExitBeforeLock_Reverts: exit(0) before lock duration reverts with Locked.
    function test_Staking_ExitBeforeLock_Reverts() public {
        _fundUser(alice, 100 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 100 * ONE);
        staking.stake(100 * ONE);
        xk613.approve(address(staking), 100 * ONE);
        staking.initiateExit(50 * ONE);
        vm.expectRevert(Staking.Locked.selector);
        staking.exit(0);
        vm.stopPrank();
    }

    /// @notice test_Staking_InstantExitAfterLock_Reverts: instantExit(0) after lock has passed reverts with Unlocked (must use exit instead).
    function test_Staking_InstantExitAfterLock_Reverts() public {
        _fundUser(alice, 100 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 100 * ONE);
        staking.stake(100 * ONE);
        xk613.approve(address(staking), 100 * ONE);
        staking.initiateExit(50 * ONE);
        vm.stopPrank();
        vm.warp(block.timestamp + _lockDuration() + 1);
        vm.prank(alice);
        vm.expectRevert(Staking.Unlocked.selector);
        staking.instantExit(0);
    }

    /// @notice test_Staking_CancelExitInvalidIndex_Reverts: cancelExit(index) with invalid index reverts with InvalidExitIndex.
    function test_Staking_CancelExitInvalidIndex_Reverts() public {
        _fundUser(alice, 100 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 100 * ONE);
        staking.stake(100 * ONE);
        xk613.approve(address(staking), 100 * ONE);
        staking.initiateExit(50 * ONE);
        vm.expectRevert(Staking.InvalidExitIndex.selector);
        staking.cancelExit(1);
        vm.stopPrank();
    }

    /// @notice test_Staking_ExitQueueFull_Reverts: initiateExit when queue already has MAX_EXIT_REQUESTS reverts with ExitQueueFull.
    function test_Staking_ExitQueueFull_Reverts() public {
        uint256 perStake = 100 * ONE;
        _fundUser(alice, 11 * perStake);
        vm.startPrank(alice);
        k613.approve(address(staking), 11 * perStake);
        staking.stake(11 * perStake);
        xk613.approve(address(staking), 11 * perStake);
        for (uint256 i = 0; i < staking.MAX_EXIT_REQUESTS(); i++) {
            staking.initiateExit(perStake);
        }
        vm.expectRevert(Staking.ExitQueueFull.selector);
        staking.initiateExit(perStake);
        vm.stopPrank();
    }

    /// @notice test_Staking_NormalExitThenIntegrity: User does normal exit after lock; asserts backingIntegrity and xK613.totalSupply() == staking.totalBacking().
    function test_Staking_NormalExitThenIntegrity() public {
        _fundUser(alice, 500 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 500 * ONE);
        staking.stake(500 * ONE);
        xk613.approve(address(staking), 500 * ONE);
        staking.initiateExit(500 * ONE);
        vm.stopPrank();
        vm.warp(block.timestamp + _lockDuration() + 1);
        vm.prank(alice);
        staking.exit(0);
        assertTrue(staking.backingIntegrity());
        assertEq(xk613.totalSupply(), staking.totalBacking());
    }

    // ---------- RewardsDistributor edge cases & reverts ----------

    /// @notice test_RewardsDistributor_DepositZero_Reverts: deposit(0) reverts with ZeroAmount.
    function test_RewardsDistributor_DepositZero_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.ZeroAmount.selector);
        distributor.deposit(0);
    }

    /// @notice test_RewardsDistributor_FirstDepositBelowMin_Reverts: First deposit below MIN_INITIAL_DEPOSIT reverts with MinimumInitialDeposit.
    function test_RewardsDistributor_FirstDepositBelowMin_Reverts() public {
        _fundUser(alice, ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), ONE);
        staking.stake(ONE);
        xk613.approve(address(distributor), ONE);
        vm.expectRevert(RewardsDistributor.MinimumInitialDeposit.selector);
        distributor.deposit(1); // below MIN_INITIAL_DEPOSIT
        vm.stopPrank();
    }

    /// @notice test_RewardsDistributor_WithdrawZero_Reverts: withdraw(0) reverts with ZeroAmount.
    function test_RewardsDistributor_WithdrawZero_Reverts() public {
        _fundUser(alice, 100 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 100 * ONE);
        staking.stake(100 * ONE);
        xk613.approve(address(distributor), 100 * ONE);
        distributor.deposit(100 * ONE);
        vm.expectRevert(RewardsDistributor.ZeroAmount.selector);
        distributor.withdraw(0);
        vm.stopPrank();
    }

    /// @notice test_RewardsDistributor_WithdrawExcess_Reverts: withdraw(amount) exceeding deposited balance reverts with InsufficientBalance.
    function test_RewardsDistributor_WithdrawExcess_Reverts() public {
        _fundUser(alice, 100 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 100 * ONE);
        staking.stake(100 * ONE);
        xk613.approve(address(distributor), 100 * ONE);
        distributor.deposit(100 * ONE);
        vm.expectRevert(RewardsDistributor.InsufficientBalance.selector);
        distributor.withdraw(101 * ONE);
        vm.stopPrank();
    }

    /// @notice test_RewardsDistributor_ClaimNoRewards_Reverts: claim() with no rewards in pool reverts with NoRewards.
    function test_RewardsDistributor_ClaimNoRewards_Reverts() public {
        _fundUser(alice, 100 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 100 * ONE);
        staking.stake(100 * ONE);
        xk613.approve(address(distributor), 100 * ONE);
        distributor.deposit(100 * ONE);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.NoRewards.selector);
        distributor.claim();
    }

    /// @notice test_RewardsDistributor_AdvanceEpochBeforeReady_Reverts: advanceEpoch() before epoch end reverts with EpochNotReady.
    function test_RewardsDistributor_AdvanceEpochBeforeReady_Reverts() public {
        _fundUser(alice, 100 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 100 * ONE);
        staking.stake(100 * ONE);
        xk613.approve(address(distributor), 100 * ONE);
        distributor.deposit(100 * ONE);
        vm.stopPrank();
        vm.expectRevert(RewardsDistributor.EpochNotReady.selector);
        distributor.advanceEpoch();
    }

    /// @notice test_RewardsDistributor_AdvanceEpochAfterTime_Succeeds: advanceEpoch() after epoch duration succeeds and user has pendingRewardsOf > 0.
    function test_RewardsDistributor_AdvanceEpochAfterTime_Succeeds() public {
        _fundUser(alice, 100 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 100 * ONE);
        staking.stake(100 * ONE);
        xk613.approve(address(distributor), 100 * ONE);
        distributor.deposit(100 * ONE);
        vm.stopPrank();
        _depositRewards(50 * ONE);
        vm.warp(block.timestamp + _epochDuration() + 1);
        distributor.advanceEpoch();
        assertGt(distributor.pendingRewardsOf(alice), 0);
    }

    // ---------- Treasury (depositRewards zero is no-op per spec) ----------

    /// @notice test_Treasury_DepositRewardsZero_NoRevert: depositRewards(0) does not revert (no-op); totalDeposits remains 0.
    function test_Treasury_DepositRewardsZero_NoRevert() public {
        treasury.depositRewards(0);
        assertEq(distributor.totalDeposits(), 0);
    }

    // ---------- Invariant: backingIntegrity after every major flow ----------

    /// @notice test_Invariant_BackingIntegrity_AfterStakeOnly: After stake only, backingIntegrity() holds and xK613.totalSupply() == staking.totalBacking().
    function test_Invariant_BackingIntegrity_AfterStakeOnly() public {
        _fundUser(alice, 1_000 * ONE);
        vm.prank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        vm.prank(alice);
        staking.stake(1_000 * ONE);
        assertTrue(staking.backingIntegrity());
        assertEq(xk613.totalSupply(), staking.totalBacking());
    }

    /// @notice test_Invariant_BackingIntegrity_AfterInstantExit: After instant exit, backingIntegrity() holds and supply matches totalBacking.
    function test_Invariant_BackingIntegrity_AfterInstantExit() public {
        _fundUser(alice, 1_000 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(staking), 500 * ONE);
        staking.initiateExit(500 * ONE);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        staking.instantExit(0);
        assertTrue(staking.backingIntegrity());
        assertEq(xk613.totalSupply(), staking.totalBacking());
    }

    /// @notice test_Invariant_BackingIntegrity_AfterCancelExit: After cancelExit, backingIntegrity() holds and supply matches totalBacking.
    function test_Invariant_BackingIntegrity_AfterCancelExit() public {
        _fundUser(alice, 1_000 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(staking), 300 * ONE);
        staking.initiateExit(300 * ONE);
        staking.cancelExit(0);
        vm.stopPrank();
        assertTrue(staking.backingIntegrity());
        assertEq(xk613.totalSupply(), staking.totalBacking());
    }

    /// @notice test_Integration_ZeroRewards_ClaimAfterEpochAdvance: No rewards deposited; after advanceEpoch user has 0 pending; claim() reverts with NoRewards.
    function test_Integration_ZeroRewards_ClaimAfterEpochAdvance() public {
        _fundUser(alice, 100 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 100 * ONE);
        staking.stake(100 * ONE);
        xk613.approve(address(distributor), 100 * ONE);
        distributor.deposit(100 * ONE);
        vm.stopPrank();
        vm.warp(block.timestamp + _epochDuration() + 1);
        distributor.advanceEpoch();
        assertEq(distributor.pendingRewardsOf(alice), 0);
        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.NoRewards.selector);
        distributor.claim();
    }
}
