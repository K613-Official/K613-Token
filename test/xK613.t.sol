// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {xK613} from "../src/token/xK613.sol";

contract xK613Test is Test {
    xK613 private token;

    address private owner = address(this);
    address private minter = address(0xBEEF);
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);

    function setUp() public {
        token = new xK613(minter);
    }

    function test_Transfer_NonWhitelistedReverts() public {
        vm.prank(minter);
        token.mint(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(xK613.TransfersDisabled.selector);
        token.transfer(bob, 1e18);
    }

    function test_Transfer_WhitelistedSucceeds() public {
        vm.prank(minter);
        token.mint(alice, 1e18);
        token.setTransferWhitelist(alice, true);
        token.setTransferWhitelist(bob, true);
        vm.prank(alice);
        token.transfer(bob, 1e18);
        assertEq(token.balanceOf(bob), 1e18);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_Pause_BlocksTransfer() public {
        vm.prank(minter);
        token.mint(alice, 1e18);
        token.setTransferWhitelist(alice, true);
        token.setTransferWhitelist(bob, true);
        token.pause();
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 1e18);
    }

    function test_BurnFrom_OnlyMinter() public {
        vm.prank(minter);
        token.mint(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(xK613.OnlyMinter.selector);
        token.burnFrom(alice, 1e18);
    }

    function test_Constructor_ZeroMinterReverts() public {
        vm.expectRevert(xK613.ZeroAddress.selector);
        new xK613(address(0));
    }

    function test_SetMinter_OnlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        token.setMinter(alice);
    }

    function test_SetTransferWhitelist_OnlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        token.setTransferWhitelist(alice, true);
    }
}
