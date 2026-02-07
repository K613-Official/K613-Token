// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {RewardsDistributor} from "../src/staking/RewardsDistributor.sol";
import {xK613} from "../src/token/xK613.sol";

contract RewardsDistributorTest is Test {
    xK613 private token;
    RewardsDistributor private distributor;

    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);

    uint256 private constant ONE = 1e18;

    function setUp() public {
        token = new xK613(address(this));
        distributor = new RewardsDistributor(address(token));
        distributor.setStaking(address(this));
        token.setTransferWhitelist(address(distributor), true);

        token.mint(alice, 1_000 * ONE);
        token.mint(bob, 1_000 * ONE);

        vm.prank(alice);
        token.approve(address(distributor), type(uint256).max);
        vm.prank(bob);
        token.approve(address(distributor), type(uint256).max);
    }

    function testConstructorRevertsOnZero() public {
        vm.expectRevert(RewardsDistributor.ZeroAddress.selector);
        new RewardsDistributor(address(0));
    }

    function testDepositUpdatesBalances() public {
        vm.prank(alice);
        distributor.deposit(100 * ONE);

        assertEq(distributor.totalDeposits(), 100 * ONE);
        assertEq(distributor.balanceOf(alice), 100 * ONE);
        assertEq(token.balanceOf(alice), 900 * ONE);
    }

    function testDepositZeroReverts() public {
        vm.expectRevert(RewardsDistributor.ZeroAmount.selector);
        vm.prank(alice);
        distributor.deposit(0);
    }

    function testWithdrawUpdatesBalances() public {
        vm.prank(alice);
        distributor.deposit(100 * ONE);

        vm.prank(alice);
        distributor.withdraw(40 * ONE);

        assertEq(distributor.totalDeposits(), 60 * ONE);
        assertEq(distributor.balanceOf(alice), 60 * ONE);
        assertEq(token.balanceOf(alice), 940 * ONE);
    }

    function testWithdrawRevertsOnInvalidAmount() public {
        vm.expectRevert(RewardsDistributor.ZeroAmount.selector);
        vm.prank(alice);
        distributor.withdraw(0);

        vm.prank(alice);
        distributor.deposit(10 * ONE);
        vm.expectRevert(RewardsDistributor.InsufficientBalance.selector);
        vm.prank(alice);
        distributor.withdraw(20 * ONE);
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

    function testNotifyRewardDistributesAfterDeposit() public {
        token.mint(address(distributor), 10 * ONE);
        distributor.notifyReward(10 * ONE);
        assertEq(distributor.pendingRewards(), 10 * ONE);

        vm.prank(alice);
        distributor.deposit(100 * ONE);

        vm.prank(alice);
        distributor.claim();

        assertEq(token.balanceOf(alice), 910 * ONE);
        assertEq(distributor.pendingRewards(), 0);
    }

    function testClaimTransfersReward() public {
        vm.prank(alice);
        distributor.deposit(100 * ONE);

        token.mint(address(distributor), 10 * ONE);
        distributor.notifyReward(10 * ONE);

        vm.prank(alice);
        distributor.claim();

        assertEq(token.balanceOf(alice), 910 * ONE);
        assertEq(distributor.userPendingRewards(alice), 0);
    }
}
