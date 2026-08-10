// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Staking} from "../src/staking/Staking.sol";
import {xK613} from "../src/token/xK613.sol";
import {StakingV2} from "../src/staking/StakingV2.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Форк мейннета: доказывает, что после катовера заявки в StakingV1 не «дозреют».
contract V1StrandedTest is Test {
    Staking private v1 = Staking(0x36451F6b4c06916aafd16359CCf99eB1f584DB0b);
    xK613 private xk = xK613(0x9064d55A8A8473fA39c41A16492Fa1094Eb4E8b5);
    address private user = 0xB1Ad60a07b284e56f6A825C6d1E860D4B00508DD;

    function setUp() public {
        vm.createSelectFork(vm.envString("MONAD_RPC"));
    }

    function test_ExitRevertsForeverEvenAfterLockExpires() public {
        (uint256 amount, uint256 startedAt) = v1.exitRequestAt(user, 0);
        emit log_named_decimal_uint("queued xK613", amount, 18);

        // Перематываем далеко за 90-дневный лок.
        vm.warp(startedAt + v1.lockDuration() + 30 days);

        vm.prank(user);
        vm.expectRevert(xK613.OnlyMinter.selector);
        v1.exit(0);
    }

    function test_InstantExitAlsoDead() public {
        vm.prank(user);
        vm.expectRevert(xK613.OnlyMinter.selector);
        v1.instantExit(0);
    }

    function test_CancelExitStillWorks_AndReturnsTokens() public {
        (uint256 amount,) = v1.exitRequestAt(user, 0);
        uint256 before = xk.balanceOf(user);

        vm.prank(user);
        v1.cancelExit(0);

        assertEq(xk.balanceOf(user) - before, amount, "xK613 returned to wallet");
        assertEq(v1.exitQueueLength(user), 0, "queue empty");
    }

    /// @notice The question that actually matters: is the money there? The cutover seeded
    ///         StakingV2 with K613 equal to the whole outstanding xK613 supply, and the tokens
    ///         sitting in V1's escrow are part of that supply. So the funds are covered — what is
    ///         needed is only the mechanical step of getting them out of escrow first. This walks
    ///         the entire path on forked mainnet state and checks the user ends up with real K613.
    function test_FullRecoveryPath_CancelInV1_ThenExitThroughV2() public {
        StakingV2 v2 = StakingV2(0x5A3DA7644c25F0A74DCb0bA13ae38214D8856415);
        IERC20 k613 = IERC20(0xb09582631336068d4B0089d943f40CbF46dE5189);

        // Инвариант после катовера: каждый выпущенный xK613 обеспечен в V2.
        assertEq(xk.totalSupply(), v2.totalBacking(), "supply == backing");

        (uint256 amount,) = v1.exitRequestAt(user, 0);
        uint256 k613Before = k613.balanceOf(user);

        vm.startPrank(user);
        v1.cancelExit(0);                       // 1. забрать xK613 из мёртвого эскроу V1
        xk.approve(address(v2), amount);
        v2.initiateExit(amount);                // 2. встать в очередь уже в V2
        vm.stopPrank();

        (, uint256 startedAt) = v2.exitRequestAt(user, 0);
        vm.warp(startedAt + v2.lockDuration()); // 3. дождаться 90 дней

        vm.prank(user);
        v2.exit(0);                             // 4. выйти

        assertEq(k613.balanceOf(user) - k613Before, amount, "got full K613 1:1, no penalty");
        emit log_named_decimal_uint("recovered K613", amount, 18);
    }
}
