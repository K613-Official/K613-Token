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

    /// @notice test_SetMinter_SuccessAndZeroRevert: admin can set minter, zero address reverts.
    function test_SetMinter_SuccessAndZeroRevert() public {
        vm.expectRevert(xK613.ZeroAddress.selector);
        token.setMinter(address(0));

        token.setMinter(alice);
        assertEq(token.minter(), alice);
    }

    /// @notice test_SetMinter_RevokesOldAndGrantsNew: old minter cannot mint after rotation, new minter can.
    function test_SetMinter_RevokesOldAndGrantsNew() public {
        token.setMinter(alice);

        vm.prank(minter);
        vm.expectRevert(xK613.OnlyMinter.selector);
        token.mint(bob, 1e18);

        vm.prank(alice);
        token.mint(bob, 1e18);
        assertEq(token.balanceOf(bob), 1e18);
    }

    /// @notice test_SetTransferWhitelist_ZeroAddressReverts: zero address cannot be whitelisted.
    function test_SetTransferWhitelist_ZeroAddressReverts() public {
        vm.expectRevert(xK613.ZeroAddress.selector);
        token.setTransferWhitelist(address(0), true);
    }

    /// @notice test_Transfer_OnlySenderWhitelistedSucceeds: transfer succeeds when sender is whitelisted.
    function test_Transfer_OnlySenderWhitelistedSucceeds() public {
        vm.prank(minter);
        token.mint(alice, 1e18);
        token.setTransferWhitelist(alice, true);

        vm.prank(alice);
        token.transfer(bob, 1e18);
        assertEq(token.balanceOf(bob), 1e18);
    }

    /// @notice test_Transfer_OnlyRecipientWhitelistedSucceeds: transfer succeeds when recipient is whitelisted.
    function test_Transfer_OnlyRecipientWhitelistedSucceeds() public {
        vm.prank(minter);
        token.mint(alice, 1e18);
        token.setTransferWhitelist(bob, true);

        vm.prank(alice);
        token.transfer(bob, 1e18);
        assertEq(token.balanceOf(bob), 1e18);
    }

    /// @notice test_Transfer_WhitelistDisabledAgainReverts: transfer reverts after whitelist flag is removed.
    function test_Transfer_WhitelistDisabledAgainReverts() public {
        vm.prank(minter);
        token.mint(alice, 1e18);
        token.setTransferWhitelist(alice, true);
        token.setTransferWhitelist(alice, false);

        vm.prank(alice);
        vm.expectRevert(xK613.TransfersDisabled.selector);
        token.transfer(bob, 1e18);
    }

    /// @notice test_BurnFrom_ByMinter_Succeeds: minter can burn and supply decreases.
    function test_BurnFrom_ByMinter_Succeeds() public {
        vm.prank(minter);
        token.mint(alice, 2e18);

        vm.prank(minter);
        token.burnFrom(alice, 1e18);

        assertEq(token.balanceOf(alice), 1e18);
        assertEq(token.totalSupply(), 1e18);
    }

    /// @notice test_BurnFrom_RevertsOnInsufficientBalance: burnFrom reverts when burn amount exceeds holder balance.
    function test_BurnFrom_RevertsOnInsufficientBalance() public {
        vm.prank(minter);
        token.mint(alice, 1e18);

        vm.prank(minter);
        vm.expectRevert();
        token.burnFrom(alice, 2e18);
    }

    /// @notice test_Pause_Unpause_AccessAndRecovery: only pauser can toggle pause and transfer recovers after unpause.
    function test_Pause_Unpause_AccessAndRecovery() public {
        vm.prank(minter);
        token.mint(alice, 1e18);
        token.setTransferWhitelist(alice, true);
        token.setTransferWhitelist(bob, true);

        vm.prank(alice);
        vm.expectRevert();
        token.pause();

        token.pause();

        vm.prank(alice);
        vm.expectRevert();
        token.unpause();

        token.unpause();

        vm.prank(alice);
        token.transfer(bob, 1e18);
        assertEq(token.balanceOf(bob), 1e18);
    }

    /// @notice test_MintAndBurn_BlockedWhenPaused: mint and burnFrom revert when contract is paused.
    function test_MintAndBurn_BlockedWhenPaused() public {
        token.pause();

        vm.prank(minter);
        vm.expectRevert();
        token.mint(alice, 1e18);

        vm.prank(minter);
        vm.expectRevert();
        token.burnFrom(alice, 1e18);
    }
}
