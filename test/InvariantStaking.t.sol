// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {K613} from "../src/token/K613.sol";
import {xK613} from "../src/token/xK613.sol";
import {Staking} from "../src/staking/Staking.sol";
import {RewardsDistributor} from "../src/staking/RewardsDistributor.sol";

contract StakingHandler is Test {
    uint256 private constant MAX_AMOUNT = 1_000_000 ether;

    K613 public k613;
    xK613 public xk613;
    Staking public staking;
    RewardsDistributor public distributor;
    address[] public actors;
    uint256 public lockDuration;

    constructor(
        K613 k613_,
        xK613 xk613_,
        Staking staking_,
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

    function initiateExit(uint256 rawAmount, uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        (uint256 deposited,) = staking.deposits(actor);
        uint256 queueLen = staking.exitQueueLength(actor);
        if (deposited == 0) return;
        uint256 inQueue = 0;
        for (uint256 i = 0; i < queueLen; i++) {
            (uint256 am,) = staking.exitRequestAt(actor, i);
            inQueue += am;
        }
        if (inQueue >= deposited) return;
        uint256 amount = bound(rawAmount, 1, deposited - inQueue);
        if (queueLen >= staking.MAX_EXIT_REQUESTS()) return;
        if (xk613.balanceOf(actor) < amount) return;

        vm.startPrank(actor);
        xk613.approve(address(staking), amount);
        staking.initiateExit(amount);
        vm.stopPrank();
    }

    function cancelExit(uint256 indexSeed, uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 queueLen = staking.exitQueueLength(actor);
        if (queueLen == 0) return;
        uint256 index = indexSeed % queueLen;

        vm.prank(actor);
        staking.cancelExit(index);
    }

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

    /// @notice Claims rewards from RD if actor has pending rewards.
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

    function withdrawFromRD(uint256 rawAmount, uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 bal = distributor.balanceOf(actor);
        if (bal == 0) return;
        uint256 amount = bound(rawAmount, 1, bal);
        vm.prank(actor);
        distributor.withdraw(amount);
    }
}

contract InvariantStakingTest is StdInvariant, Test {
    uint256 private constant LOCK_DURATION = 7 days;
    uint256 private constant EPOCH_DURATION = 7 days;
    uint256 private constant PENALTY_BPS = 5_000;

    K613 private k613;
    xK613 private xk613;
    Staking private staking;
    RewardsDistributor private distributor;
    StakingHandler private handler;
    address[] private actors;

    function setUp() public {
        actors.push(vm.addr(1));
        actors.push(vm.addr(2));
        actors.push(vm.addr(3));
        actors.push(vm.addr(4));
        actors.push(vm.addr(5));

        k613 = new K613(address(this));
        xk613 = new xK613(address(this));
        staking = new Staking(address(k613), address(xk613), LOCK_DURATION, PENALTY_BPS);
        distributor = new RewardsDistributor(address(xk613), address(xk613), address(k613), EPOCH_DURATION);

        staking.setRewardsDistributor(address(distributor));
        distributor.setStaking(address(staking));

        xk613.setMinter(address(staking));
        xk613.setTransferWhitelist(address(distributor), true);
        xk613.setTransferWhitelist(address(staking), true);

        handler = new StakingHandler(k613, xk613, staking, distributor, actors, LOCK_DURATION);
        k613.setMinter(address(handler));
        xk613.setTransferWhitelist(address(handler), true);
        distributor.grantRole(distributor.REWARDS_NOTIFIER_ROLE(), address(handler));

        targetContract(address(handler));
    }

    /// @notice 1:1 backing: xK613 totalSupply == K613 backing in Staking.
    function invariant_supplyMatchesBacking() public view {
        assertEq(xk613.totalSupply(), staking.totalBacking());
    }

    /// @notice Staking solvency: balance == totalBacking (no direct K613 / fee-on-transfer).
    function invariant_stakingSolvent() public view {
        assertEq(k613.balanceOf(address(staking)), staking.totalBacking());
    }

    /// @notice accRewardPerShare never decreases.
    uint256 private lastAccRewardPerShare;

    function invariant_accNeverDecreases() public {
        uint256 current = distributor.accRewardPerShare();
        assertGe(current, lastAccRewardPerShare);
        lastAccRewardPerShare = current;
    }

    /// @notice Claimable rewards (xK613) <= xK613 + K613 held by RD (K613 staked on claim).
    function invariant_rewardsConservation() public view {
        uint256 claimable = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            claimable += distributor.pendingRewardsOf(actors[i]);
        }
        uint256 xBalance = xk613.balanceOf(address(distributor));
        uint256 kBalance = k613.balanceOf(address(distributor));
        assertLe(claimable, xBalance + kBalance + actors.length * 1e9);
    }

    function invariant_stakingHoldsAllDeposits() public view {
        uint256 totalDeposits = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            (uint256 amount,) = staking.deposits(actors[i]);
            totalDeposits += amount;
        }
        assertGe(k613.balanceOf(address(staking)), totalDeposits);
    }

    /// @notice Explicit invariant: K613 balance == internal _totalBacking (no direct transfers / fee-on-transfer)
    function invariant_backingIntegrity() public view {
        assertTrue(staking.backingIntegrity());
    }

    /// RD xK613 + K613 >= totalDeposits (with rounding tolerance; K613 becomes xK613 on claim/advanceEpoch)
    function invariant_rdBalanceMatchesDeposits() public view {
        uint256 xBalance = xk613.balanceOf(address(distributor));
        uint256 kBalance = k613.balanceOf(address(distributor));
        uint256 total = distributor.totalDeposits();
        assertGe(xBalance + kBalance + 1e9, total);
    }

    function invariant_totalDepositsEqualsSumBalances() public view {
        uint256 sum = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += distributor.balanceOf(actors[i]);
        }
        assertEq(distributor.totalDeposits(), sum);
    }
}
