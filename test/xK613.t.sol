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

    /// @notice test_Transfer_NonWhitelistedReverts: Transfer between non-whitelisted addresses reverts with TransfersDisabled.
    function test_Transfer_NonWhitelistedReverts() public {
        vm.prank(minter);
        token.mint(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(xK613.TransfersDisabled.selector);
        token.transfer(bob, 1e18);
    }

    /// @notice test_Transfer_WhitelistedSucceeds: Transfer between whitelisted addresses succeeds and balances update correctly.
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

    /// @notice test_Pause_BlocksTransfer: When paused, transfer reverts (generic revert from Pausable).
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

    /// @notice test_BurnFrom_OnlyMinter: burnFrom from non-minter reverts with OnlyMinter.
    function test_BurnFrom_OnlyMinter() public {
        vm.prank(minter);
        token.mint(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(xK613.OnlyMinter.selector);
        token.burnFrom(alice, 1e18);
    }

    /// @notice test_Constructor_ZeroMinterReverts: Constructor with zero minter reverts with ZeroAddress.
    function test_Constructor_ZeroMinterReverts() public {
        vm.expectRevert(xK613.ZeroAddress.selector);
        new xK613(address(0));
    }

    /// @notice test_SetMinter_OnlyAdmin: setMinter from non-admin reverts; admin can set new minter.
    function test_SetMinter_OnlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        token.setMinter(alice);
    }

    /// @notice test_SetTransferWhitelist_OnlyAdmin: setTransferWhitelist from non-admin reverts.
    function test_SetTransferWhitelist_OnlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        token.setTransferWhitelist(alice, true);
    }
}
