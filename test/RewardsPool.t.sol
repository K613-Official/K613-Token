// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {RewardsPool} from "../src/RewardsPool.sol";
import {K613} from "../src/K613.sol";

contract MockRewardsController {
    function claimAllRewards(address[] calldata, address)
        external
        pure
        returns (address[] memory rewardsList, uint256[] memory claimedAmounts)
    {
        rewardsList = new address[](1);
        claimedAmounts = new uint256[](1);
        rewardsList[0] = address(0xBEEF);
        claimedAmounts[0] = 123;
    }
}

contract RewardsPoolTest is Test {
    K613 private token;
    RewardsPool private pool;

    address private treasury = address(0xABCD);
    address private stakingLock = address(0xCAFE);
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);

    uint256 private constant STAKER_SHARE_BPS = 7_000;
    uint256 private constant ONE = 1e18;

    function setUp() public {
        token = new K613(address(this));
        pool = new RewardsPool(address(token), treasury, STAKER_SHARE_BPS);
        pool.setStakingLock(stakingLock);

        token.mint(alice, 1_000 * ONE);
        token.mint(bob, 1_000 * ONE);

        vm.prank(alice);
        token.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        token.approve(address(pool), type(uint256).max);
    }

    function testConstructorRevertsOnZeroes() public {
        vm.expectRevert(bytes("ZERO_ADDRESS"));
        new RewardsPool(address(0), treasury, STAKER_SHARE_BPS);
        vm.expectRevert(bytes("ZERO_ADDRESS"));
        new RewardsPool(address(token), address(0), STAKER_SHARE_BPS);
        vm.expectRevert(bytes("BPS"));
        new RewardsPool(address(token), treasury, 10_001);
    }

    function testStakeUpdatesBalances() public {
        vm.prank(alice);
        pool.stake(100 * ONE);

        assertEq(pool.totalStaked(), 100 * ONE);
        assertEq(pool.balanceOf(alice), 100 * ONE);
        assertEq(token.balanceOf(alice), 900 * ONE);
    }

    function testStakeZeroReverts() public {
        vm.expectRevert(bytes("ZERO_AMOUNT"));
        vm.prank(alice);
        pool.stake(0);
    }

    function testWithdrawUpdatesBalances() public {
        vm.prank(alice);
        pool.stake(100 * ONE);

        vm.prank(alice);
        pool.withdraw(40 * ONE);

        assertEq(pool.totalStaked(), 60 * ONE);
        assertEq(pool.balanceOf(alice), 60 * ONE);
        assertEq(token.balanceOf(alice), 940 * ONE);
    }

    function testWithdrawRevertsOnInvalidAmount() public {
        vm.expectRevert(bytes("ZERO_AMOUNT"));
        vm.prank(alice);
        pool.withdraw(0);

        vm.prank(alice);
        pool.stake(10 * ONE);
        vm.expectRevert(bytes("BALANCE"));
        vm.prank(alice);
        pool.withdraw(20 * ONE);
    }

    function testClaimRevertsWithoutRewards() public {
        vm.expectRevert(bytes("NO_REWARD"));
        vm.prank(alice);
        pool.claim();
    }

    function testDepositRevenueSplitsAndAccrues() public {
        vm.prank(alice);
        pool.stake(100 * ONE);

        vm.prank(bob);
        pool.depositRevenue(10 * ONE);

        assertEq(token.balanceOf(treasury), 3 * ONE);
        assertEq(pool.earned(alice), 7 * ONE);
    }

    function testPendingRewardsDistributedAfterStake() public {
        vm.prank(bob);
        pool.depositRevenue(10 * ONE);

        assertEq(pool.pendingRewards(), 7 * ONE);

        vm.prank(alice);
        pool.stake(100 * ONE);

        vm.prank(alice);
        pool.withdraw(1 * ONE);

        assertEq(pool.rewards(alice), 7 * ONE);
        assertEq(pool.pendingRewards(), 0);
    }

    function testNotifyPenaltyOnlyStakingLock() public {
        vm.expectRevert(bytes("ONLY_STAKING_LOCK"));
        pool.notifyPenalty(1 * ONE);

        vm.prank(stakingLock);
        pool.notifyPenalty(1 * ONE);

        assertEq(pool.pendingRewards(), 1 * ONE);
    }

    function testClaimTransfersReward() public {
        vm.prank(alice);
        pool.stake(100 * ONE);

        vm.prank(bob);
        pool.depositRevenue(10 * ONE);

        vm.prank(alice);
        pool.claim();

        assertEq(token.balanceOf(alice), 907 * ONE);
        assertEq(pool.rewards(alice), 0);
    }

    function testClaimAaveRewardsRequiresControllerAndAssets() public {
        vm.expectRevert(bytes("NO_CONTROLLER"));
        pool.claimAaveRewards();

        MockRewardsController controller = new MockRewardsController();
        pool.setRewardsController(address(controller));

        vm.expectRevert(bytes("NO_ASSETS"));
        pool.claimAaveRewards();
    }

    function testClaimAaveRewardsReturnsData() public {
        MockRewardsController controller = new MockRewardsController();
        pool.setRewardsController(address(controller));

        address[] memory assets = new address[](1);
        assets[0] = address(token);
        pool.setRewardAssets(assets);

        (address[] memory rewardsList, uint256[] memory amounts) = pool.claimAaveRewards();
        assertEq(rewardsList.length, 1);
        assertEq(amounts.length, 1);
        assertEq(rewardsList[0], address(0xBEEF));
        assertEq(amounts[0], 123);
    }

    function testOwnerSetters() public {
        vm.prank(alice);
        vm.expectRevert();
        pool.setGovernanceTreasury(alice);

        pool.setGovernanceTreasury(alice);
        assertEq(pool.governanceTreasury(), alice);
    }
}
