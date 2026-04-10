// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {K613} from "../src/token/K613.sol";

contract K613Test is Test {
    K613 private token;

    address private owner = address(this);
    address private minter = address(0xBEEF);
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);

    function setUp() public {
        token = new K613(minter);
    }

    /// @notice testConstructorSetsMinter: Constructor sets minter and grants DEFAULT_ADMIN_ROLE to deployer.
    function testConstructorSetsMinter() public view {
        assertEq(token.minter(), minter);
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), owner));
    }

    /// @notice testSetMinterOnlyOwner: setMinter from non-admin reverts; admin can set new minter.
    function testSetMinterOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        token.setMinter(alice);

        token.setMinter(alice);
        assertEq(token.minter(), alice);
    }

    /// @notice testSetMinterRejectsZero: setMinter(address(0)) reverts with ZeroAddress.
    function testSetMinterRejectsZero() public {
        vm.expectRevert(K613.ZeroAddress.selector);
        token.setMinter(address(0));
    }

    /// @notice testMintOnlyMinter: mint from non-minter reverts with OnlyMinter; minter can mint and balance/totalSupply update.
    function testMintOnlyMinter() public {
        vm.prank(alice);
        vm.expectRevert(K613.OnlyMinter.selector);
        token.mint(alice, 1e18);

        vm.prank(minter);
        token.mint(alice, 2e18);
        assertEq(token.balanceOf(alice), 2e18);
        assertEq(token.totalSupply(), 2e18);
    }

    /// @notice testBurnOnlyMinter: burnFrom from non-minter reverts with OnlyMinter; minter with allowance can burn and balance/totalSupply update.
    function testBurnOnlyMinter() public {
        vm.prank(minter);
        token.mint(alice, 3e18);

        vm.prank(alice);
        vm.expectRevert(K613.OnlyMinter.selector);
        token.burnFrom(alice, 1e18);

        // grant allowance to minter for burnFrom
        vm.prank(alice);
        token.approve(minter, 3e18);

        vm.prank(minter);
        token.burnFrom(alice, 1e18);
        assertEq(token.balanceOf(alice), 2e18);
        assertEq(token.totalSupply(), 2e18);
    }

    /// @notice testTransfer_PauseBlocks: When paused, transfer reverts (generic revert from Pausable).
    function testTransfer_PauseBlocks() public {
        vm.prank(minter);
        token.mint(alice, 2e18);
        token.pause();
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 1e18);
    }

    /// @notice testConstructorZeroMinterReverts: constructor reverts with ZeroAddress when initial minter is zero.
    function testConstructorZeroMinterReverts() public {
        vm.expectRevert(K613.ZeroAddress.selector);
        new K613(address(0));
    }

    /// @notice testPauseUnpauseOnlyPauser: pause/unpause are restricted to PAUSER_ROLE.
    function testPauseUnpauseOnlyPauser() public {
        vm.prank(alice);
        vm.expectRevert();
        token.pause();

        token.pause();

        vm.prank(alice);
        vm.expectRevert();
        token.unpause();
    }

    /// @notice testUnpauseRestoresTransfer: transfer works again after unpause.
    function testUnpauseRestoresTransfer() public {
        vm.prank(minter);
        token.mint(alice, 2e18);
        token.pause();

        token.unpause();

        vm.prank(alice);
        token.transfer(bob, 1e18);
        assertEq(token.balanceOf(alice), 1e18);
        assertEq(token.balanceOf(bob), 1e18);
    }

    /// @notice testBurnFromRevertsOnInsufficientAllowance: burnFrom reverts when allowance is lower than amount.
    function testBurnFromRevertsOnInsufficientAllowance() public {
        vm.prank(minter);
        token.mint(alice, 3e18);

        vm.prank(alice);
        token.approve(minter, 1e18);

        vm.prank(minter);
        vm.expectRevert(K613.BurnAmountExceedsAllowance.selector);
        token.burnFrom(alice, 2e18);
    }

    /// @notice testBurnFromSpendsAllowance: successful burnFrom decreases allowance.
    function testBurnFromSpendsAllowance() public {
        vm.prank(minter);
        token.mint(alice, 3e18);

        vm.prank(alice);
        token.approve(minter, 3e18);

        vm.prank(minter);
        token.burnFrom(alice, 1e18);

        assertEq(token.allowance(alice, minter), 2e18);
    }

    /// @notice testSetMinterRevokesOldMinterAndGrantsNew: old minter loses rights, new minter gains rights.
    function testSetMinterRevokesOldMinterAndGrantsNew() public {
        token.setMinter(alice);

        vm.prank(minter);
        vm.expectRevert(K613.OnlyMinter.selector);
        token.mint(bob, 1e18);

        vm.prank(alice);
        token.mint(bob, 2e18);
        assertEq(token.balanceOf(bob), 2e18);
    }

    /// @notice testMintAndBurnBlockedWhenPaused: mint and burnFrom revert while token is paused.
    function testMintAndBurnBlockedWhenPaused() public {
        token.pause();

        vm.prank(minter);
        vm.expectRevert();
        token.mint(alice, 1e18);

        vm.prank(minter);
        vm.expectRevert();
        token.burnFrom(alice, 1e18);
    }
}
