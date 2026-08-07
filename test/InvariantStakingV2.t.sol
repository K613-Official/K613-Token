// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {K613} from "../src/token/K613.sol";
import {xK613} from "../src/token/xK613.sol";
import {StakingV2} from "../src/staking/StakingV2.sol";
import {RewardsDistributor} from "../src/staking/RewardsDistributor.sol";

/// @notice Ported from InvariantStaking.t.sol (V1). The `initiateExit` action simplifies from
///         "position minus already-queued, then also check balance" down to just "bounded by
///         balance" — mirroring the exact simplification made in the contract itself. No handler
///         action needed to be added to exercise the H-01 fix: `rewardsClaim` already has
///         RewardsDistributor pay xK613 straight to a claimer's wallet (its `rewardToken` IS xK613
///         here — see RewardsDistributor's constructor args below), which is precisely "xK613 a
///         wallet holds without personally staking it." Once `initiateExit` stopped special-casing
///         that, the existing action set exercises the fix for free, at fuzzing scale.
contract StakingV2Handler is Test {
    uint256 private constant MAX_AMOUNT = 1_000_000 ether;

    K613 public k613;
    xK613 public xk613;
    StakingV2 public staking;
    RewardsDistributor public distributor;
    address[] public actors;
    uint256 public lockDuration;

    constructor(
        K613 k613_,
        xK613 xk613_,
        StakingV2 staking_,
        RewardsDistributor distributor_,
        address[] memory actors_,
        uint256 lockDuration_
    ) {
        k613 = k613_;
        xk613 = xk613_;
        staking = staking_;
        distributor = distributor_;
        actors = actors_;
        lockDuration = lockDuration_;
    }

    /// @notice stake: Random actor stakes a bounded amount of K613.
    function stake(uint256 rawAmount, uint256 actorSeed) external {
        uint256 minStake = distributor.totalDeposits() == 0 ? distributor.MIN_INITIAL_DEPOSIT() : 1;
        uint256 amount = bound(rawAmount, minStake, MAX_AMOUNT);
        address actor = actors[actorSeed % actors.length];

        k613.mint(actor, amount);
        vm.startPrank(actor);
        k613.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    /// @notice depositToRD: Random actor deposits a bounded amount of xK613 to RewardsDistributor.
    function depositToRD(uint256 rawAmount, uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = xk613.balanceOf(actor);
        if (balance == 0) return;
        uint256 minDeposit = distributor.totalDeposits() == 0 ? distributor.MIN_INITIAL_DEPOSIT() : 1;
        if (balance < minDeposit) return;
        uint256 amount = bound(rawAmount, minDeposit, balance);

        vm.startPrank(actor);
        xk613.approve(address(distributor), amount);
        distributor.deposit(amount);
        vm.stopPrank();
    }

    /// @notice initiateExit: Random actor initiates exit for a bounded amount of their LIVE xK613
    ///         balance. V2 has no separate position to reconcile against — the balance already
    ///         excludes anything sitting in the queue (it was escrowed out at initiateExit time),
    ///         so this is the whole check.
    function initiateExit(uint256 rawAmount, uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = xk613.balanceOf(actor);
        if (balance == 0) return;
        if (staking.exitQueueLength(actor) >= staking.MAX_EXIT_REQUESTS()) return;
        uint256 amount = bound(rawAmount, 1, balance);

        vm.startPrank(actor);
        xk613.approve(address(staking), amount);
        staking.initiateExit(amount);
        vm.stopPrank();
    }

    /// @notice cancelExit: Random actor cancels one exit request by index; no-op if queue empty.
    function cancelExit(uint256 indexSeed, uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 queueLen = staking.exitQueueLength(actor);
        if (queueLen == 0) return;
        uint256 index = indexSeed % queueLen;

        vm.prank(actor);
        staking.cancelExit(index);
    }

    /// @notice instantExit: Random actor performs instant exit on one queue entry.
    function instantExit(uint256 indexSeed, uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 queueLen = staking.exitQueueLength(actor);
        if (queueLen == 0) return;
        uint256 index = indexSeed % queueLen;
        (, uint256 exitInitiatedAt) = staking.exitRequestAt(actor, index);
        uint256 unlockAt = exitInitiatedAt + lockDuration;
        if (block.timestamp >= unlockAt) {
            vm.warp(unlockAt - 1);
        }

        vm.prank(actor);
        staking.instantExit(index);
    }

    /// @notice exit: Random actor performs normal exit on one queue entry.
    function exit(uint256 indexSeed, uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 queueLen = staking.exitQueueLength(actor);
        if (queueLen == 0) return;
        uint256 index = indexSeed % queueLen;
        (, uint256 exitInitiatedAt) = staking.exitRequestAt(actor, index);
        uint256 unlockAt = exitInitiatedAt + lockDuration;
        if (block.timestamp < unlockAt) {
            vm.warp(unlockAt);
        }

        vm.prank(actor);
        staking.exit(index);
    }

    /// @notice Claims rewards from RD if actor has pending rewards. RD's rewardToken is xK613 here,
    ///         so this pays xK613 straight into the claimer's wallet — exactly the "reward xK613,
    ///         no personal stake()" shape that used to need redeemRewards.
    function rewardsClaim(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        if (distributor.pendingRewardsOf(actor) == 0) return;
        vm.prank(actor);
        distributor.claim();
    }

    /// @notice Notifies new rewards: mint K613, stake to get xK613, send xK613 to RD.
    function notifyReward(uint256 rawAmount) external {
        uint256 amount = bound(rawAmount, distributor.MIN_NOTIFY(), MAX_AMOUNT);
        k613.mint(address(this), amount);
        k613.approve(address(staking), amount);
        staking.stake(amount);
        xk613.transfer(address(distributor), amount);
        distributor.notifyReward(amount);
    }

    /// @notice withdrawFromRD: Random actor withdraws a bounded amount of xK613 from RewardsDistributor.
    function withdrawFromRD(uint256 rawAmount, uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 bal = distributor.balanceOf(actor);
        if (bal == 0) return;
        uint256 amount = bound(rawAmount, 1, bal);
        vm.prank(actor);
        distributor.withdraw(amount);
    }

    /// @notice advanceEpoch: Warp to next epoch boundary if needed and flush pending rewards/penalties.
    function advanceEpoch(uint256) external {
        uint256 next = distributor.nextEpochAt();
        if (block.timestamp < next) {
            vm.warp(next);
        }
        distributor.advanceEpoch();
    }
}

contract InvariantStakingV2Test is StdInvariant, Test {
    uint256 private constant LOCK_DURATION = 7 days;
    uint256 private constant EPOCH_DURATION = 7 days;
    uint256 private constant PENALTY_BPS = 5_000;

    K613 private k613;
    xK613 private xk613;
    StakingV2 private staking;
    RewardsDistributor private distributor;
    StakingV2Handler private handler;
    address[] private actors;

    function setUp() public {
        actors.push(vm.addr(1));
        actors.push(vm.addr(2));
        actors.push(vm.addr(3));
        actors.push(vm.addr(4));
        actors.push(vm.addr(5));

        k613 = new K613(address(this));
        xk613 = new xK613(address(this));
        staking = new StakingV2(address(k613), address(xk613), LOCK_DURATION, PENALTY_BPS);
        distributor = new RewardsDistributor(address(xk613), address(xk613), address(k613), EPOCH_DURATION);

        staking.setRewardsDistributor(address(distributor));
        distributor.setStaking(address(staking));

        xk613.setMinter(address(staking));
        xk613.setTransferWhitelist(address(distributor), true);
        xk613.setTransferWhitelist(address(staking), true);

        handler = new StakingV2Handler(k613, xk613, staking, distributor, actors, LOCK_DURATION);
        k613.setMinter(address(handler));
        xk613.setTransferWhitelist(address(handler), true);
        distributor.grantRole(distributor.REWARDS_NOTIFIER_ROLE(), address(handler));

        targetContract(address(handler));
    }

    /// @notice invariant_supplyMatchesBacking: xK613 totalSupply always equals K613 backing in Staking.
    function invariant_supplyMatchesBacking() public view {
        assertEq(xk613.totalSupply(), staking.totalBacking());
    }

    /// @notice invariant_stakingSolvent: Staking's K613 balance equals totalBacking.
    function invariant_stakingSolvent() public view {
        assertEq(k613.balanceOf(address(staking)), staking.totalBacking());
    }

    uint256 private lastAccRewardPerShare;

    /// @notice invariant_accNeverDecreases: accRewardPerShare in RewardsDistributor never decreases.
    function invariant_accNeverDecreases() public {
        uint256 current = distributor.accRewardPerShare();
        assertGe(current, lastAccRewardPerShare);
        lastAccRewardPerShare = current;
    }

    /// @notice invariant_rewardsConservation: Sum of pendingRewardsOf all actors is at most RD's balance.
    function invariant_rewardsConservation() public view {
        uint256 claimable = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            claimable += distributor.pendingRewardsOf(actors[i]);
        }
        uint256 xBalance = xk613.balanceOf(address(distributor));
        uint256 kBalance = k613.balanceOf(address(distributor));
        assertLe(claimable, xBalance + kBalance + actors.length * 1e9);
    }

    /// @notice invariant_rdBalanceMatchesDeposits: RD's xK613 + K613 balance is at least totalDeposits.
    function invariant_rdBalanceMatchesDeposits() public view {
        uint256 xBalance = xk613.balanceOf(address(distributor));
        uint256 kBalance = k613.balanceOf(address(distributor));
        uint256 total = distributor.totalDeposits();
        assertGe(xBalance + kBalance + 1e9, total);
    }

    /// @notice invariant_totalDepositsEqualsSumBalances: distributor.totalDeposits() equals sum of actor balances.
    function invariant_totalDepositsEqualsSumBalances() public view {
        uint256 sum = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += distributor.balanceOf(actors[i]);
        }
        assertEq(distributor.totalDeposits(), sum);
    }

    /// @notice invariant_depositsAmountMatchesLiveBalance: NEW for V2 — `deposits(user).amount` is,
    ///         by construction, exactly `xk613.balanceOf(user)`. This is close to tautological given
    ///         the current implementation, but it pins down the view function's contract: a future
    ///         change that reintroduces any separate per-user bookkeeping (drifting from live
    ///         balance) breaks this immediately, across the whole fuzzed action space — including
    ///         reward claims, mixed self-staked+reward balances, partial queues, and cancellations.
    function invariant_depositsAmountMatchesLiveBalance() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            (uint256 amount,) = staking.deposits(actors[i]);
            assertEq(amount, xk613.balanceOf(actors[i]));
        }
    }
}
