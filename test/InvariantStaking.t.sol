// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

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
        uint256 amount = bound(rawAmount, 1, MAX_AMOUNT);
        address actor = actors[actorSeed % actors.length];

        k613.mint(actor, amount);
        vm.startPrank(actor);
        k613.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    function instantExit(uint256 rawAmount, uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        (uint256 deposited, uint256 depositedAt) = staking.deposits(actor);
        if (deposited == 0) {
            return;
        }
        uint256 amount = bound(rawAmount, 1, deposited);
        uint256 unlockAt = depositedAt + lockDuration;
        if (block.timestamp >= unlockAt) {
            vm.warp(unlockAt - 1);
        }
        vm.prank(actor);
        staking.instantExit(amount);
    }

    function exit(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        (uint256 deposited, uint256 depositedAt) = staking.deposits(actor);
        if (deposited == 0) {
            return;
        }
        uint256 unlockAt = depositedAt + lockDuration;
        if (block.timestamp < unlockAt) {
            vm.warp(unlockAt);
        }
        vm.prank(actor);
        staking.exit();
    }

    function rewardsDeposit(uint256 rawAmount, uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = xk613.balanceOf(actor);
        if (balance == 0) {
            return;
        }
        uint256 amount = bound(rawAmount, 1, balance);
        vm.startPrank(actor);
        if (xk613.allowance(actor, address(distributor)) < amount) {
            xk613.approve(address(distributor), type(uint256).max);
        }
        distributor.deposit(amount);
        vm.stopPrank();
    }

    function rewardsWithdraw(uint256 rawAmount, uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = distributor.balanceOf(actor);
        if (balance == 0) {
            return;
        }
        uint256 amount = bound(rawAmount, 1, balance);
        vm.prank(actor);
        distributor.withdraw(amount);
    }

    function rewardsClaim(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        vm.prank(actor);
        distributor.claim();
    }
}

contract InvariantStakingTest is StdInvariant, Test {
    uint256 private constant LOCK_DURATION = 7 days;
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
        distributor = new RewardsDistributor(address(xk613));

        staking.setRewardsDistributor(address(distributor));
        distributor.setStaking(address(staking));

        xk613.setMinter(address(staking));
        xk613.setTransferWhitelist(address(distributor), true);

        handler = new StakingHandler(k613, xk613, staking, distributor, actors, LOCK_DURATION);
        k613.setMinter(address(handler));

        targetContract(address(handler));
    }

    function invariant_stakingHoldsAllDeposits() public view {
        uint256 totalDeposits = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            (uint256 amount,) = staking.deposits(actors[i]);
            totalDeposits += amount;
        }
        assertGe(k613.balanceOf(address(staking)), totalDeposits);
    }

    function invariant_rewardsDepositsAccounting() public view {
        uint256 totalDeposits = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            totalDeposits += distributor.balanceOf(actors[i]);
        }
        assertEq(distributor.totalDeposits(), totalDeposits);
    }

    function invariant_xk613SupplyMatchesBalances() public view {
        uint256 totalBalances = xk613.balanceOf(address(distributor));
        for (uint256 i = 0; i < actors.length; i++) {
            totalBalances += xk613.balanceOf(actors[i]);
        }
        assertEq(xk613.totalSupply(), totalBalances);
    }
}
