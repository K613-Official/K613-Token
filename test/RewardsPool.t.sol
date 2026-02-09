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
        token.setRewardsDistributor(address(distributor));
        token.setTransferWhitelist(address(distributor), true);

        token.mint(alice, 1_000 * ONE);
        token.mint(bob, 1_000 * ONE);
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

        uint256 aliceShare = (1_000 * ONE * 10 * ONE) / (2_000 * ONE + 10 * ONE);
        assertApproxEqAbs(aliceAfter - aliceBefore, aliceShare, 1000);
        assertEq(distributor.pendingRewards(), 0);
    }

    function testClaimTransfersReward() public {
        token.mint(address(distributor), 10 * ONE);
        distributor.notifyReward(10 * ONE);

        vm.prank(alice);
        distributor.claim();

        uint256 aliceShare = (1_000 * ONE * 10 * ONE) / (2_000 * ONE + 10 * ONE);
        assertApproxEqAbs(token.balanceOf(alice), 1_000 * ONE + aliceShare, 1000);
        assertEq(distributor.userPendingRewards(alice), 0);
    }

    function testPendingRewardsOf() public {
        token.mint(address(distributor), 10 * ONE);
        distributor.notifyReward(10 * ONE);

        uint256 aliceShare = (1_000 * ONE * 10 * ONE) / (2_000 * ONE + 10 * ONE);
        assertApproxEqAbs(distributor.pendingRewardsOf(alice), aliceShare, 1000);
        assertApproxEqAbs(distributor.pendingRewardsOf(bob), aliceShare, 1000);
    }
}
