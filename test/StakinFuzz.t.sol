// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {K613} from "../src/token/K613.sol";
import {xK613} from "../src/token/xK613.sol";
import {Staking} from "../src/staking/Staking.sol";
import {RewardsDistributor} from "../src/staking/RewardsDistributor.sol";

contract StakingFuzzTest is Test {
    uint256 private constant LOCK_DURATION = 7 days;
    uint256 private constant EPOCH_DURATION = 7 days;
    uint256 private constant PENALTY_BPS = 5_000;
    uint256 private constant MAX_AMOUNT = 1_000_000 ether;

    K613 private k613;
    xK613 private xk613;
    Staking private staking;
    RewardsDistributor private distributor;

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
    }

    function testFuzzStake(uint256 rawAmount, address user) public {
        uint256 amount = bound(rawAmount, 1, MAX_AMOUNT);
        vm.assume(user != address(0));
        vm.assume(user != address(staking));
        vm.assume(user != address(distributor));

        k613.mint(user, amount);
        vm.startPrank(user);
        k613.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();

        (uint256 deposited,) = staking.deposits(user);
        assertEq(deposited, amount);
        assertEq(k613.balanceOf(address(staking)), amount);
        assertEq(xk613.balanceOf(user), amount);
    }

    function testFuzzExit(uint256 rawAmount, address user) public {
        uint256 amount = bound(rawAmount, 1, MAX_AMOUNT);
        vm.assume(user != address(0));
        vm.assume(user != address(staking));
        vm.assume(user != address(distributor));

        k613.mint(user, amount);
        vm.startPrank(user);
        k613.approve(address(staking), amount);
        staking.stake(amount);
        xk613.approve(address(staking), amount);
        staking.initiateExit(amount);
        vm.stopPrank();

        vm.warp(block.timestamp + LOCK_DURATION);
        vm.prank(user);
        staking.exit(0);

        (uint256 deposited,) = staking.deposits(user);
        assertEq(deposited, 0);
        assertEq(k613.balanceOf(user), amount);
        assertEq(k613.balanceOf(address(staking)), 0);
    }

    function testFuzzInstantExit(uint256 rawAmount, address user) public {
        uint256 amount = bound(rawAmount, 1, MAX_AMOUNT);
        vm.assume(user != address(0));
        vm.assume(user != address(staking));
        vm.assume(user != address(distributor));

        k613.mint(user, amount);
        vm.startPrank(user);
        k613.approve(address(staking), amount);
        staking.stake(amount);
        xk613.approve(address(staking), amount);
        staking.initiateExit(amount);
        vm.stopPrank();

        vm.warp(block.timestamp + LOCK_DURATION - 1);
        vm.prank(user);
        staking.instantExit(0);

        uint256 penalty = (amount * PENALTY_BPS) / 10_000;
        uint256 payout = amount - penalty;

        (uint256 deposited,) = staking.deposits(user);
        assertEq(deposited, 0);
        assertEq(k613.balanceOf(user), payout);
    }
}
