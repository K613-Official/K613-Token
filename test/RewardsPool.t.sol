// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {RewardsDistributor} from "../src/staking/RewardsDistributor.sol";
import {xK613} from "../src/token/xK613.sol";
import {K613} from "../src/token/K613.sol";
import {Staking} from "../src/staking/Staking.sol";

contract RewardsDistributorTest is Test {
    xK613 private token;
    RewardsDistributor private distributor;

    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);

    uint256 private constant ONE = 1e18;

    function setUp() public {
        token = new xK613(address(this));
        distributor = new RewardsDistributor(address(token));
        distributor.setStaking(address(0)); // No staking in unit tests - no claim block
        distributor.grantRole(distributor.REWARDS_NOTIFIER_ROLE(), address(this));
        token.setTransferWhitelist(address(distributor), true);

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

    function testConstructorRevertsOnZero() public {
        vm.expectRevert(RewardsDistributor.ZeroAddress.selector);
        new RewardsDistributor(address(0));
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

    function testNotifyRewardDistributesToHolders() public {
        token.mint(address(distributor), 10 * ONE);
        distributor.notifyReward(10 * ONE);

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        distributor.claim();
        uint256 aliceAfter = token.balanceOf(alice);

        uint256 aliceShare = (1_000 * ONE * 10 * ONE) / (2_000 * ONE);
        assertApproxEqAbs(aliceAfter - aliceBefore, aliceShare, 1000);
        assertEq(distributor.pendingRewards(), 0);
    }

    function testClaimTransfersReward() public {
        token.mint(address(distributor), 10 * ONE);
        distributor.notifyReward(10 * ONE);

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        distributor.claim();
        uint256 aliceAfter = token.balanceOf(alice);

        uint256 aliceShare = (1_000 * ONE * 10 * ONE) / (2_000 * ONE);
        assertApproxEqAbs(aliceAfter - aliceBefore, aliceShare, 1000);
        assertEq(distributor.pendingRewardsOf(alice), 0);
    }

    function testPendingRewardsOf() public {
        token.mint(address(distributor), 10 * ONE);
        distributor.notifyReward(10 * ONE);

        uint256 aliceShare = (1_000 * ONE * 10 * ONE) / (2_000 * ONE);
        assertApproxEqAbs(distributor.pendingRewardsOf(alice), aliceShare, 1000);
        assertApproxEqAbs(distributor.pendingRewardsOf(bob), aliceShare, 1000);
    }

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

    function testWithdrawInsufficientReverts() public {
        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.InsufficientBalance.selector);
        distributor.withdraw(2_000 * ONE);
    }

    function testDeposit() public {
        token.mint(alice, 500 * ONE);
        vm.prank(alice);
        token.approve(address(distributor), 500 * ONE);
        vm.prank(alice);
        distributor.deposit(500 * ONE);

        assertEq(distributor.balanceOf(alice), 1_500 * ONE);
        assertEq(distributor.totalDeposits(), 2_500 * ONE);
    }

    function testClaimBlockedWhenExitVestingActive() public {
        // Deploy Staking for integration test
        K613 k613 = new K613(address(this));
        Staking staking = new Staking(address(k613), address(token), 7 days, 5_000);
        token.setMinter(address(staking));
        token.grantRole(token.MINTER_ROLE(), address(this)); // Keep minter for notifyReward mint
        token.setTransferWhitelist(address(staking), true);
        distributor.setStaking(address(staking));
        k613.mint(alice, 1_000 * ONE);

        // Alice stakes, deposits in RD, gets rewards
        vm.startPrank(alice);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        token.approve(address(distributor), 1_000 * ONE);
        distributor.deposit(1_000 * ONE);
        vm.stopPrank();

        token.mint(address(distributor), 10 * ONE);
        distributor.notifyReward(10 * ONE);

        // Alice withdraws from RD (to get xK613 for initiateExit), then initiates exit
        vm.prank(alice);
        distributor.withdraw(1_000 * ONE);
        vm.prank(alice);
        token.approve(address(staking), 1_000 * ONE);
        vm.prank(alice);
        staking.initiateExit(1_000 * ONE);

        // Alice has unclaimed rewards but exit vesting active - claim blocked
        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.ExitVestingActive.selector);
        distributor.claim();
        assertEq(distributor.pendingRewardsOf(alice), 0);
    }
}
