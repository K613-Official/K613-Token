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
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);

    function setUp() public {
        deployer = address(this);
        _deployFullStack(deployer);
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

    function test_FullStack_DeploySetup() public view {
        assertEq(xk613.minter(), address(staking));
        assertTrue(xk613.transferWhitelist(address(distributor)));
        assertTrue(xk613.transferWhitelist(address(staking)));
        assertEq(address(staking.rewardsDistributor()), address(distributor));
        assertEq(distributor.staking(), address(staking));
        assertTrue(distributor.hasRole(distributor.REWARDS_NOTIFIER_ROLE(), address(treasury)));
    }

    function test_FullStack_Stake_DepositRD_TreasuryRewards_Claim() public {
        k613.mint(alice, 1_000 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(distributor), 1_000 * ONE);
        distributor.deposit(1_000 * ONE);
        vm.stopPrank();

        k613.approve(address(treasury), 100 * ONE);
        treasury.depositRewards(100 * ONE);

        uint256 aliceBefore = xk613.balanceOf(alice);
        vm.prank(alice);
        distributor.claim();
        uint256 aliceAfter = xk613.balanceOf(alice);
        assertEq(aliceAfter - aliceBefore, 100 * ONE);
    }

    function test_FullStack_TreasuryAndPenaltiesInSameRD() public {
        k613.mint(alice, 1_000 * ONE);
        k613.mint(bob, 1_000 * ONE);

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

        k613.approve(address(treasury), 50 * ONE);
        treasury.depositRewards(50 * ONE);

        vm.prank(alice);
        xk613.approve(address(staking), 100 * ONE);
        vm.prank(alice);
        staking.initiateExit(100 * ONE);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        staking.instantExit(0);

        uint256 penalty = (100 * ONE * PENALTY_BPS) / 10_000;
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        distributor.advanceEpoch();

        uint256 totalRewards = 50 * ONE + penalty;
        uint256 aliceExpected = (500 * ONE * totalRewards) / (1_000 * ONE);
        uint256 bobExpected = (500 * ONE * totalRewards) / (1_000 * ONE);
        assertApproxEqAbs(distributor.pendingRewardsOf(alice), aliceExpected, 1e15);
        assertApproxEqAbs(distributor.pendingRewardsOf(bob), bobExpected, 1e15);
    }

    function test_FullStack_CompleteLifecycle_NormalExit() public {
        k613.mint(alice, 1_000 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(distributor), 1_000 * ONE);
        distributor.deposit(1_000 * ONE);
        vm.stopPrank();

        k613.approve(address(treasury), 100 * ONE);
        treasury.depositRewards(100 * ONE);

        vm.prank(alice);
        distributor.withdraw(1_000 * ONE);
        vm.prank(alice);
        xk613.approve(address(staking), 1_000 * ONE);
        vm.prank(alice);
        staking.initiateExit(1_000 * ONE);

        vm.warp(block.timestamp + LOCK_DURATION);

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

    function test_FullStack_CompleteLifecycle_InstantExit() public {
        k613.mint(alice, 1_000 * ONE);
        k613.mint(bob, 1_000 * ONE);
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

        k613.approve(address(treasury), 100 * ONE);
        treasury.depositRewards(100 * ONE);

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

        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        distributor.advanceEpoch();

        uint256 aliceBefore = xk613.balanceOf(alice);
        vm.prank(alice);
        distributor.claim();
        uint256 aliceClaimed = xk613.balanceOf(alice) - aliceBefore;
        assertEq(aliceClaimed, 50 * ONE);
    }

    function test_FullStack_Migration_NewRD() public {
        k613.mint(alice, 1_000 * ONE);
        vm.startPrank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(distributor), 500 * ONE);
        distributor.deposit(500 * ONE);
        vm.stopPrank();

        k613.approve(address(treasury), 50 * ONE);
        treasury.depositRewards(50 * ONE);

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
}
